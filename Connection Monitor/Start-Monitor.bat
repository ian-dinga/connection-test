@echo off
echo Starting the Connection Monitor...
echo.

schtasks /Change /TN "Connection Monitor" /ENABLE >nul 2>&1
schtasks /Run /TN "Connection Monitor" >nul 2>&1

echo Done. The Connection Monitor is now running in the background and will
echo also start automatically the next time this PC restarts.
echo.
pause
