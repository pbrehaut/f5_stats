<#
.SYNOPSIS
    Runs TCP/ICMP connectivity tests against devices defined in a JSON file and
    writes a timestamped copy of the file with results added.

.PARAMETER InputPath
    Path to the source JSON file.

.EXAMPLE
    .\Test-DeviceConnectivity.ps1 -InputPath .\devices.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputPath = 'C:\Users\pbrehaut4\PycharmProjects\f5_stats\test_data.json',

    [Parameter(Mandatory = $false)]
    [int]$TcpTimeoutMs = 200,

    [Parameter(Mandatory = $false)]
    [int]$IcmpTimeoutMs = 200
)

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$TimeoutMs
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $asyncResult = $client.BeginConnect($IpAddress, $Port, $null, $null)
        $completed = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $stopwatch.Stop()

        if ($completed -and $client.Connected) {
            $client.EndConnect($asyncResult)
            return [PSCustomObject]@{
                reachable  = $true
                latency_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
            }
        }
        return [PSCustomObject]@{ reachable = $false; latency_ms = $null }
    }
    catch {
        return [PSCustomObject]@{ reachable = $false; latency_ms = $null }
    }
    finally {
        $client.Close()
    }
}

function Test-IcmpPing {
    param(
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [Parameter(Mandatory = $true)][int]$TimeoutMs
    )

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($IpAddress, $TimeoutMs)
        if ($reply.Status -eq 'Success') {
            return [PSCustomObject]@{
                reachable  = $true
                latency_ms = [int]$reply.RoundtripTime
            }
        }
        return [PSCustomObject]@{ reachable = $false; latency_ms = $null }
    }
    catch {
        return [PSCustomObject]@{ reachable = $false; latency_ms = $null }
    }
}

# --- Load input ---------------------------------------------------------------

$inputFile = Get-Item -Path $InputPath -ErrorAction Stop
$data = Get-Content -Raw -Path $inputFile.FullName | ConvertFrom-Json

# --- Select devices -----------------------------------------------------------

$deviceNames = $data.PSObject.Properties.Name
$selected = $deviceNames |
    Out-GridView -Title 'Select devices to test (Ctrl+Click for multiple)' -OutputMode Multiple

if (-not $selected) {
    Write-Warning 'No devices selected. Exiting.'
    return
}

# --- Run tests ----------------------------------------------------------------

foreach ($deviceName in $selected) {
    $device = $data.$deviceName
    Write-Host "Testing $deviceName..." -ForegroundColor Cyan

    # VIPs — TCP port tests
    if ($device.PSObject.Properties.Name -contains 'vips') {
        foreach ($vipProp in $device.vips.PSObject.Properties) {
            $entry = $vipProp.Value
            $result = Test-TcpPort -IpAddress $entry.ip -Port ([int]$entry.port) -TimeoutMs $TcpTimeoutMs
            $entry | Add-Member -NotePropertyName 'results' -NotePropertyValue $result -Force
        }
    }

    # Float IPs — ICMP
    if ($device.PSObject.Properties.Name -contains 'float_ips') {
        foreach ($ipProp in $device.float_ips.PSObject.Properties) {
            $entry = $ipProp.Value
            $result = Test-IcmpPing -IpAddress $entry.ip -TimeoutMs $IcmpTimeoutMs
            $entry | Add-Member -NotePropertyName 'results' -NotePropertyValue $result -Force
        }
    }

    # Non-float IPs — ICMP
    if ($device.PSObject.Properties.Name -contains 'non_float_ips') {
        foreach ($ipProp in $device.non_float_ips.PSObject.Properties) {
            $entry = $ipProp.Value
            $result = Test-IcmpPing -IpAddress $entry.ip -TimeoutMs $IcmpTimeoutMs
            $entry | Add-Member -NotePropertyName 'results' -NotePropertyValue $result -Force
        }
    }
}

# --- Write output -------------------------------------------------------------

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputName = '{0}_results_{1}{2}' -f $inputFile.BaseName, $timestamp, $inputFile.Extension
$outputPath = Join-Path -Path $inputFile.DirectoryName -ChildPath $outputName

# Build output containing only the devices that were tested
$output = [ordered]@{}
foreach ($deviceName in $selected) {
    $output[$deviceName] = $data.$deviceName
}

$output | ConvertTo-Json -Depth 20 | Set-Content -Path $outputPath -Encoding UTF8

Write-Host "Results written to: $outputPath" -ForegroundColor Green