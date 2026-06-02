[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ApplicationName = $null,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName = $null,

    [Parameter(Mandatory = $false)]
    [string]$RootPath = $null,

    [Parameter(Mandatory = $false)]
    [string]$BaselinePath = $null,
    
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = $null,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = $null,

    [Parameter(Mandatory = $false)]
    [switch]$FailOnDrift,

    [Parameter(Mandatory = $false)]
    [switch]$CreateBaselineIfMissing,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeUnchangedFiles,

    [Parameter(Mandatory = $false)]
    [string[]]$IncludePatterns,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludePatterns,

    [Parameter(Mandatory = $false)]
    [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
    [string]$HashAlgorithm = 'SHA256'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shell executable used for invoking helper scripts when needed
$pw = 'powershell'

Write-Host "$($MyInvocation.MyCommand.Name):: START"

function Write-DriftSummaryTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [psobject]$Result,

        [Parameter(Mandatory = $false)]
        [string]$ReportPath,

        [Parameter(Mandatory = $false)]
        [string]$RecommendedAction
    )

    $color = switch -Regex ($Status) {
        'NoDrift|BaselineCreated|Succeeded' { 'Green' }
        'DriftDetectedContinue' { 'Yellow' }
        default { 'Red' }
    }

    $summary = if ($null -ne $Result -and $Result.PSObject.Properties.Name -contains 'summary') { $Result.summary } else { $null }
    $machine = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { [System.Environment]::MachineName } else { $env:COMPUTERNAME }
    $action = if (-not [string]::IsNullOrWhiteSpace($RecommendedAction)) { $RecommendedAction } elseif ($null -ne $Result -and $Result.PSObject.Properties.Name -contains 'recommendedAction') { [string]$Result.recommendedAction } else { '' }

    $rows = @(
        [pscustomobject]@{ Item = 'Status'; Value = $Status },
        [pscustomobject]@{ Item = 'ExitCode'; Value = [string]$ExitCode },
        [pscustomobject]@{ Item = 'Application'; Value = $ApplicationName },
        [pscustomobject]@{ Item = 'Environment'; Value = $EnvironmentName },
        [pscustomobject]@{ Item = 'Machine'; Value = $machine },
        [pscustomobject]@{ Item = 'HasDrift'; Value = if ($null -ne $Result -and $Result.PSObject.Properties.Name -contains 'hasDrift') { [string]$Result.hasDrift } else { '' } },
        [pscustomobject]@{ Item = 'HasConflict'; Value = if ($null -ne $Result -and $Result.PSObject.Properties.Name -contains 'hasConflict') { [string]$Result.hasConflict } else { '' } },
        [pscustomobject]@{ Item = 'Modified'; Value = if ($null -ne $summary) { [string]$summary.modifiedCount } else { '' } },
        [pscustomobject]@{ Item = 'Missing'; Value = if ($null -ne $summary) { [string]$summary.missingCount } else { '' } },
        [pscustomobject]@{ Item = 'NewUnexpected'; Value = if ($null -ne $summary) { [string]$summary.newUnexpectedCount } else { '' } },
        [pscustomobject]@{ Item = 'Conflicts'; Value = if ($null -ne $summary) { [string]$summary.conflictCount } else { '' } },
        [pscustomobject]@{ Item = 'Baseline'; Value = if ($null -ne $Result -and $Result.PSObject.Properties.Name -contains 'baselinePath') { [string]$Result.baselinePath } else { $BaselinePath } },
        [pscustomobject]@{ Item = 'Report'; Value = $ReportPath },
        [pscustomobject]@{ Item = 'Action'; Value = $action }
    )

    $itemWidth = [Math]::Max(14, (($rows | ForEach-Object { $_.Item.Length }) | Measure-Object -Maximum).Maximum)
    $valueWidth = [Math]::Max(42, (($rows | ForEach-Object { if ($null -eq $_.Value) { 0 } else { ([string]$_.Value).Length } }) | Measure-Object -Maximum).Maximum)
    $valueWidth = [Math]::Min($valueWidth, 120)
    $line = '+-' + ('-' * $itemWidth) + '-+-' + ('-' * $valueWidth) + '-+'
    $rowFormat = '| {0,-' + $itemWidth + '} | {1,-' + $valueWidth + '} |'

    Write-Host ''
    Write-Host $line -ForegroundColor $color
    Write-Host (" DEPLOYMENT DRIFT SUMMARY :: $Status ") -ForegroundColor $color
    Write-Host $line -ForegroundColor $color
    Write-Host ($rowFormat -f 'Item', 'Value') -ForegroundColor $color
    Write-Host $line -ForegroundColor $color
    foreach ($row in $rows) {
        $value = if ($null -eq $row.Value) { '' } else { [string]$row.Value }
        if ($value.Length -gt $valueWidth) {
            $value = $value.Substring(0, [Math]::Max(0, $valueWidth - 3)) + '...'
        }
        Write-Host ($rowFormat -f $row.Item, $value) -ForegroundColor $color
    }
    Write-Host $line -ForegroundColor $color
    Write-Host ''
}

try {
    $moduleManifest = Join-Path $PSScriptRoot '..\src\DeploymentDrift.Common.psd1'
    $modulePsm1 = Join-Path $PSScriptRoot '..\src\DeploymentDrift.Common.psm1'
    if (Test-Path -LiteralPath $moduleManifest) {
        Import-Module -Name $moduleManifest -Scope Local -Force -ErrorAction Stop
    }
    elseif (Test-Path -LiteralPath $modulePsm1) {
        Import-Module -Name $modulePsm1 -Scope Local -Force -ErrorAction Stop
    }
    else {
        throw [System.IO.FileNotFoundException]::new("Module manifest or psm1 not found under src: '$moduleManifest' / '$modulePsm1'")
    }

    $resolvedConfig = Resolve-DeploymentDriftConfiguration `
        -ConfigPath $ConfigPath `
        -ApplicationName $ApplicationName `
        -EnvironmentName $EnvironmentName `
        -RootPath $RootPath `
        -BaselinePath $BaselinePath `
        -ReportPath $ReportPath `
        -IncludePatterns $IncludePatterns `
        -ExcludePatterns $ExcludePatterns `
        -HashAlgorithm $HashAlgorithm

    $ConfigPath = $resolvedConfig.ConfigPath
    $ApplicationName = $resolvedConfig.ApplicationName
    $EnvironmentName = $resolvedConfig.EnvironmentName
    $RootPath = $resolvedConfig.RootPath
    $BaselinePath = $resolvedConfig.BaselinePath
    $ReportPath = $resolvedConfig.ReportPath
    $IncludePatterns = $resolvedConfig.IncludePatterns
    $ExcludePatterns = $resolvedConfig.ExcludePatterns
    $HashAlgorithm = $resolvedConfig.HashAlgorithm

    Write-Host "$($MyInvocation.MyCommand.Name):: Parameters resolved:"
    Write-Host "$($MyInvocation.MyCommand.Name):: ApplicationName     : $ApplicationName"
    Write-Host "$($MyInvocation.MyCommand.Name):: EnvironmentName     : $EnvironmentName"
    Write-Host "$($MyInvocation.MyCommand.Name):: RootPath            : $RootPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: BaselinePath        : $BaselinePath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ReportPath          : $ReportPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ConfigPath          : $ConfigPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: FailOnDrift         : $FailOnDrift"
    Write-Host "$($MyInvocation.MyCommand.Name):: CreateBaselineIfMissing : $CreateBaselineIfMissing"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludeUnchangedFiles   : $IncludeUnchangedFiles"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns     : $($IncludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns     : $($ExcludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm       : $HashAlgorithm"
    # Resolve baseline file path: if user passed a directory, compose a filename using ApplicationName
    if ([System.IO.Path]::GetExtension($BaselinePath) -ieq '.json') {
        $baselineFilePath = $BaselinePath
    }
    else {
        $baselineDir = $BaselinePath
        if (-not [System.IO.Path]::IsPathRooted($baselineDir)) { $baselineDir = Join-Path (Get-Location).Path $baselineDir }
        if (-not (Test-Path -LiteralPath $baselineDir)) { New-Item -Path $baselineDir -ItemType Directory -Force | Out-Null }
        $appSafePart = if ($null -ne $ApplicationName) { ($ApplicationName -replace '[^A-Za-z0-9._-]','_') } else { 'app' }
        $envSafePart = if ($null -ne $EnvironmentName) { ($EnvironmentName -replace '[^A-Za-z0-9._-]','_') } else { '' }
        $baselineFileName = if ([string]::IsNullOrWhiteSpace($envSafePart)) { "{0}.baseline.json" -f $appSafePart } else { "{0}.{1}.baseline.json" -f $appSafePart, $envSafePart }
        $baselineFilePath = Join-Path $baselineDir $baselineFileName
    }

    if (-not (Test-Path -LiteralPath $baselineFilePath -PathType Leaf)) {
        if ($CreateBaselineIfMissing.IsPresent) {
            Write-Host "$($MyInvocation.MyCommand.Name):: Baseline missing and CreateBaselineIfMissing requested. Attempting to create baseline..." -ForegroundColor Yellow
            $deploymentId = ('AUTO-{0}' -f ([System.DateTime]::UtcNow.ToString('yyyyMMddHHmmss')))
            $baselineArgs = @(
                '-ApplicationName', $ApplicationName,
                '-DeploymentId', $deploymentId,
                '-EnvironmentName', $EnvironmentName,
                '-ServerName', $env:COMPUTERNAME,
                '-RootPath', $RootPath,
                '-BaselinePath', $BaselinePath,
                '-ConfigPath', $ConfigPath
            )
            $createResult = & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-DeploymentBaseline.ps1') @baselineArgs
            $be = $LASTEXITCODE
            if ($be -ne 0) {
                Write-Host "$($MyInvocation.MyCommand.Name):: Failed to create baseline (exit $be). Returning code 3." -ForegroundColor Red
                Write-DriftSummaryTable -Status 'FailedBaselineBootstrap' -ExitCode 3 -ReportPath $null -RecommendedAction 'Baseline creation failed. Review New-DeploymentBaseline.ps1 output before running drift detection again.'
                exit 3
            }

            # If the called script returned an object with baselinePath, prefer that as the baseline file path
            try {
                $returned = @($createResult) | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'baselinePath' } | Select-Object -First 1
                if ($null -ne $returned -and -not [string]::IsNullOrWhiteSpace($returned.baselinePath)) {
                    $baselineFilePath = $returned.baselinePath
                }
            }
            catch {
                # ignore and continue using previously computed path
            }

            Write-Host "$($MyInvocation.MyCommand.Name):: Baseline created successfully, continuing." -ForegroundColor Green
        }
        else {
            $createdAtUtc = [System.DateTime]::UtcNow.ToString('o')
            $createdBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            if ([string]::IsNullOrWhiteSpace($createdBy)) { $createdBy = $env:USERNAME }

            $result = [pscustomobject]@{
                reportPath        = $null
                applicationName   = $ApplicationName
                environmentName   = $EnvironmentName
                rootPath          = $RootPath
                baselinePath      = $baselineFilePath
                hashAlgorithm     = $HashAlgorithm
                hasDrift          = $false
                hasConflict       = $false
                baselineMissing   = $true
                summary           = [pscustomobject]@{
                    baselineFileCount   = 0
                    currentFileCount    = 0
                    incomingFileCount   = 0
                    modifiedCount       = 0
                    missingCount        = 0
                    newUnexpectedCount  = 0
                    incomingChangeCount = 0
                    conflictCount       = 0
                    unchangedCount      = 0
                }
                files             = @()
                recommendedAction = 'Baseline file is missing. Create an initial baseline from a trusted, validated server state before enabling drift detection.'
                metadata          = [pscustomobject]@{
                    applicationName = $ApplicationName
                    environmentName = $EnvironmentName
                    rootPath        = $RootPath
                    baselinePath    = $BaselinePath
                    generatedAtUtc  = $createdAtUtc
                    generatedBy     = $createdBy
                    hashAlgorithm   = $HashAlgorithm
                }
            }

            Write-Host "$($MyInvocation.MyCommand.Name):: Baseline file is missing. Return code 3 indicates initialization is required."
            Write-DriftSummaryTable -Status 'MissingBaseline' -ExitCode 3 -Result $result -ReportPath $null
            Write-Output $result
            exit 3
        }
    }

    # Ensure required inputs exist after attempting to resolve from config
    if ([string]::IsNullOrWhiteSpace($ApplicationName) -or [string]::IsNullOrWhiteSpace($RootPath) -or [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: Missing required parameters. Ensure ApplicationName, RootPath and ReportPath are provided or available in $ConfigPath" -ForegroundColor Red
        exit 2
    }

    $baselineDocument = Read-JsonFile -Path $baselineFilePath
    $baselineInventory = $baselineDocument.files
    $currentInventory = Get-FileInventory -RootPath $RootPath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns -HashAlgorithm $HashAlgorithm

    # If an incoming manifest was previously exported to the report folder, prefer that as the incoming inventory.
    $incomingInventory = $null
    try {
        $manifestCandidate = Join-Path -Path $ReportPath -ChildPath 'incoming-manifest.json'
        if (Test-Path -LiteralPath $manifestCandidate -PathType Leaf) {
            try {
                $manifestDoc = Read-JsonFile -Path $manifestCandidate
                if ($null -ne $manifestDoc -and $manifestDoc.files) {
                    $incomingInventory = $manifestDoc.files
                }
            }
            catch {
                # ignore manifest read errors and continue without incoming inventory
                $incomingInventory = $null
            }
        }
    }
    catch {
        $incomingInventory = $null
    }

    if ($null -ne $incomingInventory) {
        $comparison = Compare-FileInventories -BaselineInventory $baselineInventory -CurrentInventory $currentInventory -IncomingInventory $incomingInventory
    }
    else {
        $comparison = Compare-FileInventories -BaselineInventory $baselineInventory -CurrentInventory $currentInventory
    }

    $createdAtUtc = [System.DateTime]::UtcNow.ToString('o')
    $createdBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($createdBy)) {
        $createdBy = $env:USERNAME
    }

    $reportMetadata = [pscustomobject]@{
        applicationName = $ApplicationName
        environmentName = $EnvironmentName
        rootPath        = $RootPath
        baselinePath    = $BaselinePath
        generatedAtUtc  = $createdAtUtc
        generatedBy     = $createdBy
        hashAlgorithm   = $HashAlgorithm
    }

    $report = New-DriftReport -Metadata $reportMetadata -ComparisonResult $comparison -IncludeUnchangedFiles:$IncludeUnchangedFiles.IsPresent

    $reportTargetPath = $ReportPath
    $reportExtension = [System.IO.Path]::GetExtension($ReportPath)

    # Create safe filename parts from ApplicationName and EnvironmentName
    $appSafe = if ($null -ne $ApplicationName) { ($ApplicationName -replace '[^A-Za-z0-9_-]','_') } else { 'app' }
    $envSafe = if ($null -ne $EnvironmentName) { ($EnvironmentName -replace '[^A-Za-z0-9_-]','_') } else { 'env' }
    $timestamp = [System.DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')

    # When ReportPath is a directory (no .json extension passed), include app/env in filename
    if ($reportExtension -ne '.json') {
        if (-not (Test-Path -LiteralPath $ReportPath -PathType Container)) {
            New-Item -Path $ReportPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $reportTargetPath = Join-Path $ReportPath ("drift-report-{0}-{1}-{2}.json" -f $appSafe, $envSafe, $timestamp)
    }
    else {
        $reportDirectory = Split-Path -Path $ReportPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($reportDirectory) -and -not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
            New-Item -Path $reportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
    }

    Write-JsonFile -InputObject $report -Path $reportTargetPath -Depth 50 | Out-Null

    $result = [pscustomobject]@{
        reportPath        = $reportTargetPath
        applicationName   = $ApplicationName
        environmentName   = $EnvironmentName
        rootPath          = $RootPath
        baselinePath      = $baselineFilePath
        hashAlgorithm     = $HashAlgorithm
        hasDrift          = $comparison.hasDrift
        hasConflict       = $comparison.hasConflict
        summary           = $comparison.summary
        files             = $report.files
        recommendedAction = $report.recommendedAction
    }

    Write-Host "$($MyInvocation.MyCommand.Name):: Result : Drift check completed"
    Write-Output $result

    # If drift or conflict detected, print a clear, prominent message including machine name and report path

    if ($comparison.hasDrift -or $comparison.hasConflict) {
        $machine = $env:COMPUTERNAME
        $recAction = $null
        try { $recAction = $report.recommendedAction } catch { $recAction = '' }

        # Strong, visible messages (use red for visibility)
        if ($comparison.hasConflict) {
            Write-Host "$($MyInvocation.MyCommand.Name):: DRIFT/CONFLICT DETECTED ON MACHINE: $machine" -ForegroundColor Red
            Write-Host "$($MyInvocation.MyCommand.Name):: REPORT PATH: $reportTargetPath" -ForegroundColor Red
            if (-not [string]::IsNullOrWhiteSpace($recAction)) {
                Write-Host "$($MyInvocation.MyCommand.Name):: ACTION: $recAction" -ForegroundColor Red
            }
            else {
                Write-Host "$($MyInvocation.MyCommand.Name):: ACTION: Conflict detected - manual intervention required. See report for details." -ForegroundColor Red
            }
        }
        else {
            Write-Host "$($MyInvocation.MyCommand.Name):: DRIFT DETECTED ON MACHINE: $machine" -ForegroundColor Red
            Write-Host "$($MyInvocation.MyCommand.Name):: REPORT PATH: $reportTargetPath" -ForegroundColor Red
            if (-not [string]::IsNullOrWhiteSpace($recAction)) {
                Write-Host "$($MyInvocation.MyCommand.Name):: ACTION: $recAction" -ForegroundColor Red
            }
            else {
                Write-Host "$($MyInvocation.MyCommand.Name):: ACTION: Drift detected - review recommended changes in the report." -ForegroundColor Red
            }
        }

        # Compact one-line summary for easy grepping/parsing (no decorative chars)
        $oneLine = "DRIFT_SUMMARY: hasDrift=$($comparison.hasDrift), hasConflict=$($comparison.hasConflict), machine=$machine, report=$reportTargetPath, action=$recAction"
        Write-Host $oneLine -ForegroundColor Red
    }

    # Decide exit codes: conflicts should be treated as failures; drift fails only when FailOnDrift is present.
    $finalStatus = 'NoDrift'
    $exitCode = 0
    if ($comparison.hasConflict) {
        $finalStatus = 'ConflictDetected'
        $exitCode = 1
        Write-DriftSummaryTable -Status $finalStatus -ExitCode $exitCode -Result $result -ReportPath $reportTargetPath
        Write-Host "$($MyInvocation.MyCommand.Name):: Conflict detected. Returning exit code 1." -ForegroundColor Red
        exit $exitCode
    }

    if ($comparison.hasDrift) {
        if ($FailOnDrift.IsPresent) {
            $finalStatus = 'DriftDetectedFail'
            $exitCode = 1
            Write-DriftSummaryTable -Status $finalStatus -ExitCode $exitCode -Result $result -ReportPath $reportTargetPath
            Write-Host "$($MyInvocation.MyCommand.Name):: Drift detected and FailOnDrift is enabled. Returning exit code 1."
            exit $exitCode
        }
        else {
            $finalStatus = 'DriftDetectedContinue'
            Write-Host "$($MyInvocation.MyCommand.Name):: Drift detected but FailOnDrift is not enabled. Returning exit code 0." -ForegroundColor Yellow
        }
    }

    Write-DriftSummaryTable -Status $finalStatus -ExitCode $exitCode -Result $result -ReportPath $reportTargetPath
    exit $exitCode
}
catch {
    $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to test deployment drift"
    Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
    throw [System.Exception]::new($contextMessage, $_.Exception)
}
finally {
    Write-Host "$($MyInvocation.MyCommand.Name):: END"
}
