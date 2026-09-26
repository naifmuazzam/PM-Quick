@echo off
:: Temp-Cleaner - TEMP and Recycle Bin maintenance.
:: This is the only tool in the project that deletes anything.
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0Temp-Cleaner.ps1"
pause
