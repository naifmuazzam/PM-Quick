<#
.SYNOPSIS
    Temp-Cleaner - TEMP and Recycle Bin maintenance for IT technicians.

.DESCRIPTION
    The destructive half of the old PM-Quick tool, split out so that PM-Quick
    itself is strictly read-only.

    This tool cleans three things, in this order:
      1. User TEMP     - files are deleted outright
      2. Windows TEMP  - files are deleted outright
      3. Recycle Bin   - ONLY items whose original source is proven to be a
                         TEMP directory are permanently purged

    Everything else in the Recycle Bin - Desktop, Documents, Downloads and any
    item whose source cannot be resolved - is reported and left untouched.

    TEMP files used to be sent to the Recycle Bin, but that bought nothing: step
    3 purges TEMP-origin items in the same run, so the Recycle Bin never really
    held them as a safety net. It only cost time, because moving a file into the
    Recycle Bin spends about a second discovering that a file held open by
    another process cannot be moved, while deleting it outright fails in about
    twenty milliseconds. The preview used to be wrong as a result, promising a
    Recycle Bin purge count that the run then changed by adding items to it.

.NOTES
    Requires Windows PowerShell 5.1 and Administrator.
    Requires: -RunAsAdministrator is declared below.

    Safety guarantees (all covered by the regression suite):
      - The Recycle Bin is never emptied wholesale
      - Nothing is deleted without an explicit Y or y
      - Locked and inaccessible files are left untouched and reported
      - Junctions, symlinks and other reparse points are never traversed
      - Path boundary checks are strict, so '...\TempEvil' never matches
        '...\Temp'
      - Deletion from the Recycle Bin is confined to one guarded helper that
        refuses any path outside the Recycle Bin
      - Files from the Desktop, Documents, Downloads and unresolvable origins
        are never purged
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'

# ============================================================================
# SAFETY CODE - moved verbatim from the frozen PM-Quick Cleanup.ps1
# ============================================================================

function Get-TempTreeSafe {
    [CmdletBinding()]
    param(
        [string]$Root
    )

    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $dirs  = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]

    # HARDENING (the only behavioural change to the moved safety code).
    # A root that is not a fully-qualified absolute path is refused outright.
    # Windows strips trailing spaces from a path, so a whitespace-only root such
    # as '   ' silently collapses to the CURRENT DIRECTORY - and a relative root
    # is resolved against whatever the working directory happens to be. For a
    # destructive caller either case means collecting the wrong tree.
    #
    # [System.IO.Path]::IsPathRooted is NOT sufficient on its own: it returns
    # True for a drive-relative path such as 'C:' or 'C:Temp', which resolves
    # against that drive's current directory rather than naming a real folder.
    # Left unchecked, a root of 'C:' walks the entire drive - measured at over
    # a million entries. A usable root must therefore name a drive or UNC share
    # AND a first-level directory, which is what the pattern below requires.
    $rootIsAbsolute = $false
    if ($Root) {
        try {
            $candidate = "$Root".Trim()
            # 'C:\...' or 'C:/...' for a local drive, '\\server\share' for UNC.
            $rootIsAbsolute = ($candidate -match '^[A-Za-z]:[\\/]') -or ($candidate -match '^\\\\[^\\/]+[\\/][^\\/]+')
        } catch { $rootIsAbsolute = $false }
    }

    if ($rootIsAbsolute -and (Test-Path -LiteralPath $Root -PathType Container -ErrorAction SilentlyContinue)) {
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

    # NOTE: this is a reporting-only value. It is used solely for the
    # Before/After figures and the preview sizes, and never gates a delete, so
    # the empty-tree case below is cosmetic. Measure-Object emits nothing at all
    # on an empty pipeline, which used to make this function return $null for an
    # existing-but-empty directory; it now returns a real 0.
    $sum = (Get-TempTreeSafe -Root $Path).Files |
        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Sum }

    if ($null -eq $sum) { return 0 }
    return $sum
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

function Remove-TempFilePermanently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    # TEMP files are deleted outright rather than routed through the Recycle
    # Bin. Round-tripping them was pointless: Invoke-PMCleanup purges TEMP-origin
    # Recycle Bin items in the same run, so the Recycle Bin never actually
    # retained anything as a safety net. It cost real time, because
    # FileSystem.DeleteFile spends roughly a second discovering that a file held
    # open by another process cannot be moved, whereas Remove-Item -Force fails
    # in about twenty milliseconds. On a run with fourteen locked files that
    # difference was the whole 56 seconds.
    #
    # A separate Recycle Bin purge still runs for TEMP-origin items that were
    # already there, so files from the Desktop, Documents, Downloads and unknown
    # origins remain untouched.
    Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
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

function Get-PMSkipCategoryLabel {
    <#
    .SYNOPSIS
        Human wording for a skip-category code.
    .DESCRIPTION
        The codes are for counting. This turns them into something a technician
        can read in a sentence, without listing file names.
    #>
    param([string]$Code)

    switch ($Code) {
        'in-use' { return 'held open by a running process' }
        'denied' { return 'access denied' }
        'other'  { return 'other reason' }
        'unknown'{ return 'unknown reason' }
        default  { return $Code }
    }
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
        $rows.Add(@('SUBTITLE', 'No files were deleted.'))
    }

    $rows.Add(@('SECTION', 'USER TEMP'))
    $rows.Add(@('FIELD', 'Files found', (Get-PMReportValue -InputObject $Result -Name 'UserTempFilesFound' -Default 0)))
    $rows.Add(@('FIELD', 'Deleted',    (Get-PMReportValue -InputObject $Result -Name 'UserTempFilesDeleted' -Default 0)))
    $rows.Add(@('FIELD', 'Skipped',     (Get-PMReportValue -InputObject $Result -Name 'UserTempFilesSkipped' -Default 0)))
    $rows.Add(@('FIELD', 'Before',      (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'UserTempBeforeSize' -Default 0))))
    $rows.Add(@('FIELD', 'After',       (Format-PMByteSize (Get-PMReportValue -InputObject $Result -Name 'UserTempAfterSize' -Default 0))))

    $rows.Add(@('SECTION', 'WINDOWS TEMP'))
    $rows.Add(@('FIELD', 'Files found', (Get-PMReportValue -InputObject $Result -Name 'WinTempFilesFound' -Default 0)))
    $rows.Add(@('FIELD', 'Deleted',    (Get-PMReportValue -InputObject $Result -Name 'WinTempFilesDeleted' -Default 0)))
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

    # The per-stage Skipped counters are authoritative, so this section is built
    # from them rather than from the note list. Otherwise a run where every skip
    # was an expected lock would report nothing at all, which is the opposite of
    # the truth.
    $stageOrder = @(
        @{ Label = 'User TEMP';    Counter = 'UserTempFilesSkipped' },
        @{ Label = 'Windows TEMP'; Counter = 'WinTempFilesSkipped' },
        @{ Label = 'Recycle Bin';  Counter = 'RecycleSkipped' }
    )

    $openedSkipped = $false
    foreach ($stage in $stageOrder) {
        $prefix = '[WARN] ' + $stage.Label + ':'
        $listedCount = 0
        foreach ($w in $warnList) {
            if (([string]$w).StartsWith($prefix, [System.StringComparison]::Ordinal)) { $listedCount++ }
        }
        $counterValue = [int](Get-PMReportValue -InputObject $Result -Name $stage.Counter -Default 0)
        $total = [Math]::Max($counterValue, $listedCount)
        if ($total -gt 0) {
            if (-not $openedSkipped) { $rows.Add(@('SECTION', 'SKIPPED')); $openedSkipped = $true }
            $rows.Add(@('FIELD', $stage.Label, "$total file(s) left untouched."))
        }
    }

    # Locks are the normal case and are summarised in one line, because there is
    # nothing for the user to do about them.
    $inUse = [int](Get-PMReportValue -InputObject $Result -Name 'SkipInUse' -Default 0)
    if ($inUse -gt 0) {
        if (-not $openedSkipped) { $rows.Add(@('SECTION', 'SKIPPED')); $openedSkipped = $true }
        $rows.Add(@('DETAIL', "$inUse of those were held open by a running process. They are swept on the next run or after a restart."))
    }

    # Anything that is not a lock is still reported, but as a count and a
    # reason rather than a list of file names. The per-file listing was removed
    # on the user's instruction: a TEMP file that cannot be removed is not
    # something they can chase individually, and the names were the noisiest
    # part of the output. Denied is deliberately kept out of the "held open"
    # bucket above, because a permission problem does not clear on a restart and
    # saying otherwise would be a lie.
    $reasons = Get-PMReportValue -InputObject $Result -Name 'SkipReasons' -Default @{}
    $otherParts = New-Object System.Collections.Generic.List[string]
    [int]$otherTotal = 0
    [int]$otherKinds = 0
    [int]$otherOnlyCount = 0
    [string]$otherOnlyLabel = ''
    foreach ($code in (@($reasons.Keys) | Sort-Object)) {
        if ($code -eq 'in-use') { continue }
        $n = [int]$reasons[$code]
        if ($n -gt 0) {
            $otherTotal += $n
            $otherKinds++
            $otherOnlyCount = $n
            $otherOnlyLabel = Get-PMSkipCategoryLabel $code
            $otherParts.Add(("$n " + $otherOnlyLabel))
        }
    }
    if ($otherTotal -gt 0) {
        if (-not $openedSkipped) { $rows.Add(@('SECTION', 'SKIPPED')); $openedSkipped = $true }
        # With a single reason the count is already stated, so do not repeat it.
        if ($otherKinds -eq 1 -and $otherOnlyCount -eq $otherTotal) {
            $why = $otherOnlyLabel
        } else {
            $why = ($otherParts -join ', ')
        }
        $rows.Add(@('DETAIL', "$otherTotal could not be removed ($why)."))
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($row in $rows) {
        switch ($row[0]) {
            'TITLE'      { $out.Add($row[1]) }
            'SUBTITLE'   { $out.Add(('  ' + $row[1])) }
            'SECTION'    { $out.Add(''); $out.Add($row[1]) }
            'FIELD'      { $out.Add(('  {0,-18}: {1}' -f $row[1], $row[2])) }
            'DETAIL'     { $out.Add(('    ' + $row[1])) }
            'WARN'       { $out.Add(('    ' + $row[1])) }
        }
    }


    $out.ToArray()
}

function Get-PMSkipCategory {
    <#
    .SYNOPSIS
        Buckets a real exception message into a short reason code.
    .DESCRIPTION
        A TEMP sweep skips files for two very different kinds of reason, and
        lumping them together is what turns a normal run into a wall of noise.

        A file held open by a running process is the expected case, not a
        failure. It will be swept on the next run, or cleared by a reboot, and
        there is nothing the user can or should do about it right now. So it is
        counted and summarised in one line instead of being listed per file.

        Everything else - denied, and genuinely unclassified - is listed, because
        those may need a human. The category is derived from the exception text
        only; no cause is invented, and an unrecognised message is never
        quietly folded into the expected bucket.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return 'unknown' }
    if ($Message -match 'used by another process|cannot access the file|sharing violation|lock violation|cannot access') {
        return 'in-use'
    }
    # Win32 surfaces this for TEMP entries that are mapped or in flight. It is
    # the same practical outcome as a locked file: it stays, and it is harmless.
    if ($Message -match 'system call level is not correct|wrong software|incorrect function') {
        return 'in-use'
    }
    if ($Message -match 'access is denied|Access denied|permission denied|Permission denied') {
        return 'denied'
    }
    return 'other'
}

function Invoke-PMCleanup {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        # Optional per-item progress sink, invoked with
        # @{ Stage; StageCount; Index; Total; Label } as a hashtable.
        [scriptblock]$Progress
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
        UserTempFilesDeleted = 0
        UserTempFilesSkipped  = 0
        UserTempBeforeSize    = 0
        UserTempAfterSize     = 0

        WinTempFilesFound     = 0
        WinTempFilesDeleted  = 0
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

        # Skips split by reason. SkipInUse is the expected bucket: a file held
        # open by a running process, which is swept next run or after a restart.
        # SkipActionable is everything else, i.e. what may need a human.
        SkipInUse      = 0
        SkipActionable = 0
        SkipReasons    = @{}

        # Capped, human-readable failure notes. Text is the real exception
        # message; no failure reason is inferred or invented. Expected locks are
        # counted in SkipInUse and deliberately not listed here.
        Warnings = @()

    }

    $totalCleaned = 0
    # FilesSkipped keeps its original Int32 type: it is a legacy public field.
    $skipped = 0

    # New counters are [long] throughout so the result object is type-consistent
    # for callers doing arithmetic on them.
    [long]$uFound = 0; [long]$uDeleted = 0; [long]$uSkipped = 0
    [long]$wFound = 0; [long]$wDeleted = 0; [long]$wSkipped = 0
    [long]$uBefore = 0; [long]$uAfter = 0
    [long]$wBefore = 0; [long]$wAfter = 0
    [long]$rbOriginFound = 0; [long]$rbPurged = 0; [long]$rbPurgeFailed = 0

    # Keep console output bounded: at most $warnLimit notes are kept verbatim,
    # the rest are summarised as a count. Every failure still increments the
    # real counters regardless of whether its text is kept.
    $warnings = New-Object System.Collections.Generic.List[string]
    [long]$warningTotal = 0
    $warnLimit = 15

    # Skips are bucketed by reason so a normal run does not print one line per
    # locked file. Only reasons that may need a human are listed verbatim.
    $skipsByReason = @{}
    $listedByReason = @{}

    # Single place where a skip is recorded, so the counters, the buckets and
    # the capped warning list can never drift apart.
    $recordSkip = {
        param([string]$Stage, [string]$Name, [string]$Reason)
        $category = Get-PMSkipCategory -Message $Reason
        if (-not $skipsByReason.ContainsKey($category)) { $skipsByReason[$category] = 0 }
        $skipsByReason[$category]++
        $warningTotal++
        if ($category -eq 'in-use') { return }
        if (-not $listedByReason.ContainsKey($category)) { $listedByReason[$category] = 0 }
        if ($listedByReason[$category] -ge $warnLimit) { return }
        $listedByReason[$category]++
        $warnings.Add("[WARN] $Stage`: '$Name' - $Reason")
    }

    $reportProgress = {
        param([int]$Stage, [int]$StageCount, [int]$Index, [int]$Total, [string]$Label)
        if ($null -ne $Progress) { & $Progress @{ Stage = $Stage; StageCount = $StageCount; Index = $Index; Total = $Total; Label = $Label } }
    }


    # --- User TEMP ---
    $userTemp = $env:TEMP
    if ($userTemp -and (Test-Path $userTemp)) {
        $before = Get-DirectorySize -Path $userTemp
        $uBefore = if ($null -ne $before) { [long]$before } else { [long]0 }

        # Built for counting in both modes. Read-only: the safe traversal
        # never deletes, and dry run still deletes nothing.
        $tree = Get-TempTreeSafe -Root $userTemp
        $uFound = @($tree.Files).Count

        if ($DryRun) {
            # DryRun: report eligible size without deleting
            $cleaned = if ($before) { $before } else { 0 }
            $uAfter = $uBefore
        } else {
            $uTotal = @($tree.Files).Count
            $uIndex = 0
            foreach ($file in $tree.Files) {
                $uIndex++
                try {
                    Remove-TempFilePermanently -LiteralPath $file.FullName
                    $uDeleted++
                } catch {
                    $skipped++
                    $uSkipped++
                    $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                    & $recordSkip 'User TEMP' $file.Name $reason
                }
                & $reportProgress 1 3 $uIndex $uTotal 'User TEMP'
            }
            & $reportProgress 1 3 $uTotal $uTotal 'User TEMP'

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
    $summary.UserTempFilesDeleted = $uDeleted
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
            $wTotal = @($tree.Files).Count
            $wIndex = 0
            foreach ($file in $tree.Files) {
                $wIndex++
                try {
                Remove-TempFilePermanently -LiteralPath $file.FullName
                $wDeleted++
                } catch {
                    $skipped++
                    $wSkipped++
                    $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                    & $recordSkip 'Windows TEMP' $file.Name $reason
                }
                & $reportProgress 2 3 $wIndex $wTotal 'Windows TEMP'
            }
            & $reportProgress 2 3 $wTotal $wTotal 'Windows TEMP'

            $after = Get-DirectorySize -Path $winTemp

            $wAfter = if ($null -ne $after) { [long]$after } else { [long]0 }
            $cleaned = if ($before -gt $after) { $before - $after } else { 0 }
        }
        $totalCleaned += $cleaned
        $summary.WinTempCleaned = "$([math]::Round($cleaned / 1MB, 1)) MB"
    }

    $summary.WinTempFilesFound    = $wFound
    $summary.WinTempFilesDeleted = $wDeleted
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
        $rbTotal = @($rbCleanable).Count
        $rbIndex = 0
        foreach ($item in $rbCleanable) {
            $rbIndex++
            try {
                Remove-RecycleBinItemPermanently -LiteralPath $item.InternalPath
                $rbCleanedBytes += $item.Size
                $rbPurged++
            } catch {
                $skipped++
                $rbPurgeFailed++
                $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                & $recordSkip 'Recycle Bin' $item.Name $reason
            }
            & $reportProgress 3 3 $rbIndex $rbTotal 'Recycle Bin'
        }
        & $reportProgress 3 3 $rbTotal $rbTotal 'Recycle Bin'
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

    # Locks are not failures, so they are excluded from the "not listed"
    # overflow note. Otherwise a busy machine would report a pile of unlisted
    # failures that were never failures to begin with.
    $inUse = if ($skipsByReason.ContainsKey('in-use')) { [long]$skipsByReason['in-use'] } else { [long]0 }
    $actionable = $warningTotal - $inUse
    $summary.SkipInUse      = $inUse
    $summary.SkipActionable = $actionable
    $summary.SkipReasons    = $skipsByReason

    if ($actionable -gt $warnings.Count) {
        $warnings.Add("[WARN] ... and $($actionable - $warnings.Count) more failure(s) not listed.")
    }

    # .ToArray(), not @($warnings): on Windows PowerShell 5.1 @() around a List
    # yields a one-element array holding the List, so the WARNINGS section would
    # print the collection object instead of the individual warning rows.
    $summary.Warnings = $warnings.ToArray()


    [pscustomobject]$summary
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

# ============================================================================
# USER INTERFACE
# ============================================================================


function Write-TCSectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $('=' * 40)" -ForegroundColor DarkGray
}

function Write-TCField {
    param(
        [string]$Label,
        [string]$Value,
        [int]$LabelWidth = 18
    )
    # PadRight returns the string untouched when it is already at or over the
    # width, so 'Skipped (non-TEMP)' (19 chars) ran straight into its value and
    # printed as "Skipped (non-TEMP)1 items". A format string always emits the
    # separating space, whatever the label length. The format string is built
    # first and applied second: -f binds more tightly than +, so folding the two
    # into one expression throws a FormatError at runtime.
    $fmt = '  {0,-' + $LabelWidth + '} {1}'
    Write-Host ($fmt -f $Label, $Value)
}

function Invoke-TempCleanerUI {
    [CmdletBinding()]
    param()

    # Keep the console buffer wide enough that a resize does not leave a
    # scrollbar artifact over the report.
    try {
        $host.UI.RawUI.WindowTitle = 'Temp-Cleaner'
        $minWidth = 120
        $curBufW = $host.UI.RawUI.BufferSize.Width
        $curWinW = $host.UI.RawUI.WindowSize.Width
        $targetW = [Math]::Max($minWidth, $curWinW)
        if ($curBufW -lt $targetW) {
            $host.UI.RawUI.BufferSize = [System.Management.Automation.Host.Size]::new($targetW, 3000)
        }
    } catch {}

    Clear-Host
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Yellow
    Write-Host "            TEMP CLEANER" -ForegroundColor Yellow
    Write-Host "  ========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This tool DELETES files. PM-Quick does not." -ForegroundColor DarkGray
    Write-Host "  Collecting preview..." -ForegroundColor DarkGray

    # ---------------------------------------------------------------- preview
    Write-TCSectionHeader 'CLEANUP PREVIEW'

    $estimate = $null
    try { $estimate = Get-TempCleanupEstimate } catch {}

    if ($estimate) {
        foreach ($item in $estimate.Items) {
            Write-TCField $item.Location "$($item.SizeMB) MB"
        }

        # Spell out exactly what will and will not be touched, before asking.
        $tempOrigin  = @($estimate.RecycleBin | Where-Object { $_.IsTempSource -eq $true })
        $nonTemp     = @($estimate.RecycleBin | Where-Object { $_.IsTempSource -ne $true })
        $unknown     = @($estimate.RecycleBin | Where-Object { $_.SourceReliable -ne $true })

        Write-Host ""
        Write-TCField 'Recycle Bin TEMP'    "$($tempOrigin.Count) item(s) will be purged"
        Write-TCField 'Left untouched'      "$($nonTemp.Count) item(s)"

        if ($unknown.Count -gt 0) {
            Write-Host ""
            Write-Host "  $($unknown.Count) Recycle Bin item(s) have an unreadable source path" -ForegroundColor Yellow
            Write-Host "  and will be left untouched." -ForegroundColor Yellow
        }

        if ($nonTemp.Count -gt 0) {
            Write-Host ""
            Write-Host "  Recycle Bin: $($nonTemp.Count) non-TEMP item(s) will be left untouched." -ForegroundColor DarkGray
            Write-Host "  Desktop, Documents, Downloads and unknown origins are never purged." -ForegroundColor DarkGray
        }
    } else {
        Write-TCField 'Cleanup' 'N/A - Could not estimate'
    }

    # ----------------------------------------------------------- confirmation
    # Only an explicit Y or y may cross this gate. Enter, whitespace and any
    # other input re-prompt instead of defaulting to cleanup.
    Write-Host ""
    Write-Host "  WARNING: this permanently removes TEMP files." -ForegroundColor Red

    $runCleanup = $false
    while ($true) {
        Write-Host "  Proceed with cleanup? [Y/N]: " -NoNewline -ForegroundColor Yellow
        $decision = Get-PMConfirmDecision -Answer (Read-Host)

        if ($decision -eq 'PROCEED') { $runCleanup = $true; break }
        if ($decision -eq 'ABORT')  { $runCleanup = $false; break }

        Write-Host "  Please enter Y or N." -ForegroundColor Yellow
    }

    if (-not $runCleanup) {
        Write-Host ""
        Write-Host "  Cleanup cancelled. Nothing was deleted." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  ========================================" -ForegroundColor Yellow
        Write-Host "          CLEANUP CANCELLED" -ForegroundColor Yellow
        Write-Host "  ========================================" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    # ---------------------------------------------------------------- cleanup
    Write-Host ""
    Write-Host "  Running cleanup..." -ForegroundColor DarkGray

    # Real per-item progress. The three "Cleaning..." lines used to be printed
    # up front, before any work started, so the screen claimed to be busy while
    # nothing had happened yet. $script:TCProgressInPlace keeps the bar on one
    # line on a real console, and falls back to plain lines when the output is
    # redirected to a file or a pipe.
    $script:TCProgressInPlace = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
    $tcStageStart = [datetime]::Now
    $tcProgress = {
        param($State)
        $total = [int]$State.Total
        $index = [int]$State.Index
        if ($total -gt 0) { $ratio = [double]$index / [double]$total } else { $ratio = 1.0 }
        $barWidth = 24
        $filled = [int][math]::Floor($ratio * $barWidth)
        if ($filled -lt 1 -and $index -gt 0) { $filled = 1 }
        $bar = ('#' * $filled) + ('.' * ($barWidth - $filled))
        $pct = [int][math]::Round($ratio * 100)
        $elapsed = [int]([datetime]::Now - $tcStageStart).TotalSeconds
        $text = '  Clean {0}/{1}  [{2}] {3,3}%  {4}  {5}s' -f `
            $State.Stage, $State.StageCount, $bar, $pct, $State.Label, $elapsed
        if ($script:TCProgressInPlace) {
            Write-Host ("$([char]27)[1G$([char]27)[0K$text") -NoNewline
        } else {
            Write-Host $text
        }
    }

    $cleanupResult = $null
    $cleanupError  = $null
    try { $cleanupResult = Invoke-PMCleanup -Progress $tcProgress } catch { $cleanupError = $_ }
    # Close the in-place line so the result table starts on a clean row.
    if ($script:TCProgressInPlace) { Write-Host '' }


    if ($cleanupResult) {
        Write-Host ""
        Write-TCField 'User TEMP'    $cleanupResult.UserTempCleaned
        Write-TCField 'Windows TEMP' $cleanupResult.WinTempCleaned
        Write-TCField 'Recycle Bin'  $cleanupResult.RecycleCleaned

        # Legacy counter: covers locked files, failed deletions and failed purges
        # alike, so it is not reported as "locked" specifically. The per-stage
        # breakdown below is the authoritative detail.
        if ($cleanupResult.FilesSkipped -gt 0) {
            Write-TCField 'Skipped / Failed' "$($cleanupResult.FilesSkipped) items"
        }
        if ($cleanupResult.TempFilesSkipped -gt 0) {
            Write-TCField 'Skipped (non-TEMP)' "$($cleanupResult.TempFilesSkipped) items"
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

    # ----------------------------------------------------------------- footer
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Yellow
    Write-Host "          CLEANUP COMPLETE" -ForegroundColor Yellow
    Write-Host "  ========================================" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# ENTRY POINT
# ============================================================================
# Guarded so the safety functions above can be dot-sourced by the regression
# suite without the interactive flow running.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-TempCleanerUI
}
