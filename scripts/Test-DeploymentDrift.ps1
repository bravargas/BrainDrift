[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApplicationName,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$BaselinePath,
    
    [Parameter(Mandatory = $true)]
    [string]$ReportPath,

    [Parameter(Mandatory = $false)]
    [switch]$FailOnDrift,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBaselineCreation,

    [Parameter(Mandatory = $false)]
    [switch]$ContinueWithoutBaseline,

    [Parameter(Mandatory = $false)]
    [switch]$CreateBaselineIfMissing,


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

    Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
    Write-Host "$($MyInvocation.MyCommand.Name):: ApplicationName     : $ApplicationName"
    Write-Host "$($MyInvocation.MyCommand.Name):: EnvironmentName     : $EnvironmentName"
    Write-Host "$($MyInvocation.MyCommand.Name):: RootPath            : $RootPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: BaselinePath        : $BaselinePath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ReportPath          : $ReportPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: FailOnDrift         : $FailOnDrift"
    Write-Host "$($MyInvocation.MyCommand.Name):: SkipBaselineCreation : $SkipBaselineCreation"
    Write-Host "$($MyInvocation.MyCommand.Name):: ContinueWithoutBaseline : $ContinueWithoutBaseline"
    Write-Host "$($MyInvocation.MyCommand.Name):: CreateBaselineIfMissing : $CreateBaselineIfMissing"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns     : $($IncludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns     : $($ExcludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm       : $HashAlgorithm"
    # support alternate flag name
    if ($ContinueWithoutBaseline.IsPresent) { $SkipBaselineCreation = $true }

    if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
        if ($CreateBaselineIfMissing.IsPresent) {
            Write-Host "$($MyInvocation.MyCommand.Name):: Baseline missing and CreateBaselineIfMissing requested. Attempting to create baseline..." -ForegroundColor Yellow
            $deploymentId = ('AUTO-{0}' -f ([System.DateTime]::UtcNow.ToString('yyyyMMddHHmmss')))
            $baselineArgs = @(
                '-ApplicationName', $ApplicationName,
                '-DeploymentId', $deploymentId,
                '-EnvironmentName', $EnvironmentName,
                '-ServerName', $env:COMPUTERNAME,
                '-RootPath', $RootPath,
                '-BaselinePath', $BaselinePath
            )
            & $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-DeploymentBaseline.ps1') @baselineArgs
            $be = $LASTEXITCODE
            if ($be -ne 0) {
                Write-Host "$($MyInvocation.MyCommand.Name):: Failed to create baseline (exit $be). Returning code 3." -ForegroundColor Red
                exit 3
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
                baselinePath      = $BaselinePath
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
            Write-Output $result
            exit 3
        }
    }

    $baselineDocument = Read-JsonFile -Path $BaselinePath
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

    $report = New-DriftReport -Metadata $reportMetadata -ComparisonResult $comparison

    $reportTargetPath = $ReportPath
    $reportExtension = [System.IO.Path]::GetExtension($ReportPath)
    if ($reportExtension -ne '.json') {
        if (-not (Test-Path -LiteralPath $ReportPath -PathType Container)) {
            New-Item -Path $ReportPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $reportTargetPath = Join-Path $ReportPath ('drift-report-{0}.json' -f ([System.DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
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
        baselinePath      = $BaselinePath
        hashAlgorithm     = $HashAlgorithm
        hasDrift          = $comparison.hasDrift
        hasConflict       = $comparison.hasConflict
        summary           = $comparison.summary
        files             = $comparison.files
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
    if ($comparison.hasConflict) {
        Write-Host "$($MyInvocation.MyCommand.Name):: Conflict detected. Returning exit code 1." -ForegroundColor Red
        exit 1
    }

    if ($comparison.hasDrift) {
        if ($FailOnDrift.IsPresent) {
            Write-Host "$($MyInvocation.MyCommand.Name):: Drift detected and FailOnDrift is enabled. Returning exit code 1."
            exit 1
        }
        else {
            Write-Host "$($MyInvocation.MyCommand.Name):: Drift detected but FailOnDrift is not enabled. Returning exit code 0." -ForegroundColor Yellow
        }
    }

    exit 0
}
catch {
    $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to test deployment drift"
    Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
    throw [System.Exception]::new($contextMessage, $_.Exception)
}
finally {
    Write-Host "$($MyInvocation.MyCommand.Name):: END"
}
