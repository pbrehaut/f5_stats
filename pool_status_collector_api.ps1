<#
.SYNOPSIS
    Collects LTM pool member and virtual server status data from an F5 BIG-IP
    via iControl REST.

.DESCRIPTION
    Authenticates to the F5 management interface using the supplied credential
    (exchanged once for an X-F5-Auth-Token), presents an Out-GridView
    multi-select of available collections, collects the selected data, and
    writes each collection to a JSON file in OutputPath using the naming
    convention:
        <chassisSerial>__<hostname>__<yyyy-MM-dd>__<HH-mm-ss>__<dataType>.json

    The output schema is a metadata wrapper containing a records array, e.g.:
        {
          "meta": { chassisSerial, hostname, collectedAt, dataType },
          "records": [ { ... }, { ... } ]
        }

.PARAMETER F5Host
    Hostname or IP address of the F5 management interface.

.PARAMETER Credential
    Credential for the F5 admin account. Prompts if omitted.

.PARAMETER OutputPath
    Directory to write JSON output files. Defaults to the current working
    directory.

.EXAMPLE
    .\Get-F5PoolStatus.ps1 -F5Host bigip1.example.com

.EXAMPLE
    $cred = Get-Credential admin
    .\Get-F5PoolStatus.ps1 -F5Host 10.0.0.10 -Credential $cred -OutputPath C:\f5data
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$F5Host,

    [Parameter(Mandatory = $true)]
    [System.Management.Automation.Credential()]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# TLS configuration: force TLS 1.2 and skip cert validation (self-signed F5s)
# ---------------------------------------------------------------------------
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
function New-F5AuthToken {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][pscredential]$Credential
    )
    $uri = "https://$F5Host/mgmt/shared/authn/login"
    $body = @{
        username          = $Credential.UserName
        password          = $Credential.GetNetworkCredential().Password
        loginProviderName = 'tmos'
    } | ConvertTo-Json

    Write-Verbose "Requesting auth token from $uri"
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json'
    return [string]$response.token.token
}

function Remove-F5AuthToken {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $uri = "https://$F5Host/mgmt/shared/authz/tokens/$Token"
    try {
        Invoke-RestMethod -Uri $uri -Method Delete -Headers @{ 'X-F5-Auth-Token' = $Token } | Out-Null
        Write-Verbose "Auth token revoked"
    }
    catch {
        Write-Warning "Failed to revoke auth token: $_"
    }
}

function Invoke-F5Rest {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $uri = "https://$F5Host$Path"
    Write-Verbose "GET $uri"
    return Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'X-F5-Auth-Token' = $Token }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-NestedStatValue {
    <#
        F5 nested stats entries are of the form:
            <fieldName>: { description: "..." }   OR
            <fieldName>: { value: 123 }
        This helper returns whichever is present, or $null if the field is missing.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][string]$FieldName
    )
    $field = $Entries.$FieldName
    if ($null -eq $field) { return $null }
    if ($field.PSObject.Properties.Name -contains 'description') { return $field.description }
    if ($field.PSObject.Properties.Name -contains 'value') { return $field.value }
    return $null
}

function Get-PartitionFromPath {
    # Derives partition name from a full path like "/Common/pool1" -> "Common"
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if ($Path -match '^/([^/]+)/') { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
# Identifiers
# ---------------------------------------------------------------------------
function Get-F5ChassisSerial {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $hw = Invoke-F5Rest -F5Host $F5Host -Token $Token -Path '/mgmt/tm/sys/hardware'

    # Traverse: entries -> *system-info* -> nestedStats -> entries -> <index>
    #           -> nestedStats -> entries -> bigipChassisSerialNum -> description
    foreach ($sysInfoKey in $hw.entries.PSObject.Properties.Name) {
        if ($sysInfoKey -like '*system-info*') {
            $sysInfoEntries = $hw.entries.$sysInfoKey.nestedStats.entries
            foreach ($subKey in $sysInfoEntries.PSObject.Properties.Name) {
                $sub = $sysInfoEntries.$subKey.nestedStats.entries
                if ($sub.bigipChassisSerialNum) {
                    return [string]$sub.bigipChassisSerialNum.description
                }
            }
        }
    }
    throw "Could not find bigipChassisSerialNum in /mgmt/tm/sys/hardware response"
}

function Get-F5Hostname {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $globals = Invoke-F5Rest -F5Host $F5Host -Token $Token -Path '/mgmt/tm/sys/global-settings'
    return [string]$globals.hostname
}

# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------
function Get-LtmPoolMemberRecords {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $records = New-Object System.Collections.Generic.List[object]

    $pools = Invoke-F5Rest -F5Host $F5Host -Token $Token -Path '/mgmt/tm/ltm/pool'
    foreach ($pool in $pools.items) {
        $poolFullPath = $pool.fullPath                     # e.g. /Common/webpool
        $poolUrlPath  = $poolFullPath -replace '/', '~'     # ~Common~webpool
        $statsPath    = "/mgmt/tm/ltm/pool/$poolUrlPath/members/stats"

        $stats = Invoke-F5Rest -F5Host $F5Host -Token $Token -Path $statsPath
        if (-not $stats.entries) { continue }

        foreach ($memberKey in $stats.entries.PSObject.Properties.Name) {
            $e = $stats.entries.$memberKey.nestedStats.entries
            $memberName = Get-NestedStatValue -Entries $e -FieldName 'tmName'

            $record = [ordered]@{
                partition          = Get-PartitionFromPath -Path $poolFullPath
                poolName           = $poolFullPath
                memberName         = $memberName
                address            = Get-NestedStatValue -Entries $e -FieldName 'addr'
                port               = Get-NestedStatValue -Entries $e -FieldName 'port'
                availabilityState  = Get-NestedStatValue -Entries $e -FieldName 'status.availabilityState'
                enabledState       = Get-NestedStatValue -Entries $e -FieldName 'status.enabledState'
                statusReason       = Get-NestedStatValue -Entries $e -FieldName 'status.statusReason'
                monitorStatus      = Get-NestedStatValue -Entries $e -FieldName 'monitorStatus'
                currentConnections = Get-NestedStatValue -Entries $e -FieldName 'serverside.curConns'
                totalConnections   = Get-NestedStatValue -Entries $e -FieldName 'serverside.totConns'
                bitsIn             = Get-NestedStatValue -Entries $e -FieldName 'serverside.bitsIn'
                bitsOut            = Get-NestedStatValue -Entries $e -FieldName 'serverside.bitsOut'
                packetsIn          = Get-NestedStatValue -Entries $e -FieldName 'serverside.pktsIn'
                packetsOut         = Get-NestedStatValue -Entries $e -FieldName 'serverside.pktsOut'
            }
            [void]$records.Add([pscustomobject]$record)
        }
    }
    return , $records.ToArray()
}

function Get-LtmVirtualRecords {
    param(
        [Parameter(Mandatory = $true)][string]$F5Host,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $records = New-Object System.Collections.Generic.List[object]

    $stats = Invoke-F5Rest -F5Host $F5Host -Token $Token -Path '/mgmt/tm/ltm/virtual/stats'
    if (-not $stats.entries) { return , $records.ToArray() }

    foreach ($vsKey in $stats.entries.PSObject.Properties.Name) {
        $e = $stats.entries.$vsKey.nestedStats.entries
        $virtualName = Get-NestedStatValue -Entries $e -FieldName 'tmName'
        $destination = Get-NestedStatValue -Entries $e -FieldName 'destination'

        # Destination is "/Partition/address:port" — split it into its parts
        $destAddress = $null
        $destPort    = $null
        if ($destination -match '^/[^/]+/(.+):(\d+)$') {
            $destAddress = $Matches[1]
            $destPort    = [int]$Matches[2]
        }

        $record = [ordered]@{
            partition          = Get-PartitionFromPath -Path $virtualName
            virtualName        = $virtualName
            destination        = $destination
            destinationAddress = $destAddress
            destinationPort    = $destPort
            availabilityState  = Get-NestedStatValue -Entries $e -FieldName 'status.availabilityState'
            enabledState       = Get-NestedStatValue -Entries $e -FieldName 'status.enabledState'
            statusReason       = Get-NestedStatValue -Entries $e -FieldName 'status.statusReason'
            currentConnections = Get-NestedStatValue -Entries $e -FieldName 'clientside.curConns'
            totalConnections   = Get-NestedStatValue -Entries $e -FieldName 'clientside.totConns'
            bitsIn             = Get-NestedStatValue -Entries $e -FieldName 'clientside.bitsIn'
            bitsOut            = Get-NestedStatValue -Entries $e -FieldName 'clientside.bitsOut'
            packetsIn          = Get-NestedStatValue -Entries $e -FieldName 'clientside.pktsIn'
            packetsOut         = Get-NestedStatValue -Entries $e -FieldName 'clientside.pktsOut'
        }
        [void]$records.Add([pscustomobject]$record)
    }
    return , $records.ToArray()
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
function Save-F5Data {
    param(
        [Parameter(Mandatory = $true)]       $Records,
        [Parameter(Mandatory = $true)][string]$ChassisSerial,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][string]$DatePart,
        [Parameter(Mandatory = $true)][string]$TimePart,
        [Parameter(Mandatory = $true)][string]$DataType,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $filename = "{0}__{1}__{2}__{3}__{4}.json" -f `
        $ChassisSerial, $Hostname, $DatePart, $TimePart, $DataType
    $fullPath = Join-Path -Path $OutputPath -ChildPath $filename

    $payload = [ordered]@{
        meta    = [ordered]@{
            chassisSerial = $ChassisSerial
            hostname      = $Hostname
            collectedAt   = (Get-Date).ToString('o')
            dataType      = $DataType
        }
        records = $Records
    }

    $json = $payload | ConvertTo-Json -Depth 10
    # PS 5.1 ConvertTo-Json serialises an empty array as "" — normalise to []
    $json = $json -replace '("records":\s*)""', '$1[]'

    $json | Out-File -FilePath $fullPath -Encoding utf8
    Write-Host "Saved to: $fullPath"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$token = $null
try {
    $token = New-F5AuthToken -F5Host $F5Host -Credential $Credential

    $chassisSerial = Get-F5ChassisSerial -F5Host $F5Host -Token $token
    $hostname      = Get-F5Hostname      -F5Host $F5Host -Token $token

    $now      = Get-Date
    $datePart = $now.ToString('yyyy-MM-dd')
    $timePart = $now.ToString('HH-mm-ss')

    $menuOptions = @(
        [pscustomobject]@{ Name = 'LTM Pool Members';         DataType = 'ltmPoolMembers'  }
        [pscustomobject]@{ Name = 'LTM Virtual Server Stats'; DataType = 'ltmVirtualStats' }
    )

    $selections = $menuOptions |
        Out-GridView -Title 'Select F5 data collections (Ctrl+click for multi-select)' -OutputMode Multiple

    if (-not $selections) {
        Write-Host "No selections made. Exiting."
        return
    }

    foreach ($selection in $selections) {
        switch ($selection.DataType) {
            'ltmPoolMembers' {
                $records = Get-LtmPoolMemberRecords -F5Host $F5Host -Token $token
                Save-F5Data -Records $records `
                    -ChassisSerial $chassisSerial -Hostname $hostname `
                    -DatePart $datePart -TimePart $timePart `
                    -DataType 'ltmPoolMembers' -OutputPath $OutputPath
            }
            'ltmVirtualStats' {
                $records = Get-LtmVirtualRecords -F5Host $F5Host -Token $token
                Save-F5Data -Records $records `
                    -ChassisSerial $chassisSerial -Hostname $hostname `
                    -DatePart $datePart -TimePart $timePart `
                    -DataType 'ltmVirtualStats' -OutputPath $OutputPath
            }
        }
    }
}
finally {
    if ($token) {
        Remove-F5AuthToken -F5Host $F5Host -Token $token
    }
}