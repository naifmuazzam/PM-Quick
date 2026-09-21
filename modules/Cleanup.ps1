function Get-DirectorySize {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) { return 0 }
    (Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
}

function Get-TempCleanupEstimate {
    [CmdletBinding()]
    param()

    $results = @()

    # Current user TEMP
    $userTemp = $env:TEMP
    if ($userTemp -and (Test-Path $userTemp)) {
        $size = Get-DirectorySize -Path $userTemp
        $results += [pscustomobject]@{
            Location = 'User TEMP'
            Path     = $userTemp
            SizeMB   = [math]::Round(($size / 1MB), 1)
        }
    }

    # Windows TEMP
    $winTemp = "$env:SystemRoot\Temp"
    if (Test-Path $winTemp) {
        $size = Get-DirectorySize -Path $winTemp
        $results += [pscustomobject]@{
            Location = 'Windows TEMP'
            Path     = $winTemp
            SizeMB   = [math]::Round(($size / 1MB), 1)
        }
    }

    # Recycle Bin estimate (source-path aware)
    $rbItems = Get-RecycleBinContent
    $rbCleanable = $rbItems | Where-Object { $_.IsTempSource -eq $true }
    $rbCleanableSize = ($rbCleanable | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
    $rbTotalSize = ($rbItems | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
    $rbSkippedCount = ($rbItems | Where-Object { $_.IsTempSource -ne $true }).Count

    $results += [pscustomobject]@{
        Location = 'Recycle Bin'
        Path     = 'N/A'
        SizeMB   = [math]::Round(($rbTotalSize / 1MB), 1)
    }

    [pscustomobject]@{
        Items          = $results
        RecycleBin     = $rbItems
        CleanableSize  = $rbCleanableSize
        SkippedCount   = $rbSkippedCount
    }
}

function Get-RecycleBinContent {
    [CmdletBinding()]
    param()

    $items = @()

    try {
        $shell = [Activator]::CreateInstance(
            [type]::GetTypeFromProgID('Shell.Application')
        )
        $recycleBin = $shell.Namespace(0x0A)

        if (-not $recycleBin) { return @() }

        $displacedFmtid = '{9B174B33-40FF-11D2-A27E-00C04FC30871}'

        foreach ($item in $recycleBin.Items()) {
            $name = $item.Name
            $size = $item.Size

            # Get original source path
            $originalLocation = $null

            # Method 1: FMTID/PID 2 (displaced property)
            try {
                $originalLocation = $item.ExtendedProperty("$displacedFmtid 2")
            } catch {}

            # Method 2: Canonical name fallback
            if ([string]::IsNullOrWhiteSpace([string]$originalLocation)) {
                try {
                    $originalLocation = $item.ExtendedProperty('System.Recycle.DeletedFrom')
                } catch {}
            }

            $isTempSource = $false
            $sourceKnown = $false

            if (-not [string]::IsNullOrWhiteSpace([string]$originalLocation)) {
                $sourceKnown = $true
                $locLower = $originalLocation.ToLower().TrimEnd('\')

                # Check if source is a TEMP directory
                $userTemp = $env:TEMP.ToLower().TrimEnd('\')
                $winTemp  = "$env:SystemRoot\Temp".ToLower().TrimEnd('\')

                if ($locLower -eq $userTemp -or $locLower -eq $winTemp) {
                    $isTempSource = $true
                }
            }

            $items += [pscustomobject]@{
                Name             = $name
                Size             = [long]($size)
                OriginalLocation = [string]$originalLocation
                SourceReliable   = $sourceKnown
                IsTempSource     = $isTempSource
                InternalPath     = [string]$item.Path
                ShellItem        = $item
            }
        }
    } catch {}

    $items
}

function Invoke-PMCleanup {
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    $summary = [ordered]@{
        UserTempCleaned  = '0 MB'
        WinTempCleaned   = '0 MB'
        RecycleCleaned   = '0 MB'
        FilesSkipped     = 0
        TempFilesSkipped = 0
    }

    $totalCleaned = 0
    $skipped = 0

    # --- User TEMP ---
    $userTemp = $env:TEMP
    if ($userTemp -and (Test-Path $userTemp)) {
        $before = Get-DirectorySize -Path $userTemp

        if ($DryRun) {
            # DryRun: report eligible size without deleting
            $cleaned = if ($before) { $before } else { 0 }
        } else {
            Get-ChildItem -Path $userTemp -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    } catch {
                        $skipped++
                    }
                }

            # Remove empty dirs
            Get-ChildItem -Path $userTemp -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    try {
                        if ((Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        }
                    } catch {}
                }

            $after = Get-DirectorySize -Path $userTemp
            $cleaned = if ($before -gt $after) { $before - $after } else { 0 }
        }
        $totalCleaned += $cleaned
        $summary.UserTempCleaned = "$([math]::Round($cleaned / 1MB, 1)) MB"
    }

    # --- Windows TEMP ---
    $winTemp = "$env:SystemRoot\Temp"
    if (Test-Path $winTemp) {
        $before = Get-DirectorySize -Path $winTemp

        if ($DryRun) {
            $cleaned = if ($before) { $before } else { 0 }
        } else {
            Get-ChildItem -Path $winTemp -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    } catch {
                        $skipped++
                    }
                }

            $after = Get-DirectorySize -Path $winTemp
            $cleaned = if ($before -gt $after) { $before - $after } else { 0 }
        }
        $totalCleaned += $cleaned
        $summary.WinTempCleaned = "$([math]::Round($cleaned / 1MB, 1)) MB"
    }

    # --- Recycle Bin (TEMP source only) ---
    $rbContent = Get-RecycleBinContent
    $rbCleanable = $rbContent | Where-Object { $_.IsTempSource -eq $true }
    $rbSkipped = $rbContent | Where-Object { $_.IsTempSource -ne $true }

    $rbCleanedBytes = 0

    if (-not $DryRun) {
        foreach ($item in $rbCleanable) {
            try {
                $item.ShellItem.Delete()
                $rbCleanedBytes += $item.Size
            } catch {
                $skipped++
            }
        }
    } else {
        $rbCleanedBytes = ($rbCleanable | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
    }

    $totalCleaned += $rbCleanedBytes
    $summary.RecycleCleaned = "$([math]::Round($rbCleanedBytes / 1MB, 1)) MB"
    $summary.FilesSkipped = $skipped
    $summary.TempFilesSkipped = $rbSkipped.Count

    [pscustomobject]$summary
}
