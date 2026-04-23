<#
.SYNOPSIS
    Compare F5 pool and member availability states between two JSON exports.

.DESCRIPTION
    PowerShell 5.1 equivalent of pool_status_report.py. Scans the current
    directory for pool member JSON files, prompts the user to pick a pool
    type (LTM or GTM) and two files via Out-GridView, then writes a CSV
    comparing every pool and member's availability state. A console summary
    of mismatches is printed after the CSV is written.

.NOTES
    Requires PowerShell 5.1+.
    Run from the directory containing the *__ltm_pool_members.json or
    *__gtm_pool_members.json files.
#>

# Mapping of host IDs to friendly site names
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
        Extracts friendly site name and timestamp from a pool member JSON filename.
    .PARAMETER FilePath
        Path to the JSON file (or just its filename).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $stem  = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    # Expected format: hostID__hostname__YYYY-MM-DD__HH-MM-SS__type_pool_members
    $parts = $stem -split '__'

    $siteId   = $parts[0]
    $hostName = $parts[1]
    $dateStr  = $parts[2]
    $timeStr  = $parts[3] -replace '-', ':'

    $altSite = if ($ChassisMapping.ContainsKey($siteId)) {
        $ChassisMapping[$siteId]
    } else {
        $siteId
    }

    [PSCustomObject]@{
        SiteName  = "$altSite $hostName"
        Timestamp = "$dateStr $timeStr"
    }
}

function Get-AvailableFiles {
    <#
    .SYNOPSIS
        Returns pool member JSON files in the current directory for a pool type.
    .PARAMETER PoolType
        'ltm' or 'gtm'.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ltm', 'gtm')]
        [string]$PoolType
    )

    $pattern = "*__${PoolType}_pool_members.json"
    @(Get-ChildItem -Path (Get-Location) -Filter $pattern -File | Sort-Object Name)
}

function Select-PoolType {
    <#
    .SYNOPSIS
        Prompts user to pick pool type via Out-GridView.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $choice = @(
        [PSCustomObject]@{ Type = 'ltm'; Description = 'LTM (Local Traffic Manager)' }
        [PSCustomObject]@{ Type = 'gtm'; Description = 'GTM (Global Traffic Manager)' }
    ) | Out-GridView -Title 'Select pool type' -OutputMode Single

    if ($null -eq $choice) { return $null }
    $choice.Type
}

function Select-ComparisonFiles {
    <#
    .SYNOPSIS
        Prompts user to select exactly 2 files via Out-GridView (multi-select).
    .PARAMETER PoolType
        'ltm' or 'gtm'.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ltm', 'gtm')]
        [string]$PoolType
    )

    $files = Get-AvailableFiles -PoolType $PoolType
    if ($files.Count -lt 2) {
        Write-Warning "At least 2 $($PoolType.ToUpper()) files required. Found $($files.Count)."
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

    $title = "Select exactly 2 $($PoolType.ToUpper()) files (Ctrl+click two rows, then OK)"
    $selected = @($rows | Out-GridView -Title $title -OutputMode Multiple)

    if ($selected.Count -ne 2) {
        Write-Warning "Exactly 2 files must be selected. You selected $($selected.Count)."
        return $null
    }

    $selected
}

function Get-StateValue {
    <#
    .SYNOPSIS
        Safely reads 'status.availability-state' from a pool/member object,
        falling back to 'N/A' when the object or property is missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        $Object
    )

    if ($null -eq $Object) { return 'N/A' }
    $val = $Object.'status.availability-state'
    if ($null -eq $val -or $val -eq '') { return 'N/A' }
    [string]$val
}

function Compare-PoolStates {
    <#
    .SYNOPSIS
        Compares pool and member availability states between two JSON files.
    .PARAMETER File1Path
        Path to first JSON file.
    .PARAMETER File2Path
        Path to second JSON file.
    .PARAMETER OutputPath
        Path to CSV output file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$File1Path,
        [Parameter(Mandatory = $true)][string]$File2Path,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $info1 = Get-FileInfo -FilePath $File1Path
    $info2 = Get-FileInfo -FilePath $File2Path

    $col1Header = "$($info1.SiteName) ($($info1.Timestamp))"
    $col2Header = "$($info2.SiteName) ($($info2.Timestamp))"

    $data1 = Get-Content -Path $File1Path -Raw | ConvertFrom-Json
    $data2 = Get-Content -Path $File2Path -Raw | ConvertFrom-Json

    $pools1   = @($data1.PSObject.Properties.Name)
    $pools2   = @($data2.PSObject.Properties.Name)
    $allPools = @(($pools1 + $pools2) | Sort-Object -Unique)

    $results    = New-Object System.Collections.Generic.List[object]
    $mismatches = New-Object System.Collections.Generic.List[object]

    foreach ($poolName in $allPools) {
        $pool1 = $data1.$poolName
        $pool2 = $data2.$poolName

        $pool1State = Get-StateValue -Object $pool1
        $pool2State = Get-StateValue -Object $pool2

        $poolMatch = if ($pool1State -eq $pool2State) { 'Yes' } else { 'No' }

        $row = [ordered]@{
            Type = 'Pool'
            Name = $poolName
        }
        $row[$col1Header] = $pool1State
        $row[$col2Header] = $pool2State
        $row['Match']     = $poolMatch
        $results.Add([PSCustomObject]$row)

        if ($poolMatch -eq 'No') {
            $mm = [ordered]@{
                Type = 'Pool'
                Name = $poolName
            }
            $mm[$col1Header] = $pool1State
            $mm[$col2Header] = $pool2State
            $mismatches.Add([PSCustomObject]$mm)
        }

        # Members
        $members1 = if ($null -ne $pool1) { $pool1.members } else { $null }
        $members2 = if ($null -ne $pool2) { $pool2.members } else { $null }

        $mNames1 = if ($null -ne $members1) { @($members1.PSObject.Properties.Name) } else { @() }
        $mNames2 = if ($null -ne $members2) { @($members2.PSObject.Properties.Name) } else { @() }
        $allMembers = @(($mNames1 + $mNames2) | Sort-Object -Unique)

        foreach ($memberName in $allMembers) {
            $m1 = if ($null -ne $members1) { $members1.$memberName } else { $null }
            $m2 = if ($null -ne $members2) { $members2.$memberName } else { $null }

            $m1State = Get-StateValue -Object $m1
            $m2State = Get-StateValue -Object $m2

            $memberMatch = if ($m1State -eq $m2State) { 'Yes' } else { 'No' }
            $fullName    = "$poolName -> $memberName"

            $row = [ordered]@{
                Type = 'Member'
                Name = $fullName
            }
            $row[$col1Header] = $m1State
            $row[$col2Header] = $m2State
            $row['Match']     = $memberMatch
            $results.Add([PSCustomObject]$row)

            if ($memberMatch -eq 'No') {
                $mm = [ordered]@{
                    Type = 'Member'
                    Name = $fullName
                }
                $mm[$col1Header] = $m1State
                $mm[$col2Header] = $m2State
                $mismatches.Add([PSCustomObject]$mm)
            }
        }
    }

    # Write CSV
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

    # Console summary
    Write-Host ""
    Write-Host "Comparison saved to $OutputPath"
    Write-Host "Compared $($info1.SiteName) ($($info1.Timestamp)) vs $($info2.SiteName) ($($info2.Timestamp))"

    $sep = '=' * 80
    if ($mismatches.Count -gt 0) {
        Write-Host ""
        Write-Host $sep
        Write-Host "MISMATCHES FOUND: $($mismatches.Count)"
        Write-Host $sep
        foreach ($mm in $mismatches) {
            Write-Host ""
            Write-Host "Type: $($mm.Type)"
            Write-Host "Name: $($mm.Name)"
            Write-Host "  ${col1Header}: $($mm.$col1Header)"
            Write-Host "  ${col2Header}: $($mm.$col2Header)"
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

$poolType = Select-PoolType
if ($null -eq $poolType) {
    Write-Host "Operation cancelled."
    return
}

$selected = Select-ComparisonFiles -PoolType $poolType
if ($null -eq $selected) {
    return
}

$outputFile = Join-Path -Path (Get-Location) -ChildPath "${poolType}_pool_comparison.csv"

Compare-PoolStates `
    -File1Path $selected[0].FullPath `
    -File2Path $selected[1].FullPath `
    -OutputPath $outputFile