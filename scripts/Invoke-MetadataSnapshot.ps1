<#
.SYNOPSIS
    Snapshots forms, views and columns from a Dataverse environment into a local Git repository,
    diffs against the previous run, and writes a change log with best-effort attribution.

.DESCRIPTION
    Read-only against Dataverse. Run it on a schedule (e.g. every 15 minutes; at least once within
    the environment's ExpireSubscriptionsInDays, 7 days in the environment we tested).

    Snapshot layout (one file per component, so Git diffs are per component):
      forms/<table>/<formid>.xml       pretty-printed FormXml with a name/type header comment
      views/<table>/<savedqueryid>.xml FetchXml + LayoutXml
      columns/<table>/<column>.json    selected AttributeMetadata properties
      changes/<timestamp>.json|.md     change log for each run that found changes

    Detection:
      forms   - incremental on publishedon (plus id list for deletes)
      views   - incremental on modifiedon (plus id list for deletes)
      columns - RetrieveMetadataChanges with a stored ClientVersionStamp; full re-baseline when it expires

    Attribution per change (confidence in brackets):
      [direct]       publish log row whose ParameterXml names this form/dashboard id
      [corroborated] publish log row in the window that published this component's table
      [last-writer]  savedquery.modifiedby at detection time
      [deployment]   change falls inside a solution import window from msdyn_solutionhistory (no user)
      [candidate]    a PublishAll in the window (doesn't say which components)
      [unattributed] nothing matched

.EXAMPLE
    .\Invoke-MetadataSnapshot.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/
.EXAMPLE
    .\Invoke-MetadataSnapshot.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/ -Tables account,contact
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$AccessToken,
    [string]$SnapshotRoot,
    # Limit to these table logical names (default: all tables with IsCustomizable = true)
    [string[]]$Tables,
    # Prefix of the publish log table installed by Install-PublishLogger.ps1
    [string]$LogPrefix = 'mda',
    # Extra minutes to look back past the previous run when matching publish logs / solution history
    [int]$OverlapMinutes = 10,
    [switch]$FullRescan
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DataverseApi.psm1') -Force

$hostName = ([uri]$EnvironmentUrl).Host.Split('.')[0]
if (-not $SnapshotRoot) { $SnapshotRoot = Join-Path $PSScriptRoot "..\snapshots\$hostName" }
$SnapshotRoot = [IO.Path]::GetFullPath($SnapshotRoot)
$StateDir = Join-Path $SnapshotRoot '.state'
$StatePath = Join-Path $StateDir 'state.json'
$ColumnIndexPath = Join-Path $StateDir 'column-index.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$runStarted = (Get-Date).ToUniversalTime()

#region Helpers
function Write-Info([string]$t) { Write-Host $t -ForegroundColor Gray }

function Invoke-Git {
    $out = & git -C $SnapshotRoot @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" }
    return $out
}

function ConvertTo-SafeName([string]$s) { return ($s -replace '[\\/:*?"<>|]', '_') }

function Format-Xml([string]$xml) {
    if ([string]::IsNullOrWhiteSpace($xml)) { return '' }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $false
        $doc.LoadXml($xml)
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = '  '
        $settings.OmitXmlDeclaration = $true
        $sb = New-Object System.Text.StringBuilder
        $w = [System.Xml.XmlWriter]::Create($sb, $settings)
        $doc.Save($w); $w.Close()
        return $sb.ToString()
    } catch { return $xml }
}

function Write-SnapshotFile([string]$relPath, [string]$content) {
    $full = Join-Path $SnapshotRoot $relPath
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($full, ($content -replace "`r`n", "`n"), $utf8)
}

function Remove-SnapshotFile([string]$relPath) {
    $full = Join-Path $SnapshotRoot $relPath
    if (Test-Path $full) { Remove-Item $full -Force }
}

function Get-Label($label) {
    if ($label -and $label.UserLocalizedLabel) { return $label.UserLocalizedLabel.Label }
    return $null
}

# Files currently on disk under a folder, keyed by id (file base name)
function Get-ExistingIds([string]$folder) {
    $map = @{}
    $root = Join-Path $SnapshotRoot $folder
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -File | ForEach-Object {
            $map[$_.BaseName.ToLower()] = $_.FullName.Substring($SnapshotRoot.Length + 1).Replace('\', '/')
        }
    }
    return $map
}

function Get-ODataDate([datetime]$d) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
#endregion

#region Setup
if (-not (Test-Path $SnapshotRoot)) { New-Item -ItemType Directory -Path $SnapshotRoot -Force | Out-Null }
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
if (-not (Test-Path (Join-Path $SnapshotRoot '.git'))) {
    Invoke-Git init -q | Out-Null
    Invoke-Git config user.name 'Dataverse metadata snapshot' | Out-Null
    Invoke-Git config user.email 'snapshot@localhost' | Out-Null
    Invoke-Git config core.autocrlf false | Out-Null
    [IO.File]::WriteAllText((Join-Path $SnapshotRoot '.gitignore'), ".state/`n", $utf8)
}

$state = if ((Test-Path $StatePath) -and -not $FullRescan) { Get-Content $StatePath -Raw | ConvertFrom-Json } else { $null }
$isBaseline = -not $state
$columnIndex = @{}
if ((Test-Path $ColumnIndexPath) -and -not $FullRescan) {
    (Get-Content $ColumnIndexPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $columnIndex[$_.Name] = $_.Value }
}
$lastRun = if ($state) { [datetime]::Parse($state.LastRunUtc).ToUniversalTime() } else { $null }

$who = Connect-Dataverse -EnvironmentUrl $EnvironmentUrl -AccessToken $AccessToken
Write-Info "Connected to $EnvironmentUrl; snapshot repo $SnapshotRoot; $(if ($isBaseline) { 'BASELINE run' } else { "incremental since $(Get-ODataDate $lastRun)" })"

$tableFilter = $null
if ($Tables) { $Tables = $Tables | ForEach-Object { $_.ToLower() } }

# Component metadata captured during this run, keyed by snapshot path, used for attribution
$componentInfo = @{}
#endregion

#region Forms
Write-Info "Forms ..."
$formTypes = @{ 0 = 'Dashboard'; 1 = 'AppointmentBook'; 2 = 'Main'; 4 = 'QuickView'; 5 = 'MiniCampaignBO'; 6 = 'Preview'; 7 = 'QuickCreate'; 8 = 'Dialog'; 9 = 'TaskFlow'; 10 = 'InteractionCentricDashboard'; 11 = 'Card'; 12 = 'MainInteractive'; 13 = 'ContextualDashboard'; 100 = 'Other'; 101 = 'MainBackup'; 102 = 'AppointmentBookBackup'; 103 = 'PowerBIDashboard' }
$formSelect = 'formid,name,objecttypecode,type,publishedon,ismanaged,formxml'
$formFilter = if ($Tables) { '(' + (($Tables | ForEach-Object { "objecttypecode eq '$_'" }) -join ' or ') + ')' } else { $null }

$allFormIds = Get-DvAll ("systemforms?`$select=formid,objecttypecode" + $(if ($formFilter) { "&`$filter=$formFilter" }))
$changedForms = if ($isBaseline) {
    Get-DvAll ("systemforms?`$select=$formSelect" + $(if ($formFilter) { "&`$filter=$formFilter" }))
} else {
    $since = Get-ODataDate $lastRun.AddMinutes(-$OverlapMinutes)
    $f = "publishedon ge $since" + $(if ($formFilter) { " and $formFilter" })
    Get-DvAll "systemforms?`$select=$formSelect&`$filter=$f"
}
foreach ($form in $changedForms) {
    $table = if ($form.objecttypecode) { $form.objecttypecode } else { '_none' }
    $typeName = $formTypes[[int]$form.type]
    $rel = "forms/$(ConvertTo-SafeName $table)/$($form.formid).xml"
    $header = "<!-- form: $($form.name) | table: $table | type: $typeName | managed: $($form.ismanaged) -->"
    Write-SnapshotFile $rel ($header + "`n" + (Format-Xml $form.formxml) + "`n")
    $componentInfo[$rel] = @{ Kind = 'form'; Table = $table; Id = $form.formid; Name = $form.name; SubType = $typeName; ChangedOn = $form.publishedon; ModifiedBy = $null }
}
$liveFormIds = @{}; foreach ($f in $allFormIds) { $liveFormIds[$f.formid.ToLower()] = $true }
$onDisk = Get-ExistingIds 'forms'
foreach ($id in @($onDisk.Keys)) { if (-not $liveFormIds.ContainsKey($id)) { Remove-SnapshotFile $onDisk[$id] } }
Write-Info "  $($allFormIds.Count) forms, $($changedForms.Count) fetched"
#endregion

#region Views
Write-Info "Views ..."
$viewSelect = 'savedqueryid,name,returnedtypecode,querytype,isdefault,ismanaged,fetchxml,layoutxml,modifiedon,_modifiedby_value'
$viewFilter = if ($Tables) { '(' + (($Tables | ForEach-Object { "returnedtypecode eq '$_'" }) -join ' or ') + ')' } else { $null }
$allViewIds = Get-DvAll ("savedqueries?`$select=savedqueryid" + $(if ($viewFilter) { "&`$filter=$viewFilter" }))
$changedViews = if ($isBaseline) {
    Get-DvAll ("savedqueries?`$select=$viewSelect" + $(if ($viewFilter) { "&`$filter=$viewFilter" }))
} else {
    $since = Get-ODataDate $lastRun.AddMinutes(-$OverlapMinutes)
    $f = "modifiedon ge $since" + $(if ($viewFilter) { " and $viewFilter" })
    Get-DvAll "savedqueries?`$select=$viewSelect&`$filter=$f"
}
foreach ($v in $changedViews) {
    $table = if ($v.returnedtypecode) { $v.returnedtypecode } else { '_none' }
    $rel = "views/$(ConvertTo-SafeName $table)/$($v.savedqueryid).xml"
    $body = "<!-- view: $($v.name) | table: $table | querytype: $($v.querytype) | default: $($v.isdefault) | managed: $($v.ismanaged) -->`n" +
        "<view>`n" + (Format-Xml $v.fetchxml) + "`n" + (Format-Xml $v.layoutxml) + "`n</view>`n"
    Write-SnapshotFile $rel $body
    $componentInfo[$rel] = @{ Kind = 'view'; Table = $table; Id = $v.savedqueryid; Name = $v.name; SubType = "querytype $($v.querytype)"; ChangedOn = $v.modifiedon; ModifiedBy = (Get-DvFormatted $v '_modifiedby_value') }
}
$liveViewIds = @{}; foreach ($v in $allViewIds) { $liveViewIds[$v.savedqueryid.ToLower()] = $true }
$onDisk = Get-ExistingIds 'views'
foreach ($id in @($onDisk.Keys)) { if (-not $liveViewIds.ContainsKey($id)) { Remove-SnapshotFile $onDisk[$id] } }
Write-Info "  $($allViewIds.Count) views, $($changedViews.Count) fetched"
#endregion

#region Columns
Write-Info "Columns ..."
$attrProps = @('MetadataId', 'LogicalName', 'SchemaName', 'AttributeType', 'AttributeTypeName', 'DisplayName', 'Description',
    'RequiredLevel', 'IsCustomAttribute', 'IsAuditEnabled', 'IsSecured', 'IsValidForAdvancedFind', 'CreatedOn', 'ModifiedOn', 'IntroducedVersion',
    'MaxLength', 'Format', 'FormatName', 'Precision', 'MinValue', 'MaxValue', 'Targets', 'DateTimeBehavior', 'SourceType', 'FormulaDefinition', 'OptionSet', 'AttributeOf')
# The Web API only accepts primitive condition values, so a table list becomes OR'd Equals conditions
if ($Tables) {
    $conditions = @($Tables | ForEach-Object { @{ PropertyName = 'LogicalName'; ConditionOperator = 'Equals'; Value = @{ Type = 'System.String'; Value = $_ } } })
    $filterOperator = 'Or'
} else {
    $conditions = @(@{ PropertyName = 'IsCustomizable'; ConditionOperator = 'Equals'; Value = @{ Type = 'System.Boolean'; Value = 'true' } })
    $filterOperator = 'And'
}
$query = @{
    Criteria       = @{ FilterOperator = $filterOperator; Conditions = $conditions }
    Properties     = @{ AllProperties = $false; PropertyNames = @('LogicalName', 'MetadataId', 'Attributes') }
    AttributeQuery = @{ Properties = @{ AllProperties = $false; PropertyNames = $attrProps } }
} | ConvertTo-Json -Depth 10 -Compress
$q = [uri]::EscapeDataString($query)

function Invoke-MetadataQuery([string]$stamp) {
    if (-not $stamp) { return Invoke-DvRequest -Path "RetrieveMetadataChanges(Query=@q)?@q=$q" }
    $s = [uri]::EscapeDataString("'$stamp'")
    $d = [uri]::EscapeDataString("Microsoft.Dynamics.CRM.DeletedMetadataFilters'Attribute'")
    return Invoke-DvRequest -Path "RetrieveMetadataChanges(Query=@q,ClientVersionStamp=@s,DeletedMetadataFilters=@d)?@q=$q&@s=$s&@d=$d"
}

# $previousJson: on delta runs, RetrieveMetadataChanges omits unchanged properties (e.g. labels), so
# properties missing from the delta keep their previous snapshot value.
function ConvertTo-ColumnJson($attr, [string]$table, [string]$previousJson) {
    $o = [ordered]@{}
    $prev = $null
    if ($previousJson) { try { $prev = $previousJson | ConvertFrom-Json } catch { } }
    foreach ($p in $attrProps) {
        $val = $attr.$p
        if ($null -eq $val) {
            if ($prev -and $null -ne $prev.$p) { $o[$p] = $prev.$p }
            continue
        }
        switch ($p) {
            'DisplayName' { $val = Get-Label $val }
            'Description' { $val = Get-Label $val }
            'RequiredLevel' { $val = $val.Value }
            'IsAuditEnabled' { $val = $val.Value }
            'IsValidForAdvancedFind' { $val = $val.Value }
            'FormatName' { $val = $val.Value }
            'AttributeTypeName' { $val = $val.Value }
            'OptionSet' {
                $val = [ordered]@{
                    Name     = $val.Name
                    IsGlobal = $val.IsGlobal
                    Options  = @($val.Options | ForEach-Object { [ordered]@{ Value = $_.Value; Label = (Get-Label $_.Label) } })
                }
            }
        }
        if ($null -ne $val) { $o[$p] = $val }
    }
    $o['Table'] = $table
    return ($o | ConvertTo-Json -Depth 8)
}

$fullColumns = $isBaseline -or -not $state.MetadataStamp
$meta = $null
if (-not $fullColumns) {
    try { $meta = Invoke-MetadataQuery $state.MetadataStamp }
    catch {
        if ($_.Exception.Message -match 'version stamp|ExpiredVersionStamp|0x80044352') {
            Write-Host "  Metadata version stamp expired - doing a full column re-baseline" -ForegroundColor Yellow
            $fullColumns = $true
        } else { throw }
    }
}
if ($fullColumns) { $meta = Invoke-MetadataQuery $null }

$changedColumnCount = 0
$seenColumnIds = @{}
foreach ($e in @($meta.EntityMetadata)) {
    foreach ($a in @($e.Attributes)) {
        if (-not $a.LogicalName) { continue }
        # Skip system-generated virtual name/yomi helper columns that change with their parent
        if ($a.AttributeOf) { continue }
        $rel = "columns/$(ConvertTo-SafeName $e.LogicalName)/$($a.LogicalName).json"
        $previous = $null
        $fullPath = Join-Path $SnapshotRoot $rel
        if (-not $fullColumns -and (Test-Path $fullPath)) { $previous = [IO.File]::ReadAllText($fullPath) }
        Write-SnapshotFile $rel ((ConvertTo-ColumnJson $a $e.LogicalName $previous) + "`n")
        $columnIndex[$a.MetadataId.ToString().ToLower()] = $rel
        $seenColumnIds[$a.MetadataId.ToString().ToLower()] = $true
        $componentInfo[$rel] = @{ Kind = 'column'; Table = $e.LogicalName; Id = $a.MetadataId; Name = $a.LogicalName; SubType = $a.AttributeType; ChangedOn = $a.ModifiedOn; ModifiedBy = $null }
        $changedColumnCount++
    }
}
if ($fullColumns) {
    # Full baseline: anything on disk we didn't see is gone
    $onDisk = Get-ChildItem (Join-Path $SnapshotRoot 'columns') -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $onDisk) {
        $rel = $f.FullName.Substring($SnapshotRoot.Length + 1).Replace('\', '/')
        if (-not $componentInfo.ContainsKey($rel)) { Remove-Item $f.FullName -Force }
    }
    $stale = @($columnIndex.Keys | Where-Object { -not $seenColumnIds.ContainsKey($_) })
    foreach ($k in $stale) { $columnIndex.Remove($k) }
} else {
    # Delta: deleted attributes come back as MetadataIds
    foreach ($entry in @($meta.DeletedMetadata)) {
        foreach ($id in @($entry.Value)) {
            $key = "$id".ToLower()
            if ($columnIndex.ContainsKey($key)) {
                $rel = $columnIndex[$key]
                $parts = $rel.Split('/')
                $componentInfo[$rel] = @{ Kind = 'column'; Table = $parts[1]; Id = $id; Name = [IO.Path]::GetFileNameWithoutExtension($rel); SubType = ''; ChangedOn = $null; ModifiedBy = $null }
                Remove-SnapshotFile $rel
                $columnIndex.Remove($key)
            }
        }
    }
}
Write-Info "  $($changedColumnCount) columns written ($(if ($fullColumns) { 'full' } else { 'delta' }))"
#endregion

#region Detect changes via git
Invoke-Git add -A | Out-Null
$statusLines = @(Invoke-Git diff --cached --name-status --no-renames)
$changes = @()
foreach ($line in $statusLines) {
    if (-not "$line".Trim()) { continue }
    $parts = "$line" -split "`t"
    $kind = switch ($parts[0]) { 'A' { 'added' } 'M' { 'modified' } 'D' { 'deleted' } default { $parts[0] } }
    $path = $parts[1]
    if ($path -like 'changes/*' -or $path -eq '.gitignore') { continue }
    $info = $componentInfo[$path]
    if (-not $info) {
        # Deleted form/view: recover name from the previous version's header
        $segs = $path.Split('/')
        $prev = ''
        try { $prev = (Invoke-Git show "HEAD:$path" | Select-Object -First 1) -join '' } catch { }
        $name = if ($prev -match '^<!-- \w+: (.*?) \|') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($path) }
        $info = @{ Kind = $segs[0].TrimEnd('s'); Table = $segs[1]; Id = [IO.Path]::GetFileNameWithoutExtension($path); Name = $name; SubType = ''; ChangedOn = $null; ModifiedBy = $null }
    }
    $changes += [pscustomobject]@{ Change = $kind; Kind = $info.Kind; Table = $info.Table; Name = $info.Name; SubType = $info.SubType; Id = "$($info.Id)"; Path = $path; ChangedOn = $info.ChangedOn; ModifiedBy = $info.ModifiedBy }
}
Write-Info "Detected $($changes.Count) changed components"
#endregion

#region Attribution
$publishLogs = @()
$imports = @()
if (-not $isBaseline -and $changes.Count) {
    $windowStart = $lastRun.AddMinutes(-$OverlapMinutes)
    $since = Get-ODataDate $windowStart
    $logSet = "${LogPrefix}_customizationpublishlogs"
    try {
        $publishLogs = Get-DvAll "$logSet`?`$select=createdon,${LogPrefix}_message,${LogPrefix}_username,${LogPrefix}_summary,${LogPrefix}_parameterxml&`$filter=createdon ge $since&`$orderby=createdon asc"
        Write-Info "  $($publishLogs.Count) publish log rows in window"
    } catch {
        $why = if ($_.Exception.Data['Status'] -eq 404) { "table ${LogPrefix}_customizationpublishlog not found" } else { $_.Exception.Message }
        Write-Host "  Publish log not used: $why - install it with Install-PublishLogger.ps1" -ForegroundColor Yellow
    }
    try {
        $imports = Get-DvAll "msdyn_solutionhistories?`$select=msdyn_name,msdyn_solutionversion,msdyn_operation,msdyn_starttime,msdyn_endtime&`$filter=msdyn_starttime ge $since"
        $imports = @($imports | Where-Object { (Get-DvFormatted $_ 'msdyn_operation') -in 'Import', 'Uninstall' })
    } catch { Write-Host "  Solution history not available: $($_.Exception.Message)" -ForegroundColor Yellow }
}

foreach ($c in $changes) {
    $attr = @()
    if ($isBaseline) { $attr += [pscustomobject]@{ Confidence = 'baseline'; Who = $null; Evidence = 'first snapshot' } }
    else {
        foreach ($log in $publishLogs) {
            $xml = "$($log."${LogPrefix}_parameterxml")"
            $msg = $log."${LogPrefix}_message"
            $user = $log."${LogPrefix}_username"
            if ($msg -eq 'PublishAll') {
                $attr += [pscustomobject]@{ Confidence = 'candidate'; Who = $user; Evidence = "PublishAll at $($log.createdon)" }
            } elseif ($c.Id -and $xml -match [regex]::Escape($c.Id.Trim('{}'))) {
                $attr += [pscustomobject]@{ Confidence = 'direct'; Who = $user; Evidence = "Publish at $($log.createdon) named component $($c.Id)" }
            } elseif ($xml -match "<entity>$([regex]::Escape($c.Table))</entity>") {
                $attr += [pscustomobject]@{ Confidence = 'corroborated'; Who = $user; Evidence = "Publish of table $($c.Table) at $($log.createdon)" }
            }
        }
        if ($c.ModifiedBy) { $attr += [pscustomobject]@{ Confidence = 'last-writer'; Who = $c.ModifiedBy; Evidence = "savedquery.modifiedby at $($c.ChangedOn)" } }
        if ($c.ChangedOn) {
            $t = [datetime]::Parse($c.ChangedOn).ToUniversalTime()
            foreach ($imp in $imports) {
                $s = [datetime]::Parse($imp.msdyn_starttime).ToUniversalTime().AddMinutes(-1)
                $e = if ($imp.msdyn_endtime) { [datetime]::Parse($imp.msdyn_endtime).ToUniversalTime().AddMinutes(2) } else { $runStarted }
                if ($t -ge $s -and $t -le $e) {
                    $attr += [pscustomobject]@{ Confidence = 'deployment'; Who = $null; Evidence = "$(Get-DvFormatted $imp 'msdyn_operation') of solution $($imp.msdyn_name) $($imp.msdyn_solutionversion) ($($imp.msdyn_starttime))" }
                }
            }
        }
        if (-not $attr) { $attr += [pscustomobject]@{ Confidence = 'unattributed'; Who = $null; Evidence = 'no matching publish log, modifiedby or import window' } }
    }
    # Keep the strongest signals first
    $rank = @{ direct = 0; corroborated = 1; 'last-writer' = 2; deployment = 3; candidate = 4; unattributed = 5; baseline = 6 }
    $c | Add-Member -NotePropertyName Attribution -NotePropertyValue @($attr | Sort-Object { $rank[$_.Confidence] })
}
#endregion

#region Write change log + commit
$stampName = $runStarted.ToString('yyyyMMdd-HHmmss')
if ($changes.Count) {
    $log = [ordered]@{
        Environment = $EnvironmentUrl
        RunUtc      = $runStarted.ToString('o')
        WindowStart = if ($lastRun) { $lastRun.ToString('o') } else { $null }
        Baseline    = $isBaseline
        Counts      = [ordered]@{
            forms   = @($changes | Where-Object Kind -eq 'form').Count
            views   = @($changes | Where-Object Kind -eq 'view').Count
            columns = @($changes | Where-Object Kind -eq 'column').Count
        }
        Changes     = if ($isBaseline) { @() } else { $changes }
    }
    Write-SnapshotFile "changes/$stampName.json" ($log | ConvertTo-Json -Depth 8)

    $md = @("# Metadata changes $($runStarted.ToString('yyyy-MM-dd HH:mm')) UTC", "", "Environment: $EnvironmentUrl  ")
    if ($isBaseline) {
        $md += "Baseline snapshot: $($log.Counts.forms) forms, $($log.Counts.views) views, $($log.Counts.columns) columns.", ""
    } else {
        $md += "Window: since $($lastRun.ToString('yyyy-MM-dd HH:mm')) UTC", "", "| Change | Kind | Table | Name | Who | Confidence | Evidence |", "|---|---|---|---|---|---|---|"
        foreach ($c in $changes) {
            $top = $c.Attribution[0]
            $md += "| $($c.Change) | $($c.Kind) | $($c.Table) | $($c.Name) | $($top.Who) | $($top.Confidence) | $($top.Evidence) |"
        }
        $md += "", "Full diff: ``git -C `"$SnapshotRoot`" show HEAD``"
    }
    Write-SnapshotFile "changes/$stampName.md" ($md -join "`n")

    Invoke-Git add -A | Out-Null
    $msgTitle = if ($isBaseline) { "Baseline snapshot $stampName" } else { "Snapshot $stampName - $($changes.Count) change(s)" }
    Invoke-Git commit -q -m $msgTitle | Out-Null
    Write-Host "Committed: $msgTitle" -ForegroundColor Green
    if (-not $isBaseline) { $changes | Select-Object Change, Kind, Table, Name, @{ n = 'Who'; e = { $_.Attribution[0].Who } }, @{ n = 'Confidence'; e = { $_.Attribution[0].Confidence } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
    Write-Host "Change log: $(Join-Path $SnapshotRoot "changes\$stampName.md")"
} else {
    Write-Host "No changes since last run." -ForegroundColor Green
}

$newState = [ordered]@{ LastRunUtc = $runStarted.ToString('o'); MetadataStamp = $meta.ServerVersionStamp; Tables = $Tables }
[IO.File]::WriteAllText($StatePath, ($newState | ConvertTo-Json), $utf8)
[IO.File]::WriteAllText($ColumnIndexPath, ($columnIndex | ConvertTo-Json -Compress), $utf8)
#endregion
