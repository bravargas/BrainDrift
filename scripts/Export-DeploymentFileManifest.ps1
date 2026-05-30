[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

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
    Write-Host "$($MyInvocation.MyCommand.Name):: SourcePath      : $SourcePath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ManifestPath    : $ManifestPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns : $($IncludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns : $($ExcludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm   : $HashAlgorithm"

    $inventory = Get-FileInventory -RootPath $SourcePath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns -HashAlgorithm $HashAlgorithm
    $createdAtUtc = [System.DateTime]::UtcNow.ToString('o')
    $createdBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($createdBy)) {
        $createdBy = $env:USERNAME
    }

    $manifest = [pscustomobject]@{
        metadata = [pscustomobject]@{
            sourcePath = $SourcePath
            createdAtUtc = $createdAtUtc
            createdBy = $createdBy
            hashAlgorithm = $HashAlgorithm
        }
        files = $inventory
    }

    Write-JsonFile -InputObject $manifest -Path $ManifestPath -Depth 50 | Out-Null

    $result = [pscustomobject]@{
        manifestPath = $ManifestPath
        sourcePath = $SourcePath
        fileCount = $inventory.Count
        hashAlgorithm = $HashAlgorithm
        createdAtUtc = $createdAtUtc
        createdBy = $createdBy
        files = $inventory
    }

    Write-Host "$($MyInvocation.MyCommand.Name):: Result : Manifest created"
    return $result
}
catch {
    $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to export file manifest"
    Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
    throw [System.Exception]::new($contextMessage, $_.Exception)
}
finally {
    Write-Host "$($MyInvocation.MyCommand.Name):: END"
}
