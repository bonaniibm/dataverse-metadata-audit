<#
.SYNOPSIS
    Read-only feasibility checks for tracking customization (metadata) changes in a Dataverse environment.

.DESCRIPTION
    Runs the verification checks from the "Dataverse metadata change auditing" research report.
    Only GET requests are issued - nothing in the environment is created, updated or deleted.

      1. Auditability   - org audit settings, IsAuditEnabled/CanBeChanged on component tables,
                          and whether audit rows / metadata audit actions (100-111) already exist.
      2. Plug-ins       - whether customization messages (PublishXml, ImportSolution, CreateAttribute, ...)
                          and Create/Update/Delete on component tables accept custom plug-in steps.
      3. Solution history - what msdyn_solutionhistory records (operations seen, columns, any user column).
      4. Polling        - ExpireSubscriptionsInDays, RetrieveMetadataChanges cost with/without deletes,
                          systemform version/publish columns, unpublished retrieval, component layers.

    Results are printed and saved as JSON + Markdown in the output folder.

.PARAMETER EnvironmentUrl
    Dataverse environment URL, e.g. https://contoso.crm.dynamics.com/

.PARAMETER AccessToken
    Optional bearer token. If omitted, the script calls Azure CLI (az account get-access-token).

.PARAMETER TenantId
    Optional Entra tenant id. If omitted, it is detected from the environment's auth challenge and
    a signed-in Azure CLI account in that tenant is used.

.EXAMPLE
    .\Test-MetadataAuditFeasibility.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$AccessToken,
    [string]$TenantId,
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'results')
)

$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$ApiBase = "$EnvironmentUrl/api/data/v9.2"

# Component tables the report cares about
$ComponentTables = @(
    'systemform', 'savedquery', 'savedqueryvisualization', 'userquery', 'webresource', 'sitemap',
    'appmodule', 'solution', 'solutioncomponent', 'workflow', 'sdkmessageprocessingstep',
    'pluginassembly', 'role', 'entity', 'attribute', 'ribboncustomization', 'customcontrol'
)

# Messages that would let a plug-in observe customization work.
# These are sdkmessage names, which differ from SDK request names: PublishXmlRequest -> 'Publish',
# PublishAllXmlRequest -> 'PublishAll', CreateOneToManyRequest -> 'CreateOneToMany'.
$CustomizationMessages = @(
    'Publish', 'PublishAll', 'PublishAllAsync', 'Unpublish', 'PublishTheme',
    'ImportSolution', 'ImportSolutionAsync', 'StageAndUpgrade', 'StageAndUpgradeAsync',
    'ExportSolution', 'ExportSolutionAsync', 'UninstallSolution', 'UninstallSolutionAsync',
    'DeleteAndPromote', 'DeleteAndPromoteAsync', 'CloneAsPatch', 'CloneAsSolution',
    'AddSolutionComponent', 'RemoveSolutionComponent',
    'CreateEntity', 'UpdateEntity', 'DeleteEntity',
    'CreateAttribute', 'UpdateAttribute', 'DeleteAttribute',
    'CreateOptionSet', 'UpdateOptionSet', 'DeleteOptionSet',
    'InsertOptionValue', 'UpdateOptionValue', 'DeleteOptionValue',
    'CreateOneToMany', 'CreateManyToMany', 'UpdateRelationship', 'DeleteRelationship'
)

# Tables whose Create/Update/Delete steps we want to probe
$CrudProbeTables = @('systemform', 'savedquery', 'savedqueryvisualization', 'webresource', 'sitemap', 'appmodule', 'solution', 'solutioncomponent', 'workflow')

#region Helpers
# Reads the environment's Entra tenant id from the unauthenticated 401 challenge
function Get-EnvironmentTenantId {
    try { Invoke-WebRequest -Uri "$ApiBase/" -UseBasicParsing | Out-Null }
    catch {
        $challenge = $_.Exception.Response.Headers['WWW-Authenticate']
        if ($challenge -match 'login\.microsoftonline\.com/([0-9a-f-]{36})') { return $Matches[1] }
    }
    return $null
}

function Get-Token {
    if ($AccessToken) { return $AccessToken }
    if (-not $TenantId) { $script:TenantId = Get-EnvironmentTenantId }
    Write-Host "Getting token from Azure CLI for $EnvironmentUrl (tenant $TenantId) ..." -ForegroundColor DarkGray
    $tok = $null
    if ($TenantId) {
        # Prefer an already signed-in az account in the environment's tenant, so the active az account doesn't matter
        $sub = az account list --all --query "[?tenantId=='$TenantId'].id | [0]" -o tsv 2>$null
        if ($sub) { $tok = az account get-access-token --subscription $sub --resource $EnvironmentUrl --query accessToken -o tsv 2>$null }
        if (-not $tok) { $tok = az account get-access-token --tenant $TenantId --resource $EnvironmentUrl --query accessToken -o tsv 2>$null }
    } else {
        $tok = az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv 2>$null
    }
    if (-not $tok) { throw "Could not get a token. Run: az login --tenant $TenantId --scope $EnvironmentUrl/.default  (or pass -AccessToken)." }
    return $tok
}

$script:Headers = @{
    Authorization      = "Bearer $(Get-Token)"
    Accept             = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    Prefer             = 'odata.include-annotations="*"'
}

# GET wrapper: returns @{ Ok; Data; Error; Ms }
function Invoke-DvGet([string]$RelativeUrl) {
    $url = if ($RelativeUrl -match '^https?://') { $RelativeUrl } else { "$ApiBase/$RelativeUrl" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $data = Invoke-RestMethod -Method Get -Uri $url -Headers $script:Headers
        return @{ Ok = $true; Data = $data; Error = $null; Ms = $sw.ElapsedMilliseconds }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $msg = $_.ErrorDetails.Message }
        }
        return @{ Ok = $false; Data = $null; Error = $msg; Ms = $sw.ElapsedMilliseconds }
    }
}

# Follows @odata.nextLink up to $MaxPages
function Get-DvAll([string]$RelativeUrl, [int]$MaxPages = 20) {
    $rows = @()
    $r = Invoke-DvGet $RelativeUrl
    if (-not $r.Ok) { return $r }
    $rows += $r.Data.value
    $page = 1
    while ($r.Data.'@odata.nextLink' -and $page -lt $MaxPages) {
        $r = Invoke-DvGet $r.Data.'@odata.nextLink'
        if (-not $r.Ok) { break }
        $rows += $r.Data.value
        $page++
    }
    return @{ Ok = $true; Data = $rows; Error = $null }
}

function Get-Fmt($row, [string]$field) {
    $f = $row."$field@OData.Community.Display.V1.FormattedValue"
    if ($f) { return $f } else { return $row.$field }
}

function Write-Section([string]$title) { Write-Host "`n=== $title ===" -ForegroundColor Cyan }
function Write-Finding([string]$text, [string]$level = 'info') {
    $color = switch ($level) { 'good' { 'Green' } 'bad' { 'Red' } 'warn' { 'Yellow' } default { 'Gray' } }
    Write-Host "  $text" -ForegroundColor $color
    $script:Findings += [pscustomobject]@{ Section = $script:CurrentSection; Level = $level; Text = $text }
}

$script:Findings = @()
$script:Results = [ordered]@{ Environment = $EnvironmentUrl; RunAt = (Get-Date).ToString('o') }
#endregion

#region 0. Identity
$script:CurrentSection = '0. Connection'
Write-Section $script:CurrentSection
$who = Invoke-DvGet 'WhoAmI()'
if (-not $who.Ok) { throw "WhoAmI failed: $($who.Error)" }
$me = Invoke-DvGet "systemusers($($who.Data.UserId))?`$select=fullname,domainname"
$ver = Invoke-DvGet 'RetrieveVersion()'
Write-Finding "Connected as $($me.Data.fullname) <$($me.Data.domainname)>, org $($who.Data.OrganizationId), version $($ver.Data.Version)"
$script:Results.Connection = @{ User = $me.Data.domainname; OrganizationId = $who.Data.OrganizationId; Version = $ver.Data.Version }
#endregion

#region 1. Auditability
$script:CurrentSection = '1. Auditability'
Write-Section $script:CurrentSection

$org = Invoke-DvGet "organizations?`$select=isauditenabled,auditretentionperiodv2,auditretentionperiod,isuseraccessauditenabled,isreadauditenabled,expiresubscriptionsindays"
$orgRow = if ($org.Ok) { $org.Data.value[0] } else { $null }
if ($orgRow) {
    $lvl = if ($orgRow.isauditenabled) { 'good' } else { 'warn' }
    $retention = if ($null -ne $orgRow.auditretentionperiodv2) { $orgRow.auditretentionperiodv2 } else { "(not set; legacy value $($orgRow.auditretentionperiod))" }
    Write-Finding "Org auditing enabled: $($orgRow.isauditenabled); retention (v2, days): $retention; read/'log access' auditing: $($orgRow.isreadauditenabled); user access auditing: $($orgRow.isuseraccessauditenabled)" $lvl
    if ($orgRow.auditretentionperiodv2 -eq -1) { Write-Finding "Audit retention = -1 (Forever)" }
} else {
    Write-Finding "Could not read organization audit settings: $($org.Error)" 'bad'
}
$script:Results.OrgAudit = $orgRow

$tableAudit = @()
foreach ($t in $ComponentTables) {
    $r = Invoke-DvGet "EntityDefinitions(LogicalName='$t')?`$select=LogicalName,ObjectTypeCode,IsAuditEnabled,IsCustomizable,IsValidForAdvancedFind,ChangeTrackingEnabled"
    if ($r.Ok) {
        $tableAudit += [pscustomobject]@{
            Table               = $t
            ObjectTypeCode      = $r.Data.ObjectTypeCode
            AuditEnabled        = $r.Data.IsAuditEnabled.Value
            AuditCanBeChanged   = $r.Data.IsAuditEnabled.CanBeChanged
            ChangeTracking      = $r.Data.ChangeTrackingEnabled
            Note                = ''
        }
    } else {
        $tableAudit += [pscustomobject]@{ Table = $t; ObjectTypeCode = $null; AuditEnabled = $null; AuditCanBeChanged = $null; ChangeTracking = $null; Note = $r.Error }
    }
}
$tableAudit | Format-Table -AutoSize | Out-String | Write-Host
foreach ($row in $tableAudit) {
    if ($row.Note) { Write-Finding "$($row.Table): not available ($($row.Note))" 'warn'; continue }
    if ($row.AuditCanBeChanged) {
        $lvl = if ($row.AuditEnabled) { 'good' } else { 'warn' }
        Write-Finding "$($row.Table): auditing CAN be enabled (currently $($row.AuditEnabled))" $lvl
    } else {
        Write-Finding "$($row.Table): auditing setting is LOCKED (IsAuditEnabled=$($row.AuditEnabled), CanBeChanged=false)" 'bad'
    }
}
$script:Results.TableAuditability = $tableAudit

# Do audit rows already exist for component tables / metadata actions?
$auditRows = @()
foreach ($t in @('systemform', 'savedquery', 'savedqueryvisualization', 'webresource', 'sitemap', 'appmodule', 'solution', 'entity', 'attribute')) {
    $r = Invoke-DvGet "audits?`$select=createdon,action,operation,objecttypecode,_userid_value&`$filter=objecttypecode eq '$t'&`$orderby=createdon desc&`$top=5"
    if ($r.Ok) {
        $n = @($r.Data.value).Count
        $latest = if ($n -gt 0) { $r.Data.value[0] } else { $null }
        $auditRows += [pscustomobject]@{
            Table = $t; RowsSampled = $n
            LatestOn = if ($latest) { $latest.createdon } else { '' }
            LatestAction = if ($latest) { Get-Fmt $latest 'action' } else { '' }
            LatestBy = if ($latest) { Get-Fmt $latest '_userid_value' } else { '' }
        }
    } else {
        $auditRows += [pscustomobject]@{ Table = $t; RowsSampled = -1; LatestOn = ''; LatestAction = $r.Error; LatestBy = '' }
    }
}
$auditRows | Format-Table -AutoSize | Out-String | Write-Host
foreach ($a in $auditRows) {
    if ($a.RowsSampled -gt 0) { Write-Finding "Audit rows exist for $($a.Table) (latest $($a.LatestOn), '$($a.LatestAction)' by $($a.LatestBy))" 'good' }
    elseif ($a.RowsSampled -eq 0) { Write-Finding "No audit rows for $($a.Table)" }
    else { Write-Finding "Could not query audits for $($a.Table): $($a.LatestAction)" 'warn' }
}
$script:Results.ComponentAuditRows = $auditRows

# Metadata-change audit actions: 100 Delete Entity, 101 Delete Attribute, 102-104 audit changes, 105-111 audit start/stop/delete
$metaActions = Invoke-DvGet "audits?`$select=createdon,action,objecttypecode,_objectid_value,_userid_value&`$filter=action ge 100 and action le 111&`$orderby=createdon desc&`$top=25"
if ($metaActions.Ok) {
    $rows = @($metaActions.Data.value)
    Write-Finding "Metadata/audit-setting audit events (actions 100-111) found: $($rows.Count) (latest 25 sampled)" $(if ($rows.Count) { 'good' } else { 'info' })
    $sample = $rows | ForEach-Object { [pscustomobject]@{ On = $_.createdon; Action = (Get-Fmt $_ 'action'); Object = (Get-Fmt $_ 'objecttypecode'); By = (Get-Fmt $_ '_userid_value') } }
    if ($sample) { $sample | Select-Object -First 10 | Format-Table -AutoSize | Out-String | Write-Host }
    $script:Results.MetadataAuditActions = $sample
} else {
    Write-Finding "Could not query metadata audit actions: $($metaActions.Error)" 'warn'
}
#endregion

#region 2. Plug-in registrability
$script:CurrentSection = '2. Plug-in registrability'
Write-Section $script:CurrentSection

$msgFilter = ($CustomizationMessages | ForEach-Object { "name eq '$_'" }) -join ' or '
$msgs = Get-DvAll "sdkmessages?`$select=sdkmessageid,name,isprivate,isactive,autotransact&`$filter=$msgFilter"
$crudMsgs = Get-DvAll "sdkmessages?`$select=sdkmessageid,name&`$filter=name eq 'Create' or name eq 'Update' or name eq 'Delete'"

$pluginRows = @()
if ($msgs.Ok) {
    $found = @($msgs.Data | ForEach-Object { $_.name })
    foreach ($missing in ($CustomizationMessages | Where-Object { $found -notcontains $_ })) {
        $pluginRows += [pscustomobject]@{ Message = $missing; Table = ''; MessageExists = $false; Private = ''; CustomStepAllowed = ''; FilterCount = 0 }
    }
    foreach ($m in $msgs.Data) {
        $f = Get-DvAll "sdkmessagefilters?`$select=primaryobjecttypecode,iscustomprocessingstepallowed,isvisible,availability&`$filter=_sdkmessageid_value eq $($m.sdkmessageid)"
        $filters = if ($f.Ok) { @($f.Data) } else { @() }
        $allowed = @($filters | Where-Object { $_.iscustomprocessingstepallowed }).Count -gt 0
        $pluginRows += [pscustomobject]@{
            Message           = $m.name
            Table             = (($filters | ForEach-Object { $_.primaryobjecttypecode } | Select-Object -Unique) -join ',')
            MessageExists     = $true
            Private           = $m.isprivate
            CustomStepAllowed = $allowed
            FilterCount       = $filters.Count
        }
    }
} else {
    Write-Finding "Could not read sdkmessages: $($msgs.Error)" 'bad'
}

if ($crudMsgs.Ok) {
    foreach ($m in $crudMsgs.Data) {
        $tblFilter = ($CrudProbeTables | ForEach-Object { "primaryobjecttypecode eq '$_'" }) -join ' or '
        $f = Get-DvAll "sdkmessagefilters?`$select=primaryobjecttypecode,iscustomprocessingstepallowed&`$filter=_sdkmessageid_value eq $($m.sdkmessageid) and ($tblFilter)"
        $foundTables = @()
        if ($f.Ok) {
            foreach ($row in $f.Data) {
                $foundTables += $row.primaryobjecttypecode
                $pluginRows += [pscustomobject]@{ Message = $m.name; Table = $row.primaryobjecttypecode; MessageExists = $true; Private = ''; CustomStepAllowed = $row.iscustomprocessingstepallowed; FilterCount = 1 }
            }
        }
        foreach ($t in ($CrudProbeTables | Where-Object { $foundTables -notcontains $_ })) {
            $pluginRows += [pscustomobject]@{ Message = $m.name; Table = $t; MessageExists = $true; Private = ''; CustomStepAllowed = $false; FilterCount = 0 }
        }
    }
}

$pluginRows = $pluginRows | Sort-Object Message, Table
$pluginRows | Format-Table Message, Table, MessageExists, Private, CustomStepAllowed, FilterCount -AutoSize | Out-String -Width 200 | Write-Host
foreach ($p in $pluginRows) {
    $label = if ($p.Table -and $p.Message -in 'Create', 'Update', 'Delete') { "$($p.Message) on $($p.Table)" } else { $p.Message }
    if (-not $p.MessageExists) { Write-Finding "${label}: message does not exist in this environment" 'warn' }
    elseif ($p.CustomStepAllowed -eq $true) { Write-Finding "${label}: custom plug-in steps ALLOWED" 'good' }
    elseif ($p.FilterCount -eq 0) { Write-Finding "${label}: no message filter - cannot register a step" 'bad' }
    else { Write-Finding "${label}: custom plug-in steps NOT allowed" 'bad' }
}
$script:Results.PluginRegistrability = $pluginRows

# Existing steps already listening on customization messages (someone may already log publishes)
if ($msgs.Ok -and @($msgs.Data).Count) {
    $idFilter = (@($msgs.Data) | ForEach-Object { "_sdkmessageid_value eq $($_.sdkmessageid)" }) -join ' or '
    $steps = Get-DvAll "sdkmessageprocessingsteps?`$select=name,stage,mode,statecode,ishidden,_sdkmessageid_value&`$filter=$idFilter"
    if ($steps.Ok) {
        $visible = @($steps.Data | Where-Object { -not $_.ishidden.Value })
        Write-Finding "Existing (non-hidden) steps registered on customization messages: $($visible.Count)"
        $visible | Select-Object -First 15 | ForEach-Object { Write-Finding "   - $($_.name) [$(Get-Fmt $_ '_sdkmessageid_value'), stage $($_.stage), $(Get-Fmt $_ 'statecode')]" }
        $script:Results.ExistingCustomizationSteps = $visible | ForEach-Object { [pscustomobject]@{ Name = $_.name; Message = (Get-Fmt $_ '_sdkmessageid_value'); Stage = $_.stage; State = (Get-Fmt $_ 'statecode') } }
    }
}
#endregion

#region 3. Solution history
$script:CurrentSection = '3. Solution history'
Write-Section $script:CurrentSection

$shAttrs = Invoke-DvGet "EntityDefinitions(LogicalName='msdyn_solutionhistory')/Attributes?`$select=LogicalName,AttributeType"
if ($shAttrs.Ok) {
    $cols = @($shAttrs.Data.value | ForEach-Object { "$($_.LogicalName):$($_.AttributeType)" })
    $userCols = @($shAttrs.Data.value | Where-Object { $_.AttributeType -in 'Lookup', 'Owner', 'Customer' -or $_.LogicalName -match 'user|by$|owner|initiat' })
    Write-Finding "msdyn_solutionhistory has $($cols.Count) columns"
    if ($userCols.Count) { Write-Finding "Possible user columns: $(($userCols | ForEach-Object { "$($_.LogicalName) ($($_.AttributeType))" }) -join ', ')" 'good' }
    else { Write-Finding "No user/lookup column on msdyn_solutionhistory - it cannot tell you WHO ran an operation" 'bad' }
    $script:Results.SolutionHistoryColumns = $cols
} else {
    Write-Finding "Could not read msdyn_solutionhistory definition: $($shAttrs.Error)" 'bad'
}

$sh = Get-DvAll "msdyn_solutionhistories?`$orderby=msdyn_starttime desc&`$top=500" -MaxPages 5
if ($sh.Ok) {
    $rows = @($sh.Data)
    $oldest = ($rows | Sort-Object msdyn_starttime | Select-Object -First 1).msdyn_starttime
    Write-Finding "Solution history rows read: $($rows.Count); oldest: $oldest (Microsoft purges after ~180 days)"
    $byOp = $rows | Group-Object { "$(Get-Fmt $_ 'msdyn_operation') / $(Get-Fmt $_ 'msdyn_suboperation')" } | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ OperationAndSub = $_.Name; Count = $_.Count; Latest = ($_.Group | Sort-Object msdyn_starttime -Descending | Select-Object -First 1).msdyn_starttime } }
    $byOp | Format-Table -AutoSize | Out-String | Write-Host
    $ops = @($rows | ForEach-Object { Get-Fmt $_ 'msdyn_operation' } | Select-Object -Unique)
    foreach ($op in 'Publish', 'PublishAll') {
        if ($ops -contains $op) { Write-Finding "Solution history DOES record '$op' operations" 'good' }
        else { Write-Finding "No '$op' operation in sampled history (either not logged, or none occurred)" 'warn' }
    }
    $script:Results.SolutionHistoryByOperation = $byOp
    $script:Results.SolutionHistorySample = $rows | Select-Object -First 5
} else {
    Write-Finding "Could not query msdyn_solutionhistories: $($sh.Error)" 'bad'
}
#endregion

#region 4. Polling mechanics
$script:CurrentSection = '4. Polling mechanics'
Write-Section $script:CurrentSection

if ($orgRow) { Write-Finding "ExpireSubscriptionsInDays (metadata version stamp / change-tracking lifetime): $($orgRow.expiresubscriptionsindays)" }

# RetrieveMetadataChanges: full, delta, delta+deletes
$query = @{
    Criteria   = @{ FilterOperator = 'And'; Conditions = @(@{ PropertyName = 'IsCustomizable'; ConditionOperator = 'Equals'; Value = @{ Type = 'System.Boolean'; Value = 'true' } }) }
    Properties = @{ AllProperties = $false; PropertyNames = @('LogicalName', 'ModifiedOn', 'CreatedOn', 'Attributes') }
    AttributeQuery = @{ Properties = @{ AllProperties = $false; PropertyNames = @('LogicalName', 'ModifiedOn', 'CreatedOn') } }
} | ConvertTo-Json -Depth 10 -Compress
$q = [uri]::EscapeDataString($query)

$full = Invoke-DvGet "RetrieveMetadataChanges(Query=@q)?@q=$q"
$rmc = [ordered]@{}
if ($full.Ok) {
    $stamp = $full.Data.ServerVersionStamp
    $entities = @($full.Data.EntityMetadata)
    $attrCount = ($entities | ForEach-Object { @($_.Attributes).Count } | Measure-Object -Sum).Sum
    Write-Finding "RetrieveMetadataChanges full baseline: $($entities.Count) tables / $attrCount columns in $($full.Ms) ms" 'good'
    $rmc.FullMs = $full.Ms; $rmc.Tables = $entities.Count; $rmc.Columns = $attrCount

    $recent = $entities | Where-Object { $_.ModifiedOn } | Sort-Object { [datetime]$_.ModifiedOn } -Descending | Select-Object -First 5
    if ($recent) { Write-Finding "Most recently modified tables: $(($recent | ForEach-Object { "$($_.LogicalName) ($($_.ModifiedOn))" }) -join '; ')" }

    $s = [uri]::EscapeDataString("'$stamp'")
    $delta = Invoke-DvGet "RetrieveMetadataChanges(Query=@q,ClientVersionStamp=@s)?@q=$q&@s=$s"
    if ($delta.Ok) {
        Write-Finding "Delta call with ClientVersionStamp: $(@($delta.Data.EntityMetadata).Count) changed tables in $($delta.Ms) ms" 'good'
        $rmc.DeltaMs = $delta.Ms
    } else { Write-Finding "Delta call failed: $($delta.Error)" 'bad' }

    $d = [uri]::EscapeDataString("Microsoft.Dynamics.CRM.DeletedMetadataFilters'All'")
    $del = Invoke-DvGet "RetrieveMetadataChanges(Query=@q,ClientVersionStamp=@s,DeletedMetadataFilters=@d)?@q=$q&@s=$s&@d=$d"
    if ($del.Ok) {
        Write-Finding "Delta + DeletedMetadataFilters=All: $($del.Ms) ms (vs $($delta.Ms) ms without deletes)" 'good'
        $rmc.DeltaWithDeletesMs = $del.Ms
    } else { Write-Finding "Delta with deletes failed: $($del.Error)" 'bad' }

    $bad = [uri]::EscapeDataString("'0!0'")
    $exp = Invoke-DvGet "RetrieveMetadataChanges(Query=@q,ClientVersionStamp=@s)?@q=$q&@s=$bad"
    if (-not $exp.Ok) { Write-Finding "Invalid/expired stamp returns: $($exp.Error)"; $rmc.ExpiredStampError = $exp.Error }
} else {
    Write-Finding "RetrieveMetadataChanges failed: $($full.Error)" 'bad'
}
$script:Results.RetrieveMetadataChanges = $rmc

# systemform: who/when columns and versioning
$sfAttrs = Invoke-DvGet "EntityDefinitions(LogicalName='systemform')/Attributes?`$select=LogicalName"
if ($sfAttrs.Ok) {
    $names = @($sfAttrs.Data.value | ForEach-Object { $_.LogicalName })
    foreach ($c in 'createdby', 'modifiedby', 'modifiedon', 'publishedon', 'versionnumber', 'overwritetime', 'componentstate') {
        $has = $names -contains $c
        Write-Finding "systemform.$c present: $has" $(if ($has) { 'good' } else { 'warn' })
    }
}
$forms = Invoke-DvGet "systemforms?`$select=name,objecttypecode,type,publishedon,versionnumber,componentstate,ismanaged,formid&`$orderby=publishedon desc&`$top=5"
if ($forms.Ok) {
    $fs = @($forms.Data.value) | ForEach-Object { [pscustomobject]@{ Name = $_.name; Table = $_.objecttypecode; PublishedOn = $_.publishedon; VersionNumber = $_.versionnumber; State = (Get-Fmt $_ 'componentstate'); Managed = $_.ismanaged; Id = $_.formid } }
    Write-Finding "Most recently published forms:"
    $fs | Format-Table Name, Table, PublishedOn, VersionNumber, State, Managed -AutoSize | Out-String | Write-Host
    $script:Results.RecentForms = $fs
}

# savedquery: last writer sample
$views = Invoke-DvGet "savedqueries?`$select=name,returnedtypecode,modifiedon,_modifiedby_value,ismanaged&`$orderby=modifiedon desc&`$top=5"
if ($views.Ok) {
    $vs = @($views.Data.value) | ForEach-Object { [pscustomobject]@{ Name = $_.name; Table = $_.returnedtypecode; ModifiedOn = $_.modifiedon; ModifiedBy = (Get-Fmt $_ '_modifiedby_value'); Managed = $_.ismanaged } }
    Write-Finding "Most recently modified views (last-writer only):"
    $vs | Format-Table -AutoSize | Out-String | Write-Host
    $script:Results.RecentViews = $vs
}

# Unpublished customizations (pending edits not yet published)
$unpub = Invoke-DvGet "systemforms/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()?`$select=name,objecttypecode"
# Note: this returns the unpublished copy of every form, not only forms with pending edits - diff it against the published copy
if ($unpub.Ok) { Write-Finding "RetrieveUnpublishedMultiple on systemforms works: returned $(@($unpub.Data.value).Count) unpublished form copies (diff against published to find pending edits)" 'good' }
else { Write-Finding "RetrieveUnpublishedMultiple on systemforms failed: $($unpub.Error)" 'warn' }

# Component layers for the most recently published form
if ($forms.Ok -and @($forms.Data.value).Count) {
    $fid = $forms.Data.value[0].formid
    $layerFilter = [uri]::EscapeDataString("(msdyn_componentid eq '$fid' and msdyn_solutioncomponentname eq 'SystemForm')")
    $layers = Invoke-DvGet "msdyn_componentlayers?`$filter=$layerFilter&`$select=msdyn_name,msdyn_solutionname,msdyn_publishername,msdyn_order,msdyn_overwritetime,msdyn_changes"
    if ($layers.Ok) {
        $ls = @($layers.Data.value) | ForEach-Object { [pscustomobject]@{ Solution = $_.msdyn_solutionname; Publisher = $_.msdyn_publishername; Order = $_.msdyn_order; OverwriteTime = $_.msdyn_overwritetime; ChangesLength = "$($_.msdyn_changes)".Length } }
        Write-Finding "msdyn_componentlayer for form '$($forms.Data.value[0].name)': $(@($ls).Count) layers in $($layers.Ms) ms" 'good'
        $ls | Format-Table -AutoSize | Out-String | Write-Host
        $script:Results.FormLayers = $ls
    } else { Write-Finding "msdyn_componentlayer query failed: $($layers.Error)" 'warn' }
}
#endregion

#region Save results
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$stampName = Get-Date -Format 'yyyyMMdd-HHmmss'
$host_ = ([uri]$EnvironmentUrl).Host.Split('.')[0]
$jsonPath = Join-Path $OutputFolder "checks-$host_-$stampName.json"
$mdPath = Join-Path $OutputFolder "checks-$host_-$stampName.md"

$script:Results.Findings = $script:Findings
$script:Results | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8

$md = @("# Metadata audit feasibility checks", "", "Environment: $EnvironmentUrl  ", "Run: $($script:Results.RunAt)  ", "User: $($script:Results.Connection.User)", "")
foreach ($g in ($script:Findings | Group-Object Section)) {
    $md += "## $($g.Name)", ""
    foreach ($f in $g.Group) {
        $icon = switch ($f.Level) { 'good' { '[OK]' } 'bad' { '[NO]' } 'warn' { '[??]' } default { '-' } }
        $md += "- $icon $($f.Text)"
    }
    $md += ""
}
$md | Out-File -FilePath $mdPath -Encoding utf8

Write-Host "`nSaved:`n  $jsonPath`n  $mdPath" -ForegroundColor Cyan
#endregion
