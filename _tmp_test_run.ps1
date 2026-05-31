$ErrorActionPreference = 'Stop'
$incoming = Join-Path $PSScriptRoot '_sample\deploy-package\packages\mybank_2251.1.0.0.nupkg'
$root = 'C:\Architect\2251_MU'
$baseline = 'C:\Deploy\Baselines\mybank_2251.baseline.json'
$report = 'C:\Deploy\Reports'

# Clean targets
if (Test-Path -LiteralPath $baseline) { Remove-Item -LiteralPath $baseline -Force }
if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Recurse -Force }

Write-Host "Running run-deploy.ps1 without CreateBaselineIfMissing"
& "$PSScriptRoot\_sample\deploy-package\run-deploy.ps1" -IncomingPackagePath $incoming -RootPath $root -BaselinePath $baseline -ReportPath $report -ApplicationName 'mybank' -EnvironmentName 'prod'
Write-Host "LASTEXIT=$LASTEXITCODE"
if (Test-Path -LiteralPath $baseline) { Write-Host 'BASELINE_CREATED' } else { Write-Host 'BASELINE_NOT_CREATED' }
