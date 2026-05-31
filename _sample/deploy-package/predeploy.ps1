[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,

    [Parameter(Mandatory=$true)]
    [string]$StagingPath,

    [Parameter(Mandatory=$false)]
    [string[]]$IncludePatterns = @('*'),

    [Parameter(Mandatory=$false)]
    [ValidateSet('SHA1','SHA256','SHA384','SHA512','MD5')]
    [string]$HashAlgorithm = 'SHA256'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "predeploy:: START"

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    Write-Host "predeploy:: ERROR: Source path not found: $SourcePath"
    exit 2
}

# prepare staging
if (-not (Test-Path -LiteralPath $StagingPath)) {
    New-Item -Path $StagingPath -ItemType Directory -Force | Out-Null
}

$manifestPath = Join-Path $StagingPath 'incoming-manifest.json'

Write-Host "predeploy:: Exporting incoming manifest to $manifestPath"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\Export-DeploymentFileManifest.ps1') `
    -SourcePath $SourcePath -ManifestPath $manifestPath -IncludePatterns $IncludePatterns -HashAlgorithm $HashAlgorithm | Out-Null

Write-Host "predeploy:: DONE"
Write-Output @{ ManifestPath = $manifestPath }
exit 0
