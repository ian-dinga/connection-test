@echo off
set "MONITOR_DIR=C:\Users\PG1\Documents\Passive Monitor"

echo Stopping the Passive Connection Monitor...
echo.

echo stop > "%MONITOR_DIR%\STOP.flag"

echo Waiting up to 35 seconds for it to shut down cleanly...
timeout /t 35 /nobreak >nul

schtasks /Change /TN "Passive Connection Monitor" /DISABLE >nul 2>&1

echo.
echo Done. The Passive Connection Monitor has been stopped and will not run
echo again until someone re-enables it (see Start-PassiveMonitor.bat).
echo.
pause
