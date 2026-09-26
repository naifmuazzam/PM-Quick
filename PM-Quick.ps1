<#
.SYNOPSIS
    PM-Quick - read-only PC health and inspection report for IT technicians.

.DESCRIPTION
    Collects hardware, network, storage and health information and prints a
    report. That is all it does.

    This tool is STRICTLY READ-ONLY. It does not delete, recycle, empty or
    modify anything:

      - No file is deleted, moved or renamed
      - The Recycle Bin is not read, enumerated or emptied
      - No registry value is written
      - No service, process or scheduled task is started or stopped
      - No software is installed, updated or uninstalled
      - Nothing is uploaded; there is no network call of any kind

    All file cleanup lives in the separate Temp-Cleaner tool.

.NOTES
    Requires Windows PowerShell 5.1.
    Runs without Administrator, but TPM, disk SMART and some firmware values
    need elevation. Anything unreadable is reported as N/A or Unknown rather
    than guessed.

    Optional: -Json <path> writes the same data to a local JSON file for
    attaching to a ticket. The file is written locally and nowhere else.
#>

[CmdletBinding()]
param(
    # Write the collected data to a local JSON file. Local only, no upload.
    [string]$Json,

    # Suppress the end-of-run Y/N export offer. Used by the validation harness,
    # where stdin is redirected and a prompt would never be answered.
    [switch]$NoExportPrompt
)

$ErrorActionPreference = 'SilentlyContinue'

# Keep the console wide enough that a resize does not leave a scrollbar
# artifact over the report.
try {
    $host.UI.RawUI.WindowTitle = 'PM-Quick'
    $minWidth = 120
    $curBufW = $host.UI.RawUI.BufferSize.Width
    $curWinW = $host.UI.RawUI.WindowSize.Width
    $targetW = [Math]::Max($minWidth, $curWinW)
    if ($curBufW -lt $targetW) {
        $host.UI.RawUI.BufferSize = [System.Management.Automation.Host.Size]::new($targetW, 3000)
    }
} catch {}

# ============================================================================
# MODULES
# ============================================================================
# Every module below is read-only. The list is explicit rather than a wildcard
# so an added file can never be picked up by accident.
$script:ModuleRoot = Join-Path -Path $PSScriptRoot -ChildPath 'modules'

$modules = @(
    'System.ps1'
    'Hardware.ps1'
    'Network.ps1'
    'Performance.ps1'
    'Storage.ps1'
    'Health.ps1'
    'Report.ps1'
    'SSD.ps1'   # optional: not every machine exposes wear data
)

foreach ($m in $modules) {
    $path = Join-Path -Path $script:ModuleRoot -ChildPath $m
    if (Test-Path -LiteralPath $path) {
        try { . $path } catch { Write-Warning "Failed to load $m : $($_.Exception.Message)" }
    } elseif ($m -eq 'SSD.ps1') {
        # Optional module: its absence is normal and handled by the health check.
    } else {
        Write-Warning "Missing module: $m"
    }
}

# ============================================================================
# PROGRESS
# ============================================================================
# Collection is not instant: the performance sampler alone blocks for seconds
# and SMART/SSD queries can stall on a spinning disk or a bridge that will not
# answer. Without feedback that reads as a hang, so each step updates a bar.
#
# In an interactive console the bar is rewritten in place on a single line.
# When output is redirected, or the host is not a console host, escape codes
# would corrupt a log file, so the same bar is printed as one plain line per
# step instead. Both paths show identical text.
$script:ProgressInPlace = $false
try {
    if ($Host.Name -match 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
        $script:ProgressInPlace = $true
    }
} catch {
    $script:ProgressInPlace = $false
}

function Write-PMProgress {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Label,
        [string]$Note = ''
    )

    $barWidth = 24
    $ratio = [double]$Index / [double]$Total
    $filled = [int][math]::Floor($ratio * $barWidth)
    # Show at least one block for any completed step, otherwise step 1 of 6
    # renders as an empty bar and looks like nothing happened.
    if ($filled -lt 1 -and $Index -gt 0) { $filled = 1 }
    $bar = ('#' * $filled) + ('.' * ($barWidth - $filled))
    $pct = [int][math]::Round($ratio * 100)
    $text = '  Step {0}/{1}  [{2}] {3,3}%  {4}' -f $Index, $Total, $bar, $pct, $Label
    if ($Note) { $text = "$text  $Note" }

    if ($script:ProgressInPlace) {
        # Home, clear to end of line, then rewrite, so each step overwrites the
        # last instead of scrolling a new line.
        Write-Host ("$([char]27)[1G$([char]27)[0K$text") -NoNewline
    } else {
        Write-Host $text
    }
}

# ============================================================================
# COLLECT
# ============================================================================
# Every collector is wrapped so that one unavailable WMI class cannot abort
# the whole report. A missing value is shown as N/A, never invented.
#
# Steps are data, not a hand-written sequence, so the bar can never drift out of
# sync with what actually runs: the label, the call and the progress counter all
# come from the same entry.

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "            PM-QUICK  v2.0" -ForegroundColor Cyan
Write-Host "         READ-ONLY INSPECTION" -ForegroundColor DarkGray
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Collecting system information..." -ForegroundColor DarkGray

# Warnings are buffered rather than emitted mid-bar: Write-Warning between two
# in-place updates would land on the bar line and corrupt it.
$script:CollectWarnings = New-Object System.Collections.ArrayList
$script:AddCollectWarning = {
    param([string]$Message)
    [void]$script:CollectWarnings.Add($Message)
}

$collectSteps = @(
    [pscustomobject]@{
        Label = 'System identity'
        Run   = { Get-PMSystemInfo }
    }
    [pscustomobject]@{
        Label = 'Device type'
        Run   = { Get-PMDeviceType }
    }
    [pscustomobject]@{
        Label = 'Hardware inventory'
        Run   = { Get-PMHardwareInfo }
    }
    [pscustomobject]@{
        Label = 'Network adapters'
        Run   = { Get-PMNetworkInfo }
    }
    [pscustomobject]@{
        Label = 'Performance sample'
        Run   = { Get-PMPerformanceSnapshot }
    }
    [pscustomobject]@{
        # Storage and health share one step because health re-queries the disks
        # and SSDs that storage just walked, so they are the same slow phase.
        Label = 'Storage + health'
        Run   = {
            $sto = $null
            $hea = $null
            try { $sto = Get-PMStorageInfo } catch { & $script:AddCollectWarning 'Storage info unavailable' }
            try { $hea = Get-PMHealthCheck } catch { & $script:AddCollectWarning 'Health checks unavailable' }
            [pscustomobject]@{ Storage = $sto; Health = $hea }
        }
    }
)

$collected = New-Object System.Collections.ArrayList
# Two stopwatches on purpose: $sw is restarted per step for the per-step
# timing, $swTotal runs across the whole loop. Reusing one would report only
# the final step's duration as the total.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt $collectSteps.Count; $i++) {
    $step = $collectSteps[$i]
    $result = $null
    $sw.Restart()
    try {
        $result = & $step.Run
    } catch {
        & $script:AddCollectWarning "$($step.Label) unavailable"
        $result = $null
    }
    $sw.Stop()
    [void]$collected.Add($result)

    $note = ''
    if ($result) { $note = ('{0:N1}s' -f $sw.Elapsed.TotalSeconds) }
    Write-PMProgress -Index ($i + 1) -Total $collectSteps.Count -Label $step.Label -Note $note
}
$swTotal.Stop()

# Close the bar line before any further output.
if ($script:ProgressInPlace) { Write-Host '' }

Write-Host ("  Collection finished in {0:N1}s." -f $swTotal.Elapsed.TotalSeconds) -ForegroundColor DarkGray
foreach ($w in $script:CollectWarnings) {
    Write-Warning $w
}

$system      = $collected[0]
$device      = $collected[1]
$hardware    = $collected[2]
$network     = $collected[3]
$performance = $collected[4]
$storage     = $null
$health      = $null
if ($collected[5]) {
    $storage = $collected[5].Storage
    $health  = $collected[5].Health
}

# Merge device identity into the system view for display.
if ($system) {
    if ($device) {
        Add-Member -InputObject $system -NotePropertyName 'DeviceType' -NotePropertyValue $device.DeviceType -Force
        Add-Member -InputObject $system -NotePropertyName 'DeviceEvidence' -NotePropertyValue $device.Evidence -Force
    } else {
        Add-Member -InputObject $system -NotePropertyName 'DeviceType' -NotePropertyValue 'Unknown' -Force
    }
}

# Assemble the full result set for the summary and the optional JSON export.
$inspection = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    ComputerName = [System.Environment]::MachineName
    Tool        = 'PM-Quick 2.0 (read-only)'
    System      = $system
    Device      = [pscustomobject]@{
        DeviceType     = if ($device) { $device.DeviceType } else { 'Unknown' }
        Manufacturer   = if ($system) { $system.Manufacturer } else { 'N/A' }
        Model          = if ($system) { $system.Model } else { 'N/A' }
        Evidence       = if ($device) { $device.Evidence } else { 'N/A' }
    }
    Hardware    = $hardware
    Performance = $performance
    Network     = $network
    Storage     = $storage
    Health      = $health
}

# ============================================================================
# DISPLAY
# ============================================================================

if ($system) {
    Format-PMSectionHeader 'SYSTEM'
    Write-PMField 'PC Name'         $system.PCName
    Write-PMField 'Manufacturer'    $system.Manufacturer
    Write-PMField 'Model'           $system.Model
    Write-PMField 'Serial'          $system.Serial
    Write-PMField 'Type'            $system.DeviceType
    Write-PMField 'Windows'         $system.Windows
    Write-PMField 'Build'           $system.Build
    Write-PMField 'Architecture'    $system.Architecture
    Write-PMField 'User'            $system.User
    Write-PMField 'Uptime'          $system.Uptime
    if ($device -and $device.Evidence) {
        Write-Host "    type detected from: $($device.Evidence)" -ForegroundColor DarkGray
    }
}

if ($hardware) {
    Format-PMSectionHeader 'HARDWARE'
    # These are built before printing. An if-expression cannot be passed inline
    # as a command argument: PowerShell binds 'if' as the argument and leaves
    # the else-branch as a stray statement, which renders as "CPU Clockif".
    $cpuClockText = 'N/A'
    if ($hardware.CPUBaseMHz -ne 'N/A') {
        # Labelled "current", not "base": this is Win32_Processor
        # .CurrentClockSpeed, which is the clock at the sampling instant and
        # has nothing to do with the architectural base frequency.
        $cpuClockText = "$($hardware.CPUBaseMHz) MHz current / $($hardware.CPUMaxMHz) MHz max"
    }
    $slotTotalText = 'N/A'
    if ($hardware.RAMSlotsTotal -ne 'N/A') { $slotTotalText = $hardware.RAMSlotsTotal }
    $ramSpeedText = 'N/A'
    if ($hardware.RAMSpeedMHz -ne 'N/A') { $ramSpeedText = "$($hardware.RAMSpeedMHz) MHz" }

    Write-PMField 'CPU'             $hardware.CPU
    Write-PMField 'CPU Cores'       "$($hardware.CPUCores) physical / $($hardware.CPUThreads) logical"
    Write-PMField 'CPU Clock'       $cpuClockText
    Write-PMField 'RAM'             $hardware.RAMTotal
    Write-PMField 'RAM Slots'       "$($hardware.RAMSlotsUsed) used / $slotTotalText total"
    Write-PMField 'RAM Speed'       $ramSpeedText
    Write-PMField 'RAM Type'        $hardware.RAMFormFactor

    if (@($hardware.RAMModules).Count -gt 0) {
        Write-Host ""
        Write-Host "  Memory modules:" -ForegroundColor DarkGray
        foreach ($m in $hardware.RAMModules) {
            # The PadLeft calls have to live INSIDE the subexpression, otherwise
            # PowerShell expands the value and leaves ".PadLeft(5)" as literal text.
            $cap = ([string]$m.CapacityGB).PadLeft(5)
            # BankLabel is only worth a second column when it adds information.
            # On boards that report a duplicate DeviceLocator, Hardware.ps1
            # promotes BankLabel into Locator, and printing both would repeat it.
            $slot = $m.Locator
            if ($m.Bank -and $m.Bank -ne 'N/A' -and $m.Bank -ne $m.Locator) {
                $slot = "$($m.Locator) / $($m.Bank)"
            }
            Write-Host "    $($slot.PadRight(26)) $cap GB  $($m.SpeedMHz) MHz  $($m.FormFactor)  $($m.Manufacturer)" -ForegroundColor DarkGray
        }
    }

    $gpus = @($hardware.GPU)
    Write-Host ""
    if ($gpus.Count -gt 0) {
        Write-Host "  Graphics:" -ForegroundColor DarkGray
        foreach ($g in $gpus) {
            Write-Host "    $($g.Name)" -ForegroundColor DarkGray
            Write-Host "      VRAM: $($g.VRAM)   Driver: $($g.DriverVersion) ($($g.DriverDate))" -ForegroundColor DarkGray
        }
    } else {
        Write-PMField 'Graphics' 'No GPU reported by WMI'
    }

    Write-Host ""
    Write-PMField 'Motherboard'     "$($hardware.Motherboard) $($hardware.MotherboardModel)"

    $ph = @($hardware.StorageHardware)
    if ($ph.Count -gt 0) {
        Write-Host ""
        Write-Host "  Physical disks:" -ForegroundColor DarkGray
        foreach ($d in $ph) {
            # The field is Interface, not InterfaceType. Reading InterfaceType
            # here returned nothing at all, which is why "bus:" printed blank.
            $busText = if ($d.Interface) { $d.Interface } else { 'N/A' }
            Write-Host "    [$($d.Index)] $($d.Model)" -ForegroundColor DarkGray
            Write-Host "      $($d.SizeGB) GB  bus: $busText  media: $($d.MediaType)  serial: $($d.Serial)" -ForegroundColor DarkGray
        }
    }
}

if ($performance) {
    Format-PMSectionHeader 'PERFORMANCE'
    # Get-PMPerformanceSnapshot reports CPUUsage, MemoryUsage and TotalRAMGB.
    # Rendering its real contract matters: an if-expression cannot be passed as
    # an argument inline, so each line is built first and printed after.
    if ($null -ne $performance.CPUUsage -and $performance.CPUUsage -ne 'N/A') {
        $c = $performance.CPUUsage
        $cpuColor = if ($c -ge 90) { 'Red' } elseif ($c -ge 70) { 'Yellow' } else { 'Green' }
        Write-Host "  " -NoNewline
        Write-Host 'CPU Load'.PadRight(18) -NoNewline
        Write-Host "$c%" -ForegroundColor $cpuColor
    } else {
        Write-PMField 'CPU Load' 'N/A'
    }

    if ($null -ne $performance.MemoryUsage -and $performance.MemoryUsage -ne 'N/A') {
        $m = $performance.MemoryUsage
        $memColor = if ($m -ge 90) { 'Red' } elseif ($m -ge 75) { 'Yellow' } else { 'Green' }
        $totalText = ''
        if ($performance.TotalRAMGB -and $performance.TotalRAMGB -ne 'N/A') {
            $totalText = " of $($performance.TotalRAMGB) GB"
        }
        Write-Host "  " -NoNewline
        Write-Host 'Memory'.PadRight(18) -NoNewline
        Write-Host "$m% used$totalText" -ForegroundColor $memColor
    } else {
        Write-PMField 'Memory' 'N/A'
    }
}

if ($network) {
    Format-PMSectionHeader 'NETWORK'
    $adapters = @($network.Adapters)
    if ($adapters.Count -gt 0) {
        foreach ($a in $adapters) {
            $state = if ($a.Status -eq 2) { 'Connected' } else { 'Disconnected' }
            $color = if ($a.Status -eq 2) { 'Green' } else { 'DarkGray' }
            Write-Host "  " -NoNewline
            Write-Host $a.Name -NoNewline
            Write-Host "  [$state]" -ForegroundColor $color
            Write-Host "    $($a.Description)" -ForegroundColor DarkGray
            Write-Host "    Type: $($a.Type)   MAC: $($a.MAC)   DHCP: $($a.DHCP)" -ForegroundColor DarkGray
            if ($a.SpeedMbps -ne 'N/A') {
                Write-Host "    Speed: $($a.SpeedMbps) Mbps" -ForegroundColor DarkGray
            }
            foreach ($addr in @($a.Addresses)) {
                if ($addr.IP -ne '127.0.0.1' -and $addr.IP -ne '::1') {
                    Write-Host "    $($addr.Version): $($addr.IP)" -ForegroundColor DarkGray
                }
            }
        }
    } else {
        Write-PMField 'Adapters' 'None reported'
    }

    if (@($network.Gateways).Count -gt 0) {
        # Lead with the routable gateway the module picked, and only list
        # extras that a technician could act on. An IPv6 fe80:: link-local
        # gateway is not actionable, so it is not shown alongside IPv4.
        $gwShown = @()
        if ($network.PrimaryGateway -and $network.PrimaryGateway -ne 'N/A') { $gwShown += $network.PrimaryGateway }
        foreach ($g in @($network.Gateways)) {
            if ($gwShown -contains $g) { continue }
            if ($g -like 'fe80:*') { continue }
            $gwShown += $g
        }
        if ($gwShown.Count -gt 0) {
            Write-Host ""
            Write-PMField 'Default Gateway' ($gwShown -join ', ')
        }
    }
    if (@($network.DNSServers).Count -gt 0) {
        Write-PMField 'DNS Servers'    (@($network.DNSServers) -join ', ')
    }
}

if ($storage) {
    Format-PMSectionHeader 'STORAGE'
    foreach ($d in @($storage.Drives)) {
        $line = "{0}  {1,-6}  Total {2} GB  Used {3} GB  Free {4} GB ({5})" -f `
            $d.Drive, $d.FileSystem, $d.TotalGB, $d.UsedGB, $d.FreeGB, $d.FreePct
        $color = Get-PMHealthColor -Status $d.Status
        Write-Host "  " -NoNewline
        Write-Host $line -ForegroundColor $color
    }

    $pd = @($storage.PhysicalDisks)
    if ($pd.Count -gt 0) {
        Write-Host ""
        Write-Host "  Disk health:" -ForegroundColor DarkGray
        foreach ($d in $pd) {
            Write-Host "    " -NoNewline
            Write-Host $d.Model.PadRight(34) -NoNewline
            Write-Host $d.Status -ForegroundColor (Get-PMHealthColor -Status $d.Status)
        }
    }
}

if ($health) {
    Format-PMSectionHeader 'HEALTH CHECKS'
    Write-PMHealthChecks -Checks $health.Checks

    Write-Host ""
    $overallColor = if ($health.WarningCount -gt 0) { 'Yellow' } elseif ($health.UnknownCount -gt 0) { 'DarkGray' } else { 'Green' }
    Write-Host "  Overall: " -NoNewline
    Write-Host $health.OverallStatus -ForegroundColor $overallColor
}

# ============================================================================
# SUMMARY
# ============================================================================
Format-PMSectionHeader 'SUMMARY'
$summary = $null
try { $summary = Get-PMSummaryText -Inspection $inspection } catch {}
if ($summary) {
    foreach ($line in ($summary -split [Environment]::NewLine)) {
        Write-Host "  $line"
    }
}

# ============================================================================
# OPTIONAL LOCAL JSON EXPORT
# ============================================================================
# Offered at the end, because that is the moment the user knows whether they
# want the file. -Json still writes directly and skips the question.
#
# Consent rule, identical to the cleaner's destructive gate: only a literal
# Y/y or N/n is an answer. A bare Enter is not an answer. Someone leaning on the
# key must not be able to create a file by accident, so Enter re-prompts instead
# of defaulting to yes.
$exportedReport = $null
$exportFailed = $false

function Get-PMExportDecision {
    # Total and side-effect free: returns the decision, never infers one.
    param([AllowNull()][AllowEmptyString()][string]$Answer)

    if ($null -eq $Answer) { return 'RETRY' }
    $normalized = $Answer.Trim()
    if ($normalized.Length -eq 0) { return 'RETRY' }
    if ($normalized -ceq 'Y' -or $normalized -ceq 'y') { return 'YES' }
    if ($normalized -ceq 'N' -or $normalized -ceq 'n') { return 'NO' }
    return 'RETRY'
}

function Request-PMExportDecision {
    <#
    .SYNOPSIS
        Asks whether to save the report, and refuses to guess.
    .DESCRIPTION
        The reader is injected so the consent rule can be tested without a
        console. Only a literal Y/y or N/n ends the exchange. A bare Enter -
        what happens when someone leans on the key - re-prompts and is never
        read as consent, so no file can be created by accident.

        Two escape hatches keep this from ever trapping the console:
          - the reader throwing (Ctrl+C, or the window being closed) returns NO
          - a bounded attempt count falls back to NO, because skipping an
            optional file is always the safe outcome
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Read,
        [int]$MaxAttempts = 20
    )

    $decision = 'RETRY'
    $attempts = 0
    while ($decision -eq 'RETRY' -and $attempts -lt $MaxAttempts) {
        $attempts++
        $answer = $null
        try {
            $answer = & $Read
        } catch {
            return 'NO'
        }
        $decision = Get-PMExportDecision -Answer $answer
        if ($decision -eq 'RETRY' -and $attempts -lt $MaxAttempts) {
            Write-Host "  Enter is not an answer. Type Y to save, N to skip." -ForegroundColor DarkGray
        }
    }
    if ($decision -eq 'RETRY') { return 'NO' }
    return $decision
}

function Resolve-PMExportName {
    <#
    .SYNOPSIS
        Turns whatever was typed at the name prompt into a safe file name.
    .DESCRIPTION
        Pure - returns a name, or $null if the request must be refused. Total
        and side-effect free, so the refusal rules are testable on their own.

        Refused:
          - anything holding a path character, so the write cannot be redirected
            out of the output directory by .., a rooted path or a UNC share
          - a name made only of dots ('.' and '..' are not file names)
          - a name ending in a dot or space, because Win32 silently strips those
            and would write to a differently named file than the one displayed

        A reserved device name is not refused here. Windows rejects those at
        write time and the caller already surfaces the real error, so guessing
        at the list here would only add a second, divergent copy of it.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Typed,
        [string]$DefaultName
    )

    if ([string]::IsNullOrWhiteSpace($DefaultName)) {
        $DefaultName = 'pm-quick-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    if ([string]::IsNullOrWhiteSpace($Typed)) { $Typed = $DefaultName }

    $name = $Typed.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    # The backslash must be doubled here. In a single-quoted PowerShell string
    # '[\\/...]' is a class holding both separators; writing '[\/...]' lets the
    # backslash escape the slash instead of matching it, which would let
    # '..\evil.json' straight through.
    if ($name -match '[\\/:*?"<>|]') { return $null }
    if ($name -match '^\.+$') { return $null }
    # Trim has already removed a trailing space, so only the dot is left to
    # catch: Win32 strips it silently and the file written would not match the
    # name shown to the user.
    if ($name -match '\.$') { return $null }
    return $name
}

function Get-PMClosingSummary {
    <#
    .SYNOPSIS
        Builds the closing block, stating what actually happened.
    .DESCRIPTION
        Pure - returns lines, prints nothing. An unconditional "nothing was
        changed" would be a false claim in the one mode that does write a file,
        so each outcome gets its own wording and each is asserted by the suite.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$ExportedReport,
        [switch]$ExportFailed
    )

    $lines = @('========================================')
    $lines += 'Nothing was changed, deleted or uploaded.'
    if (-not [string]::IsNullOrWhiteSpace($ExportedReport)) {
        $lines += "Saved: $ExportedReport"
    } elseif ($ExportFailed) {
        $lines += 'Export failed - no report file was written.'
    }
    $lines += 'For TEMP/Recycle Bin cleanup run Temp-Cleaner.bat'
    $lines += '========================================'
    return $lines
}

if (-not $Json) {
    # Never prompt when there is no human there to answer. A redirected stdin
    # returns EOF forever and would spin, so the offer is skipped outright.
    $canPrompt = (-not $NoExportPrompt) -and
                 [Environment]::UserInteractive -and
                 (-not [Console]::IsInputRedirected)

    if ($canPrompt) {
        Write-Host ""
        Write-Host "  Save this report as a local JSON file? [Y/N]" -ForegroundColor Cyan
        Write-Host "  Press Enter to skip. Nothing is written unless you type Y." -ForegroundColor DarkGray

        $decision = Request-PMExportDecision -Read { Read-Host '  Export JSON? [Y/N]' }

        if ($decision -eq 'YES') {
            $defaultName = 'pm-quick-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
            $typed = $null
            try {
                $typed = Read-Host "  File name [$defaultName]"
            } catch {
                # Interrupted at the name prompt: no file, no error spew.
                $typed = $null
            }
            $safeName = Resolve-PMExportName -Typed $typed -DefaultName $defaultName
            if ($safeName) {
                $Json = $safeName
            } else {
                Write-Host "  '$typed' is not a usable file name. Nothing was written." -ForegroundColor Red
                $exportFailed = $true
            }
        }
        # A declined offer is deliberately silent: nothing happened, and the
        # summary says exactly that.
    }
}

if ($Json) {
    try {
        # Default into the project's own output directory, never anywhere else.
        if (-not [System.IO.Path]::IsPathRooted($Json)) {
            $Json = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path 'output' -ChildPath $Json)
        }

        $saved = Export-PMInspectionJson -Inspection $inspection -Path $Json
        $exportedReport = $saved
        Write-Host ""
        Write-Host "  Report saved locally: $saved" -ForegroundColor Green
    } catch {
        $exportFailed = $true
        Write-Host ""
        Write-Host "  Could not write JSON report: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# FOOTER
# ============================================================================
# States what actually happened. An unconditional "nothing was changed" would be
# a false claim in the one mode that does write a file.
Write-Host ""
foreach ($summaryLine in Get-PMClosingSummary -ExportedReport $exportedReport -ExportFailed:$exportFailed) {
    if ($summaryLine -match '^=+$') {
        Write-Host "  $summaryLine" -ForegroundColor Cyan
    } else {
        Write-Host "  $summaryLine" -ForegroundColor DarkGray
    }
}
Write-Host ""
