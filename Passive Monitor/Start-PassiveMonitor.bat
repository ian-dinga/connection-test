@echo off
echo Starting the Passive Connection Monitor...
echo.

schtasks /Change /TN "Passive Connection Monitor" /ENABLE >nul 2>&1
schtasks /Run /TN "Passive Connection Monitor" >nul 2>&1

echo Done. The Passive Connection Monitor is now running in the background
echo and will also start automatically the next time this PC restarts.
echo.
pause
