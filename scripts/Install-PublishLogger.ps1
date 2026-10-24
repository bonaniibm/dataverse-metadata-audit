<#
.SYNOPSIS
    Installs (or removes) the Publish/PublishAll logging plug-in and its log table in a Dataverse environment.

.DESCRIPTION
    THIS SCRIPT CHANGES THE ENVIRONMENT. Everything it creates goes into an unmanaged solution
    (default "MetadataAuditPrototype") under its own publisher, so it is easy to find and remove.

    Install (idempotent - safe to re-run; re-running uploads the latest plug-in build):
      1. Publisher + unmanaged solution
      2. Table {prefix}_customizationpublishlog with text columns for message, user, ParameterXml, summary
      3. Plug-in assembly (sandbox) + plug-in type
      4. Synchronous PostOperation steps on "Publish" and "PublishAll"

    -Uninstall removes the steps, plug-in type, assembly, log table (and its rows) and the solution.

.EXAMPLE
    .\Install-PublishLogger.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/
.EXAMPLE
    .\Install-PublishLogger.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/ -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$AccessToken,
    [string]$Prefix = 'mda',
    [string]$PublisherUniqueName = 'metadataaudit',
    [int]$OptionValuePrefix = 10500,
    [string]$SolutionUniqueName = 'MetadataAuditPrototype',
    [string]$AssemblyPath = (Join-Path $PSScriptRoot '..\plugin\MetadataAudit.Plugins\bin\Release\net462\MetadataAudit.Plugins.dll'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DataverseApi.psm1') -Force

$TableLogical = "${Prefix}_customizationpublishlog"
$TableSchema = "${Prefix}_CustomizationPublishLog"
$AssemblyName = 'MetadataAudit.Plugins'
$TypeName = 'MetadataAudit.Plugins.PublishLoggerPlugin'
$Messages = @('Publish', 'PublishAll')
$SolutionHeader = @{ 'MSCRM.SolutionUniqueName' = $SolutionUniqueName }

# Columns of the log table (primary name column is created with the table)
$Columns = @(
    @{ Schema = "${Prefix}_Message"; Label = 'Message'; Type = 'String'; Max = 100 }
    @{ Schema = "${Prefix}_UserId"; Label = 'User Id'; Type = 'String'; Max = 100 }
    @{ Schema = "${Prefix}_UserName"; Label = 'User Name'; Type = 'String'; Max = 200 }
    @{ Schema = "${Prefix}_InitiatingUserId"; Label = 'Initiating User Id'; Type = 'String'; Max = 100 }
    @{ Schema = "${Prefix}_InitiatingUserName"; Label = 'Initiating User Name'; Type = 'String'; Max = 200 }
    @{ Schema = "${Prefix}_CorrelationId"; Label = 'Correlation Id'; Type = 'String'; Max = 100 }
    @{ Schema = "${Prefix}_Summary"; Label = 'Summary'; Type = 'Memo'; Max = 4000 }
    @{ Schema = "${Prefix}_ParameterXml"; Label = 'Parameter XML'; Type = 'Memo'; Max = 1048576 }
)

function Write-Step([string]$text) { Write-Host "-> $text" -ForegroundColor Cyan }

$who = Connect-Dataverse -EnvironmentUrl $EnvironmentUrl -AccessToken $AccessToken
Write-Host "Connected to $EnvironmentUrl as user $($who.UserId)" -ForegroundColor DarkGray

if ($Uninstall) {
    $type = (Invoke-DvRequest -Path "plugintypes?`$select=plugintypeid&`$filter=typename eq '$TypeName'").value | Select-Object -First 1
    if ($type) {
        $steps = (Invoke-DvRequest -Path "sdkmessageprocessingsteps?`$select=sdkmessageprocessingstepid,name&`$filter=_eventhandler_value eq $($type.plugintypeid)").value
        foreach ($s in $steps) { Write-Step "Deleting step $($s.name)"; Invoke-DvRequest -Method Delete -Path "sdkmessageprocessingsteps($($s.sdkmessageprocessingstepid))" | Out-Null }
        Write-Step "Deleting plug-in type $TypeName"
        Invoke-DvRequest -Method Delete -Path "plugintypes($($type.plugintypeid))" | Out-Null
    }
    $asm = (Invoke-DvRequest -Path "pluginassemblies?`$select=pluginassemblyid&`$filter=name eq '$AssemblyName'").value | Select-Object -First 1
    if ($asm) { Write-Step "Deleting assembly $AssemblyName"; Invoke-DvRequest -Method Delete -Path "pluginassemblies($($asm.pluginassemblyid))" | Out-Null }
    if (Get-DvOrNull "EntityDefinitions(LogicalName='$TableLogical')?`$select=LogicalName") {
        Write-Step "Deleting table $TableLogical (and all logged rows)"
        Invoke-DvRequest -Method Delete -Path "EntityDefinitions(LogicalName='$TableLogical')" | Out-Null
    }
    $sol = (Invoke-DvRequest -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$SolutionUniqueName'").value | Select-Object -First 1
    if ($sol) { Write-Step "Deleting solution $SolutionUniqueName"; Invoke-DvRequest -Method Delete -Path "solutions($($sol.solutionid))" | Out-Null }
    Write-Host "Uninstalled. Publisher '$PublisherUniqueName' was left in place." -ForegroundColor Green
    return
}

if (-not (Test-Path $AssemblyPath)) { throw "Plug-in assembly not found at $AssemblyPath. Build it first: dotnet build plugin\MetadataAudit.Plugins -c Release" }

# 1. Publisher + solution
$pub = (Invoke-DvRequest -Path "publishers?`$select=publisherid,customizationprefix&`$filter=uniquename eq '$PublisherUniqueName'").value | Select-Object -First 1
if (-not $pub) {
    Write-Step "Creating publisher $PublisherUniqueName (prefix $Prefix)"
    Invoke-DvRequest -Method Post -Path 'publishers' -Body @{
        uniquename = $PublisherUniqueName; friendlyname = 'Metadata Audit'; customizationprefix = $Prefix
        customizationoptionvalueprefix = $OptionValuePrefix
    } | Out-Null
    $pub = (Invoke-DvRequest -Path "publishers?`$select=publisherid,customizationprefix&`$filter=uniquename eq '$PublisherUniqueName'").value | Select-Object -First 1
} elseif ($pub.customizationprefix -ne $Prefix) {
    throw "Publisher $PublisherUniqueName exists with prefix '$($pub.customizationprefix)', not '$Prefix'. Pass -Prefix $($pub.customizationprefix)."
}

$sol = (Invoke-DvRequest -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$SolutionUniqueName'").value | Select-Object -First 1
if (-not $sol) {
    Write-Step "Creating solution $SolutionUniqueName"
    Invoke-DvRequest -Method Post -Path 'solutions' -Body @{
        uniquename = $SolutionUniqueName; friendlyname = 'Metadata Audit Prototype'; version = '1.0.0.0'
        'publisherid@odata.bind' = "/publishers($($pub.publisherid))"
    } | Out-Null
}

# 2. Log table + columns
$tableCreated = $false
if (-not (Get-DvOrNull "EntityDefinitions(LogicalName='$TableLogical')?`$select=LogicalName")) {
    Write-Step "Creating table $TableLogical"
    Invoke-DvRequest -Method Post -Path 'EntityDefinitions' -ExtraHeaders $SolutionHeader -Body @{
        '@odata.type'          = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName             = $TableSchema
        DisplayName            = New-DvLabel 'Customization Publish Log'
        DisplayCollectionName  = New-DvLabel 'Customization Publish Logs'
        Description            = New-DvLabel 'One row per Publish / PublishAll call, written by the MetadataAudit plug-in.'
        OwnershipType          = 'OrganizationOwned'
        IsActivity             = $false
        HasNotes               = $false
        HasActivities          = $false
        Attributes             = @(@{
                '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
                SchemaName    = "${Prefix}_Name"
                IsPrimaryName = $true
                MaxLength     = 200
                FormatName    = @{ Value = 'Text' }
                RequiredLevel = @{ Value = 'None'; CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' }
                DisplayName   = New-DvLabel 'Name'
            })
    } | Out-Null
    $tableCreated = $true
}

$existing = (Invoke-DvRequest -Path "EntityDefinitions(LogicalName='$TableLogical')/Attributes?`$select=LogicalName").value | ForEach-Object { $_.LogicalName }
foreach ($c in $Columns) {
    if ($existing -contains $c.Schema.ToLower()) { continue }
    Write-Step "Adding column $($c.Schema)"
    $body = @{
        SchemaName    = $c.Schema
        DisplayName   = New-DvLabel $c.Label
        RequiredLevel = @{ Value = 'None'; CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' }
        MaxLength     = $c.Max
    }
    if ($c.Type -eq 'String') {
        $body['@odata.type'] = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
        $body.FormatName = @{ Value = 'Text' }
    } else {
        $body['@odata.type'] = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'
        $body.Format = 'TextArea'
    }
    Invoke-DvRequest -Method Post -Path "EntityDefinitions(LogicalName='$TableLogical')/Attributes" -ExtraHeaders $SolutionHeader -Body $body | Out-Null
    $tableCreated = $true
}

if ($tableCreated) {
    Write-Step "Publishing $TableLogical"
    Invoke-DvRequest -Method Post -Path 'PublishXml' -Body @{ ParameterXml = "<importexportxml><entities><entity>$TableLogical</entity></entities></importexportxml>" } | Out-Null
}

# 3. Plug-in assembly + type
$content = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $AssemblyPath)))
$asm = (Invoke-DvRequest -Path "pluginassemblies?`$select=pluginassemblyid&`$filter=name eq '$AssemblyName'").value | Select-Object -First 1
if ($asm) {
    Write-Step "Updating assembly $AssemblyName"
    Invoke-DvRequest -Method Patch -Path "pluginassemblies($($asm.pluginassemblyid))" -Body @{ content = $content } | Out-Null
} else {
    Write-Step "Registering assembly $AssemblyName (sandbox)"
    Invoke-DvRequest -Method Post -Path 'pluginassemblies' -ExtraHeaders $SolutionHeader -Body @{
        name = $AssemblyName; content = $content; isolationmode = 2; sourcetype = 0
    } | Out-Null
    $asm = (Invoke-DvRequest -Path "pluginassemblies?`$select=pluginassemblyid&`$filter=name eq '$AssemblyName'").value | Select-Object -First 1
}

$type = (Invoke-DvRequest -Path "plugintypes?`$select=plugintypeid&`$filter=typename eq '$TypeName'").value | Select-Object -First 1
if (-not $type) {
    Write-Step "Registering plug-in type $TypeName"
    Invoke-DvRequest -Method Post -Path 'plugintypes' -Body @{
        typename = $TypeName; name = $TypeName; friendlyname = 'Publish Logger'
        'pluginassemblyid@odata.bind' = "/pluginassemblies($($asm.pluginassemblyid))"
    } | Out-Null
    $type = (Invoke-DvRequest -Path "plugintypes?`$select=plugintypeid&`$filter=typename eq '$TypeName'").value | Select-Object -First 1
}

# 4. Steps on Publish and PublishAll
foreach ($m in $Messages) {
    $stepName = "MetadataAudit: log $m"
    $existingStep = (Invoke-DvRequest -Path "sdkmessageprocessingsteps?`$select=sdkmessageprocessingstepid&`$filter=name eq '$stepName'").value | Select-Object -First 1
    if ($existingStep) { Write-Host "   step '$stepName' already registered" -ForegroundColor DarkGray; continue }

    $msg = (Invoke-DvRequest -Path "sdkmessages?`$select=sdkmessageid&`$filter=name eq '$m'").value | Select-Object -First 1
    $filter = (Invoke-DvRequest -Path "sdkmessagefilters?`$select=sdkmessagefilterid,iscustomprocessingstepallowed&`$filter=_sdkmessageid_value eq $($msg.sdkmessageid) and primaryobjecttypecode eq 'none'").value | Select-Object -First 1
    if (-not $filter -or -not $filter.iscustomprocessingstepallowed) { throw "Message $m does not allow custom steps in this environment." }

    Write-Step "Registering step '$stepName' (PostOperation, synchronous)"
    Invoke-DvRequest -Method Post -Path 'sdkmessageprocessingsteps' -ExtraHeaders $SolutionHeader -Body @{
        name                           = $stepName
        description                    = "Logs who called $m and its ParameterXml to $TableLogical"
        stage                          = 40
        mode                           = 0
        rank                           = 1
        supporteddeployment            = 0
        configuration                  = $Prefix
        'sdkmessageid@odata.bind'      = "/sdkmessages($($msg.sdkmessageid))"
        'sdkmessagefilterid@odata.bind' = "/sdkmessagefilters($($filter.sdkmessagefilterid))"
        'eventhandler_plugintype@odata.bind' = "/plugintypes($($type.plugintypeid))"
    } | Out-Null
}

Write-Host "`nInstalled. Publish something in the maker portal, then check: $($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/${TableLogical}s" -ForegroundColor Green
