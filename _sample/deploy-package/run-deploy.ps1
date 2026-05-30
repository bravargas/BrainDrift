[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$IncomingPath,

    [Parameter(Mandatory=$true)]
    [string]$TargetPath,

    [Parameter(Mandatory=$true)]
    [string]$BaselinePath,

    [Parameter(Mandatory=$true)]
    [string]$ReportsPath,

    [Parameter(Mandatory=$false)]
    [switch]$PromoteBaselineOnSuccess,

    [Parameter(Mandatory=$false)]
    [switch]$FailOnDrift
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "run-deploy:: START"

$pw = 'powershell'
$staging = Join-Path $env:TEMP 'BrainDriftDeployStaging'
if (-not (Test-Path -LiteralPath $staging)) { New-Item -Path $staging -ItemType Directory -Force | Out-Null }
$resolvedIncoming = $IncomingPath
if (Test-Path -LiteralPath $IncomingPath) {
    $resolvedIncoming = (Resolve-Path -LiteralPath $IncomingPath).Path
}

# If incoming is a .nupkg file, extract it to staging and point IncomingPath to extracted content
$extractedTemp = $null
$copiedZip = $null
try {
    if ((Test-Path -LiteralPath $resolvedIncoming) -and -not (Test-Path -LiteralPath $resolvedIncoming -PathType Container)) {
        $ext = [System.IO.Path]::GetExtension($resolvedIncoming)
        if ($ext -ieq '.nupkg') {
            Write-Host "run-deploy:: Detected .nupkg incoming package. Preparing extraction."
            $extractedTemp = Join-Path $staging ([System.Guid]::NewGuid().ToString())
            New-Item -Path $extractedTemp -ItemType Directory -Force | Out-Null

            $copiedZip = [System.IO.Path]::ChangeExtension($resolvedIncoming, '.zip')
            Copy-Item -Path $resolvedIncoming -Destination $copiedZip -Force

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($copiedZip, $extractedTemp)

            $possibleContent = Join-Path $extractedTemp 'content'
            if (Test-Path -LiteralPath $possibleContent) {
                $IncomingPath = $possibleContent
            }
            else {
                $IncomingPath = $extractedTemp
            }

            Write-Host "run-deploy:: Extracted package to $IncomingPath"
        }
    }

    # Pre-deployment drift check: stop before deployment if the incoming package conflicts with the current target state.
    $precheckReports = Join-Path $staging 'precheck-reports'
    if (-not (Test-Path -LiteralPath $precheckReports)) {
        New-Item -Path $precheckReports -ItemType Directory -Force | Out-Null
    }

    $precheckArgs = @(
        '-ApplicationName', 'Sample',
        '-EnvironmentName', 'PROD',
        '-RootPath', $TargetPath,
        '-BaselinePath', $BaselinePath,
        '-IncomingPackagePath', $IncomingPath,
        '-ReportPath', $precheckReports
    )

    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\Test-DeploymentDrift.ps1') @precheckArgs
    $precheckExit = $LASTEXITCODE

    if ($precheckExit -eq 3) {
        Write-Host 'run-deploy:: Pre-deployment baseline missing; continuing with initial deployment.'
    }
    else {
        $precheckReport = Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $precheckReport) {
            $precheckObject = Get-Content -LiteralPath $precheckReport.FullName -Raw | ConvertFrom-Json
            if ($precheckObject.classification.hasConflict) {
                Write-Host "run-deploy:: Pre-deployment conflict detected. Report: $($precheckReport.FullName)"
                exit 1
            }
            if ($FailOnDrift.IsPresent -and $precheckObject.classification.hasDrift) {
                Write-Host "run-deploy:: Pre-deployment drift detected and FailOnDrift is enabled. Report: $($precheckReport.FullName)"
                exit 1
            }
        }
    }

    # 1) pre-deployment manifest export
    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'predeploy.ps1') -IncomingPath $IncomingPath -StagingPath $staging
    if ($LASTEXITCODE -ne 0) { Write-Host 'run-deploy:: pre-deployment step failed'; exit 2 }

    # 2) deploy: apply files
    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'deploy.ps1') -IncomingPath $IncomingPath -TargetPath $TargetPath -Apply
    if ($LASTEXITCODE -ne 0) { Write-Host 'run-deploy:: deploy failed'; exit 2 }

    # 3) run BrainDrift check (non-destructive)
    $driftArgs = @(
        '-ApplicationName', 'Sample',
        '-EnvironmentName', 'PROD',
        '-RootPath', $TargetPath,
        '-BaselinePath', $BaselinePath,
        '-IncomingPackagePath', $IncomingPath,
        '-ReportPath', $ReportsPath
    )
    if ($FailOnDrift.IsPresent) {
        $driftArgs += '-FailOnDrift'
    }
    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\Test-DeploymentDrift.ps1') @driftArgs
    $driftExit = $LASTEXITCODE

    if ($driftExit -eq 3) {
        Write-Host 'run-deploy:: Baseline missing (initial deployment).'
        if ($PromoteBaselineOnSuccess.IsPresent) {
            Write-Host 'run-deploy:: Promoting current target to baseline (creating baseline)'
            & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\New-DeploymentBaseline.ps1') `
                -ApplicationName 'Sample' -DeploymentId 'AUTO' -EnvironmentName 'PROD' -ServerName 'AUTO' -RootPath $TargetPath -BaselinePath $BaselinePath
            if ($LASTEXITCODE -ne 0) { Write-Host 'run-deploy:: baseline promotion failed'; exit 2 }
        }
    }
    elseif ($driftExit -eq 1) {
        Write-Host 'run-deploy:: Drift detected.'
        if ($FailOnDrift.IsPresent) { exit 1 }
    }
    elseif ($driftExit -eq 0) {
        Write-Host 'run-deploy:: No drift detected.'
        if ($PromoteBaselineOnSuccess.IsPresent) {
            Write-Host 'run-deploy:: Promoting current target to baseline as requested.'
            & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\New-DeploymentBaseline.ps1') `
                -ApplicationName 'Sample' -DeploymentId 'AUTO' -EnvironmentName 'PROD' -ServerName 'AUTO' -RootPath $TargetPath -BaselinePath $BaselinePath
            if ($LASTEXITCODE -ne 0) { Write-Host 'run-deploy:: baseline promotion failed'; exit 2 }
        }
    }

    Write-Host 'run-deploy:: DONE'
    exit 0
}
finally {
    # cleanup temporary extraction artifacts
    if ($null -ne $copiedZip -and (Test-Path -LiteralPath $copiedZip)) {
        Remove-Item -LiteralPath $copiedZip -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $extractedTemp -and (Test-Path -LiteralPath $extractedTemp)) {
        Remove-Item -LiteralPath $extractedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
