<#
.SYNOPSIS
    Runs TCP/ICMP connectivity tests against devices defined in a JSON file
    and writes a timestamped, labelled copy of the file with results added.

.DESCRIPTION
    After selecting devices to test, the user is prompted for a run label
    (none, pre-change, post-change, or a custom value). The label, run time
    and other metadata are embedded in a top-level '_meta' block in the
    output JSON and are also reflected in the output filename so that runs
    are easy to identify later.

.PARAMETER InputPath
    Path to the source JSON file.

.EXAMPLE
    .\test_runner.ps1 -InputPath .\test_data.json
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

# --- Connectivity helpers -----------------------------------------------------

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

# --- Label helpers ------------------------------------------------------------

function Get-SanitisedLabel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Raw
    )
    # Allow letters, digits, dash, underscore. Everything else becomes underscore.
    $clean = ($Raw -replace '[^A-Za-z0-9_\-]', '_').Trim('_')
    if ($clean.Length -gt 40) { $clean = $clean.Substring(0, 40) }
    return $clean
}

function Get-RunLabel {
    $options = @(
        [PSCustomObject]@{ Choice = 'pre-change';  Description = 'Before a change has been made' }
        [PSCustomObject]@{ Choice = 'post-change'; Description = 'After a change has been made' }
        [PSCustomObject]@{ Choice = 'Custom...';   Description = 'Enter a custom label' }
    )

    $picked = $options |
        Out-GridView -Title 'Select a label for this run (required)' -OutputMode Single

    if (-not $picked) {
        Write-Warning 'A label is required. Exiting.'
        exit 1
    }

    switch ($picked.Choice) {
        'Custom...' {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $raw = [Microsoft.VisualBasic.Interaction]::InputBox(
                'Enter a label for this run (letters, digits, dash and underscore only):',
                'Custom run label',
                '')
            if (-not $raw) {
                Write-Warning 'No custom label entered. Exiting.'
                exit 1
            }
            $clean = Get-SanitisedLabel -Raw $raw
            if (-not $clean) {
                Write-Warning 'Custom label was empty after sanitising. Exiting.'
                exit 1
            }
            return $clean
        }
        default {
            return (Get-SanitisedLabel -Raw $picked.Choice)
        }
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

# --- Select run label (after device selection, as requested) ------------------

$label = Get-RunLabel

# --- Run tests ----------------------------------------------------------------

foreach ($deviceName in $selected) {
    $device = $data.$deviceName
    Write-Host "Testing $deviceName..." -ForegroundColor Cyan

    if ($device.PSObject.Properties.Name -contains 'vips') {
        foreach ($vipProp in $device.vips.PSObject.Properties) {
            $entry = $vipProp.Value
            $result = Test-TcpPort -IpAddress $entry.ip -Port ([int]$entry.port) -TimeoutMs $TcpTimeoutMs
            $entry | Add-Member -NotePropertyName 'results' -NotePropertyValue $result -Force
        }
    }

    if ($device.PSObject.Properties.Name -contains 'float_ips') {
        foreach ($ipProp in $device.float_ips.PSObject.Properties) {
            $entry = $ipProp.Value
            $result = Test-IcmpPing -IpAddress $entry.ip -TimeoutMs $IcmpTimeoutMs
            $entry | Add-Member -NotePropertyName 'results' -NotePropertyValue $result -Force
        }
    }

    if ($device.PSObject.Properties.Name -contains 'non_float_ips') {
        foreach ($ipProp in $device.non_float_ips.PSObject.Properties) {
            $entry = $ipProp.Value
            $result = Test-IcmpPing -IpAddress $entry.ip -TimeoutMs $IcmpTimeoutMs
            $entry | Add-Member -NotePropertyName 'results' -NotePropertyValue $result -Force
        }
    }
}

# --- Assemble output with metadata --------------------------------------------

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runAtIso  = (Get-Date).ToString('o')  # ISO-8601 for unambiguous parsing later

$meta = [ordered]@{
    run_at     = $runAtIso
    label      = $label
    devices    = @($selected)
    host       = $env:COMPUTERNAME
    user       = $env:USERNAME
    input_file = $inputFile.Name
}

$output = [ordered]@{ _meta = $meta }
foreach ($deviceName in $selected) {
    $output[$deviceName] = $data.$deviceName
}

# --- Build filename -----------------------------------------------------------

$devicePart   = ($selected -join '+')
$labelSegment = "__$label"

$outputName = '{0}_results__{1}{2}__{3}{4}' -f `
    $inputFile.BaseName, $devicePart, $labelSegment, $timestamp, $inputFile.Extension

$outputPath = Join-Path -Path $inputFile.DirectoryName -ChildPath $outputName

$output | ConvertTo-Json -Depth 20 | Set-Content -Path $outputPath -Encoding UTF8

Write-Host ''
Write-Host "Label:   $label" -ForegroundColor Cyan
Write-Host "Results written to: $outputPath" -ForegroundColor Green