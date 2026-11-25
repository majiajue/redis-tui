@echo off
rem Runs redis-tui.ps1 with Windows PowerShell for this launch only, without
rem changing the machine's script execution policy.
rem Usage: redis-tui.cmd [host] [port] ["password"]   (recommended: no arguments)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0redis-tui.ps1" %*
if errorlevel 1 pause
