<#
.SYNOPSIS
    Creates the strong-name key (MetadataAudit.snk) the plug-in project needs. Dataverse only accepts
    signed plug-in assemblies. The key is not committed to the repository - generate your own.
#>
param([string]$Path = (Join-Path $PSScriptRoot '..\plugin\MetadataAudit.Plugins\MetadataAudit.snk'))

if (Test-Path $Path) { Write-Host "Key already exists: $Path"; return }
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
[IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Path), $rsa.ExportCspBlob($true))
Write-Host "Created $Path"
