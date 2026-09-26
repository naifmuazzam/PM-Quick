function Get-PMDeviceType {
    <#
    .SYNOPSIS
        Determines whether the machine is a Desktop, a Laptop, or Unknown.
    .DESCRIPTION
        Combines three independent Windows hardware signals and returns the
        winner plus the raw evidence, so a technician can see WHY a call was
        made. The PC name is never used: naming conventions are not evidence.

        Signals, in order of trust:
          1. Win32_SystemEnclosure.ChassisTypes - the physical chassis
          2. Win32_ComputerSystem.PCSystemType     - 2 Laptop, 3 Desktop
          3. Win32_Battery                         - a battery implies portable

        A score is used rather than a first-match-wins chain, because real
        hardware disagrees with itself: some ultraportables report a Desktop
        chassis, and some desktops expose a controller battery.
    #>
    [CmdletBinding()]
    param()

    $laptopScore = 0
    $desktopScore = 0
    $evidence = New-Object System.Collections.Generic.List[string]

    # --- chassis ------------------------------------------------------------
    $portableChassis = @(8, 9, 10, 11, 12, 14, 30, 31, 32)
    $desktopChassis  = @(3, 6, 7, 13, 15, 16, 17, 23, 24, 28, 34)

    $chassisTypes = @()
    try {
        $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1
        if ($enclosure -and $enclosure.ChassisTypes) {
            $chassisTypes = @($enclosure.ChassisTypes)
            $evidence.Add("chassis types: $($chassisTypes -join ',')")
            if (@($chassisTypes | Where-Object { $portableChassis -contains $_ }).Count -gt 0) { $laptopScore += 2 }
            if (@($chassisTypes | Where-Object { $desktopChassis -contains $_ }).Count -gt 0) { $desktopScore += 1 }
        }
    } catch {}

    # --- PCSystemType -------------------------------------------------------
    $pcSystemType = $null
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $pcSystemType = $cs.PCSystemType
        $evidence.Add("PCSystemType: $pcSystemType")
        if ($pcSystemType -eq 2) { $laptopScore += 2 }
        if ($pcSystemType -eq 3) { $desktopScore += 2 }
    } catch {}

    # --- battery ------------------------------------------------------------
    # Only counted as evidence when a battery really is present.
    $batteryPresent = $false
    try {
        $batteryPresent = ($null -ne (Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1))
        $evidence.Add("battery present: $batteryPresent")
        if ($batteryPresent) { $laptopScore += 2 } else { $desktopScore += 1 }
    } catch {
        $evidence.Add('battery query unavailable')
    }

    $deviceType = 'Unknown'
    if ($laptopScore -ge 2 -and $laptopScore -gt $desktopScore) {
        $deviceType = 'Laptop'
    } elseif ($desktopScore -ge 2 -and $desktopScore -gt $laptopScore) {
        $deviceType = 'Desktop'
    } elseif ($batteryPresent) {
        # A real battery is still the strongest single physical fact available.
        $deviceType = 'Laptop'
    }

    [pscustomobject]@{
        DeviceType    = $deviceType
        BatteryPresent = $batteryPresent
        PCSystemType  = $pcSystemType
        ChassisTypes  = ($chassisTypes -join ',')
        Evidence      = ($evidence -join '; ')
    }
}

function Get-PMSystemInfo {
    <#
    .SYNOPSIS
        Read-only core system identity: name, serial, manufacturer, model,
        Windows edition and build, architecture, logged-on user and uptime.
    .DESCRIPTION
        Every field falls back to 'N/A' rather than guessing. No product key,
        no credential and no registry write is involved.
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        PCName       = 'N/A'
        Serial       = 'N/A'
        Manufacturer = 'N/A'
        Model        = 'N/A'
        Windows      = 'N/A'
        Build        = 'N/A'
        Architecture = 'N/A'
        User         = 'N/A'
        Uptime       = 'N/A'
    }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $result.PCName = $cs.Name
        $result.User   = $cs.UserName
        if ($cs.Manufacturer) { $result.Manufacturer = $cs.Manufacturer }
        if ($cs.Model) { $result.Model = $cs.Model }
    } catch {}

    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        # SerialNumber is routinely padded with spaces or a placeholder string.
        $serial = ([string]$bios.SerialNumber).Trim()
        if ($serial -and $serial -notmatch '^(To be filled by O\.E\.M\.|Default string|None|N/A)$') {
            $result.Serial = $serial
        }
    } catch {}

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = $os.Caption
        $build   = $os.BuildNumber

        if ($caption -match 'Windows 11') {
            $result.Windows = ($caption -replace 'Microsoft Windows ', 'Windows ')
        } elseif ($caption -match 'Windows 10') {
            $result.Windows = ($caption -replace 'Microsoft Windows ', 'Windows ')
        } elseif ($caption) {
            $result.Windows = $caption
        }

        # UBR is the update build revision; without it a build number is
        # ambiguous on a patched machine.
        $ubr = $null
        try {
            $ubr = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction SilentlyContinue).UBR
        } catch {}
        $result.Build = if ($ubr) { "$build.$ubr" } else { "$build" }

        if ($os.OSArchitecture) { $result.Architecture = $os.OSArchitecture }
    } catch {}

    if (-not $result.Architecture -or $result.Architecture -eq 'N/A') {
        if ($env:PROCESSOR_ARCHITECTURE) { $result.Architecture = $env:PROCESSOR_ARCHITECTURE }
    }

    # Extract username from DOMAIN\user format
    if ($result.User -and $result.User -match '\\(.+)$') {
        $result.User = $Matches[1]
    }

    # Uptime, rendered the way a technician reads it.
    try {
        $os2 = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os2.LastBootUpTime) {
            $uptime = (Get-Date) - $os2.LastBootUpTime
            $days = [int]$uptime.TotalDays
            $hours = $uptime.Hours
            $mins = $uptime.Minutes

            $parts = @()
            if ($days -gt 0) { $parts += "$days day$(if ($days -ne 1) { 's' })" }
            if ($hours -gt 0 -or $days -gt 0) { $parts += "$hours hour$(if ($hours -ne 1) { 's' })" }
            if ($parts.Count -eq 0) { $parts += "$mins min" }
            $result.Uptime = ($parts -join ' ')
        }
    } catch {}

    [pscustomobject]$result
}
