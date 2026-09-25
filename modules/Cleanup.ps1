function Get-TempTreeSafe {
    [CmdletBinding()]
    param(
        [string]$Root
    )

    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $dirs  = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]

    if ($Root -and (Test-Path -LiteralPath $Root -PathType Container -ErrorAction SilentlyContinue)) {
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push((Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue).ProviderPath)

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()

            # Non-recursive by design: descent is driven by the stack below
            foreach ($entry in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
                # Never traverse into or act on junctions / symlinks / other reparse points,
                # so cleanup can never escape the intended TEMP tree.
                if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }

                if ($entry.PSIsContainer) {
                    $dirs.Add($entry)
                    $stack.Push($entry.FullName)
                } else {
                    $files.Add($entry)
                }
            }
        }
    }

    [pscustomobject]@{
        Files       = $files
        Directories = $dirs
    }
}

function Get-DirectorySize {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) { return 0 }
    (Get-TempTreeSafe -Root $Path).Files |
        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue | ForEach-Object { $_.Sum }
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

function ConvertTo-ComparablePath {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $p = $Path.Trim().Trim('"')
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    $p = $p -replace '/', '\'

    try {
        # A relative path cannot be evaluated reliably - refuse it rather than
        # resolving it against the current working directory.
        if (-not [System.IO.Path]::IsPathRooted($p)) { return $null }

        # Resolves '.' and '..' segments, so traversal cannot escape a root.
        $p = [System.IO.Path]::GetFullPath($p)
    } catch {
        return $null
    }

    $p = ($p -replace '\\+', '\').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }

    $p.ToLowerInvariant()
}

function Test-PathWithinRoot {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Root
    )

    $nPath = ConvertTo-ComparablePath -Path $Path
    $nRoot = ConvertTo-ComparablePath -Path $Root

    if (-not $nPath) { return $false }
    if (-not $nRoot) { return $false }

    if ($nPath -eq $nRoot) { return $true }

    # Require a real directory separator so '...\TempEvil' never matches '...\Temp'
    $nPath.StartsWith(($nRoot + '\'), [System.StringComparison]::Ordinal)
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

            # Classify as TEMP only when the source path is a known TEMP root
            # or a genuine child of one. Anything unresolvable stays unreliable.
            if (-not [string]::IsNullOrWhiteSpace([string]$originalLocation)) {
                if (Test-PathWithinRoot -Path $originalLocation -Root $env:TEMP) {
                    $sourceKnown = $true
                    $isTempSource = $true
                } elseif (Test-PathWithinRoot -Path $originalLocation -Root "$env:SystemRoot\Temp") {
                    $sourceKnown = $true
                    $isTempSource = $true
                } elseif (ConvertTo-ComparablePath -Path $originalLocation) {
                    $sourceKnown = $true
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

function Send-FileToRecycleBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if (-not ('Microsoft.VisualBasic.FileIO.FileSystem' -as [type])) {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    }

    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $LiteralPath,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    )
}

function Remove-RecycleBinItemPermanently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return }
    if ($LiteralPath -notmatch '\\\$Recycle\.Bin\\') { return }

    if (-not ('Microsoft.VisualBasic.FileIO.FileSystem' -as [type])) {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    }

    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $LiteralPath,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::DeletePermanently
    )
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
            $tree = Get-TempTreeSafe -Root $userTemp

            foreach ($file in $tree.Files) {
                try {
                    Send-FileToRecycleBin -LiteralPath $file.FullName
                } catch {
                    $skipped++
                }
            }

            # Remove empty dirs (deepest first). Reparse points were never
            # collected, so they can never be removed here.
            foreach ($dir in ($tree.Directories | Sort-Object { $_.FullName.Length } -Descending)) {
                try {
                    if (-not (Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)) {
                        Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
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
            $tree = Get-TempTreeSafe -Root $winTemp

            foreach ($file in $tree.Files) {
                try {
                    Send-FileToRecycleBin -LiteralPath $file.FullName
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
                Remove-RecycleBinItemPermanently -LiteralPath $item.InternalPath
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
