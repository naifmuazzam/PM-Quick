function Get-PMStorageInfo {
    [CmdletBinding()]
    param()

    $drives = @()

    $externalBusTypes = @('USB', '1394', 'SD', 'MMC')

    # Method 1: Get-Volume + Get-Partition + Get-Disk + Get-PhysicalDisk chain
    try {
        $volumes = Get-Volume -ErrorAction Stop |
            Where-Object { $_.DriveLetter -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') }

        foreach ($vol in $volumes) {
            $letter   = $vol.DriveLetter
            $fs       = $vol.FileSystem
            $totalRaw = $vol.Size
            $freeRaw  = $vol.SizeRemaining

            if (-not $totalRaw -or $totalRaw -eq 0) { continue }

            $totalGB = [math]::Round($totalRaw / 1GB, 2)
            $freeGB  = [math]::Round($freeRaw / 1GB, 2)

            # Try to map to physical disk
            $mediaType  = 'Unknown'
            $busType    = 'Unknown'
            $location   = 'Unknown'

            try {
                $partition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if ($partition) {
                    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue

                    if ($disk) {
                        $busType = "$($disk.BusType)"

                        $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue |
                            Where-Object { "$($_.DeviceId)" -eq "$($disk.Number)" } |
                            Select-Object -First 1

                        if ($physical) {
                            $mediaType = "$($physical.MediaType)"
                        } else {
                            # Fallback: SpindleSpeed from CIM
                            try {
                                $cimDisk = Get-CimInstance -Namespace Root\Microsoft\Windows\Storage `
                                    -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue |
                                    Where-Object { "$($_.DeviceId)" -eq "$($disk.Number)" } |
                                    Select-Object -First 1

                                if ($cimDisk -and $cimDisk.SpindleSpeed -eq 0) {
                                    $mediaType = 'SSD'
                                } elseif ($cimDisk -and $cimDisk.SpindleSpeed -gt 0 -and $cimDisk.SpindleSpeed -ne 4294967295) {
                                    $mediaType = 'HDD'
                                }
                            } catch {}
                        }

                        if ($busType -in $externalBusTypes) {
                            $location = 'External'
                        } else {
                            $location = 'Internal'
                        }
                    }
                }
            } catch {}

            # Classify media type
            $typeLabel = switch ($mediaType) {
                'SSD'         { 'SSD' }
                'HDD'         { 'HDD' }
                'SCM'         { 'SCM' }
                'Unspecified' { 'Unknown' }
                default       { $mediaType }
            }

            $drives += [pscustomobject]@{
                Drive        = "${letter}:"
                FileSystem   = $fs
                TotalGB      = $totalGB
                FreeGB       = $freeGB
                MediaType    = $typeLabel
                BusType      = $busType
                Location     = $location
            }
        }
    } catch {}

    # Fallback: Win32_LogicalDisk if Get-Volume failed
    if ($drives.Count -eq 0) {
        try {
            $logicalDisks = Get-CimInstance Win32_LogicalDisk -ErrorAction Stop |
                Where-Object { $_.DriveType -in @(2, 3) }  # Fixed=3, Removable=2

            foreach ($ld in $logicalDisks) {
                $letter = $ld.DeviceID
                $totalRaw = $ld.Size
                $freeRaw  = $ld.FreeSpace

                if (-not $totalRaw -or $totalRaw -eq 0) { continue }

                $drives += [pscustomobject]@{
                    Drive        = $letter
                    FileSystem   = $ld.FileSystem
                    TotalGB      = [math]::Round($totalRaw / 1GB, 2)
                    FreeGB       = [math]::Round($freeRaw / 1GB, 2)
                    MediaType    = 'Unknown'
                    BusType      = 'Unknown'
                    Location     = if ($ld.DriveType -eq 2) { 'External' } else { 'Internal' }
                }
            }
        } catch {}
    }

    # Sort: Internal first, then External, by drive letter
    $drives | Sort-Object Location, Drive
}
