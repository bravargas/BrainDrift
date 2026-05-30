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

    [Parameter(Mandatory = $false)]
    [string]$IncomingPackagePath,

    [Parameter(Mandatory = $true)]
    [string]$ReportPath,

    [Parameter(Mandatory = $false)]
    [switch]$FailOnDrift,

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
    Write-Host "$($MyInvocation.MyCommand.Name):: IncomingPackagePath : $IncomingPackagePath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ReportPath          : $ReportPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: FailOnDrift         : $FailOnDrift"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns     : $($IncludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns     : $($ExcludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm       : $HashAlgorithm"

    if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
        $createdAtUtc = [System.DateTime]::UtcNow.ToString('o')
        $createdBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ([string]::IsNullOrWhiteSpace($createdBy)) {
            $createdBy = $env:USERNAME
        }

        $result = [pscustomobject]@{
            reportPath = $null
            applicationName = $ApplicationName
            environmentName = $EnvironmentName
            rootPath = $RootPath
            baselinePath = $BaselinePath
            incomingPackagePath = $IncomingPackagePath
            hashAlgorithm = $HashAlgorithm
            hasDrift = $false
            hasConflict = $false
            baselineMissing = $true
            summary = [pscustomobject]@{
                baselineFileCount = 0
                currentFileCount = 0
                incomingFileCount = if ([string]::IsNullOrWhiteSpace($IncomingPackagePath)) { 0 } else { 0 }
                modifiedCount = 0
                missingCount = 0
                newUnexpectedCount = 0
                incomingChangeCount = 0
                conflictCount = 0
                unchangedCount = 0
            }
            files = @()
            recommendedAction = 'Baseline file is missing. Create an initial baseline from a trusted, validated server state before enabling drift detection.'
            metadata = [pscustomobject]@{
                applicationName = $ApplicationName
                environmentName = $EnvironmentName
                rootPath = $RootPath
                baselinePath = $BaselinePath
                incomingPackagePath = $IncomingPackagePath
                generatedAtUtc = $createdAtUtc
                generatedBy = $createdBy
                hashAlgorithm = $HashAlgorithm
            }
        }

        Write-Host "$($MyInvocation.MyCommand.Name):: Baseline file is missing. Return code 3 indicates initialization is required."
        Write-Output $result
        exit 3
    }

    $baselineDocument = Read-JsonFile -Path $BaselinePath
    $baselineInventory = $baselineDocument.files
    $currentInventory = Get-FileInventory -RootPath $RootPath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns -HashAlgorithm $HashAlgorithm

    $incomingInventory = $null
    if (-not [string]::IsNullOrWhiteSpace($IncomingPackagePath)) {
        $incomingInventory = Get-FileInventory -RootPath $IncomingPackagePath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns -HashAlgorithm $HashAlgorithm
    }

    $comparison = Compare-FileInventories -BaselineInventory $baselineInventory -CurrentInventory $currentInventory -IncomingInventory $incomingInventory

    $createdAtUtc = [System.DateTime]::UtcNow.ToString('o')
    $createdBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($createdBy)) {
        $createdBy = $env:USERNAME
    }

    $reportMetadata = [pscustomobject]@{
        applicationName = $ApplicationName
        environmentName = $EnvironmentName
        rootPath = $RootPath
        baselinePath = $BaselinePath
        incomingPackagePath = $IncomingPackagePath
        generatedAtUtc = $createdAtUtc
        generatedBy = $createdBy
        hashAlgorithm = $HashAlgorithm
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
        reportPath = $reportTargetPath
        applicationName = $ApplicationName
        environmentName = $EnvironmentName
        rootPath = $RootPath
        baselinePath = $BaselinePath
        incomingPackagePath = $IncomingPackagePath
        hashAlgorithm = $HashAlgorithm
        hasDrift = $comparison.hasDrift
        hasConflict = $comparison.hasConflict
        summary = $comparison.summary
        files = $comparison.files
        recommendedAction = $report.recommendedAction
    }

    Write-Host "$($MyInvocation.MyCommand.Name):: Result : Drift check completed"
    Write-Output $result

    if ($FailOnDrift.IsPresent -and $comparison.hasDrift) {
        Write-Host "$($MyInvocation.MyCommand.Name):: Drift detected and FailOnDrift is enabled. Returning exit code 1."
        exit 1
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
