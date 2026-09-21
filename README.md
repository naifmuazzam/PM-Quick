# PM Quick Tool

A lightweight Windows preventive maintenance assistant for IT technicians.

## Features

- System information (PC name, BIOS serial, Windows version/build, username)
- IPv4 address detection (all active adapters, no auto-selection)
- CPU usage snapshot
- Memory usage snapshot
- Storage capacity and free space per drive
- SSD/HDD classification and internal/external detection
- SSD health and estimated life (when reliable data is available)
- TEMP directory cleanup
- TEMP-source-only Recycle Bin cleanup

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Administrator privileges (auto-requested by the BAT launcher)

## Usage

Double-click `PM-Quick.bat` to launch.

The BAT launcher automatically requests Administrator privileges. The tool collects system information, displays results, then asks whether to perform cleanup.

## Cleanup Safety

- Cleanup requires explicit Y/N confirmation before any deletion.
- Only User TEMP (`%TEMP%`) and Windows TEMP (`C:\Windows\Temp`) are targeted.
- Recycle Bin cleanup is restricted to items originally deleted from TEMP directories only.
- Non-TEMP and unknown-source Recycle Bin items are skipped.
- Locked/in-use files are skipped (never force-deleted).
- The tool does **not** empty the entire Recycle Bin.

## Network Behavior

- Multiple IPv4 addresses may be displayed if the workstation has more than one active adapter.
- The tool does **not** automatically select an IP for MyERP.
- The technician must manually verify the correct IP in MyERP.
- The tool does **not** modify any network configuration.

## MyERP

- This tool does **not** connect to MyERP.
- This tool does **not** use a MyERP API.
- It is intended to assist the technician with manual PM work.

## Limitations

- SSD Estimated Life may show N/A when reliable wear/life information is unavailable (common with many SATA consumer SSDs).
- Virtual adapter filtering is name-based. Adapters with non-standard names may not be filtered.
- Complex RAID or Storage Spaces configurations may not map drive letters cleanly.
- Some Windows TEMP files may remain locked by running services.
- Wi-Fi adapter detection depends on the adapter name matching expected patterns.

## Project Structure

```
PM-Quick/
├── PM-Quick.bat          (launcher, auto-elevates to admin)
├── PM-Quick.ps1          (main script)
├── PM-Quick-AUDIT-REPORT.md
├── README.md
├── .gitignore
└── modules/
    ├── System.ps1        (PC name, serial, Windows, user)
    ├── Network.ps1       (IPv4 detection, adapter filtering)
    ├── Performance.ps1   (CPU and memory snapshot)
    ├── Storage.ps1       (drive detection, SSD/HDD, internal/external)
    ├── SSD.ps1           (SSD health, drive letter mapping)
    └── Cleanup.ps1       (TEMP cleanup, Recycle Bin filtering)
```

## Safety / Scope

- Local-only tool. No data is sent externally.
- No registry, service, network, or Windows Update modifications.
- No telemetry, cloud, API, or database functionality.
- No external dependencies beyond built-in Windows/PowerShell APIs.
