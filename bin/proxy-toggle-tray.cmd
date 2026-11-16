@echo off
setlocal
set "SCRIPT=%~dp0..\src\proxy-toggle.ps1"
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" tray
) else (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" tray
)
exit /b %ERRORLEVEL%
