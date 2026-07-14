# Connection Test

Two PowerShell watchdogs for a Windows control-box PC that talks to a USB-serial (CH340) hardware device via a "Host Service" process. Both detect when the connection has genuinely failed (not just a brief blip) and auto-restart the machine to recover, with safeguards against reboot loops.

## Connection Monitor (active)

Every 30 seconds, opens the CH340 device's COM port directly and sends a probe command. Classifies each check as healthy (device responds, or the port is in use by the Host Service) or fault.

- If a fault persists for 5 minutes straight, force-restarts the computer and logs the exact time-to-failure.
- On the reboot that follows, waits up to 5 minutes to confirm the device reconnects. If it doesn't, a consecutive-failure counter increments.
- After 3 consecutive reboots that fail to reconnect the device, auto-reboot halts entirely (to avoid a runaway reboot loop) and just logs an alert for manual intervention.
- A manual/external restart always resets the counter.
- Can be stopped cleanly at any time by dropping a `STOP.flag` file in the working directory (see `Stop-Monitor.bat`) — checked at the top of every loop, so it never reboots after a stop was requested.

## Passive Monitor (log-based)

A non-invasive alternative that never touches the COM port itself — it only tails the Host Service's own log file, the same way `tail -f` would. It infers health from:

1. A `Connection Manager State: "Disconnected"` line written by the Host Service, or
2. Total log silence beyond a threshold (the Host Service normally writes routine lines every ~30s even when idle, so extended silence means the whole process is hung, not just the device).

Same 5-minute grace period, reboot-recovery check, and consecutive-failure cap as the active monitor.

## Files

- `connection-monitor.ps1` / `passive-monitor.ps1` — the two watchdog scripts
- `Setup-Monitor.bat`, `Setup-PassiveMonitor.bat` — register the script to run at startup via Task Scheduler (no password stored — runs as "when logged on")
- `Setup-AppAutoLaunch.bat` — configures the monitored app to auto-launch
- `Start-*.bat` / `Stop-*.bat` — manually start a monitor, or request a clean stop via `STOP.flag`

## Notes

Both scripts assume a Windows PC with a device matching `*CH340*` in Device Manager, and write their logs/state files to a local working directory alongside the script.
