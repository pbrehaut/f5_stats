<#
.SYNOPSIS
    Compares two connectivity-test result JSON files and produces a CSV report
    highlighting reachability mismatches.

.DESCRIPTION
    Validates that both files have identical structure (same devices, same
    entries, all with results blocks) before comparing. Aborts on any
    structural difference to prevent misleading reports.

    The comparison is based only on the 'reachable' field. Latency values are
    included in the output for reference but are not compared.

.PARAMETER FileA
    Path to the baseline results file. If omitted, a file picker is shown.

.PARAMETER FileB
    Path to the comparison results file. If omitted, a file picker is shown.

.PARAMETER LabelA
    Column suffix for File A values in the CSV (default 'a').

.PARAMETER LabelB
    Column suffix for File B values in the CSV (default 'b').

.PARAMETER OutputPath
    Output CSV path. Defaults to comparison_<timestamp>.csv next to File A.

.EXAMPLE
    .\Compare-ConnectivityResults.ps1

.EXAMPLE
    .\Compare-ConnectivityResults.ps1 -FileA .\before.json -FileB .\after.json -LabelA before -LabelB after
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$FileA,
    [Parameter(Mandatory = $false)][string]$FileB,
    [Parameter(Mandatory = $false)][string]$LabelA = 'a',
    [Parameter(Mandatory = $false)][string]$LabelB = 'b',
    [Parameter(Mandatory = $false)][string]$OutputPath
)

# --- File picker helper -------------------------------------------------------

function Select-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Title)

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dialog.Multiselect = $false

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Warning "$Title - cancelled. Exiting."
        exit 1
    }
    return $dialog.FileName
}

# --- Resolve input files ------------------------------------------------------

if (-not $FileA) { $FileA = Select-JsonFile -Title 'Select File A (baseline)' }
if (-not $FileB) { $FileB = Select-JsonFile -Title 'Select File B (comparison)' }

$fileAItem = Get-Item -Path $FileA -ErrorAction Stop
$fileBItem = Get-Item -Path $FileB -ErrorAction Stop

Write-Host "File A: $($fileAItem.FullName)" -ForegroundColor Cyan
Write-Host "File B: $($fileBItem.FullName)" -ForegroundColor Cyan

$dataA = Get-Content -Raw -Path $fileAItem.FullName | ConvertFrom-Json
$dataB = Get-Content -Raw -Path $fileBItem.FullName | ConvertFrom-Json

# --- Validation ---------------------------------------------------------------

$categories = @('vips', 'float_ips', 'non_float_ips')
$validationErrors = New-Object System.Collections.Generic.List[string]

$devicesA = $dataA.PSObject.Properties.Name | Sort-Object
$devicesB = $dataB.PSObject.Properties.Name | Sort-Object

$onlyInA = $devicesA | Where-Object { $_ -notin $devicesB }
$onlyInB = $devicesB | Where-Object { $_ -notin $devicesA }

foreach ($d in $onlyInA) { $validationErrors.Add("Device '$d' exists in File A but not File B") }
foreach ($d in $onlyInB) { $validationErrors.Add("Device '$d' exists in File B but not File A") }

$commonDevices = $devicesA | Where-Object { $_ -in $devicesB }

foreach ($device in $commonDevices) {
    foreach ($category in $categories) {
        $hasA = $dataA.$device.PSObject.Properties.Name -contains $category
        $hasB = $dataB.$device.PSObject.Properties.Name -contains $category

        if ($hasA -ne $hasB) {
            $validationErrors.Add("Device '$device': category '$category' is present in only one file")
            continue
        }
        if (-not $hasA) { continue }

        $entriesA = $dataA.$device.$category.PSObject.Properties.Name | Sort-Object
        $entriesB = $dataB.$device.$category.PSObject.Properties.Name | Sort-Object

        foreach ($e in ($entriesA | Where-Object { $_ -notin $entriesB })) {
            $validationErrors.Add("Device '$device' / $category / '$e': in File A but not File B")
        }
        foreach ($e in ($entriesB | Where-Object { $_ -notin $entriesA })) {
            $validationErrors.Add("Device '$device' / $category / '$e': in File B but not File A")
        }

        $commonEntries = $entriesA | Where-Object { $_ -in $entriesB }
        foreach ($entryName in $commonEntries) {
            foreach ($pair in @(@{ File = 'A'; Data = $dataA }, @{ File = 'B'; Data = $dataB })) {
                $entry = $pair.Data.$device.$category.$entryName
                $hasResults = $entry.PSObject.Properties.Name -contains 'results'
                if (-not $hasResults) {
                    $validationErrors.Add("Device '$device' / $category / '$entryName': missing 'results' block in File $($pair.File)")
                    continue
                }
                $hasReachable = $entry.results.PSObject.Properties.Name -contains 'reachable'
                if (-not $hasReachable) {
                    $validationErrors.Add("Device '$device' / $category / '$entryName': 'results.reachable' missing in File $($pair.File)")
                }
            }
        }
    }
}

if ($validationErrors.Count -gt 0) {
    Write-Host ''
    Write-Host 'VALIDATION FAILED - files do not have matching structure.' -ForegroundColor Red
    Write-Host 'This usually means the wrong files were selected.' -ForegroundColor Red
    Write-Host ''
    foreach ($err in $validationErrors) { Write-Host "  - $err" -ForegroundColor Yellow }
    Write-Host ''
    exit 1
}

Write-Host 'Validation passed. Generating comparison...' -ForegroundColor Green

# --- Build report rows --------------------------------------------------------

$categoryTestType = @{
    vips          = 'TCP'
    float_ips     = 'ICMP'
    non_float_ips = 'ICMP'
}

$rows = New-Object System.Collections.Generic.List[PSCustomObject]

foreach ($device in $commonDevices) {
    foreach ($category in $categories) {
        if (-not ($dataA.$device.PSObject.Properties.Name -contains $category)) { continue }

        foreach ($entryProp in $dataA.$device.$category.PSObject.Properties) {
            $entryName = $entryProp.Name
            $entryA = $entryProp.Value
            $entryB = $dataB.$device.$category.$entryName

            $reachableA = [bool]$entryA.results.reachable
            $reachableB = [bool]$entryB.results.reachable
            $latencyA = $entryA.results.latency_ms
            $latencyB = $entryB.results.latency_ms

            $status = if ($reachableA -eq $reachableB) { 'MATCH' } else { 'MISMATCH' }

            $port = if ($entryA.PSObject.Properties.Name -contains 'port') { $entryA.port } else { '' }

            $row = [ordered]@{
                device     = $device
                category   = $category
                name       = $entryName
                ip         = $entryA.ip
                port       = $port
                test_type  = $categoryTestType[$category]
                status     = $status
            }
            $row["reachable_$LabelA"]  = $reachableA.ToString().ToUpper()
            $row["reachable_$LabelB"]  = $reachableB.ToString().ToUpper()
            $row["latency_ms_$LabelA"] = $latencyA
            $row["latency_ms_$LabelB"] = $latencyB

            $rows.Add([PSCustomObject]$row)
        }
    }
}

# Mismatches first, then device, then name
$sorted = $rows | Sort-Object `
    @{ Expression = { if ($_.status -eq 'MISMATCH') { 0 } else { 1 } } }, `
    device, category, name

# --- Write CSV ----------------------------------------------------------------

if (-not $OutputPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputPath = Join-Path -Path $fileAItem.DirectoryName -ChildPath ("comparison_{0}.csv" -f $timestamp)
}

$sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$mismatchCount = ($sorted | Where-Object { $_.status -eq 'MISMATCH' }).Count
$matchCount = $sorted.Count - $mismatchCount

Write-Host ''
Write-Host "Total rows:  $($sorted.Count)" -ForegroundColor Cyan
Write-Host "Matches:     $matchCount" -ForegroundColor Green
Write-Host "Mismatches:  $mismatchCount" -ForegroundColor $(if ($mismatchCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ''
Write-Host "Report written to: $OutputPath" -ForegroundColor Green