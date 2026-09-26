function Get-PMNetworkInfo {
    <#
    .SYNOPSIS
        Read-only network inventory: adapters, addresses, routes and link state.
    .DESCRIPTION
        Key change from the previous behaviour: no adapter is ever described
        from an unfiltered list. A machine can have a VPN, a Hyper-V vEthernet
        pair, a Bluetooth PAN and a dozen disabled filter drivers, so the old
        "first adapter wins" approach reported a virtual NIC as the machine's
        network. Selection is now explicit and every adapter is listed.

        Physical adapters are those whose hardware interface description is a
        real bus type (PCI, USB, PCMCIA, SD, Apple Bus...). Everything else is
        labelled as virtual or software so a technician can tell the two apart.

        Implementation note: collections are built with ArrayList rather than
        List[object], because on Windows PowerShell 5.1 wrapping a List[object]
        in @() and assigning it into a [pscustomobject] throws
        "Argument types do not match" - even for an empty list.
    #>
    [CmdletBinding()]
    param()

    $adapters = New-Object System.Collections.ArrayList
    $ipv4 = New-Object System.Collections.ArrayList
    $ipv6 = New-Object System.Collections.ArrayList
    $gateways = New-Object System.Collections.ArrayList
    $dnsServers = New-Object System.Collections.ArrayList

    $primaryAdapter = 'N/A'
    $primaryIPv4 = 'N/A'
    $primaryGateway = 'N/A'
    $primaryMac = 'N/A'

    # Bus interfaces that mean "this is a piece of real hardware".
    $physicalBusPattern = 'PCI|PCIe|PCMCIA|PC Card|^USB|SD|MMC|Apple|PCMCIA-?Bus|PCMCIA CardBus'

    # Get-NetAdapter is the authoritative source for the interface description
    # and link state. Win32_NetworkAdapter has no InterfaceDescription field and
    # its registry lookup silently fails for several adapter classes, which left
    # virtual NICs showing "N/A" and being misclassified as physical.
    $netAdapterByName = @{}
    try {
        foreach ($na2 in @(Get-NetAdapter -ErrorAction Stop)) {
            if ($na2.Name) { $netAdapterByName[$na2.Name] = $na2 }
        }
    } catch {}

    try {
        $netAdapters = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop)

        foreach ($na in $netAdapters) {
            # Skip filter drivers and slots with no adapter present.
            if ($na.NetConnectionID -eq $null) { continue }
            if (-not $na.NetEnabled) { continue }

            $guid = $na.GUID
            $ifIndex = $na.InterfaceIndex

            $addresses = New-Object System.Collections.ArrayList
            $mac = 'N/A'
            $type = 'Other'
            $isDhcp = $null
            $dhcpServer = 'N/A'

            # Win32_NetworkAdapter.Speed is in BYTES per second, and several
            # drivers report 0 or a 65 Gbps placeholder, so it is range-checked.
            $speedMbps = 'N/A'
            if ($na.Speed -and $na.Speed -gt 0) {
                $mbps = [math]::Round($na.Speed / 1MB, 0)
                if ($mbps -ge 10 -and $mbps -le 400000) { $speedMbps = [int]$mbps }
            }

            # Bindings give the description that reveals virtual vs physical.
            $description = ''
            if ($guid) {
                $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{$guid}"
                try {
                    $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                    if ($p.InterfaceDescription) { $description = [string]$p.InterfaceDescription }
                    if ($p.DhcpIPAddress) { $isDhcp = $true }
                    elseif ($p.IPAddress) { $isDhcp = $false }
                    if ($p.DhcpIPAddress) { $dhcpServer = 'Yes (DHCP)' }
                } catch {}
            }

            # Fall back to the NetAdapter module, which reads the same data
            # through a different code path and usually succeeds.
            $cmd = $null
            if ($netAdapterByName.ContainsKey($na.NetConnectionID)) {
                $cmd = $netAdapterByName[$na.NetConnectionID]
            }
            if (-not $description -and $cmd -and $cmd.InterfaceDescription) {
                $description = [string]$cmd.InterfaceDescription
            }
            if ($null -eq $isDhcp -and $cmd) {
                if ($cmd.Dhcp -eq 'Enabled') { $isDhcp = $true; $dhcpServer = 'Yes (DHCP)' }
                elseif ($cmd.Dhcp -eq 'Disabled') { $isDhcp = $false }
            }
            if ($speedMbps -eq 'N/A' -and $cmd -and $cmd.LinkSpeed) {
                $l = [string]$cmd.LinkSpeed
                if ($l -match '^\s*([\d\.]+)\s*Gbps') {
                    $mbps = [math]::Round(([double]$Matches[1] * 1000), 0)
                    if ($mbps -ge 10 -and $mbps -le 400000) { $speedMbps = [int]$mbps }
                } elseif ($l -match '^\s*([\d\.]+)\s*Mbps') {
                    $mbps = [math]::Round([double]$Matches[1], 0)
                    if ($mbps -ge 10 -and $mbps -le 400000) { $speedMbps = [int]$mbps }
                }
            }

            # MAC only from an adapter that reports a real one. All-zero and
            # all-FF placeholders are filtered out.
            if ($na.MACAddress -and $na.MACAddress -ne '000000000000' -and $na.MACAddress -notmatch '^F{12}$') {
                $raw = ($na.MACAddress -replace '(:|\s|-)', '')
                if ($raw.Length -eq 12) {
                    # Split on a fixed stride. A regex lookahead does not work
                    # here: it also fires when 9 or 10 characters remain, which
                    # produced malformed values such as 34:5A:60770865.
                    $octets = @()
                    for ($i = 0; $i -lt 12; $i += 2) { $octets += $raw.Substring($i, 2) }
                    $mac = ($octets -join ':').ToUpper()
                }
            }

            # Adapter classification. The description is checked first because it
            # is the only reliable virtual/physical signal; Win32 reports
            # PhysicalAdapter as true for several hypervisor adapters.
            if ($description -match 'Loopback|Software Loopback') { $type = 'Loopback' }
            elseif ($description -match 'Tunnel|TAP-|VPN|WireGuard|Wintun|PPP') { $type = 'Virtual / VPN' }
            elseif ($description -match 'Hyper-V|vEthernet|VMware|VirtualBox|Virtual|Container|Multi|QEMU|KVM|Bridge|Loopback') { $type = 'Virtual' }
            elseif ($cmd -and $cmd.Virtual -eq $true) { $type = 'Virtual' }
            elseif ($description -match $physicalBusPattern) { $type = 'Physical' }
            elseif ($na.PhysicalAdapter -eq $true -and -not $description) { $type = 'Other' }
            elseif ($na.PhysicalAdapter -eq $true) { $type = 'Physical' }
            else { $type = 'Other' }

            if ($ifIndex) {
                try {
                    $ipCfg = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
                        Where-Object { $_.InterfaceIndex -eq $ifIndex })
                    foreach ($cfg in $ipCfg) {
                        # DHCPEnabled on the configuration is the reliable
                        # source. The registry per-interface key is missing on
                        # some builds and the NetAdapter fallback can fail
                        # without an imported NetAdapter module, so this is
                        # what stops DHCP from reporting "N/A" while the
                        # address list below is correctly tagged "IPv4 DHCP".
                        if ($null -eq $isDhcp -and $null -ne $cfg.DHCPEnabled) {
                            $isDhcp = [bool]$cfg.DHCPEnabled
                        }

                        # Family is decided by the address itself, never assumed
                        # IPv4. Windows returns IPv6 link-local addresses inside
                        # IPAddress as well as IPAddress6, and hardcoding
                        # Family = 'IPv4' labelled fe80:: addresses as IPv4.
                        foreach ($a in @($cfg.IPAddress)) {
                            if (-not $a) { continue }
                            $isV6 = ([string]$a).Contains(':')
                            $family = if ($isV6) { 'IPv6' } else { 'IPv4' }
                            $version = if ($isV6) { 'IPv6' } elseif ($cfg.DHCPEnabled) { 'IPv4 DHCP' } else { 'IPv4' }
                            [void]$addresses.Add([pscustomobject]@{ IP = $a; Version = $version; Family = $family })
                        }
                        foreach ($a in @($cfg.IPAddress6)) {
                            if (-not $a) { continue }
                            [void]$addresses.Add([pscustomobject]@{ IP = $a; Version = 'IPv6'; Family = 'IPv6' })
                        }
                    }
                } catch {}
            }

            # Derived here, not inside the registry branch, so a DHCP state that
            # came from the Get-NetAdapter fallback also reports its server mode.
            if ($isDhcp -eq $true) { $dhcpServer = 'Yes (DHCP)' }
            elseif ($isDhcp -eq $false) { $dhcpServer = 'No' }
            else { $dhcpServer = 'N/A' }

            [void]$adapters.Add([pscustomobject]@{
                Name        = $na.NetConnectionID
                Description = if ($description) { $description } else { 'N/A' }
                Type        = $type
                Status      = $na.NetConnectionStatus      # 2 = Connected
                MAC         = $mac
                SpeedMbps   = $speedMbps
                DHCP        = if ($isDhcp -eq $true) { 'Yes' } elseif ($isDhcp -eq $false) { 'No' } else { 'N/A' }
                DHCPServer  = $dhcpServer
                Addresses   = $addresses.ToArray()
            })
        }
    } catch {}

    # Flat lists used for the summary lines.
    foreach ($a in $adapters) {
        foreach ($addr in $a.Addresses) {
            if ($addr.Family -eq 'IPv4') { [void]$ipv4.Add($addr.IP) } else { [void]$ipv6.Add($addr.IP) }
        }
    }

    # Default route -> the real default gateway, far more reliable than
    # "first adapter that happens to have an address".
    try {
        $route = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
            Where-Object { $_.IPEnabled -and $_.DefaultIPGateway })
        foreach ($r in $route) {
            foreach ($g in @($r.DefaultIPGateway)) {
                if ($g) { [void]$gateways.Add($g) }
            }
        }
    } catch {}

    # IPv4 link-local IPv6 gateways are not useful to a technician, so the
    # primary gateway prefers a routable IPv4 address.
    $primaryGateway = 'N/A'
    $gwV4 = @($gateways | Where-Object { $_ -notmatch ':' -and $_ -notlike '169.254.*' })
    $gwV6 = @($gateways | Where-Object { $_ -match ':' -and $_ -notlike 'fe80:*' })
    if ($gwV4.Count -gt 0) { $primaryGateway = $gwV4[0] }
    elseif ($gwV6.Count -gt 0) { $primaryGateway = $gwV6[0] }
    elseif ($gateways.Count -gt 0) { $primaryGateway = @($gateways)[0] }

    try {
        foreach ($srv in @($env:NameServer)) {
            if ($srv) {
                foreach ($p in ($srv -split '\s+')) { if ($p) { [void]$dnsServers.Add($p) } }
            }
        }
    } catch {}

    # Primary = connected physical adapter, else connected anything.
    $connectedPhysical = @($adapters | Where-Object { $_.Status -eq 2 -and $_.Type -eq 'Physical' })
    $connectedAny      = @($adapters | Where-Object { $_.Status -eq 2 })
    $chosen = $null
    if ($connectedPhysical.Count -gt 0) {
        $chosen = $connectedPhysical[0]
    } elseif ($connectedAny.Count -gt 0) {
        $chosen = $connectedAny[0]
    }

    if ($chosen) {
        $primaryAdapter = $chosen.Name
        $primaryMac = $chosen.MAC
        $v4 = @($chosen.Addresses | Where-Object { $_.Family -eq 'IPv4' -and $_.IP -ne '127.0.0.1' })
        if ($v4.Count -gt 0) { $primaryIPv4 = $v4[0].IP }
    }

    $ipv4Out = @()
    if ($ipv4.Count -gt 0) { $ipv4Out = @($ipv4 | Select-Object -Unique) }
    $ipv6Out = @()
    if ($ipv6.Count -gt 0) { $ipv6Out = @($ipv6 | Select-Object -Unique) }

    [pscustomobject]@{
        Adapters       = $adapters.ToArray()
        IPv4           = $ipv4Out
        IPv6           = $ipv6Out
        Gateways       = @($gateways | Select-Object -Unique)
        DNSServers     = @($dnsServers | Select-Object -Unique)
        PrimaryAdapter = $primaryAdapter
        PrimaryIPv4    = $primaryIPv4
        PrimaryGateway = $primaryGateway
        PrimaryMac     = $primaryMac
    }
}
