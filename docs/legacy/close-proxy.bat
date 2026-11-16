@echo off
REM Original 6-line version, kept for comparison.
REM Superseded by src\proxy-toggle.ps1; do not use this for real work.
title Close Proxy
set "key=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
reg add "%key%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
echo [OK] System proxy has been disabled.
pause
