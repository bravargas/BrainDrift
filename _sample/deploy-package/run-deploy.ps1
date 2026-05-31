[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$IncomingPackagePath,

    [Parameter(Mandatory=$true)]
    [string]$RootPath,

    [Parameter(Mandatory=$true)]
    [string]$BaselinePath,

    [Parameter(Mandatory=$true)]
    [string]$ReportPath,

    [Parameter(Mandatory=$false)]
    [string]$ApplicationName = 'Sample',

    [Parameter(Mandatory=$false)]
    [string]$EnvironmentName = 'PROD',

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
    [switch]$SkipBaselineCreation,

    [Parameter(Mandatory=$false)]
    [switch]$ContinueWithoutBaseline,

    [Parameter(Mandatory=$false)]
    [string[]]$IncludePatterns,

    [Parameter(Mandatory=$false)]
    [string[]]$ExcludePatterns,

    [Parameter(Mandatory=$false)]
    [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
    [string]$HashAlgorithm = 'SHA256'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# CreateBaselineIfMissing defaults to false when the caller does not explicitly bind the parameter.
# This ensures baseline files are NOT auto-created unless the caller explicitly requests it.
if (-not $PSBoundParameters.ContainsKey('CreateBaselineIfMissing')) { $CreateBaselineIfMissing = $false }

# support an alternate, more explicit flag name that maps to SkipBaselineCreation
if ($ContinueWithoutBaseline.IsPresent) { $SkipBaselineCreation = $true }

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
if (-not $FailOnDrift.IsPresent) {
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

function Print-Summary {
    Write-Log 'SUMMARY: Run summary follows' 'Gray'
    foreach ($k in $script:Summary.Keys) {
        Write-Log ("SUMMARY: {0}: {1}" -f $k, $script:Summary[$k]) 'Gray'
    }
}

$pw = 'powershell'
$staging = Join-Path $env:TEMP 'BrainDriftDeployStaging'
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

    $baselineExists = Test-Path -LiteralPath $BaselinePath -PathType Leaf
    if (-not $baselineExists) {
        # If baseline is missing, fail-safe: abort unless caller explicitly allows bootstrap
        if ($FailOnDrift.IsPresent) {
            $script:Summary.BaselineBootstrapBlocked = $true
            Write-Log 'run-deploy:: Baseline file is missing and FailOnDrift is present - aborting before bootstrap baseline creation.' 'Red'
            Print-Summary
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
                '-BaselinePath', $BaselinePath
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
        elseif ($SkipBaselineCreation.IsPresent) {
            Write-Warning 'run-deploy:: Baseline file is missing but caller allowed skipping baseline creation - proceeding with predeploy/deploy.'
            Write-Stage 'run-deploy:: BOOTSTRAP: No baseline found - proceeding to predeploy and deploy (skip requested).'
        }
        else {
            $script:Summary.BaselineBootstrapBlocked = $true
            Write-Log 'run-deploy:: Baseline file is missing and auto-bootstrap was not allowed. Aborting to avoid unsafe deployment.' 'Red'
            Print-Summary
            exit 3
        }
    }
    else {
        Write-Warning 'run-deploy:: Baseline exists. Running pre-deployment drift gate; any drift or conflict will stop predeploy/deploy.'

        $precheckReports = Join-Path $staging 'precheck-reports'
        if (-not (Test-Path -LiteralPath $precheckReports)) {
            New-Item -Path $precheckReports -ItemType Directory -Force | Out-Null
        }

        $precheckArgs = @(
            '-ApplicationName', $ApplicationName,
            '-EnvironmentName', $EnvironmentName,
            '-RootPath', $RootPath,
            '-BaselinePath', $BaselinePath,
            '-ReportPath', $precheckReports
        )

        # Forward run-deploy switches to Test-DeploymentDrift.ps1 where appropriate
        if ($FailOnDrift.IsPresent) { $precheckArgs += '-FailOnDrift' }

        if ($CreateBaselineIfMissing.IsPresent) {
            $precheckArgs += '-CreateBaselineIfMissing'
        }
        elseif ($SkipBaselineCreation.IsPresent) {
            $precheckArgs += '-SkipBaselineCreation'
        }
        else {
            # Default behavior: if caller didn't specify, forward what we auto-defaulted earlier
            if ($CreateBaselineIfMissing) { $precheckArgs += '-CreateBaselineIfMissing' } else { $precheckArgs += '-SkipBaselineCreation' }
        }

        if ($null -ne $IncludePatterns -and $IncludePatterns.Count -gt 0) {
            $precheckArgs += '-IncludePatterns'
            $precheckArgs += $IncludePatterns
        }
        if ($null -ne $ExcludePatterns -and $ExcludePatterns.Count -gt 0) {
            $precheckArgs += '-ExcludePatterns'
            $precheckArgs += $ExcludePatterns
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
            Print-Summary
            exit 1
        }
        else {
            $precheckReport = Get-ChildItem -Path $precheckReports -Filter 'drift-report-*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -eq $precheckReport) {
                Write-Log 'run-deploy:: Pre-deployment drift gate completed but no report was written.' 'Red'
                Print-Summary
                exit 2
            }

            $precheckObject = Get-Content -LiteralPath $precheckReport.FullName -Raw | ConvertFrom-Json
            if ($precheckObject.classification.hasConflict -or $precheckObject.classification.hasDrift) {
                $script:Summary.PrecheckReport = $precheckReport.FullName
                if ($precheckObject.classification.hasConflict) {
                    Write-Log "run-deploy:: PRECHECK: CONFLICT detected. Report: $($precheckReport.FullName) -- ABORTING." 'Red'
                    Print-Summary
                    exit 1
                }
                elseif ($precheckObject.classification.hasDrift) {
                    if ($FailOnDrift.IsPresent) {
                        Write-Log "run-deploy:: PRECHECK: DRIFT detected and FailOnDrift is present. Report: $($precheckReport.FullName) -- ABORTING." 'Red'
                        Print-Summary
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

    # 1) pre-deployment manifest export
    Write-Stage 'run-deploy:: STEP: Pre-deployment manifest export (predeploy.ps1)' 'Blue'
    Write-Log "run-deploy:: Invoking predeploy.ps1 -SourcePath $IncomingPackagePath -StagingPath $staging" 'Yellow'
    $script:Summary.PredeployInvoked = $true
    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'predeploy.ps1') -SourcePath $IncomingPackagePath -StagingPath $staging
    $predeployExit = $LASTEXITCODE
    $script:Summary.PredeployExit = $predeployExit
    Write-Log "run-deploy:: predeploy.ps1 exit code: $predeployExit" 'Yellow'
    if ($predeployExit -ne 0) { Write-Log 'run-deploy:: pre-deployment step failed' 'Red'; Print-Summary; exit 2 }

    # 2) deploy: apply files
    Write-Stage 'run-deploy:: STEP: Deploy - applying files (deploy.ps1)' 'Blue'
    Write-Log "run-deploy:: Invoking deploy.ps1 -SourcePath $IncomingPackagePath -RootPath $RootPath -Apply" 'Yellow'
    $script:Summary.DeployInvoked = $true
    & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'deploy.ps1') -SourcePath $IncomingPackagePath -RootPath $RootPath -Apply
    $deployExit = $LASTEXITCODE
    $script:Summary.DeployExit = $deployExit
    Write-Log "run-deploy:: deploy.ps1 exit code: $deployExit" 'Yellow'
    if ($deployExit -ne 0) { Write-Log 'run-deploy:: deploy failed' 'Red'; Print-Summary; exit 2 }

    # 3) refresh the baseline after a successful deployment only if explicitly requested
    if ($PromoteBaselineOnSuccess.IsPresent) {
        Write-Stage 'run-deploy:: STEP: Deployment succeeded - creating or refreshing baseline (New-DeploymentBaseline.ps1)' 'Green'
        Write-Warning 'run-deploy:: -PromoteBaselineOnSuccess requested: refreshing baseline now.'
        Write-Log "run-deploy:: Invoking New-DeploymentBaseline.ps1 -RootPath $RootPath -BaselinePath $BaselinePath" 'Yellow'
        & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\New-DeploymentBaseline.ps1') `
            -ApplicationName $ApplicationName -DeploymentId $DeploymentId -EnvironmentName $EnvironmentName -ServerName $ServerName -RootPath $RootPath -BaselinePath $BaselinePath
        $baselineExit = $LASTEXITCODE
        $script:Summary.BaselineExit = $baselineExit
        if ($baselineExit -eq 0) {
            $script:Summary.BaselineCreated = $true
            $script:Summary.BaselinePath = $BaselinePath
        }
        Write-Log "run-deploy:: New-DeploymentBaseline.ps1 exit code: $baselineExit" 'Yellow'
        if ($baselineExit -ne 0) { Write-Log 'run-deploy:: baseline creation failed' 'Red'; Print-Summary; exit 2 }
    }
    else {
        Write-Log 'run-deploy:: Baseline refresh skipped (PromoteBaselineOnSuccess not present).' 'Gray'
    }

    if ($FailOnDrift.IsPresent) {
        Write-Log 'run-deploy:: FailOnDrift was supplied but is not needed for the new baseline-first flow.' 'Gray'
    }

    Print-Summary
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
