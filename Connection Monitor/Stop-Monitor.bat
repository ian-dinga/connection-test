@echo off
set "MONITOR_DIR=C:\Users\PG1\Documents\Connection Monitor"

echo Stopping the Connection Monitor...
echo.

REM Tell the running monitor to shut down cleanly on its next check
REM (it logs a clean "stopped" line and will NOT reboot the computer).
echo stop > "%MONITOR_DIR%\STOP.flag"

echo Waiting up to 35 seconds for it to shut down cleanly...
timeout /t 35 /nobreak >nul

REM Prevent it from starting again automatically the next time this PC restarts.
schtasks /Change /TN "Connection Monitor" /DISABLE >nul 2>&1

echo.
echo Done. The Connection Monitor has been stopped and will not run again
echo until someone re-enables it (see Start-Monitor.bat).
echo.
pause
