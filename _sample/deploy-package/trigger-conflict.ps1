[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$TemplatePath,

    [Parameter(Mandatory=$false)]
    [string]$RootPath,

    [Parameter(Mandatory=$false)]
    [string]$BaselinePath,

    [Parameter(Mandatory=$false)]
    [string]$ReportPath,

    [Parameter(Mandatory=$false)]
    [string]$SourcePath,

    [Parameter(Mandatory=$false)]
    [string]$ServerValue = 'SERVER_B',

    [Parameter(Mandatory=$false)]
    [string]$PackageValue = 'PACKAGE_C',

    [Parameter(Mandatory=$false)]
    [switch]$KeepWorkingCopies
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host 'trigger-conflict:: START'

if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
    $TemplatePath = Join-Path $PSScriptRoot 'package-content'
}
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Join-Path $env:TEMP 'BrainDriftDeployTarget'
}
if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    $BaselinePath = Join-Path $env:TEMP 'bd-baseline.json'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $env:TEMP 'BrainDriftReports'
}
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $env:TEMP 'BrainDriftIncomingConflict'
}

$resolvedTemplatePath = (Resolve-Path -LiteralPath $TemplatePath).Path
if (-not (Test-Path -LiteralPath $resolvedTemplatePath -PathType Container)) {
    throw "Template path not found: $resolvedTemplatePath"
}

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    New-Item -Path $RootPath -ItemType Directory -Force | Out-Null
}

$targetFiles = Get-ChildItem -Path $RootPath -File -ErrorAction SilentlyContinue
if ($null -eq $targetFiles -or $targetFiles.Count -eq 0) {
    Get-ChildItem -LiteralPath $resolvedTemplatePath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $RootPath -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
    Write-Host 'trigger-conflict:: Baseline missing; creating an initial baseline from the template content.'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\New-DeploymentBaseline.ps1') `
        -ApplicationName 'Sample' -DeploymentId 'AUTO' -EnvironmentName 'PROD' -ServerName 'AUTO' -RootPath $RootPath -BaselinePath $BaselinePath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create baseline. Exit code: $LASTEXITCODE"
    }
}

if (Test-Path -LiteralPath $SourcePath) {
    Remove-Item -LiteralPath $SourcePath -Recurse -Force
}
New-Item -Path $SourcePath -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath $resolvedTemplatePath -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $SourcePath -Recurse -Force
}

$targetWebConfig = Join-Path $RootPath 'web.config'
$incomingWebConfig = Join-Path $SourcePath 'web.config'

if (-not (Test-Path -LiteralPath $targetWebConfig -PathType Leaf)) {
    throw "Target web.config not found: $targetWebConfig"
}
if (-not (Test-Path -LiteralPath $incomingWebConfig -PathType Leaf)) {
    throw "Incoming web.config not found: $incomingWebConfig"
}

$runDeployPath = Join-Path $PSScriptRoot 'run-deploy.ps1'
Set-Content -LiteralPath $targetWebConfig -Value $ServerValue -Encoding UTF8
Set-Content -LiteralPath $incomingWebConfig -Value $PackageValue -Encoding UTF8

& powershell -NoProfile -ExecutionPolicy Bypass -File $runDeployPath `
    -IncomingPackagePath $SourcePath -RootPath $RootPath -BaselinePath $BaselinePath -ReportPath $ReportPath
$runDeployExit = $LASTEXITCODE

$precheckReports = Join-Path (Join-Path $env:TEMP 'BrainDriftDeployStaging') 'precheck-reports'
$precheckReport = $null
if (Test-Path -LiteralPath $precheckReports) {
    $precheckReport = Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

if ($null -eq $precheckReport) {
    throw "trigger-conflict:: run-deploy exit code was $runDeployExit, but no pre-deployment report was found in $precheckReports"
}

$precheckObject = Get-Content -LiteralPath $precheckReport.FullName -Raw | ConvertFrom-Json
if (-not $precheckObject.classification.hasConflict) {
    throw "trigger-conflict:: Expected a conflict, but the precheck report did not flag one: $($precheckReport.FullName)"
}

Write-Host "trigger-conflict:: Conflict confirmed. Report: $($precheckReport.FullName)"

if (-not $KeepWorkingCopies.IsPresent) {
    Remove-Item -LiteralPath $IncomingPackagePath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ([pscustomobject]@{
    Status = 'ConflictTriggered'
    ExitCode = $runDeployExit
    RootPath = $RootPath
    IncomingPackagePath = $SourcePath
    BaselinePath = $BaselinePath
    ReportPath = $precheckReport.FullName
})

Write-Host 'trigger-conflict:: END'
exit 0