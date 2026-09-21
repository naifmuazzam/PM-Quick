@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0PM-Quick.ps1"
pause
