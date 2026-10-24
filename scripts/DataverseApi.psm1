# Minimal Dataverse Web API helpers shared by the prototype scripts (Windows PowerShell 5.1 compatible).
# Auth uses Azure CLI: the environment's tenant is read from its 401 challenge and a signed-in az
# account in that tenant is used, so the active az account doesn't matter.

$script:Dv = @{ Url = $null; ApiBase = $null; Headers = $null }

function Get-DvTenantId([string]$EnvironmentUrl) {
    try { Invoke-WebRequest -Uri "$EnvironmentUrl/api/data/v9.2/" -UseBasicParsing | Out-Null }
    catch {
        $challenge = $_.Exception.Response.Headers['WWW-Authenticate']
        if ($challenge -match 'login\.microsoftonline\.com/([0-9a-f-]{36})') { return $Matches[1] }
    }
    return $null
}

function Connect-Dataverse {
    param([Parameter(Mandatory)][string]$EnvironmentUrl, [string]$AccessToken, [string]$TenantId)
    $EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
    if (-not $AccessToken) {
        if (-not $TenantId) { $TenantId = Get-DvTenantId $EnvironmentUrl }
        if ($TenantId) {
            $sub = az account list --all --query "[?tenantId=='$TenantId'].id | [0]" -o tsv 2>$null
            if ($sub) { $AccessToken = az account get-access-token --subscription $sub --resource $EnvironmentUrl --query accessToken -o tsv 2>$null }
            if (-not $AccessToken) { $AccessToken = az account get-access-token --tenant $TenantId --resource $EnvironmentUrl --query accessToken -o tsv 2>$null }
        } else {
            $AccessToken = az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv 2>$null
        }
        if (-not $AccessToken) { throw "Could not get a token. Run: az login --tenant $TenantId --scope $EnvironmentUrl/.default  (or pass -AccessToken)." }
    }
    $script:Dv.Url = $EnvironmentUrl
    $script:Dv.ApiBase = "$EnvironmentUrl/api/data/v9.2"
    $script:Dv.Headers = @{
        Authorization      = "Bearer $AccessToken"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Prefer             = 'odata.include-annotations="*",odata.maxpagesize=200'
    }
    $who = Invoke-DvRequest -Method Get -Path 'WhoAmI()'
    return $who
}

# Throws a readable error message on failure. Returns parsed JSON (or $null for 204).
function Invoke-DvRequest {
    param(
        [ValidateSet('Get', 'Post', 'Patch', 'Delete')][string]$Method = 'Get',
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [hashtable]$ExtraHeaders
    )
    $url = if ($Path -match '^https?://') { $Path } else { "$($script:Dv.ApiBase)/$Path" }
    $headers = $script:Dv.Headers.Clone()
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }
    $args_ = @{ Method = $Method; Uri = $url; Headers = $headers }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $args_.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $args_.ContentType = 'application/json; charset=utf-8'
    }
    try { return Invoke-RestMethod @args_ }
    catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $msg = $_.ErrorDetails.Message }
        }
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $shortPath = if ($Path.Length -gt 120) { $Path.Substring(0, 120) + '...' } else { $Path }
        $err = New-Object System.Exception("$Method $shortPath failed ($status): $msg")
        $err.Data['Status'] = $status
        throw $err
    }
}

# GET that returns $null on 404 instead of throwing
function Get-DvOrNull([string]$Path) {
    try { return Invoke-DvRequest -Method Get -Path $Path }
    catch { if ($_.Exception.Data['Status'] -eq 404) { return $null } else { throw } }
}

# GET a collection, following @odata.nextLink
function Get-DvAll([string]$Path, [int]$MaxPages = 1000) {
    $rows = New-Object System.Collections.Generic.List[object]
    $r = Invoke-DvRequest -Method Get -Path $Path
    foreach ($v in $r.value) { $rows.Add($v) }
    $page = 1
    while ($r.'@odata.nextLink' -and $page -lt $MaxPages) {
        $r = Invoke-DvRequest -Method Get -Path $r.'@odata.nextLink'
        foreach ($v in $r.value) { $rows.Add($v) }
        $page++
    }
    return , $rows.ToArray()
}

function Get-DvFormatted($row, [string]$field) {
    $f = $row."$field@OData.Community.Display.V1.FormattedValue"
    if ($f) { return $f } else { return $row.$field }
}

function New-DvLabel([string]$text) {
    return @{
        '@odata.type'   = 'Microsoft.Dynamics.CRM.Label'
        LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $text; LanguageCode = 1033 })
    }
}

Export-ModuleMember -Function Connect-Dataverse, Invoke-DvRequest, Get-DvOrNull, Get-DvAll, Get-DvFormatted, New-DvLabel
