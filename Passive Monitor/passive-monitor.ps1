# Passive Log-Based Connection Monitor with Auto-Recovery
#
# Unlike connection-monitor.ps1, this script NEVER touches the COM port. It
# only reads (tails) the Host Service's own log file, the same way you'd
# "tail -f" it. That means it cannot itself act as a keep-alive -- if the
# device goes idle/asleep on its own, this script will not interfere.
#
# Detection is based on two things confirmed tonight against the real
# Platform log:
#   1. The line   Connection Manager State: "Disconnected"   -- the Host
#      Service's own internal state change, which matched our old port-probe
#      fault detection within 2 seconds.
#   2. Total log silence for $logSilenceThresholdSeconds -- the Host Service
#      writes routine cloud-auth lines roughly every ~30 sec even when
#      completely idle, so an extended gap with NO lines at all (not just no
#      "Disconnected" line) means the whole process is hung, not just the
#      device -- this is the second failure mode we found earlier tonight
#      (82+ min of total log silence).
#
# Either condition is treated as "unhealthy" for a given check. If it
# persists for $graceMinutes straight (not just a one-off blip -- e.g. a
# "Connected" line reappears, or normal logging resumes), the computer is
# restarted, with the same consecutive-failure cap and STOP.flag support as
# the original script so it can't loop forever if reboots stop helping.

$baseDir                  = "C:\Users\PG1\Documents\Passive Monitor"
$logPath                  = Join-Path $baseDir "passive-monitor.log"
$consecutiveFailPath      = Join-Path $baseDir "consecutive-fail-count.txt"
$awaitingRecoveryFlagPath = Join-Path $baseDir "awaiting-recovery.flag"
$stopFlagPath             = Join-Path $baseDir "STOP.flag"

$hostServiceLogDir        = "C:\ProgramData\Platform Golf\logs"   # where the Host Service writes log-YYYYMMDD.log
$pollSeconds              = 30
$logSilenceThresholdSec   = 90    # no lines at all for this long = suspicious (routine chatter normally every ~30s)
$graceMinutes             = 5     # how long the unhealthy condition must persist before we decide to reboot
$recoveryWindowMinutes    = 5     # how long to wait after a self-triggered reboot for logging to look healthy again
$maxConsecutiveFailures   = 3     # stop auto-rebooting after this many reboots IN A ROW fail to fix it

New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $message" | Out-File -FilePath $logPath -Append -Encoding utf8
}

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

# ---- Passive log tailing state ----
# $script:tailPath / $script:tailPos track which file + byte offset we've
# already read up to, so we only ever read NEW content -- never the whole
# log, and never anything that requires locking or interacting with the
# device itself.
$script:tailPath = $null
$script:tailPos  = 0

function Get-TodayLogPath {
    Join-Path $hostServiceLogDir ("log-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
}

# Reads whatever new lines have been appended since the last check (handles
# midnight rollover to a new day's file automatically). Returns an array of
# new lines (may be empty). Opens with ReadWrite sharing so it never
# conflicts with the Host Service, which keeps the file open itself.
function Get-NewLogLines {
    $currentPath = Get-TodayLogPath

    if ($currentPath -ne $script:tailPath) {
        # First run, or the day rolled over -- (re)point at the current file
        # and start from its current end, not from byte 0, so we don't treat
        # its entire existing history as "new" activity.
        $script:tailPath = $currentPath
        $script:tailPos = 0
        if (Test-Path $currentPath) {
            $script:tailPos = (Get-Item $currentPath).Length
        }
        Write-Log "Now tailing: $currentPath (starting at end, offset $($script:tailPos))"
    }

    if (-not (Test-Path $script:tailPath)) {
        return @()
    }

    $len = (Get-Item $script:tailPath).Length
    if ($len -lt $script:tailPos) {
        # File shrank/rotated unexpectedly -- restart from its current end.
        $script:tailPos = 0
    }
    if ($len -eq $script:tailPos) {
        return @()
    }

    $fs = [System.IO.File]::Open($script:tailPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fs.Seek($script:tailPos, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($fs)
        $text = $reader.ReadToEnd()
        $script:tailPos = $fs.Position
    } finally {
        $fs.Close()
    }

    if ([string]::IsNullOrEmpty($text)) { return @() }
    return $text -split "`r?`n" | Where-Object { $_.Length -gt 0 }
}

# ---- Startup ----

Write-Log "=== Passive monitor started. Watching $hostServiceLogDir for log-YYYYMMDD.log (never opens the COM port) ==="

$lastLogLineTime    = Get-Date   # updated every time ANY new line is seen -- our "is the process even alive" heartbeat
$connState          = "Unknown"  # tracks the most recent Connection Manager State line seen
$healthyStreakStart = Get-Date
$lastHealthyTime    = Get-Date
$faultStartTime     = $null

$consecutiveFails = Get-ConsecutiveFailCount
$autoRebootHalted = $consecutiveFails -ge $maxConsecutiveFailures

# Processes any backlog before the recovery-check / main loop uses it, so the
# very first read after a (re)start doesn't miss lines written in between.
function Update-StateFromNewLines {
    $newLines = Get-NewLogLines
    foreach ($line in $newLines) {
        $script:lastLogLineTime = Get-Date
        if ($line -match 'Connection Manager State:\s*"Disconnected"') {
            if ($script:connState -ne "Disconnected") {
                Write-Log "LOG: Host Service reported Connection Manager State: Disconnected"
            }
            $script:connState = "Disconnected"
        } elseif ($line -match 'Connection Manager State:\s*"Connected"') {
            if ($script:connState -ne "Connected") {
                Write-Log "LOG: Host Service reported Connection Manager State: Connected"
            }
            $script:connState = "Connected"
        }
    }
}

# Healthy = the log is still alive (recent activity) AND the last known
# connection state isn't explicitly "Disconnected". If the log file is
# simply missing (wrong path, not rotated yet, etc.) we do NOT count that as
# a fault -- it likely means $hostServiceLogDir needs a second look, and we
# shouldn't reboot the machine over a misconfigured path.
function Test-LogHealthy {
    Update-StateFromNewLines

    if (-not (Test-Path $script:tailPath)) {
        Write-Log "WARNING: log file not found at $script:tailPath -- check `$hostServiceLogDir. Not treating this as a device fault."
        return $true
    }

    $silence = (Get-Date) - $script:lastLogLineTime
    if ($silence.TotalSeconds -ge $logSilenceThresholdSec) {
        Write-Log ("HEARTBEAT: no log activity for {0:N0}s (>= {1}s threshold) -- Host Service may be hung" -f $silence.TotalSeconds, $logSilenceThresholdSec)
        return $false
    }

    if ($script:connState -eq "Disconnected") {
        return $false
    }

    return $true
}

if (Test-Path $awaitingRecoveryFlagPath) {
    Write-Log "Post-reboot startup detected (this script triggered the last reboot). Checking for recovery within $recoveryWindowMinutes min..."
    Remove-Item $awaitingRecoveryFlagPath -Force -ErrorAction SilentlyContinue
    $lastLogLineTime = Get-Date   # give it a fresh clock -- don't count boot time itself as silence

    $recoveryDeadline = (Get-Date).AddMinutes($recoveryWindowMinutes)
    $recovered = $false
    while ((Get-Date) -lt $recoveryDeadline) {
        if (Test-StopRequested) { exit }
        if (Test-LogHealthy) { $recovered = $true; break }
        Start-Sleep -Seconds $pollSeconds
    }

    if ($recovered) {
        $consecutiveFails = 0
        Set-ConsecutiveFailCount 0
        $autoRebootHalted = $false
        $healthyStreakStart = Get-Date
        Write-Log "REBOOT SUCCEEDED -- logging looks healthy again. Consecutive-failure counter reset to 0."
    } else {
        $consecutiveFails++
        Set-ConsecutiveFailCount $consecutiveFails
        Write-Log "REBOOT FAILED TO RESOLVE the fault within $recoveryWindowMinutes min (consecutive failure #$consecutiveFails of $maxConsecutiveFailures)."
        if ($consecutiveFails -ge $maxConsecutiveFailures) {
            $autoRebootHalted = $true
            Write-Log "STOPPING AUTO-REBOOT: $maxConsecutiveFailures consecutive reboots failed to fix it. Manual intervention required -- monitoring will continue but will not reboot again until this is reset (delete $consecutiveFailPath, or restart the PC manually)."
        }
    }
} elseif ($autoRebootHalted) {
    Write-Log "External/manual restart detected while previously halted -- resuming auto-recovery, resetting consecutive-failure counter."
    $consecutiveFails = 0
    Set-ConsecutiveFailCount 0
    $autoRebootHalted = $false
}

# ---- Main monitoring loop ----

while ($true) {
    if (Test-StopRequested) { exit }
    $healthy = Test-LogHealthy

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
            Write-Log ("FAULT DETECTED (passive/log-based). MINUTES_HEALTHY_BEFORE_FAULT={0:N1}" -f $streakLength.TotalMinutes)
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
