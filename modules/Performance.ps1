function Get-PMPerformanceSnapshot {
    [CmdletBinding()]
    param(
        [int]$SampleSeconds = 3
    )

    $cpuUsage  = 'N/A'
    $memUsage  = 'N/A'
    $totalRAM  = 'N/A'

    # CPU: short sample
    try {
        $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' `
            -SampleInterval $SampleSeconds -MaxSamples 2 -ErrorAction Stop

        $samples = $cpuCounter.CounterSamples | Select-Object -Last 1
        $cpuUsage = [math]::Round($samples.CookedValue, 0)
    } catch {
        $cpuUsage = 'N/A'
    }

    # Memory: instant snapshot
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalBytes = $os.TotalVisibleMemorySize
        $freeBytes  = $os.FreePhysicalMemory

        if ($totalBytes -gt 0) {
            $usedBytes  = $totalBytes - $freeBytes
            $memUsage   = [math]::Round(($usedBytes / $totalBytes) * 100, 0)
            $totalRAM   = [math]::Round($totalBytes / 1MB, 1)
        }
    } catch {}

    [pscustomobject]@{
        CPUUsage     = $cpuUsage
        MemoryUsage  = $memUsage
        TotalRAMGB   = $totalRAM
    }
}
