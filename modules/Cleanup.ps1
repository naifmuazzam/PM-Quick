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
    # @() keeps this well-formed when the Recycle Bin is empty. Without it,
    # Get-RecycleBinContent's empty return and Measure-Object's empty Sum both
    # surface as $null and the preview renders blanks.
    $rbItems = @(Get-RecycleBinContent)
    $rbCleanable = @($rbItems | Where-Object { $_.IsTempSource -eq $true })
    $rbCleanableSize = ($rbCleanable | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
    $rbTotalSize = ($rbItems | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
    if ($null -eq $rbCleanableSize) { $rbCleanableSize = [long]0 }
    if ($null -eq $rbTotalSize) { $rbTotalSize = [long]0 }
    $rbSkippedCount = @($rbItems | Where-Object { $_.IsTempSource -ne $true }).Count

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

function Format-PMByteSize {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $Bytes
    )

    if ($null -eq $Bytes) { return '0 MB' }

    $b = [long]$Bytes
    if ($b -lt 0) { return '0 MB' }
    if ($b -eq 0) { return '0 MB' }
    if ($b -lt 1KB) { return "$b B" }
    if ($b -lt 1MB) { return "$([math]::Round($b / 1KB, 1)) KB" }
    if ($b -lt 1GB) { return "$([math]::Round($b / 1MB, 1)) MB" }
    return "$([math]::Round($b / 1GB, 2)) GB"
}

# Reads a property without throwing when it is absent, so the report can
# render a partial or older result object instead of dying on it.
function Get-PMReportValue {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [AllowEmptyCollection()]
        [object]$Default = 'n/a'
    )

    if ($null -eq $InputObject) { return $Default }

    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Format-PMCleanupReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [object]$Result
    )

    $dryRun = [bool](Get-PMReportValue -InputObject $Result -Name 'DryRun' -Default $false)

    # Rows are collected first, then rendered, so ordering stays declarative.
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@('TITLE', $(if ($dryRun) { '=== PM CLEANUP (DRY RUN) ===' } else { '=== PM CLEANUP ===' })))
    if ($dryRun) {
        $rows.Add(@('SUBTITLE', 'No files were recycled or permanently deleted.'))
    }

    $rows.Add(@('SECTION', 'USER TEMP'))
    $rows.Add(@('FIELD', 'Files found', (Get-PMReportValue -InputObject $Result -Name 'UserTempFilesFound' -Default 0)))
    $rows.Add(@('FIELD', 'Recycled',    (Get-PMReportValue -InputObject $Result -Name 'UserTempFilesRecycled' -Default 0)))
    $rows.Add(@('FIELD', 'Skipped',     (Get-PMReportValue -InputObject $Result -Name 'UserTempFilesSkipped' -Default 0)))
    $rows.Add(@('FIELD', 'Before',      (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'UserTempBeforeSize' -Default 0))))
    $rows.Add(@('FIELD', 'After',       (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'UserTempAfterSize' -Default 0))))

    $rows.Add(@('SECTION', 'WINDOWS TEMP'))
    $rows.Add(@('FIELD', 'Files found', (Get-PMReportValue -InputObject $Result -Name 'WinTempFilesFound' -Default 0)))
    $rows.Add(@('FIELD', 'Recycled',    (Get-PMReportValue -InputObject $Result -Name 'WinTempFilesRecycled' -Default 0)))
    $rows.Add(@('FIELD', 'Skipped',     (Get-PMReportValue -InputObject $Result -Name 'WinTempFilesSkipped' -Default 0)))
    $rows.Add(@('FIELD', 'Before',      (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'WinTempBeforeSize' -Default 0))))
    $rows.Add(@('FIELD', 'After',       (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'WinTempAfterSize' -Default 0))))

    $rows.Add(@('SECTION', 'RECYCLE BIN'))
    $rows.Add(@('FIELD', 'TEMP-origin found', (Get-PMReportValue -InputObject $Result -Name 'RecycleTempOriginFound' -Default 0)))
    $rows.Add(@('FIELD', 'Purged',            (Get-PMReportValue -InputObject $Result -Name 'RecyclePurged' -Default 0)))
    $rows.Add(@('FIELD', 'Skipped',           (Get-PMReportValue -InputObject $Result -Name 'RecycleSkipped' -Default 0)))

    # Non-TEMP items are deliberately left untouched. Shown on its own line so
    # it can never be read as, or folded into, the TEMP skip counters.
    $leftAlone = Get-PMReportValue -InputObject $Result -Name 'TempFilesSkipped' -Default 0
    if ($leftAlone -gt 0) {
        $rows.Add(@('FIELD', 'Left untouched', "$leftAlone (non-TEMP source)"))
    }

    $rows.Add(@('SECTION', 'RESULT'))
    $rows.Add(@('FIELD', 'Total cleaned', (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'TotalCleaned' -Default 0))))

    # Per-stage Skipped counters above are the authoritative skip figures. The
    # warnings only restate the real exception text; no reason is inferred,
    # because the recycle and purge APIs cannot reliably tell a locked file
    # apart from an access-denied or shell failure.
    # Per-stage counts come from the authoritative per-stage Skipped counters,
    # so the summary stays correct even when the note list is capped at 15.
    # The number of listed notes is used as a floor, so an older or synthetic
    # result object that carries notes but no counters still summarises.
    # No failure reason is categorised or invented here: the per-file detail
    # lines below carry the real exception text.
    $warnList = @(Get-PMReportValue -InputObject $Result -Name 'Warnings' -Default @())
    if ($warnList.Count -gt 0) {
        $rows.Add(@('SECTION', 'WARNINGS'))

        $stageOrder = @(
            @{ Label = 'User TEMP';    Counter = 'UserTempFilesSkipped' },
            @{ Label = 'Windows TEMP'; Counter = 'WinTempFilesSkipped' },
            @{ Label = 'Recycle Bin';  Counter = 'RecycleSkipped' }
        )

        foreach ($stage in $stageOrder) {
            $prefix = '[WARN] ' + $stage.Label + ':'
            $listedCount = 0
            foreach ($w in $warnList) {
                if (([string]$w).StartsWith($prefix, [System.StringComparison]::Ordinal)) { $listedCount++ }
            }
            $counterValue = [int](Get-PMReportValue -InputObject $Result -Name $stage.Counter -Default 0)
            $total = [Math]::Max($counterValue, $listedCount)
            if ($total -gt 0) {
                $rows.Add(@('FIELD', $stage.Label, "$total file(s) left untouched."))
            }
        }

        $rows.Add(@('DETAILHEAD', 'Details:'))
        foreach ($w in $warnList) { $rows.Add(@('WARN', [string]$w)) }
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($row in $rows) {
        switch ($row[0]) {
            'TITLE'      { $out.Add($row[1]) }
            'SUBTITLE'   { $out.Add(('  ' + $row[1])) }
            'SECTION'    { $out.Add(''); $out.Add($row[1]) }
            'FIELD'      { $out.Add(('  {0,-18}: {1}' -f $row[1], $row[2])) }
            'DETAILHEAD' { $out.Add(''); $out.Add(('    ' + $row[1])) }
            'WARN'       { $out.Add(('    ' + $row[1])) }
        }
    }

    $out.ToArray()
}

function Invoke-PMCleanup {
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    # The first five keys are the original public contract and keep their exact
    # names, order and meaning. Everything below them is additive reporting.
    $summary = [ordered]@{
        UserTempCleaned  = '0 MB'
        WinTempCleaned   = '0 MB'
        RecycleCleaned   = '0 MB'
        FilesSkipped     = 0
        TempFilesSkipped = 0

        # --- Per-location counters ---
        UserTempFilesFound    = 0
        UserTempFilesRecycled = 0
        UserTempFilesSkipped  = 0
        UserTempBeforeSize    = 0
        UserTempAfterSize     = 0

        WinTempFilesFound     = 0
        WinTempFilesRecycled  = 0
        WinTempFilesSkipped   = 0
        WinTempBeforeSize     = 0
        WinTempAfterSize      = 0

        # RecycleSkipped counts only TEMP-origin items that could not be
        # purged. Non-TEMP/unknown items stay in TempFilesSkipped and are
        # never counted here.
        RecycleTempOriginFound = 0
        RecyclePurged          = 0
        RecycleSkipped         = 0

        TotalCleaned = 0
        DryRun       = [bool]$DryRun

        # Capped, human-readable failure notes. Text is the real exception
        # message; no failure reason is inferred or invented.
        Warnings = @()
    }

    $totalCleaned = 0
    # FilesSkipped keeps its original Int32 type: it is a legacy public field.
    $skipped = 0

    # New counters are [long] throughout so the result object is type-consistent
    # for callers doing arithmetic on them.
    [long]$uFound = 0; [long]$uRecycled = 0; [long]$uSkipped = 0
    [long]$wFound = 0; [long]$wRecycled = 0; [long]$wSkipped = 0
    [long]$uBefore = 0; [long]$uAfter = 0
    [long]$wBefore = 0; [long]$wAfter = 0
    [long]$rbOriginFound = 0; [long]$rbPurged = 0; [long]$rbPurgeFailed = 0

    # Keep console output bounded: at most $warnLimit notes are kept verbatim,
    # the rest are summarised as a count. Every failure still increments the
    # real counters regardless of whether its text is kept.
    $warnings = New-Object System.Collections.Generic.List[string]
    [long]$warningTotal = 0
    $warnLimit = 15

    # --- User TEMP ---
    $userTemp = $env:TEMP
    if ($userTemp -and (Test-Path $userTemp)) {
        $before = Get-DirectorySize -Path $userTemp
        $uBefore = if ($null -ne $before) { [long]$before } else { [long]0 }

        # Built for counting in both modes. Read-only: the safe traversal
        # never deletes, and dry run still deletes/recycles nothing.
        $tree = Get-TempTreeSafe -Root $userTemp
        $uFound = @($tree.Files).Count

        if ($DryRun) {
            # DryRun: report eligible size without deleting
            $cleaned = if ($before) { $before } else { 0 }
            $uAfter = $uBefore
        } else {
            foreach ($file in $tree.Files) {
                try {
                    Send-FileToRecycleBin -LiteralPath $file.FullName
                    $uRecycled++
                } catch {
                    $skipped++
                    $uSkipped++
                    $warningTotal++
                    if ($warnings.Count -lt $warnLimit) {
                        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                        $warnings.Add("[WARN] User TEMP: '$($file.Name)' - $reason")
                    }
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
            $uAfter = if ($null -ne $after) { [long]$after } else { [long]0 }
            $cleaned = if ($before -gt $after) { $before - $after } else { 0 }
        }
        $totalCleaned += $cleaned
        $summary.UserTempCleaned = "$([math]::Round($cleaned / 1MB, 1)) MB"
    }

    $summary.UserTempFilesFound    = $uFound
    $summary.UserTempFilesRecycled = $uRecycled
    $summary.UserTempFilesSkipped  = $uSkipped
    $summary.UserTempBeforeSize    = $uBefore
    $summary.UserTempAfterSize     = $uAfter

    # --- Windows TEMP ---
    $winTemp = "$env:SystemRoot\Temp"
    if (Test-Path $winTemp) {
        $before = Get-DirectorySize -Path $winTemp
        $wBefore = if ($null -ne $before) { [long]$before } else { [long]0 }

        $tree = Get-TempTreeSafe -Root $winTemp
        $wFound = @($tree.Files).Count

        if ($DryRun) {
            $cleaned = if ($before) { $before } else { 0 }
            $wAfter = $wBefore
        } else {
            foreach ($file in $tree.Files) {
                try {
                    Send-FileToRecycleBin -LiteralPath $file.FullName
                    $wRecycled++
                } catch {
                    $skipped++
                    $wSkipped++
                    $warningTotal++
                    if ($warnings.Count -lt $warnLimit) {
                        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                        $warnings.Add("[WARN] Windows TEMP: '$($file.Name)' - $reason")
                    }
                }
            }

            $after = Get-DirectorySize -Path $winTemp
            $wAfter = if ($null -ne $after) { [long]$after } else { [long]0 }
            $cleaned = if ($before -gt $after) { $before - $after } else { 0 }
        }
        $totalCleaned += $cleaned
        $summary.WinTempCleaned = "$([math]::Round($cleaned / 1MB, 1)) MB"
    }

    $summary.WinTempFilesFound    = $wFound
    $summary.WinTempFilesRecycled = $wRecycled
    $summary.WinTempFilesSkipped  = $wSkipped
    $summary.WinTempBeforeSize    = $wBefore
    $summary.WinTempAfterSize     = $wAfter

    # --- Recycle Bin (TEMP source only) ---
    $rbContent = Get-RecycleBinContent
    $rbCleanable = @($rbContent | Where-Object { $_.IsTempSource -eq $true })
    $rbSkipped = @($rbContent | Where-Object { $_.IsTempSource -ne $true })

    $rbOriginFound = $rbCleanable.Count
    $rbCleanedBytes = 0

    if (-not $DryRun) {
        foreach ($item in $rbCleanable) {
            try {
                Remove-RecycleBinItemPermanently -LiteralPath $item.InternalPath
                $rbCleanedBytes += $item.Size
                $rbPurged++
            } catch {
                $skipped++
                $rbPurgeFailed++
                $warningTotal++
                if ($warnings.Count -lt $warnLimit) {
                    $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                        $warnings.Add("[WARN] Recycle Bin: '$($item.Name)' - $reason")
                }
            }
        }
    } else {
        $rbCleanedBytes = ($rbCleanable | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
    }

    if ($null -ne $rbCleanedBytes) { $rbCleanedBytes = [long]$rbCleanedBytes } else { $rbCleanedBytes = [long]0 }

    $totalCleaned += $rbCleanedBytes
    $summary.RecycleCleaned = "$([math]::Round($rbCleanedBytes / 1MB, 1)) MB"
    $summary.FilesSkipped = $skipped
    # @() keeps this an integer when exactly one non-TEMP item is present.
    $summary.TempFilesSkipped = $rbSkipped.Count

    $summary.RecycleTempOriginFound = $rbOriginFound
    $summary.RecyclePurged          = $rbPurged
    $summary.RecycleSkipped         = $rbPurgeFailed
    $summary.TotalCleaned           = [long]$totalCleaned

    if ($warningTotal -gt $warnings.Count) {
        $warnings.Add("[WARN] ... and $($warningTotal - $warnings.Count) more failure(s) not listed.")
    }
    $summary.Warnings = @($warnings)

    [pscustomobject]$summary
}
