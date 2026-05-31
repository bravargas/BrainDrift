[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApplicationName,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentId,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$BaselinePath,

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
    Write-Host "$($MyInvocation.MyCommand.Name):: ApplicationName : $ApplicationName"
    Write-Host "$($MyInvocation.MyCommand.Name):: DeploymentId    : $DeploymentId"
    Write-Host "$($MyInvocation.MyCommand.Name):: EnvironmentName : $EnvironmentName"
    Write-Host "$($MyInvocation.MyCommand.Name):: ServerName      : $ServerName"
    Write-Host "$($MyInvocation.MyCommand.Name):: RootPath        : $RootPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: BaselinePath    : $BaselinePath"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns : $($IncludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns : $($ExcludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm   : $HashAlgorithm"

    # Ensure patterns are arrays (avoid null/singleton issues)
    if ($null -eq $IncludePatterns) { $IncludePatterns = @() }
    elseif (-not ($IncludePatterns -is [System.Array])) { $IncludePatterns = @($IncludePatterns) }
    if ($null -eq $ExcludePatterns) { $ExcludePatterns = @() }
    elseif (-not ($ExcludePatterns -is [System.Array])) { $ExcludePatterns = @($ExcludePatterns) }

    $inventory = Get-FileInventory -RootPath $RootPath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns -HashAlgorithm $HashAlgorithm
    # Force inventory to an array to ensure .Count property exists even for single item results
    $inventory = @($inventory)

    $createdAtUtc = [System.DateTime]::UtcNow.ToString('o')
    $createdBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($createdBy)) {
        $createdBy = $env:USERNAME
    }

    $baseline = [pscustomobject]@{
        metadata = [pscustomobject]@{
            applicationName = $ApplicationName
            deploymentId = $DeploymentId
            environmentName = $EnvironmentName
            serverName = $ServerName
            rootPath = $RootPath
            createdAtUtc = $createdAtUtc
            createdBy = $createdBy
            hashAlgorithm = $HashAlgorithm
        }
        files = $inventory
    }

    Write-JsonFile -InputObject $baseline -Path $BaselinePath -Depth 50 | Out-Null

    $result = [pscustomobject]@{
        baselinePath = $BaselinePath
        applicationName = $ApplicationName
        deploymentId = $DeploymentId
        environmentName = $EnvironmentName
        serverName = $ServerName
        rootPath = $RootPath
        fileCount = ($inventory | Measure-Object).Count
        hashAlgorithm = $HashAlgorithm
        createdAtUtc = $createdAtUtc
        createdBy = $createdBy
        files = $inventory
    }

    Write-Host "$($MyInvocation.MyCommand.Name):: Result : Baseline created"
    return $result
}
catch {
    $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to create deployment baseline"
    Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
    throw [System.Exception]::new($contextMessage, $_.Exception)
}
finally {
    Write-Host "$($MyInvocation.MyCommand.Name):: END"
}
