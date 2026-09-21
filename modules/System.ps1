function Get-PMSystemInfo {
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        PCName    = 'N/A'
        Serial    = 'N/A'
        Windows   = 'N/A'
        User      = 'N/A'
    }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $result.PCName = $cs.Name
        $result.User   = $cs.UserName
    } catch {}

    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $result.Serial = $bios.SerialNumber
    } catch {}

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = $os.Caption
        $build   = $os.BuildNumber

        if ($caption -match 'Windows 11') {
            $edition = $caption -replace 'Microsoft Windows ', ''
            $result.Windows = "Windows 11 (Build $build)"
        } elseif ($caption -match 'Windows 10') {
            $result.Windows = "Windows 10 (Build $build)"
        } else {
            $result.Windows = $caption
        }
    } catch {}

    # Extract username from DOMAIN\user format
    if ($result.User -and $result.User -match '\\(.+)$') {
        $result.User = $Matches[1]
    }

    [pscustomobject]$result
}
