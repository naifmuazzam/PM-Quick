@echo off
setlocal
:: PM-Quick - read-only PC inspection report. This tool deletes nothing.
::
:: Always elevates to Administrator. TPM, disk SMART and several firmware
:: values - including the machine serial - are only readable with elevation,
:: and the report is wrong without them.
::
:: The admin test is done in PowerShell rather than with "net session", which
:: also fails when the Server service is stopped. An already-elevated relaunch
:: would then loop forever, re-elevating itself on every pass.

powershell -NoProfile -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
if errorlevel 1 (
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0PM-Quick.ps1" %*
pause
