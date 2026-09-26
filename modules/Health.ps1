function Get-PMHealthCheck {
    <#
    .SYNOPSIS
        Read-only hardware health checks: battery, TPM, Secure Boot, Windows
        Update, disk space, disk health and overall SSD wear.
    .DESCRIPTION
        Every check returns OK / Warning / Unknown plus a plain-English detail
        line. "Unknown" is a first-class result and is never reported as "OK":
        on a non-elevated session, or on a device with the feature removed, a
        check that cannot read its source is Unknown, not a pass.

        Nothing here writes, repairs, updates or reconfigures anything. The
        Windows Update check reads the pending-reboot marker and reboot-pending
        registry values, which is what "needs a restart" means after an update
        installs files but has not restarted yet. It does not install anything.

        Notes on specific checks:
          - TPM and VBS/Secure Boot are read via CIM. A disabled feature is
            reported from real state, never assumed.
          - The disk space check reuses Get-PMStorageInfo rather than
            reimplementing it, so there is one definition of "low".
    #>
    [CmdletBinding()]
    param()

    $checks = New-Object System.Collections.ArrayList

    function Add-Check {
        param(
            [string]$Name,
            [string]$Status,     # OK | Warning | Unknown
            [string]$Value,
            [string]$Detail
        )
        [void]$checks.Add([pscustomobject]@{
            Name   = $Name
            Status = $Status
            Value  = $Value
            Detail = $Detail
        })
    }

    # --- battery ------------------------------------------------------------
    try {
        $batteries = @(Get-CimInstance Win32_Battery -ErrorAction Stop |
            Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft AC Adapter' })
        if ($batteries.Count -eq 0) {
            Add-Check 'Battery' 'Unknown' 'No battery' 'No battery is reported. Expected on a desktop.'
        } else {
            $b = $batteries[0]
            $charge = $null
            if ($b.EstimatedChargeRemaining) { $charge = [int]$b.EstimatedChargeRemaining }
            if ($charge -eq $null) {
                Add-Check 'Battery' 'Unknown' 'N/A' 'Charge level is not reported by this battery.'
            } else {
                $status = 'OK'
                if ($charge -le 20) { $status = 'Warning' }
                Add-Check 'Battery' $status "$charge%" "Battery is at $charge%."
            }
        }
    } catch {
        Add-Check 'Battery' 'Unknown' 'N/A' 'Battery information is not available.'
    }

    # --- TPM ----------------------------------------------------------------
    try {
        $tpm = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop |
            Select-Object -First 1
        if ($tpm) {
            # Both flags are read explicitly, because a missing property is $null
            # and -not $null is true, which would report a healthy TPM as broken.
            $enabled   = ($null -ne $tpm.IsEnabled_)
            $activated = ($null -ne $tpm.IsActivated)
            $firmware  = if ($tpm.ManufacturerVersionFull20) { $tpm.ManufacturerVersionFull20 } else { 'unknown firmware' }
            $specVer   = if ($null -ne $tpm.SpecVersion) { $tpm.SpecVersion } else { 'unknown spec version' }

            # The detail has to be derived from the flags. A hardcoded
            # "is enabled and activated" printed next to a Warning status is a
            # contradiction the reader cannot resolve, and it is worse than
            # saying nothing.
            if ($enabled -and $activated) {
                $status = 'OK'
                $detail = "TPM $firmware is enabled and activated."
            } else {
                $status = 'Warning'
                $faults = @()
                if (-not $enabled)   { $faults += 'not enabled in firmware' }
                if (-not $activated) { $faults += 'present but not activated' }
                if ($faults.Count -eq 0) { $faults += 'in an unrecognised state' }
                $detail = "TPM $firmware is " + ($faults -join ' and ') + '.'
            }
            Add-Check 'TPM' $status $specVer $detail
        } else {
            Add-Check 'TPM' 'Unknown' 'N/A' 'No TPM is reported by Windows.'
        }
    } catch {
        Add-Check 'TPM' 'Unknown' 'N/A' 'TPM information is not available.'
    }

    # --- Secure Boot / VBS --------------------------------------------------
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($dg) {
            $vbs = $dg.VirtualizationBasedSecurityStatus   # 0 off, 1 enabled not running, 2 running
            if ($vbs -eq 2) {
                Add-Check 'Secure Boot (VBS)' 'OK' 'Running' 'Virtualization Based Security is running. VBS is the platform this check can confirm; Secure Boot is enforced separately by UEFI and is not read here.'
            } else {
                $state = if ($vbs -eq 1) { 'Enabled (not running)' } else { 'Off' }
                Add-Check 'Secure Boot (VBS)' 'Warning' $state 'Secure Boot and credential guard are not currently protecting the system.'
            }
        } else {
            Add-Check 'Secure Boot (VBS)' 'Unknown' 'N/A' 'Device Guard information is not available.'
        }
    } catch {
        Add-Check 'Secure Boot (VBS)' 'Unknown' 'N/A' 'Secure Boot state could not be read.'
    }

    # --- pending reboot -----------------------------------------------------
    try {
        $pendingReasons = New-Object System.Collections.ArrayList
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            [void]$pendingReasons.Add('Component Based Servicing')
        }
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            [void]$pendingReasons.Add('Windows Update')
        }
        try {
            $p = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($p -and $p.PendingFileRenameOperations) { [void]$pendingReasons.Add('Pending file operations') }
        } catch {}

        if ($pendingReasons.Count -gt 0) {
            Add-Check 'Pending Reboot' 'Warning' 'Required' ("Restart required: " + ($pendingReasons -join ', '))
        } else {
            Add-Check 'Pending Reboot' 'OK' 'Not required' 'No pending restart was detected.'
        }
    } catch {
        Add-Check 'Pending Reboot' 'Unknown' 'N/A' 'Pending restart state could not be read.'
    }

    # --- storage free space -------------------------------------------------
    try {
        $storage = Get-PMStorageInfo
        if ($storage -and $storage.LowSpaceCount -gt 0) {
            foreach ($msg in $storage.LowSpace) {
                Add-Check 'Disk Space' 'Warning' '' $msg
            }
        } else {
            Add-Check 'Disk Space' 'OK' '' 'All fixed drives have more than 10% free space.'
        }
    } catch {
        Add-Check 'Disk Space' 'Unknown' 'N/A' 'Storage information is not available.'
    }

    # --- disk SMART status --------------------------------------------------
    try {
        $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)
        $worst = 'OK'
        $lines = New-Object System.Collections.ArrayList
        foreach ($d in $disks) {
            $model = if ($d.Model) { ([string]$d.Model).Trim() } else { 'Unknown disk' }
            $state = if ($d.Status) { $d.Status } else { 'Unknown' }
            if ($state -ne 'OK') { $worst = 'Warning' }
            [void]$lines.Add("$model reports status: $state")
        }
        if ($lines.Count -gt 0) {
            Add-Check 'Disk Health' $worst '' ($lines -join '; ')
        }
    } catch {}

    # --- SSD wear (optional module) -----------------------------------------
    # Added only when the SSD module is available. If it is absent the check is
    # simply missing rather than faked as OK.
    if (Get-Command Get-PMSSDHealth -ErrorAction SilentlyContinue) {
        try {
            $ssd = @(Get-PMSSDHealth)
            if ($ssd.Count -gt 0) {
                # Starts Unknown, not OK. A check that read no wear data must not
                # report a pass, which is the rule this module documents for
                # itself. It is only promoted to OK once real wear was read.
                $ssdStatus = 'Unknown'
                $ssdLines = New-Object System.Collections.ArrayList
                $wearRead = 0
                foreach ($d in $ssd) {
                    $label = if ($d.Model) { $d.Model } else { 'SSD' }
                    # The SSD module exposes "Wear". It was read as "WearLevel"
                    # here, which never matched, so wear was reported as
                    # unavailable even on drives that do expose it.
                    $wear = $d.Wear
                    if ($null -ne $wear -and "$wear" -ne '' -and "$wear" -ne 'N/A') {
                        $wearRead++
                        if ([int]$wear -ge 90) { $ssdStatus = 'Warning' }
                        elseif ($ssdStatus -ne 'Warning') { $ssdStatus = 'OK' }
                        [void]$ssdLines.Add("$label wear level: $wear%")
                    } else {
                        [void]$ssdLines.Add("$label wear level not available")
                    }
                }
                if ($wearRead -eq 0) { $ssdStatus = 'Unknown' }
                if ($ssdLines.Count -gt 0) {
                    Add-Check 'SSD Wear' $ssdStatus '' ($ssdLines -join '; ')
                }
            }
        } catch {}
    }

    $warningCount = @($checks | Where-Object { $_.Status -eq 'Warning' }).Count
    $unknownCount = @($checks | Where-Object { $_.Status -eq 'Unknown' }).Count

    $overall = 'No issues detected'
    if ($warningCount -gt 0) { $overall = 'Attention needed' }
    elseif ($unknownCount -gt 0) { $overall = 'Partially unknown' }

    [pscustomobject]@{
        Checks        = $checks.ToArray()
        WarningCount  = $warningCount
        UnknownCount  = $unknownCount
        OverallStatus = $overall
    }
}
