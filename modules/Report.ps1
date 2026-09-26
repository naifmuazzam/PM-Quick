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

function Format-PMSectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $('=' * 40)" -ForegroundColor DarkGray
}

function Write-PMField {
    param(
        [string]$Label,
        [string]$Value,
        [int]$LabelWidth = 18
    )
    $padded = $Label.PadRight($LabelWidth)
    Write-Host "  $padded" -NoNewline
    Write-Host $Value
}

function Write-PMBullet {
    param(
        [string]$Text,
        [string]$Color = 'Gray'
    )
    Write-Host "  - $Text" -ForegroundColor $Color
}

function Get-PMHealthColor {
    <#
    .SYNOPSIS
        Maps a health status to a console colour.
    #>
    param([string]$Status)
    switch ($Status) {
        'OK'          { return 'Green' }
        'Warning'     { return 'Yellow' }
        'Healthy'     { return 'Green' }
        'Normal'      { return 'Green' }
        'Low'         { return 'Yellow' }
        'Critical'    { return 'Red' }
        'Failing'     { return 'Red' }
        'Error'       { return 'Red' }
        default       { return 'DarkGray' }
    }
}

function Write-PMHealthChecks {
    <#
    .SYNOPSIS
        Renders the health check list.
    #>
    param($Checks)

    foreach ($c in $Checks) {
        $color = Get-PMHealthColor -Status $c.Status
        $statusText = $c.Status
        if ($c.Value -and $c.Value -ne 'N/A') { $statusText = "$($c.Status) ($($c.Value))" }
        Write-Host "  " -NoNewline
        Write-Host ($c.Name.PadRight(24)) -NoNewline
        Write-Host $statusText -ForegroundColor $color
        if ($c.Detail) {
            Write-Host "    $($c.Detail)" -ForegroundColor DarkGray
        }
    }
}

function Get-PMSummaryText {
    <#
    .SYNOPSIS
        Builds a compact plain-text technician summary.
    .DESCRIPTION
        Intended to be pasted into a ticket. It states the facts and the
        recommended actions; it does not include credentials, product keys,
        software serials or any machine-unique secret.
    #>
    param($Inspection)

    $lines = New-Object System.Collections.Generic.List[string]
    $sys = $Inspection.System
    $dev = $Inspection.Device

    $lines.Add("TECHNICIAN SUMMARY")
    $lines.Add("==================")
    $lines.Add("Machine   : $($dev.Manufacturer) $($dev.Model)")
    $lines.Add("Name      : $($sys.PCName)")
    $lines.Add("Serial    : $($sys.Serial)")
    $lines.Add("Type      : $($dev.DeviceType)")
    $lines.Add("OS        : $($sys.Windows) (Build $($sys.Build), $($sys.Architecture))")
    $lines.Add("Uptime    : $($sys.Uptime)")
    $lines.Add("User      : $($sys.User)")
    $lines.Add("")

    $lines.Add("HARDWARE")
    $lines.Add("--------")
    $lines.Add("CPU       : $($Inspection.Hardware.CPU)")
    $lines.Add("Cores     : $($Inspection.Hardware.CPUCores) physical / $($Inspection.Hardware.CPUThreads) logical")
    $lines.Add("RAM       : $($Inspection.Hardware.RAMTotal) ($($Inspection.Hardware.RAMFormFactor), $($Inspection.Hardware.RAMSpeedMHz) MHz)")
    $gpuParts = @()
    foreach ($g in @($Inspection.Hardware.GPU)) {
        $gpuParts += "$($g.Name) [$($g.VRAM)]"
    }
    $lines.Add("GPU       : $(if ($gpuParts.Count -gt 0) { $gpuParts -join '; ' } else { 'N/A' })")
    $lines.Add("Motherboard: $($Inspection.Hardware.Motherboard) $($Inspection.Hardware.MotherboardModel)")
    $lines.Add("")

    $lines.Add("STORAGE")
    $lines.Add("-------")
    foreach ($d in @($Inspection.Storage.Drives)) {
        $lines.Add("$($d.Drive.PadRight(4)) $($d.FileSystem.PadRight(6)) Total $($d.TotalGB) GB / Free $($d.FreeGB) GB ($($d.FreePct))  [$($d.Status)]")
    }
    $lines.Add("")

    $lines.Add("NETWORK")
    $lines.Add("-------")
    $lines.Add("Adapter   : $($Inspection.Network.PrimaryAdapter)")
    $lines.Add("IPv4      : $($Inspection.Network.PrimaryIPv4)")
    $lines.Add("Gateway   : $($Inspection.Network.PrimaryGateway)")
    $lines.Add("MAC       : $($Inspection.Network.PrimaryMac)")
    $lines.Add("")

    $lines.Add("HEALTH")
    $lines.Add("------")
    $lines.Add("Overall   : $($Inspection.Health.OverallStatus)")
    foreach ($c in @($Inspection.Health.Checks)) {
        $value = if ($c.Value -and $c.Value -ne 'N/A') { " ($($c.Value))" } else { '' }
        $lines.Add("  $($c.Name.PadRight(24)) $($c.Status)$value")
    }

    $lines.Add("")
    $lines.Add("RECOMMENDED ACTIONS")
    $lines.Add("-------------------")
    $actions = Get-PMRecommendations -Inspection $Inspection
    if ($actions.Count -eq 0) {
        $lines.Add("  - No action required.")
    } else {
        foreach ($a in $actions) { $lines.Add("  - $a") }
    }

    ($lines -join [Environment]::NewLine)
}

function Get-PMRecommendations {
    <#
    .SYNOPSIS
        Derives recommended actions from collected facts.
    .DESCRIPTION
        Recommendations are only produced from values that were actually read.
        A check that returned Unknown never produces a recommendation, because
        "we could not read it" is not the same as "it is broken".
    #>
    param($Inspection)

    $actions = New-Object System.Collections.Generic.List[string]

    $storage = $Inspection.Storage
    if ($storage -and $storage.LowSpaceCount -gt 0) {
        foreach ($m in $storage.LowSpace) { $actions.Add("Clear space: $m") }
    }

    $health = $Inspection.Health
    if ($health) {
        foreach ($c in @($health.Checks)) {
            if ($c.Status -ne 'Warning') { continue }
            switch ($c.Name) {
                'Battery'          { $actions.Add('Battery is low. Connect power and plan a battery health check.') }
                'TPM'              { $actions.Add('TPM is disabled or not activated. Check firmware TPM state.') }
                'Secure Boot (VBS)' { $actions.Add('Secure Boot is off. Confirm whether it was disabled deliberately.') }
                'Pending Reboot'   { $actions.Add('Restart required to finish a pending update or file operation.') }
                'SSD Wear'         { $actions.Add('SSD wear is high. Plan a replacement.') }
                'Disk Health'      { $actions.Add('A disk reported a non-OK status. Review the SMART detail.') }
                'Disk Space'       { $actions.Add('Free up disk space.') }
            }
        }
    }

    $gpuCount = @($Inspection.Hardware.GPU).Count
    if ($gpuCount -eq 0) {
        $actions.Add('No GPU was reported by WMI. Confirm display drivers are installed.')
    }

    if ($sys = $Inspection.System) {
        if ($sys.Serial -eq 'N/A') {
            $actions.Add('Machine serial is not exposed by the BIOS. Check the OEM label for the service tag.')
        }
    }

    if (@($Inspection.Hardware.CPUMaxMHz).Count -gt 0 -and $Inspection.Hardware.CPUMaxMHz -eq 'N/A') {
        $actions.Add('CPU clock speed is not reported by this CPU/driver combination.')
    }

    $ram = $Inspection.Hardware
    if ($ram.RAMSlotsUsed -eq 0) {
        $actions.Add('No memory modules were reported. Verify RAM detection in firmware.')
    }

    # .ToArray(), not @($actions). Wrapping a List in @() on Windows PowerShell
    # 5.1 yields a single-element array holding the List itself, so the caller
    # saw Count 1 and printed the collection object instead of the strings.
    return $actions.ToArray()
}

function Export-PMInspectionJson {
    <#
    .SYNOPSIS
        Writes the inspection to a local JSON file.
    .DESCRIPTION
        The file is written under the project 'output' directory by the caller.
        This function performs no network call of any kind: no upload, no API,
        no telemetry, no registry write. Values that PowerShell cannot serialise
        are dropped rather than stringified into something misleading.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Inspection,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Depth 8 is required: Inspection -> Hardware -> GPU[] -> each object.
    $json = $Inspection | ConvertTo-Json -Depth 8

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    $Path
}
