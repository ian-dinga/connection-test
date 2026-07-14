# Control Box Connection Monitor with Auto-Recovery + Time-to-Failure Tracking
#
# Every 30 seconds, checks the CH340 device's PnP status and attempts to open/
# query the COM port. Classifies each check as HEALTHY (device responded, or
# port is in use by the Host Service) or FAULT (no response, open error, or
# device missing entirely).
#
# If a fault persists for longer than $graceMinutes (not just a one-off blip),
# it logs the exact elapsed time since the device was last known healthy --
# this is your time-to-failure data point -- then force-restarts the computer.
#
# Since this script is set to run "At startup" in Task Scheduler, it relaunches
# after the reboot and checks, within $recoveryWindowMinutes, whether the device
# comes back healthy:
#   - If yes: the reboot worked. Consecutive-failure counter resets to 0, and
#     normal monitoring resumes -- this is expected to repeat every ~15-20 min
#     indefinitely without ever hitting a cap.
#   - If no: the reboot didn't fix anything. Consecutive-failure counter goes
#     up by 1. After $maxConsecutiveFailures reboots IN A ROW that each fail
#     to reconnect, auto-reboot stops entirely and just logs an alert --
#     protects against a runaway reboot loop when reboots genuinely aren't
#     helping, without penalizing the normal fault-every-15-min pattern.
# A manual/external restart (one this script didn't trigger itself) always
# gives the counter a fresh start.

$baseDir                  = "C:\Users\PG1\Documents\Connection Monitor"
$logPath                  = Join-Path $baseDir "connection-monitor.log"
$consecutiveFailPath      = Join-Path $baseDir "consecutive-fail-count.txt"
$awaitingRecoveryFlagPath = Join-Path $baseDir "awaiting-recovery.flag"
$stopFlagPath             = Join-Path $baseDir "STOP.flag"
$deviceMatch              = "*CH340*"   # matches Windows' "USB-SERIAL CH340 (COMx)" device name
$pollSeconds              = 30
$graceMinutes             = 5   # how long a fault must persist before we decide to reboot
$recoveryWindowMinutes    = 5   # how long to wait after a self-triggered reboot for the device to come back
$maxConsecutiveFailures   = 3   # stop auto-rebooting after this many reboots IN A ROW fail to reconnect

New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $message" | Out-File -FilePath $logPath -Append -Encoding utf8
}

# Anyone (technical or not) can stop this cleanly -- with no risk of a
# mid-check reboot -- by creating STOP.flag in this same folder (the
# Stop-Monitor.bat helper does this). Checked at the top of every loop and during the post-reboot
# recovery wait, so it never leaves the log mid-line or triggers a reboot after
# a stop was requested.
function Test-StopRequested {
    if (Test-Path $stopFlagPath) {
        Write-Log "=== Monitor stopped via STOP.flag -- clean shutdown, no reboot will occur ==="
        Remove-Item $stopFlagPath -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Get-ConsecutiveFailCount {
    if (-not (Test-Path $consecutiveFailPath)) { return 0 }
    try { return [int](Get-Content $consecutiveFailPath -Raw).Trim() } catch { return 0 }
}

function Set-ConsecutiveFailCount($n) {
    Set-Content -Path $consecutiveFailPath -Value $n
}

# Returns $true if the device is healthy (responded, or in use by another
# process), $false if it's in a fault state. Also writes the detailed line.
function Test-DeviceHealthy {
    try {
        $device = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -like $deviceMatch }

        if (-not $device) {
            Write-Log "PNP: NOT FOUND -- device missing from Windows enumeration entirely"
            return $false
        }

        $status  = $device.Status
        $name    = $device.Name
        $comPort = if ($name -match '\((COM\d+)\)') { $matches[1] } else { $null }
        Write-Log "PNP: Status=$status  Name='$name'"

        if (-not $comPort) { return $false }

        try {
            $port = New-Object System.IO.Ports.SerialPort $comPort, 115200
            $port.ReadTimeout  = 1000
            $port.WriteTimeout = 1000
            $port.Open()
            try {
                $port.DiscardInBuffer()
                $port.Write("dg`r")
                Start-Sleep -Milliseconds 300
                if ($port.BytesToRead -gt 0) {
                    $resp = $port.ReadExisting()
                    Write-Log "PORT $comPort : OPENED (was free) -- device responded: '$($resp.Trim())'"
                    return $true
                } else {
                    Write-Log "PORT $comPort : OPENED (was free) -- NO RESPONSE from device (port free but device unresponsive)"
                    return $false
                }
            } finally {
                $port.Close()
            }
        } catch [UnauthorizedAccessException] {
            Write-Log "PORT $comPort : in use by another process (expected during normal operation -- Host Service holds it)"
            return $true
        } catch {
            Write-Log "PORT $comPort : ERROR opening -- $($_.Exception.Message)"
            return $false
        }
    } catch {
        Write-Log "MONITOR ERROR: $($_.Exception.Message)"
        return $false
    }
}

# ---- Startup: figure out whether this boot follows a self-triggered reboot ----

$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Write-Log "=== Monitor started. System boot time: $bootTime ==="

# Tracks when the CURRENT healthy streak began -- set once here, and only
# reset when transitioning from fault back to healthy. This is what lets us
# report a true "how long did it stay healthy before this fault" duration,
# rather than just the gap since the last 30-second poll.
$healthyStreakStart = $bootTime

$consecutiveFails = Get-ConsecutiveFailCount
$autoRebootHalted = $consecutiveFails -ge $maxConsecutiveFailures

if (Test-Path $awaitingRecoveryFlagPath) {
    Write-Log "Post-reboot startup detected (this script triggered the last reboot). Checking for recovery within $recoveryWindowMinutes min..."
    Remove-Item $awaitingRecoveryFlagPath -Force -ErrorAction SilentlyContinue

    $recoveryDeadline = (Get-Date).AddMinutes($recoveryWindowMinutes)
    $recovered = $false
    while ((Get-Date) -lt $recoveryDeadline) {
        if (Test-StopRequested) { exit }
        if (Test-DeviceHealthy) { $recovered = $true; break }
        Start-Sleep -Seconds $pollSeconds
    }

    if ($recovered) {
        $consecutiveFails = 0
        Set-ConsecutiveFailCount 0
        $autoRebootHalted = $false
        $healthyStreakStart = Get-Date
        Write-Log "REBOOT SUCCEEDED -- device reconnected. Consecutive-failure counter reset to 0."
    } else {
        $consecutiveFails++
        Set-ConsecutiveFailCount $consecutiveFails
        Write-Log "REBOOT FAILED TO RECONNECT device within $recoveryWindowMinutes min (consecutive failure #$consecutiveFails of $maxConsecutiveFailures)."
        if ($consecutiveFails -ge $maxConsecutiveFailures) {
            $autoRebootHalted = $true
            Write-Log "STOPPING AUTO-REBOOT: $maxConsecutiveFailures consecutive reboots failed to reconnect. Manual intervention required -- monitoring will continue but will not reboot again until this is reset (delete $consecutiveFailPath, or restart the PC manually)."
        }
    }
} elseif ($autoRebootHalted) {
    # No pending-recovery flag, but we were previously halted -- this must be a
    # manual/external restart, so give auto-recovery a fresh chance.
    Write-Log "External/manual restart detected while previously halted -- resuming auto-recovery, resetting consecutive-failure counter."
    $consecutiveFails = 0
    Set-ConsecutiveFailCount 0
    $autoRebootHalted = $false
}

# ---- Main monitoring loop ----

$lastHealthyTime = Get-Date
$faultStartTime  = $null

while ($true) {
    if (Test-StopRequested) { exit }
    $healthy = Test-DeviceHealthy

    if ($healthy) {
        if ($faultStartTime) {
            $faultDuration = (Get-Date) - $faultStartTime
            Write-Log "RECOVERED ON ITS OWN after $($faultDuration.ToString('mm\m\ ss\s')) -- no reboot was needed."
            $faultStartTime = $null
            $healthyStreakStart = Get-Date
        }
        $lastHealthyTime = Get-Date
    } else {
        if (-not $faultStartTime) {
            $faultStartTime = Get-Date
            $streakLength = $faultStartTime - $healthyStreakStart
            Write-Log ("FAULT DETECTED. MINUTES_HEALTHY_BEFORE_FAULT={0:N1}" -f $streakLength.TotalMinutes)
        } else {
            $sinceFault = (Get-Date) - $faultStartTime
            if ($sinceFault.TotalMinutes -ge $graceMinutes) {
                if ($autoRebootHalted) {
                    Write-Log "Fault confirmed but auto-reboot is halted (consecutive-failure cap reached). Not rebooting -- manual intervention required."
                } else {
                    $totalDowntime = (Get-Date) - $lastHealthyTime
                    Write-Log ("FAULT PERSISTED for {0:N1} min -- confirmed real, not a blip. Total time since last healthy: {1:N1} min. Restarting computer now." -f $sinceFault.TotalMinutes, $totalDowntime.TotalMinutes)
                    New-Item -ItemType File -Path $awaitingRecoveryFlagPath -Force | Out-Null
                    Start-Sleep -Seconds 2
                    Restart-Computer -Force
                    exit
                }
            }
        }
    }

    Start-Sleep -Seconds $pollSeconds
}
