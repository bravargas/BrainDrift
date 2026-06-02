[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$IncomingPackagePath = $null,

    [Parameter(Mandatory=$false)]
    [string]$RootPath = $null,

    [Parameter(Mandatory=$false)]
    [string]$BaselinePath = $null,

    [Parameter(Mandatory=$false)]
    [string]$ReportPath = $null,

    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = $null,

    [Parameter(Mandatory=$false)]
    [string]$ApplicationName = $null,

    [Parameter(Mandatory=$false)]
    [string]$EnvironmentName = $null,

    [Parameter(Mandatory=$false)]
    [string]$DeploymentId = ('AUTO-{0}' -f ([System.DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))),

    [Parameter(Mandatory=$false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [switch]$PromoteBaselineOnSuccess,

    [Parameter(Mandatory=$false)]
    [switch]$FailOnDrift,

    [Parameter(Mandatory=$false)]
    [switch]$CreateBaselineIfMissing,

    [Parameter(Mandatory=$false)]
    [string[]]$IncludePatterns,

    [Parameter(Mandatory=$false)]
    [string[]]$ExcludePatterns,

    [Parameter(Mandatory=$false)]
    [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
    [string]$HashAlgorithm = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Removed deprecated flags related to skipping baseline creation.

function Resolve-SampleDeployPackageDefaults {
    param(
        [Parameter(Mandatory = $false)]
        [string]$IncomingPackagePath,

        [Parameter(Mandatory = $false)]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [string]$BaselinePath,

        [Parameter(Mandatory = $false)]
        [string]$ReportPath,

        [Parameter(Mandatory = $false)]
        [string]$ApplicationName,

        [Parameter(Mandatory = $false)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [string[]]$IncludePatterns,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludePatterns,

        [Parameter(Mandatory = $false)]
        [string]$HashAlgorithm
    )

    $sampleRoot = Split-Path -Path $PSScriptRoot -Parent
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot '..\..\config\deployment-drift.config.json'
    }

    $moduleManifest = Join-Path $PSScriptRoot '..\..\src\DeploymentDrift.Common.psd1'
    $modulePsm1 = Join-Path $PSScriptRoot '..\..\src\DeploymentDrift.Common.psm1'
    if (Test-Path -LiteralPath $moduleManifest -PathType Leaf) {
        Import-Module -Name $moduleManifest -Scope Local -Force -ErrorAction Stop
    }
    elseif (Test-Path -LiteralPath $modulePsm1 -PathType Leaf) {
        Import-Module -Name $modulePsm1 -Scope Local -Force -ErrorAction Stop
    }
    else {
        throw "DeploymentDrift module not found under src."
    }

    $configurationArgs = @{
        ConfigPath = $ConfigPath
        ApplicationName = $ApplicationName
        EnvironmentName = $EnvironmentName
        RootPath = $RootPath
        BaselinePath = $BaselinePath
        ReportPath = $ReportPath
        IncludePatterns = $IncludePatterns
        ExcludePatterns = $ExcludePatterns
    }
    if (-not [string]::IsNullOrWhiteSpace($HashAlgorithm)) {
        $configurationArgs.HashAlgorithm = $HashAlgorithm
    }

    $configuration = Resolve-DeploymentDriftConfiguration @configurationArgs

    $resolved = [pscustomobject]@{
        IncomingPackagePath = $IncomingPackagePath
        RootPath = $configuration.RootPath
        BaselinePath = $configuration.BaselinePath
        ReportPath = $configuration.ReportPath
        ConfigPath = $configuration.ConfigPath
        ApplicationName = $configuration.ApplicationName
        EnvironmentName = $configuration.EnvironmentName
        IncludePatterns = @($configuration.IncludePatterns)
        ExcludePatterns = @($configuration.ExcludePatterns)
        HashAlgorithm = $configuration.HashAlgorithm
    }

    if ([string]::IsNullOrWhiteSpace($resolved.IncomingPackagePath)) { $resolved.IncomingPackagePath = Join-Path $PSScriptRoot 'packages\mybank_2251.1.0.0.nupkg' }
    if ([string]::IsNullOrWhiteSpace($resolved.RootPath)) { $resolved.RootPath = Join-Path $sampleRoot 'server' }
    if ([string]::IsNullOrWhiteSpace($resolved.BaselinePath)) { $resolved.BaselinePath = Join-Path $sampleRoot 'baseline\last-successful-deployment.json' }
    if ([string]::IsNullOrWhiteSpace($resolved.ReportPath)) { $resolved.ReportPath = Join-Path $sampleRoot 'reports' }
    if ([string]::IsNullOrWhiteSpace($resolved.ApplicationName)) { $resolved.ApplicationName = 'Sample' }
    if ([string]::IsNullOrWhiteSpace($resolved.EnvironmentName)) { $resolved.EnvironmentName = 'TEST' }
    if ([string]::IsNullOrWhiteSpace($resolved.HashAlgorithm)) { $resolved.HashAlgorithm = 'SHA256' }

    return $resolved
}

function Get-BaselineFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationName,

        [Parameter(Mandatory = $false)]
        [string]$EnvironmentName
    )

    $appSafePart = $ApplicationName -replace '[^A-Za-z0-9._-]', '_'
    $envSafePart = if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) { $EnvironmentName -replace '[^A-Za-z0-9._-]', '_' } else { '' }
    if ([string]::IsNullOrWhiteSpace($envSafePart)) {
        return "{0}.baseline.json" -f $appSafePart
    }

    return "{0}.{1}.baseline.json" -f $appSafePart, $envSafePart
}

function Resolve-BaselineFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaselinePath,

        [Parameter(Mandatory = $true)]
        [string]$ApplicationName,

        [Parameter(Mandatory = $false)]
        [string]$EnvironmentName
    )

    if ([System.IO.Path]::GetExtension($BaselinePath) -ieq '.json') {
        return $BaselinePath
    }

    return Join-Path $BaselinePath (Get-BaselineFileName -ApplicationName $ApplicationName -EnvironmentName $EnvironmentName)
}

$defaults = Resolve-SampleDeployPackageDefaults `
    -IncomingPackagePath $IncomingPackagePath `
    -RootPath $RootPath `
    -BaselinePath $BaselinePath `
    -ReportPath $ReportPath `
    -ApplicationName $ApplicationName `
    -EnvironmentName $EnvironmentName `
    -ConfigPath $ConfigPath `
    -IncludePatterns $IncludePatterns `
    -ExcludePatterns $ExcludePatterns `
    -HashAlgorithm $HashAlgorithm

$IncomingPackagePath = $defaults.IncomingPackagePath
$RootPath = $defaults.RootPath
$BaselinePath = $defaults.BaselinePath
$ReportPath = $defaults.ReportPath
$ConfigPath = $defaults.ConfigPath
$ApplicationName = $defaults.ApplicationName
$EnvironmentName = $defaults.EnvironmentName
$IncludePatterns = @($defaults.IncludePatterns)
$ExcludePatterns = @($defaults.ExcludePatterns)
$HashAlgorithm = $defaults.HashAlgorithm

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Black','DarkBlue','DarkGreen','DarkCyan','DarkRed','DarkMagenta','DarkYellow','Gray','DarkGray','Blue','Green','Cyan','Red','Magenta','Yellow','White')]
        [string]$Color = 'Gray'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "$ts $Message" -ForegroundColor $Color
}

function Write-Stage {
    param(
        [string]$Message,
        [string]$Color = 'Cyan'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "`n$ts STAGE: $Message`n" -ForegroundColor $Color
}

Write-Stage "run-deploy:: START - Application: $ApplicationName | Environment: $EnvironmentName | DeploymentId: $DeploymentId | Server: $ServerName" 'Green'

# If FailOnDrift is false, clearly note that drift will not abort the deployment
if (-not $FailOnDrift) {
    Write-Log 'run-deploy:: NOTE: FailOnDrift is NOT present - drift will NOT abort the deployment. Proceeding with caution.' 'Yellow'
}
else {
    Write-Log 'run-deploy:: NOTE: FailOnDrift IS present - any detected drift will ABORT the deployment.' 'Red'
}

# Summary tracking for final report
$script:Summary = [ordered]@{
    ExtractionPerformed = $false
    ExtractedPath = ''
    PrecheckPerformed = $false
    PrecheckExit = ''
    PrecheckResult = ''
    PrecheckReport = ''
    PredeployExit = ''
    PredeployInvoked = $false
    DeployExit = ''
    DeployInvoked = $false
    BaselineExit = ''
    BaselineCreated = $false
    BaselinePath = ''
    BaselineBootstrapAttempted = $false
    BaselineBootstrapBlocked = $false
}

function Write-Summary {
    Write-Log 'SUMMARY: Run summary follows' 'Gray'
    foreach ($k in $script:Summary.Keys) {
        Write-Log ("SUMMARY: {0}: {1}" -f $k, $script:Summary[$k]) 'Gray'
    }
}

$pw = 'powershell'
$stagingRoot = Join-Path $env:TEMP 'BrainDriftDeployStaging'
if (-not (Test-Path -LiteralPath $stagingRoot)) { New-Item -Path $stagingRoot -ItemType Directory -Force | Out-Null }
$staging = Join-Path $stagingRoot ([System.Guid]::NewGuid().ToString())
if (-not (Test-Path -LiteralPath $staging)) { New-Item -Path $staging -ItemType Directory -Force | Out-Null }
$resolvedIncoming = $IncomingPackagePath
if (Test-Path -LiteralPath $IncomingPackagePath) {
    $resolvedIncoming = (Resolve-Path -LiteralPath $IncomingPackagePath).Path
}

# If incoming is a .nupkg file, extract it to staging and point IncomingPackagePath to extracted content
$extractedTemp = $null
$copiedZip = $null
try {
    if ((Test-Path -LiteralPath $resolvedIncoming) -and -not (Test-Path -LiteralPath $resolvedIncoming -PathType Container)) {
        $ext = [System.IO.Path]::GetExtension($resolvedIncoming)
        if ($ext -ieq '.nupkg') {
            Write-Stage "run-deploy:: Detected .nupkg incoming package. Preparing extraction."
            $extractedTemp = Join-Path $staging ([System.Guid]::NewGuid().ToString())
            New-Item -Path $extractedTemp -ItemType Directory -Force | Out-Null

            $copiedZip = [System.IO.Path]::ChangeExtension($resolvedIncoming, '.zip')
            Copy-Item -Path $resolvedIncoming -Destination $copiedZip -Force

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($copiedZip, $extractedTemp)

            $possibleContent = Join-Path $extractedTemp 'content'
            if (Test-Path -LiteralPath $possibleContent) {
                $IncomingPackagePath = $possibleContent
            }
            else {
                $IncomingPackagePath = $extractedTemp
            }

            Write-Stage "run-deploy:: Extracted package to $IncomingPackagePath"
            $script:Summary.ExtractionPerformed = $true
            $script:Summary.ExtractedPath = $IncomingPackagePath
        }
    }

    $baselineFilePath = Resolve-BaselineFilePath -BaselinePath $BaselinePath -ApplicationName $ApplicationName -EnvironmentName $EnvironmentName
    $baselineExists = Test-Path -LiteralPath $baselineFilePath -PathType Leaf
    if (-not $baselineExists) {
        # If baseline is missing, fail-safe: abort unless caller explicitly allows bootstrap
        if ($FailOnDrift) {
            $script:Summary.BaselineBootstrapBlocked = $true
            Write-Log 'run-deploy:: Baseline file is missing and FailOnDrift is present - aborting before bootstrap baseline creation.' 'Red'
            Write-Summary
            exit 3
        }

        if ($CreateBaselineIfMissing) {
            $script:Summary.BaselineBootstrapAttempted = $true
            Write-Stage 'run-deploy:: BOOTSTRAP: Baseline missing - creating new baseline as requested.' 'Green'
            Write-Log "run-deploy:: Invoking New-DeploymentBaseline.ps1 -RootPath $RootPath -BaselinePath $BaselinePath" 'Yellow'
            $baselineArgs = @(
                '-ApplicationName', $ApplicationName,
                '-DeploymentId', $DeploymentId,
                '-EnvironmentName', $EnvironmentName,
                '-ServerName', $ServerName,
                '-RootPath', $RootPath,
                '-BaselinePath', $BaselinePath,
                '-ConfigPath', $ConfigPath
            )
            & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\New-DeploymentBaseline.ps1') @baselineArgs
            $be = $LASTEXITCODE
            $script:Summary.BaselineExit = $be
            if ($be -eq 0) {
                $script:Summary.BaselineCreated = $true
                $script:Summary.BaselinePath = $BaselinePath
                Write-Log "run-deploy:: Baseline created: $BaselinePath" 'Green'
            }
            else {
                Write-Log "run-deploy:: Baseline creation failed (exit $be). Proceeding without baseline." 'Red'
            }
        }
        else {
            $script:Summary.BaselineBootstrapBlocked = $true
            Write-Log 'run-deploy:: Baseline file is missing and auto-bootstrap was not allowed. Aborting to avoid unsafe deployment.' 'Red'
            Write-Summary
            exit 3
        }
    }
    else {
        Write-Warning 'run-deploy:: Baseline exists. Running pre-deployment drift gate; any drift or conflict will stop predeploy/deploy.'

        $precheckReports = Join-Path $staging 'precheck-reports'
        if (-not (Test-Path -LiteralPath $precheckReports)) {
            New-Item -Path $precheckReports -ItemType Directory -Force | Out-Null
        }
        else {
            Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $precheckReports 'incoming-manifest.json') -Force -ErrorAction SilentlyContinue
        }

        Write-Log 'run-deploy:: Precheck compares baseline against current server only.' 'Yellow'

        $precheckArgs = @(
            '-ApplicationName', $ApplicationName,
            '-EnvironmentName', $EnvironmentName,
            '-RootPath', $RootPath,
            '-BaselinePath', $BaselinePath,
            '-ReportPath', $precheckReports,
            '-ConfigPath', $ConfigPath
        )

        # Forward run-deploy switches to Test-DeploymentDrift.ps1 where appropriate
        if ($FailOnDrift) { $precheckArgs += '-FailOnDrift' }

        if ($CreateBaselineIfMissing) {
            $precheckArgs += '-CreateBaselineIfMissing'
        }

        if ($HashAlgorithm) { $precheckArgs += '-HashAlgorithm'; $precheckArgs += $HashAlgorithm }
        # No combined flags; individual flags only

        Write-Log "run-deploy:: Running Test-DeploymentDrift.ps1 with args: $($precheckArgs -join ' ')" 'Yellow'

        & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts/Test-DeploymentDrift.ps1') @precheckArgs
        $precheckExit = $LASTEXITCODE
        $script:Summary.PrecheckPerformed = $true
        $script:Summary.PrecheckExit = $precheckExit
        # capture latest precheck report and summarize its result
        $latestPrecheck = Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latestPrecheck) {
            $script:Summary.PrecheckReport = $latestPrecheck.FullName
            try {
                $pObj = Get-Content -LiteralPath $latestPrecheck.FullName -Raw | ConvertFrom-Json
                if ($pObj.classification.hasConflict) { $script:Summary.PrecheckResult = 'Conflict' }
                elseif ($pObj.classification.hasDrift) { $script:Summary.PrecheckResult = 'Drift' }
                else { $script:Summary.PrecheckResult = 'NoDrift' }
            }
            catch {
                $script:Summary.PrecheckResult = 'ReportReadError'
            }
            $precheckReport = $latestPrecheck
        }
        else {
            $script:Summary.PrecheckReport = ''
            $script:Summary.PrecheckResult = 'NoReport'
        }
        Write-Log "run-deploy:: Precheck exit code: $precheckExit" 'Yellow'

        if ($precheckExit -eq 3) {
            Write-Warning 'run-deploy:: Baseline disappeared before the drift gate ran. Continuing as deployment zero.'
        }
        elseif ($precheckExit -ne 0) {
            $precheckReport = Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -ne $precheckReport) {
                $script:Summary.PrecheckReport = $precheckReport.FullName
                Write-Log "run-deploy:: Pre-deployment drift gate failed. Report: $($precheckReport.FullName)" 'Red'
            }
            else {
                Write-Log 'run-deploy:: Pre-deployment drift gate failed before a report could be written.' 'Red'
            }
            Write-Summary
            exit 1
        }
        else {
            $precheckReport = Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -eq $precheckReport) {
                Write-Log 'run-deploy:: Pre-deployment drift gate completed but no report was written.' 'Red'
                Write-Summary
                exit 2
            }

            $precheckObject = Get-Content -LiteralPath $precheckReport.FullName -Raw | ConvertFrom-Json
            if ($precheckObject.classification.hasConflict -or $precheckObject.classification.hasDrift) {
                $script:Summary.PrecheckReport = $precheckReport.FullName
                if ($precheckObject.classification.hasConflict) {
                    Write-Log "run-deploy:: PRECHECK: CONFLICT detected. Report: $($precheckReport.FullName) -- ABORTING." 'Red'
                    Write-Summary
                    exit 1
                }
                elseif ($precheckObject.classification.hasDrift) {
                    if ($FailOnDrift) {
                        Write-Log "run-deploy:: PRECHECK: DRIFT detected and FailOnDrift is present. Report: $($precheckReport.FullName) -- ABORTING." 'Red'
                        Write-Summary
                        exit 1
                    }
                    else {
                        Write-Log "run-deploy:: PRECHECK: DRIFT detected but FailOnDrift is NOT present. Report: $($precheckReport.FullName) -- CONTINUING WITH DEPLOY." 'Yellow'
                        # continue to predeploy/deploy flow; summary will note PrecheckReport and result
                    }
                }
            }
        }
    }

    # 1) deploy: apply files
    Write-Stage 'run-deploy:: STEP: Deploy - applying files (deploy.ps1)' 'Blue'
    Write-Log "run-deploy:: Invoking deploy.ps1 -SourcePath $IncomingPackagePath -RootPath $RootPath -Apply" 'Yellow'
    $script:Summary.DeployInvoked = $true
    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'deploy.ps1') -SourcePath $IncomingPackagePath -RootPath $RootPath -Apply
    $deployExit = $LASTEXITCODE
    $script:Summary.DeployExit = $deployExit
    Write-Log "run-deploy:: deploy.ps1 exit code: $deployExit" 'Yellow'
    if ($deployExit -ne 0) { Write-Log 'run-deploy:: deploy failed' 'Red'; Write-Summary; exit 2 }

    # 3) refresh the baseline after a successful deployment only if explicitly requested
    if ($PromoteBaselineOnSuccess) {
        Write-Stage 'run-deploy:: STEP: Deployment succeeded - creating or refreshing baseline (New-DeploymentBaseline.ps1)' 'Green'
        Write-Warning 'run-deploy:: -PromoteBaselineOnSuccess requested: refreshing baseline now.'
        Write-Log "run-deploy:: Invoking New-DeploymentBaseline.ps1 -RootPath $RootPath -BaselinePath $BaselinePath" 'Yellow'
        & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\New-DeploymentBaseline.ps1') `
            -ApplicationName $ApplicationName -DeploymentId $DeploymentId -EnvironmentName $EnvironmentName -ServerName $ServerName -RootPath $RootPath -BaselinePath $BaselinePath -ConfigPath $ConfigPath
        $baselineExit = $LASTEXITCODE
        $script:Summary.BaselineExit = $baselineExit
        if ($baselineExit -eq 0) {
            $script:Summary.BaselineCreated = $true
            $script:Summary.BaselinePath = $BaselinePath
        }
        Write-Log "run-deploy:: New-DeploymentBaseline.ps1 exit code: $baselineExit" 'Yellow'
        if ($baselineExit -ne 0) { Write-Log 'run-deploy:: baseline creation failed' 'Red'; Write-Summary; exit 2 }
    }
    else {
        Write-Log 'run-deploy:: Baseline refresh skipped (PromoteBaselineOnSuccess not present).' 'Gray'
    }

    if ($FailOnDrift) {
        Write-Log 'run-deploy:: FailOnDrift was supplied but is not needed for the new baseline-first flow.' 'Gray'
    }

    Write-Summary
    Write-Stage 'run-deploy:: DONE - deployment flow complete' 'Green'
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
