function Get-PMSSDHealth {
    [CmdletBinding()]
    param()

    $ssdInfo = @()

    try {
        $physicalDisks = Get-PhysicalDisk -ErrorAction Stop |
            Where-Object { $_.MediaType -eq 'SSD' }

        foreach ($pd in $physicalDisks) {
            $model     = $pd.FriendlyName
            $health    = "$($pd.HealthStatus)"
            $opStatus  = ($pd.OperationalStatus -join ', ')
            $busType   = "$($pd.BusType)"
            $diskNum   = $pd.DeviceId

            $temperature   = 'N/A'
            $wear          = 'N/A'
            $estLife       = 'N/A'
            $powerOnHours  = 'N/A'
            $readErrors    = 'N/A'
            $writeErrors   = 'N/A'

            # === Map to drive letters via Volume → Partition → Disk chain ===
            $driveLetters = @()
            try {
                $partitions = Get-Partition -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter -and "$($_.DiskNumber)" -eq "$diskNum" }
                foreach ($p in $partitions) {
                    $driveLetters += "$($p.DriveLetter):"
                }
            } catch {}
            $driveLetters = $driveLetters | Sort-Object -Unique

            # === Method 1: Get-StorageReliabilityCounter ===
            try {
                $counter = $pd | Get-StorageReliabilityCounter -ErrorAction Stop

                if ($counter) {
                    if ($null -ne $counter.Temperature -and $counter.Temperature -gt 0) {
                        $temperature = "$($counter.Temperature) C"
                    }
                    # Wear = 0% on many SATA SSDs means "not reported", not "0% worn"
                    # Only use when > 0 (reliable indicator of actual wear)
                    if ($null -ne $counter.Wear -and [int]$counter.Wear -gt 0) {
                        $wearPct = [int]$counter.Wear
                        $wear = "$wearPct%"
                        $estLife = "~$(100 - $wearPct)%"
                    }
                    if ($null -ne $counter.PowerOnHours) {
                        $powerOnHours = "$($counter.PowerOnHours) hrs"
                    }
                    if ($null -ne $counter.ReadErrorsTotal -and $counter.ReadErrorsTotal -gt 0) {
                        $readErrors = "$($counter.ReadErrorsTotal)"
                    }
                    if ($null -ne $counter.WriteErrorsTotal -and $counter.WriteErrorsTotal -gt 0) {
                        $writeErrors = "$($counter.WriteErrorsTotal)"
                    }
                }
            } catch {}

            # === Method 2: Raw SMART via WMI (admin required) ===
            if ($wear -eq 'N/A') {
                try {
                    $smartData = Get-CimInstance -Namespace Root\WMI `
                        -ClassName MSStorageDriver_FailurePredictData -ErrorAction Stop

                    $smartStatus = Get-CimInstance -Namespace Root\WMI `
                        -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop

                    $mySmart = $smartData | Where-Object {
                        $_.InstanceName -match "Disk$($diskNum)$" -or
                        $_.InstanceName -match "Disk$($diskNum) "
                    } | Select-Object -First 1

                    $myStatus = $smartStatus | Where-Object {
                        $_.InstanceName -match "Disk$($diskNum)$" -or
                        $_.InstanceName -match "Disk$($diskNum) "
                    } | Select-Object -First 1

                    if ($myStatus -and $myStatus.PredictFailure) {
                        $health = 'Unhealthy'
                    }

                    if ($mySmart -and $mySmart.VendorSpecific) {
                        $raw = $mySmart.VendorSpecific
                        $numAttrs = [Math]::Floor(($raw.Length - 2) / 12)

                        for ($i = 0; $i -lt $numAttrs; $i++) {
                            $offset = 2 + ($i * 12)
                            if ($offset + 12 -le $raw.Length) {
                                $attrId = $raw[$offset]
                                $attrValue = $raw[$offset + 3]
                                $rawBytes = $raw[($offset + 5)..($offset + 11)]
                                $rawValue = 0
                                for ($b = 0; $b -lt $rawBytes.Length; $b++) {
                                    $rawValue += [long]$rawBytes[$b] * [Math]::Pow(256, $b)
                                }

                                switch ($attrId) {
                                    173 {
                                        if ($attrValue -gt 0 -and $attrValue -le 100) {
                                            $estLife = "~$attrValue%"
                                            $wear = "$([int](100 - $attrValue))%"
                                        }
                                    }
                                    177 {
                                        if ($attrValue -gt 0 -and $attrValue -le 100) {
                                            $estLife = "~$attrValue%"
                                            $wear = "$([int](100 - $attrValue))%"
                                        }
                                    }
                                    231 {
                                        if ($attrValue -gt 0 -and $attrValue -le 100) {
                                            $estLife = "~$attrValue%"
                                            $wear = "$([int](100 - $attrValue))%"
                                        }
                                    }
                                    232 {
                                        if ($attrValue -gt 0 -and $attrValue -le 100) {
                                            $estLife = "~$attrValue%"
                                            $wear = "$([int](100 - $attrValue))%"
                                        }
                                    }
                                    233 {
                                        if ($attrValue -gt 0 -and $attrValue -le 100) {
                                            $estLife = "~$attrValue%"
                                            $wear = "$([int](100 - $attrValue))%"
                                        }
                                    }
                                    9 {
                                        if ($temperature -eq 'N/A' -and $rawValue -gt 0 -and $rawValue -lt 200) {
                                            $temperature = "$rawValue C"
                                        }
                                    }
                                    194 {
                                        if ($temperature -eq 'N/A' -and $rawValue -gt 0 -and $rawValue -lt 200) {
                                            $temperature = "$rawValue C"
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {}
            }

            # === Method 3: Fallback to StorageReliabilityCounter temp/power ===
            if ($temperature -eq 'N/A' -or $powerOnHours -eq 'N/A') {
                try {
                    $counter2 = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($counter2) {
                        if ($temperature -eq 'N/A' -and $null -ne $counter2.Temperature -and $counter2.Temperature -gt 0) {
                            $temperature = "$($counter2.Temperature) C"
                        }
                        if ($powerOnHours -eq 'N/A' -and $null -ne $counter2.PowerOnHours) {
                            $powerOnHours = "$($counter2.PowerOnHours) hrs"
                        }
                        if ($readErrors -eq 'N/A' -and $null -ne $counter2.ReadErrorsTotal -and $counter2.ReadErrorsTotal -gt 0) {
                            $readErrors = "$($counter2.ReadErrorsTotal)"
                        }
                        if ($writeErrors -eq 'N/A' -and $null -ne $counter2.WriteErrorsTotal -and $counter2.WriteErrorsTotal -gt 0) {
                            $writeErrors = "$($counter2.WriteErrorsTotal)"
                        }
                    }
                } catch {}
            }

            $ssdInfo += [pscustomobject]@{
                Model         = $model
                Health        = $health
                Operational   = $opStatus
                BusType       = $busType
                Temperature   = $temperature
                Wear          = $wear
                EstimatedLife = $estLife
                PowerOnHours  = $powerOnHours
                ReadErrors    = $readErrors
                WriteErrors   = $writeErrors
                DriveLetters  = ($driveLetters -join ', ')
            }
        }
    } catch {}

    # Fallback: CIM direct query if Get-PhysicalDisk failed
    if ($ssdInfo.Count -eq 0) {
        try {
            $cimDisks = Get-CimInstance -Namespace Root\Microsoft\Windows\Storage `
                -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
                Where-Object { $_.MediaType -eq 1 }

            foreach ($cd in $cimDisks) {
                $ssdInfo += [pscustomobject]@{
                    Model         = $cd.FriendlyName
                    Health        = if ($cd.HealthStatus -eq 0) { 'Healthy' } else { "Status $($cd.HealthStatus)" }
                    Operational   = ($cd.OperationalStatus -join ', ')
                    BusType       = "$($cd.BusType)"
                    Temperature   = 'N/A'
                    Wear          = 'N/A'
                    EstimatedLife = 'N/A'
                    PowerOnHours  = 'N/A'
                    ReadErrors    = 'N/A'
                    WriteErrors   = 'N/A'
                    DriveLetters  = ''
                }
            }
        } catch {}
    }

    $ssdInfo
}
