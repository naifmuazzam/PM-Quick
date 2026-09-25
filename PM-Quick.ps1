<#
.SYNOPSIS
    PM Quick Tool - Lightweight Windows 11 Preventive Maintenance Assistant
.DESCRIPTION
    Gathers system info, performance snapshot, storage details, SSD health,
    and performs safe TEMP/Recycle Bin cleanup.
.NOTES
    For IT technician use during routine workstation preventive maintenance.
    Does NOT modify system configuration, registry, services, or network settings.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'
$scriptRoot = $PSScriptRoot

# Fix console scrollbar cut-off after maximize/restore
try {
    $host.UI.RawUI.WindowTitle = 'PM Quick Tool'
    # Ensure buffer is wide enough to prevent scrollbar glitch on resize
    $minWidth = 120
    $curBufW = $host.UI.RawUI.BufferSize.Width
    $curWinW = $host.UI.RawUI.WindowSize.Width
    $targetW = [Math]::Max($minWidth, $curWinW)
    if ($curBufW -lt $targetW) {
        $host.UI.RawUI.BufferSize = [System.Management.Automation.Host.Size]::new($targetW, 3000)
    }
} catch {}

# Load modules
. "$scriptRoot\modules\System.ps1"
. "$scriptRoot\modules\Network.ps1"
. "$scriptRoot\modules\Performance.ps1"
. "$scriptRoot\modules\Storage.ps1"
. "$scriptRoot\modules\SSD.ps1"
. "$scriptRoot\modules\Cleanup.ps1"

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $('=' * 40)" -ForegroundColor DarkGray
}

function Write-Field {
    param(
        [string]$Label,
        [string]$Value,
        [int]$LabelWidth = 18
    )
    $padded = $Label.PadRight($LabelWidth)
    Write-Host "  $padded" -NoNewline
    Write-Host $Value
}

# Decides what a single answer to the cleanup confirmation means.
# Deliberately total and side-effect free: only a literal Y/y can ever
# authorise the destructive action, so stray or buffered keystrokes - including
# a bare Enter - can never be read as consent.
function Get-PMConfirmDecision {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Answer
    )

    # Enter, or anything with no non-whitespace content, is not consent.
    if ($null -eq $Answer) { return 'RETRY' }
    $normalized = $Answer.Trim()
    if ($normalized.Length -eq 0) { return 'RETRY' }

    if ($normalized -ceq 'Y' -or $normalized -ceq 'y') { return 'PROCEED' }
    if ($normalized -ceq 'N' -or $normalized -ceq 'n') { return 'ABORT' }

    # Anything else is invalid input: re-prompt, never assume consent.
    return 'RETRY'
}

# ============================================
# HEADER
# ============================================
Clear-Host
Write-Host ""
Write-Host "  ========================================" -ForegroundColor Yellow
Write-Host "            PM QUICK TOOL" -ForegroundColor Yellow
Write-Host "  ========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Collecting system information..." -ForegroundColor DarkGray

# ============================================
# 1. SYSTEM INFORMATION
# ============================================
$sysInfo = $null
try { $sysInfo = Get-PMSystemInfo } catch {}

Write-SectionHeader 'SYSTEM'
if ($sysInfo) {
    Write-Field 'PC Name'      $sysInfo.PCName
    Write-Field 'Serial'       $sysInfo.Serial
    Write-Field 'Windows'      $sysInfo.Windows
    Write-Field 'User'         $sysInfo.User
} else {
    Write-Field 'System' 'N/A - Collection failed'
}

# ============================================
# 2. NETWORK INFORMATION
# ============================================
$netInfo = $null
try { $netInfo = Get-PMNetworkInfo } catch {}

Write-SectionHeader 'NETWORK'

if ($netInfo -and $netInfo.Count -gt 0) {
    $grouped = $netInfo.Adapters | Group-Object Adapter

    foreach ($group in $grouped) {
        $adapterName = $group.Name
        $ips = ($group.Group | ForEach-Object { $_.IPv4 }) -join ', '
        Write-Field $adapterName $ips
    }

    if ($netInfo.Count -gt 1) {
        Write-Host ""
        Write-Host "  Multiple IPv4 addresses detected." -ForegroundColor Yellow
        Write-Host "  Verify the IP used in MyERP manually." -ForegroundColor Yellow
    }
} else {
    Write-Field 'IPv4' 'N/A'
}

# ============================================
# 3. PERFORMANCE SNAPSHOT
# ============================================
Write-Host ""
Write-Host "  Sampling performance (3 seconds)..." -ForegroundColor DarkGray

$perfSnap = $null
try { $perfSnap = Get-PMPerformanceSnapshot -SampleSeconds 3 } catch {}

Write-SectionHeader 'PERFORMANCE'
if ($perfSnap) {
    $cpuVal = if ($perfSnap.CPUUsage -eq 'N/A') { 'N/A' } else { "$($perfSnap.CPUUsage)%" }
    $memVal = if ($perfSnap.MemoryUsage -eq 'N/A') { 'N/A' } else { "$($perfSnap.MemoryUsage)%" }
    Write-Field 'CPU Usage'    $cpuVal
    Write-Field 'Memory Usage' $memVal
} else {
    Write-Field 'CPU Usage'    'N/A'
    Write-Field 'Memory Usage' 'N/A'
}

# ============================================
# 4. STORAGE
# ============================================
$storageInfo = $null
try { $storageInfo = Get-PMStorageInfo } catch {}

Write-SectionHeader 'STORAGE'

if ($storageInfo -and $storageInfo.Count -gt 0) {
    $internalDrives = $storageInfo | Where-Object { $_.Location -eq 'Internal' }
    $externalDrives = $storageInfo | Where-Object { $_.Location -eq 'External' }
    $unknownDrives  = $storageInfo | Where-Object { $_.Location -notin @('Internal', 'External') }

    if ($internalDrives) {
        Write-Host "  [INTERNAL]" -ForegroundColor Green
        foreach ($d in $internalDrives) {
            $typeTag = if ($d.MediaType -and $d.MediaType -ne 'Unknown') { $d.MediaType } else { $d.BusType }
            Write-Host "  $($d.Drive) $typeTag" -ForegroundColor White
            Write-Field 'Total' "$($d.TotalGB) GB"
            Write-Field 'Free'  "$($d.FreeGB) GB"
            Write-Host ""
        }
    }

    if ($externalDrives) {
        Write-Host "  [EXTERNAL]" -ForegroundColor Magenta
        foreach ($d in $externalDrives) {
            $typeTag = if ($d.MediaType -and $d.MediaType -ne 'Unknown') { $d.MediaType } else { $d.BusType }
            Write-Host "  $($d.Drive) $typeTag" -ForegroundColor White
            Write-Field 'Total' "$($d.TotalGB) GB"
            Write-Field 'Free'  "$($d.FreeGB) GB"
            Write-Host ""
        }
    }

    if ($unknownDrives) {
        Write-Host "  [UNKNOWN]" -ForegroundColor Yellow
        foreach ($d in $unknownDrives) {
            $typeTag = if ($d.MediaType -and $d.MediaType -ne 'Unknown') { $d.MediaType } else { $d.BusType }
            Write-Host "  $($d.Drive) $typeTag" -ForegroundColor White
            Write-Field 'Total' "$($d.TotalGB) GB"
            Write-Field 'Free'  "$($d.FreeGB) GB"
            Write-Host ""
        }
    }
} else {
    Write-Field 'Storage' 'N/A - No drives detected'
}

# ============================================
# 5. SSD HEALTH
# ============================================
$ssdHealth = $null
try { $ssdHealth = Get-PMSSDHealth } catch {}

Write-SectionHeader 'SSD HEALTH'

if ($ssdHealth -and $ssdHealth.Count -gt 0) {
    $mappedCount = 0
    foreach ($ssd in $ssdHealth) {
        if ($ssd.DriveLetters) {
            Write-Host "  $($ssd.DriveLetters) SSD" -ForegroundColor White
            Write-Field 'Health'         $ssd.Health
            Write-Field 'Estimated Life' $ssd.EstimatedLife
            Write-Host ""
            $mappedCount++
        }
    }

    # If no drive letters could be mapped, show generic info
    if ($mappedCount -eq 0) {
        Write-Host "  Physical SSDs detected: $($ssdHealth.Count)" -ForegroundColor White
        Write-Host "  Health information available," -ForegroundColor DarkGray
        Write-Host "  but drive mapping could not be determined reliably." -ForegroundColor DarkGray
        Write-Host ""
    }
} else {
    Write-Host "  No SSDs detected or health data unavailable." -ForegroundColor DarkGray
}

# ============================================
# 6. CLEANUP
# ============================================
Write-SectionHeader 'CLEANUP PREVIEW'

$cleanupEst = $null
try { $cleanupEst = Get-TempCleanupEstimate } catch {}

if ($cleanupEst) {
    foreach ($item in $cleanupEst.Items) {
        Write-Field $item.Location "$($item.SizeMB) MB"
    }

    if ($cleanupEst.SkippedCount -gt 0) {
        Write-Host ""
        Write-Host "  Recycle Bin: $($cleanupEst.SkippedCount) non-TEMP items will be left untouched." -ForegroundColor DarkGray
    }
} else {
    Write-Field 'Cleanup' 'N/A - Could not estimate'
}

# Ask for confirmation. Only an explicit Y or y may cross this gate; Enter,
# whitespace and any other input re-prompt instead of defaulting to cleanup.
$runCleanup = $false
while ($true) {
    Write-Host "  Proceed with cleanup? [Y/N]: " -NoNewline -ForegroundColor Yellow
    $decision = Get-PMConfirmDecision -Answer (Read-Host)

    if ($decision -eq 'PROCEED') { $runCleanup = $true; break }
    if ($decision -eq 'ABORT')  { $runCleanup = $false; break }

    Write-Host "  Please enter Y or N." -ForegroundColor Yellow
}

if ($runCleanup) {
    Write-Host ""
    Write-Host "  Running cleanup..." -ForegroundColor DarkGray
    Write-Field 'User TEMP'    'Cleaning...'
    Write-Field 'Windows TEMP' 'Cleaning...'
    Write-Field 'Recycle Bin'  'Cleaning...'

    $cleanupResult = $null
    $cleanupError = $null
    try { $cleanupResult = Invoke-PMCleanup } catch { $cleanupError = $_ }

    if ($cleanupResult) {
        Write-Host ""
        Write-Field 'User TEMP'     $cleanupResult.UserTempCleaned
        Write-Field 'Windows TEMP'  $cleanupResult.WinTempCleaned
        Write-Field 'Recycle Bin'   $cleanupResult.RecycleCleaned

        # Legacy counter: covers locked files, failed recycles and failed purges
        # alike, so it is not reported as "locked" specifically. The per-stage
        # breakdown below is the authoritative detail.
        if ($cleanupResult.FilesSkipped -gt 0) {
            Write-Field 'Skipped / Failed' "$($cleanupResult.FilesSkipped) items"
        }
        if ($cleanupResult.TempFilesSkipped -gt 0) {
            Write-Field 'Skipped (non-TEMP)' "$($cleanupResult.TempFilesSkipped) items"
        }

        # Detailed per-location report. Purely additive: the fields above keep
        # their original names, order and meaning.
        try {
            Write-Host ""
            Format-PMCleanupReport -Result $cleanupResult | ForEach-Object { Write-Host $_ }
        } catch {}
    } else {
        Write-Host "  Cleanup failed or was interrupted." -ForegroundColor Red
        if ($cleanupError) {
            Write-Host "  Reason: $($cleanupError.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host ""
    Write-Host "  Cleanup skipped by user." -ForegroundColor DarkGray
}

# ============================================
# FOOTER
# ============================================
Write-Host ""
Write-Host "  ========================================" -ForegroundColor Yellow
Write-Host "            PM COMPLETE" -ForegroundColor Yellow
Write-Host "  ========================================" -ForegroundColor Yellow
Write-Host ""
