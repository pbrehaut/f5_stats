<#
.SYNOPSIS
    Compare F5 pool member or virtual server availability states between two
    JSON exports produced by the iControl REST collector.

.DESCRIPTION
    PowerShell 5.1 report script for the new iControl REST JSON schema
    (meta + records envelope). Scans the current directory for either
    ltmPoolMembers or ltmVirtualStats JSON files, prompts the user to pick
    which data type to compare, then prompts for two files via Out-GridView.
    Writes a CSV comparing availabilityState per member (or per virtual
    server) and prints a console summary of mismatches.

.NOTES
    Requires PowerShell 5.1+.
    Run from the directory containing the new-format JSON files:
        <chassisSerial>__<hostname>__<yyyy-MM-dd>__<HH-mm-ss>__<dataType>.json
    where <dataType> is ltmPoolMembers or ltmVirtualStats.
#>

# Mapping of chassis serial numbers (first filename component) to friendly
# site names. Matches meta.chassisSerial in the JSON.
$ChassisMapping = @{
    'chs412276s'   = 'HMB-Viprion-01'
    'chs412821s'   = 'HMB-Viprion-02'
    'chs412274s'   = 'GSW-Viprion-01'
    'chs412822s'   = 'GSW-Viprion-02'
    'f5-arut-orvq' = 'HMB-F5-r5900-03'
    'f5-buoc-hruj' = 'HMB-F5-r5900-04'
}

function Get-FileInfo {
    <#
    .SYNOPSIS
        Extracts friendly site name and timestamp from a JSON filename.
    .PARAMETER FilePath
        Path to the JSON file (or just its filename).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    # Expected format: chassisSerial__hostname__YYYY-MM-DD__HH-MM-SS__dataType
    $stem  = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $parts = $stem -split '__'

    $chassisSerial = $parts[0]
    $hostName      = $parts[1]
    $dateStr       = $parts[2]
    $timeStr       = $parts[3] -replace '-', ':'

    $altSite = if ($ChassisMapping.ContainsKey($chassisSerial)) {
        $ChassisMapping[$chassisSerial]
    } else {
        $chassisSerial
    }

    [PSCustomObject]@{
        SiteName  = "$altSite $hostName"
        Timestamp = "$dateStr $timeStr"
    }
}

function Get-AvailableFiles {
    <#
    .SYNOPSIS
        Returns JSON files in the current directory for a given data type.
    .PARAMETER DataType
        'ltmPoolMembers' or 'ltmVirtualStats'.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ltmPoolMembers', 'ltmVirtualStats')]
        [string]$DataType
    )

    $pattern = "*__${DataType}.json"
    @(Get-ChildItem -Path (Get-Location) -Filter $pattern -File | Sort-Object Name)
}

function Select-DataType {
    <#
    .SYNOPSIS
        Prompts user to pick data type via Out-GridView.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $choice = @(
        [PSCustomObject]@{ DataType = 'ltmPoolMembers';  Description = 'LTM Pool Members' }
        [PSCustomObject]@{ DataType = 'ltmVirtualStats'; Description = 'LTM Virtual Server Stats' }
    ) | Out-GridView -Title 'Select data type to compare' -OutputMode Single

    if ($null -eq $choice) { return $null }
    $choice.DataType
}

function Select-ComparisonFiles {
    <#
    .SYNOPSIS
        Prompts user to select two files via two sequential Out-GridView prompts.
    .PARAMETER DataType
        'ltmPoolMembers' or 'ltmVirtualStats'.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ltmPoolMembers', 'ltmVirtualStats')]
        [string]$DataType
    )

    $files = Get-AvailableFiles -DataType $DataType
    if ($files.Count -lt 2) {
        Write-Warning "At least 2 ${DataType} files required. Found $($files.Count)."
        return $null
    }

    $rows = foreach ($f in $files) {
        $info = Get-FileInfo -FilePath $f.Name
        [PSCustomObject]@{
            Site      = $info.SiteName
            Timestamp = $info.Timestamp
            FileName  = $f.Name
            FullPath  = $f.FullName
        }
    }

    $first = $rows |
        Out-GridView -Title "Select FIRST ${DataType} file" -OutputMode Single
    if ($null -eq $first) {
        Write-Warning "No file selected for first slot."
        return $null
    }

    $remaining = @($rows | Where-Object { $_.FullPath -ne $first.FullPath })
    $second = $remaining |
        Out-GridView -Title "Select SECOND ${DataType} file (compared against '$($first.FileName)')" -OutputMode Single
    if ($null -eq $second) {
        Write-Warning "No file selected for second slot."
        return $null
    }

    @($first, $second)
}

function Get-StateValue {
    <#
    .SYNOPSIS
        Safely reads availabilityState from a record, returning 'N/A' when
        the record or property is missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        $Record
    )

    if ($null -eq $Record) { return 'N/A' }
    $val = $Record.availabilityState
    if ($null -eq $val -or $val -eq '') { return 'N/A' }
    [string]$val
}

function Get-MemberDisplayName {
    <#
    .SYNOPSIS
        Returns a display name for a pool member record, falling back through
        memberName -> address:port -> address -> '' when fields are missing.
    .NOTES
        The collector currently has a bug where memberName is null; this
        fallback keeps the report usable until the collector is fixed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        $Record
    )

    if ($null -ne $Record.memberName -and $Record.memberName -ne '') {
        return [string]$Record.memberName
    }

    $addr = $Record.address
    $port = $Record.port
    if ($null -ne $addr -and $addr -ne '') {
        if ($null -ne $port -and $port -ne '') {
            return "${addr}:${port}"
        }
        return [string]$addr
    }
    return ''
}

function Get-IdentifiedRecords {
    <#
    .SYNOPSIS
        Indexes an array of records by the concatenated values returned by
        an identifier-builder scriptblock. Each map entry stores both the
        original record and the ordered identifier hashtable so the output
        row can reproduce the identifier columns.
    .PARAMETER Records
        Array of record objects (may be $null, a single object, or an array —
        PS 5.1 ConvertFrom-Json can return any of these).
    .PARAMETER IdentifierBuilder
        Scriptblock taking one record and returning [ordered]@{col=value;...}.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Records,
        [Parameter(Mandatory = $true)][scriptblock]$IdentifierBuilder
    )

    $map = @{}
    if ($null -eq $Records) { return $map }

    foreach ($r in $Records) {
        $idents = & $IdentifierBuilder $r
        $key    = ($idents.Values | ForEach-Object { "$_" }) -join '|'
        # Skip records where every identifier value is blank.
        if ($key -replace '\|', '' -eq '') { continue }
        $map[$key] = @{ Record = $r; Identifiers = $idents }
    }
    $map
}

function Compare-Records {
    <#
    .SYNOPSIS
        Compares availabilityState across two sets of records, keyed and
        labelled by an identifier-builder scriptblock. Writes CSV output and
        prints a console mismatch summary.
    .PARAMETER IdentifierBuilder
        Scriptblock taking one record and returning [ordered]@{col=value;...}.
        The keys of the returned hashtable become the leading columns of
        the CSV; the values are used both as column data and (joined with '|')
        as the cross-file matching key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$File1Path,
        [Parameter(Mandatory = $true)][string]$File2Path,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][scriptblock]$IdentifierBuilder
    )

    $info1 = Get-FileInfo -FilePath $File1Path
    $info2 = Get-FileInfo -FilePath $File2Path
    $col1  = "$($info1.SiteName) ($($info1.Timestamp))"
    $col2  = "$($info2.SiteName) ($($info2.Timestamp))"

    $data1 = Get-Content -Path $File1Path -Raw | ConvertFrom-Json
    $data2 = Get-Content -Path $File2Path -Raw | ConvertFrom-Json

    $map1 = Get-IdentifiedRecords -Records $data1.records -IdentifierBuilder $IdentifierBuilder
    $map2 = Get-IdentifiedRecords -Records $data2.records -IdentifierBuilder $IdentifierBuilder

    $allKeys = @(($map1.Keys + $map2.Keys) | Sort-Object -Unique)

    $results    = New-Object System.Collections.Generic.List[object]
    $mismatches = New-Object System.Collections.Generic.List[object]
    $identifierColumns = @()

    foreach ($key in $allKeys) {
        $entry1 = $map1[$key]
        $entry2 = $map2[$key]

        # Prefer file 1 for the identifier values. If a record only exists
        # on one side, use that side's identifiers.
        $idents = if ($null -ne $entry1) { $entry1.Identifiers } else { $entry2.Identifiers }
        if ($identifierColumns.Count -eq 0) { $identifierColumns = @($idents.Keys) }

        $r1 = if ($null -ne $entry1) { $entry1.Record } else { $null }
        $r2 = if ($null -ne $entry2) { $entry2.Record } else { $null }
        $s1 = Get-StateValue -Record $r1
        $s2 = Get-StateValue -Record $r2
        $match = if ($s1 -eq $s2) { 'Yes' } else { 'No' }

        $row = [ordered]@{}
        foreach ($k in $idents.Keys) { $row[$k] = $idents[$k] }
        $row[$col1]   = $s1
        $row[$col2]   = $s2
        $row['Match'] = $match
        $results.Add([PSCustomObject]$row)

        if ($match -eq 'No') {
            $mm = [ordered]@{}
            foreach ($k in $idents.Keys) { $mm[$k] = $idents[$k] }
            $mm[$col1] = $s1
            $mm[$col2] = $s2
            $mismatches.Add([PSCustomObject]$mm)
        }
    }

    Write-ComparisonOutput `
        -Results $results -Mismatches $mismatches `
        -Col1 $col1 -Col2 $col2 `
        -Info1 $info1 -Info2 $info2 `
        -IdentifierColumns $identifierColumns `
        -OutputPath $OutputPath
}

function Write-ComparisonOutput {
    <#
    .SYNOPSIS
        Writes the CSV output and prints a console summary of mismatches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)]$Mismatches,
        [Parameter(Mandatory = $true)][string]$Col1,
        [Parameter(Mandatory = $true)][string]$Col2,
        [Parameter(Mandatory = $true)]$Info1,
        [Parameter(Mandatory = $true)]$Info2,
        [Parameter(Mandatory = $true)][string[]]$IdentifierColumns,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $Results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "Comparison saved to $OutputPath"
    Write-Host "Compared $($Info1.SiteName) ($($Info1.Timestamp)) vs $($Info2.SiteName) ($($Info2.Timestamp))"

    $sep = '=' * 80
    if ($Mismatches.Count -gt 0) {
        Write-Host ""
        Write-Host $sep
        Write-Host "MISMATCHES FOUND: $($Mismatches.Count)"
        Write-Host $sep
        foreach ($mm in $Mismatches) {
            Write-Host ""
            foreach ($c in $IdentifierColumns) {
                Write-Host "${c}: $($mm.$c)"
            }
            Write-Host "  ${Col1}: $($mm.$Col1)"
            Write-Host "  ${Col2}: $($mm.$Col2)"
        }
    } else {
        Write-Host ""
        Write-Host $sep
        Write-Host "NO MISMATCHES FOUND - All states match!"
        Write-Host $sep
    }
}

# ============================================================================
# Main
# ============================================================================

$dataType = Select-DataType
if ($null -eq $dataType) {
    Write-Host "Operation cancelled."
    return
}

$selected = Select-ComparisonFiles -DataType $dataType
if ($null -eq $selected) {
    return
}

$outputFile = Join-Path -Path (Get-Location) -ChildPath "${dataType}_comparison.csv"

switch ($dataType) {
    'ltmPoolMembers' {
        # Pool + Member identifier columns. Member falls back to address:port
        # when memberName is null (known collector bug).
        $identBuilder = {
            param($r)
            [ordered]@{
                Pool   = [string]$r.poolName
                Member = Get-MemberDisplayName -Record $r
            }
        }
        Compare-Records `
            -File1Path $selected[0].FullPath `
            -File2Path $selected[1].FullPath `
            -OutputPath $outputFile `
            -IdentifierBuilder $identBuilder
    }
    'ltmVirtualStats' {
        # virtualName is already a unique full path, e.g. "/Common/vs_web"
        $identBuilder = {
            param($r)
            [ordered]@{ Virtual = [string]$r.virtualName }
        }
        Compare-Records `
            -File1Path $selected[0].FullPath `
            -File2Path $selected[1].FullPath `
            -OutputPath $outputFile `
            -IdentifierBuilder $identBuilder
    }
}