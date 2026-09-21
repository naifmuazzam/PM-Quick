function Get-PMNetworkInfo {
    [CmdletBinding()]
    param()

    $virtualPatterns = @(
        'Hyper-V',
        'vEthernet',
        'vSwitch',
        'VMware',
        'VirtualBox',
        'VPN',
        'TAP',
        'Tunnel',
        'Teredo',
        'ISATAP',
        '6to4',
        'WAN Miniport',
        'RAS Async',
        'AsyncMac',
        'NDIS',
        'Cellular',
        'Bluetooth'
    )

    $adapters = @()

    try {
        $netAdapters = Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' }

        foreach ($adapter in $netAdapters) {
            $name = $adapter.Name
            $isVirtual = $false

            foreach ($pattern in $virtualPatterns) {
                if ($name -like "*$pattern*") {
                    $isVirtual = $true
                    break
                }
            }

            if ($isVirtual) { continue }

            $ipConfigs = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                -AddressFamily IPv4 -ErrorAction SilentlyContinue

            foreach ($ip in $ipConfigs) {
                if ($ip.IPAddress -eq '127.0.0.1') { continue }

                $adapters += [pscustomobject]@{
                    Adapter     = $name
                    IPv4        = $ip.IPAddress
                    PrefixLength = $ip.PrefixLength
                }
            }
        }
    } catch {}

    # Fallback: CIM query if Get-NetAdapter unavailable
    if ($adapters.Count -eq 0) {
        try {
            $netConfigs = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
                Where-Object { $_.IPEnabled -eq $true }

            foreach ($nc in $netConfigs) {
                $desc = $nc.Description
                $isVirtual = $false
                foreach ($pattern in $virtualPatterns) {
                    if ($desc -like "*$pattern*") {
                        $isVirtual = $true
                        break
                    }
                }
                if ($isVirtual) { continue }

                if ($nc.IPAddress) {
                    foreach ($ip in $nc.IPAddress) {
                        if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -and $ip -ne '127.0.0.1') {
                            $adapters += [pscustomobject]@{
                                Adapter      = $desc
                                IPv4         = $ip
                                PrefixLength = $null
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    [pscustomobject]@{
        Adapters = $adapters
        Count    = $adapters.Count
    }
}
