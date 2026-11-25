@echo off
rem Starts redis-tui.sh inside WSL (Ubuntu-22.04), where the official redis-cli is installed.
rem Running the whole script inside WSL is much faster than forwarding every redis-cli
rem call from Windows (about 1 second per call vs. well under a millisecond).
setlocal
for %%I in ("%~dp0.") do set "BINDIR=%%~fI"
wsl.exe -d Ubuntu-22.04 --cd "%BINDIR%" -- bash ./redis-tui.sh %*
if errorlevel 1 pause
endlocal
