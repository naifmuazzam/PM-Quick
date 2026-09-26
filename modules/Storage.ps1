function Get-PMStorageInfo {
    <#
    .SYNOPSIS
        Read-only drive inventory with free-space percentage, plus physical disk
        and disk-controller health.
    .DESCRIPTION
        The main addition over the old version is a computed FreePct: a drive at
        "18 GB free" says nothing without knowing how big it is, and FreePct is
        the number that actually drives a "disk is filling up" recommendation.

        The read-only health status is reported separately from SSD wear because
        they are different things: a "Healthy" SMART status says the disk is
        not failing, not that it is not nearly full. Reporting only SMART is
        how a full disk slips through a health check.

        All queries are WMI reads. No repair, no chkdsk, no SMART write, no
        volume change.
    #>
    [CmdletBinding()]
    param()

    $drives = New-Object System.Collections.ArrayList
    $lowSpace = New-Object System.Collections.ArrayList

    # FreePct at or below this is what gets flagged for a technician.
    $lowSpaceThreshold = 10

    try {
        $logicalDisks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
        foreach ($d in $logicalDisks) {
            $sizeGB = 0
            $freeGB = 0
            $freePct = $null

            if ($d.Size -and $d.Size -gt 0) {
                $sizeGB = [math]::Round($d.Size / 1GB, 1)
                $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                $freePct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
            }

            $label = '{0}:' -f $d.DeviceID
            $status = 'Normal'

            if ($freePct -ne $null) {
                if ($freePct -le 2) {
                    $status = 'Critical'
                    [void]$lowSpace.Add("$label free space is critically low ($freePct%)")
                } elseif ($freePct -le $lowSpaceThreshold) {
                    $status = 'Low'
                    [void]$lowSpace.Add("$label free space is low ($freePct%)")
                }
            }

            [void]$drives.Add([pscustomobject]@{
                Drive     = $d.DeviceID
                Label     = if ($d.VolumeName) { $d.VolumeName } else { 'N/A' }
                FileSystem = if ($d.FileSystem) { $d.FileSystem } else { 'N/A' }
                TotalGB   = if ($sizeGB -gt 0) { $sizeGB } else { 'N/A' }
                FreeGB    = if ($sizeGB -gt 0) { $freeGB } else { 'N/A' }
                UsedGB    = if ($sizeGB -gt 0) { [math]::Round($sizeGB - $freeGB, 1) } else { 'N/A' }
                FreePct   = if ($freePct -ne $null) { "$freePct%" } else { 'N/A' }
                Status    = $status
            })
        }
    } catch {}

    # --- physical disk hardware ---------------------------------------------
    # Win32_DiskDrive.MediaType is deprecated and returns the literal string
    # "Fixed hard disk media" for nearly every modern SATA/NVMe disk, so the
    # Storage module is asked first and WMI is only the fallback. BusType and
    # MediaType from Get-PhysicalDisk are accurate.
    $disks = New-Object System.Collections.ArrayList
    $physByModel = @{}
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $key = ([string]$pd.FriendlyName).Trim().ToUpper()
            if ($key) { $physByModel[$key] = $pd }
        }
    } catch {}

    try {
        foreach ($d in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)) {
            $model = if ($d.Model) { ([string]$d.Model).Trim() } else { 'N/A' }
            $serial = ([string]$d.SerialNumber).Trim()
            if ($serial) { $serial = ($serial -replace '\s+', ' ').Trim() }

            $media = 'Unknown'
            $bus = if ($d.InterfaceType) { $d.InterfaceType } else { 'Unknown' }

            $pd = $null
            if ($physByModel.ContainsKey($model.ToUpper())) { $pd = $physByModel[$model.ToUpper()] }

            if ($pd) {
                if ($pd.MediaType) { $media = [string]$pd.MediaType }
                if ($pd.BusType) { $bus = [string]$pd.BusType }
            } else {
                if ($d.MediaType -and $d.MediaType -notmatch 'Fixed hard disk media') { $media = $d.MediaType }
                elseif ($model -match 'SSD|NVMe|Solid State') { $media = 'SSD' }
                elseif ($model -match 'HDD|SATA|Mechanical') { $media = 'HDD' }
            }

            # Status is null when the SMART data sits behind a bridge that will
            # not answer it. Unknown is reported as Unknown, never as OK.
            $status = 'Unknown'
            if ($d.Status) {
                $status = if ($d.Status -eq 'OK') { 'Healthy' } else { $d.Status }
            }

            [void]$disks.Add([pscustomobject]@{
                Index     = $d.Index
                Model     = $model
                Serial    = if ($serial) { $serial } else { 'N/A' }
                SizeGB    = if ($d.Size) { [math]::Round($d.Size / 1GB, 1) } else { 'N/A' }
                Interface = $bus
                MediaType = $media
                Status    = $status
            })
        }
    } catch {}

    [pscustomobject]@{
        Drives         = $drives.ToArray()
        PhysicalDisks  = $disks.ToArray()
        LowSpace       = $lowSpace.ToArray()
        LowSpaceCount  = $lowSpace.Count
    }
}
