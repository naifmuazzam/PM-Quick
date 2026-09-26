function Get-PMHardwareInfo {
    <#
    .SYNOPSIS
        Read-only hardware inventory: CPU, RAM, GPU, motherboard and the
        physical storage devices behind each drive letter.
    .DESCRIPTION
        Every field degrades to 'N/A' when the hardware or driver does not
        expose it. Nothing is inferred and no value is invented:

        - GPU VRAM from Win32_VideoController.AdapterRAM is only reported when
          it is plausible. WMI caps this field and reports it as a signed
          32-bit integer, so a modern GPU overflows it to a negative number or
          a 2 GB value. Both are reported as 'N/A', never as a wrong number.
        - RAM form factor and speed come from Win32_PhysicalMemory only.
        - Storage serials are frequently blank without Administrator; the
          blank is reported as 'N/A' rather than invented.

        No product key, credential or software serial is collected.
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        CPU           = 'N/A'
        CPUCores      = 'N/A'
        CPUThreads    = 'N/A'
        CPUMaxMHz     = 'N/A'
        CPUBaseMHz    = 'N/A'

        RAMTotal      = 'N/A'
        RAMSlotsUsed  = 'N/A'
        RAMSlotsTotal = 'N/A'
        RAMSpeedMHz   = 'N/A'
        RAMFormFactor = 'N/A'
        RAMModules    = @()

        GPU           = @()
        Motherboard   = 'N/A'
        MotherboardModel = 'N/A'

        StorageHardware = @()
    }

    # --- CPU ----------------------------------------------------------------
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop |
            Sort-Object -Property NumberOfCores -Descending |
            Select-Object -First 1

        if ($cpu) {
            if ($cpu.Name) { $result.CPU = ([string]$cpu.Name).Trim() }
            if ($cpu.NumberOfCores) { $result.CPUCores = [int]$cpu.NumberOfCores }
            if ($cpu.NumberOfLogicalProcessors) { $result.CPUThreads = [int]$cpu.NumberOfLogicalProcessors }
            if ($cpu.MaxClockSpeed) { $result.CPUMaxMHz = [int]$cpu.MaxClockSpeed }
            # CurrentClockSpeed is the closest thing WMI exposes to a base clock.
            if ($cpu.CurrentClockSpeed) { $result.CPUBaseMHz = [int]$cpu.CurrentClockSpeed }
        }
    } catch {}

    # --- RAM ----------------------------------------------------------------
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs -and $cs.TotalPhysicalMemory -gt 0) {
            $result.RAMTotal = '{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        }
    } catch {}

    $modules = New-Object System.Collections.ArrayList
    try {
        $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if ($dimms.Count -gt 0) {
            $speeds = @()
            $factors = @()
            foreach ($d in $dimms) {
                $speed = $d.ConfiguredClockSpeed
                if (-not $speed) { $speed = $d.Speed }
                if ($speed) { $speeds += [int]$speed }

                $formFactor = Format-PMFormFactor -FormFactor $d.FormFactor
                if ($formFactor -ne 'N/A') { $factors += $formFactor }

                [void]$modules.Add([pscustomobject]@{
                    Bank        = if ($d.BankLabel) { $d.BankLabel } else { 'N/A' }
                    Locator     = if ($d.DeviceLocator) { $d.DeviceLocator } else { 'N/A' }
                    CapacityGB  = if ($d.Capacity) { [math]::Round($d.Capacity / 1GB, 1) } else { 'N/A' }
                    SpeedMHz    = if ($d.ConfiguredClockSpeed) { [int]$d.ConfiguredClockSpeed }
                                  elseif ($d.Speed) { [int]$d.Speed } else { 'N/A' }
                    FormFactor  = $formFactor
                    Manufacturer = if ($d.Manufacturer) { ([string]$d.Manufacturer).Trim() } else { 'N/A' }
                    PartNumber  = if ($d.PartNumber) { ([string]$d.PartNumber).Trim() } else { 'N/A' }
                })
            }

            $result.RAMSlotsUsed = $dimms.Count

            # Some boards report the same DeviceLocator ("DIMM 0") for every
            # populated slot, which makes the per-module rows indistinguishable.
            # When that happens, the BankLabel ("P0 CHANNEL A") is the field that
            # actually identifies the physical slot, so it is promoted into
            # Locator. Unique real locators are left untouched.
            $locators = @($modules | ForEach-Object { $_.Locator })
            $locatorIsUnique = (@($locators | Select-Object -Unique).Count -eq $locators.Count)
            if (-not $locatorIsUnique) {
                foreach ($mm in $modules) {
                    if ($mm.Bank -ne 'N/A') { $mm.Locator = $mm.Bank }
                }
            }

            $result.RAMModules  = $modules.ToArray()

            if ($speeds.Count -gt 0) {
                $result.RAMSpeedMHz = (@($speeds | Sort-Object -Unique) -join ', ')
            }
            if ($factors.Count -gt 0) {
                $result.RAMFormFactor = (@($factors | Sort-Object -Unique) -join ', ')
            }
        }
    } catch {}

    # Slot count comes from the array/memory device description, which is the
    # only place the physical slot count is exposed. Absent on most desktops.
    try {
        $arrayInfo = @(Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop)
        if ($arrayInfo.Count -gt 0) {
            $slots = ($arrayInfo | Measure-Object -Property MemoryDevices -Sum).Sum
            if ($slots) { $result.RAMSlotsTotal = [int]$slots }
        }
    } catch {}

    # --- GPU ----------------------------------------------------------------
    $gpus = New-Object System.Collections.ArrayList
    try {
        $video = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -and $_.Name -notmatch '^(Microsoft Basic Display|RDP|Citrix|Indirect)' })
        foreach ($v in $video) {
            [void]$gpus.Add([pscustomobject]@{
                Name          = ([string]$v.Name).Trim()
                VRAM          = Format-PMVideoMemory -Bytes $v.AdapterRAM
                DriverVersion = if ($v.DriverVersion) { $v.DriverVersion } else { 'N/A' }
                DriverDate    = if ($v.DriverDate) { $v.DriverDate.ToString('yyyy-MM-dd') } else { 'N/A' }
            })
        }
    } catch {}
    $result.GPU = $gpus.ToArray()

    # --- motherboard --------------------------------------------------------
    try {
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        if ($board) {
            if ($board.Manufacturer) { $result.Motherboard = ([string]$board.Manufacturer).Trim() }
            if ($board.Product) { $result.MotherboardModel = ([string]$board.Product).Trim() }
        }
    } catch {}

    # --- storage hardware ---------------------------------------------------
    # Deliberately delegated rather than re-enumerated. Two independent disk
    # enumerations drift apart, and the one in Storage.ps1 is authoritative:
    # it merges Get-PhysicalDisk (accurate bus and media type) with WMI.
    $diskHw = @()
    if (Get-Command Get-PMStorageInfo -ErrorAction SilentlyContinue) {
        try { $diskHw = @((Get-PMStorageInfo).PhysicalDisks) } catch {}
    }
    $result.StorageHardware = $diskHw

    [pscustomobject]$result
}

function Format-PMFormFactor {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()]$FormFactor)

    if ($null -eq $FormFactor -or "$FormFactor" -eq '') { return 'N/A' }

    switch ([int]$FormFactor) {
        8  { return 'DIMM' }
        9  { return 'SODIMM' }
        12 { return 'SODIMM' }
        13 { return 'SRIMM' }
        34 { return 'LFDIMM' }
        # An unrecognised code must read as N/A. Returning "FormFactor 99"
        # leaks a raw WMI enum value into a technician-facing report and looks
        # like a hardware reading when it is really an unknown.
        default { return 'N/A' }
    }
}

function Format-PMVideoMemory {
    <#
    .SYNOPSIS
        Formats Win32_VideoController.AdapterRAM, or refuses to.
    .DESCRIPTION
        AdapterRAM is a signed 32-bit WMI field capped by the provider, so on a
        GPU with more than 2 GB it overflows negative or pins at 0xFFFF0000,
        which is 4095.9 MB and renders as a confident, wrong "4 GB". A card
        reporting ~4 GB through this field is indistinguishable from that
        overflow pin, so the boundary is treated as unreliable. A wrong number
        here is worse than no number, and the adapter Name still carries the
        real size (for example "GTX 1060 6GB").
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()]$Bytes)

    if ($null -eq $Bytes) { return 'N/A' }

    try { $b = [long]$Bytes } catch { return 'N/A' }

    # Negative means the 32-bit field overflowed: the true value is unknown.
    if ($b -le 0) { return 'N/A' }

    $mb = $b / 1MB
    # >= 4000 MB is the 0xFFFF0000 overflow pin, not a real 4 GB reading.
    if ($mb -ge 4000) { return 'N/A' }
    if ($mb -ge 1024) { return ('{0} GB' -f [math]::Round($mb / 1024, 1)) }
    return ('{0} MB' -f [math]::Round($mb, 0))
}
