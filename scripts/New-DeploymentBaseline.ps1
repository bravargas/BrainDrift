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
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1000)]
    [int]$ArchiveRetentionCount = 10,

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
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot '..\config\deployment-drift.config.json'
    }

    function Get-SafeFileNamePart {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Value,

            [Parameter(Mandatory = $false)]
            [string]$Fallback = 'unknown'
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $Fallback
        }

        $safeValue = $Value -replace '[^A-Za-z0-9._-]', '_'
        $safeValue = $safeValue.Trim('_', '.')
        if ([string]::IsNullOrWhiteSpace($safeValue)) {
            return $Fallback
        }

        return $safeValue
    }

    function Get-BaselineArchivePath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$CurrentBaselinePath,

            [Parameter(Mandatory = $false)]
            [object]$ExistingBaselineDocument
        )

        $baselineDirectory = Split-Path -Path $CurrentBaselinePath -Parent
        $baselineStem = [System.IO.Path]::GetFileNameWithoutExtension($CurrentBaselinePath)
        $archiveDirectory = Join-Path -Path (Join-Path -Path $baselineDirectory -ChildPath 'archive') -ChildPath $baselineStem
        if (-not (Test-Path -LiteralPath $archiveDirectory -PathType Container)) {
            New-Item -Path $archiveDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $deploymentIdPart = 'unknown-deployment'
        $timestampSource = $null
        if ($null -ne $ExistingBaselineDocument) {
            if ($null -ne $ExistingBaselineDocument.metadata -and -not [string]::IsNullOrWhiteSpace($ExistingBaselineDocument.metadata.deploymentId)) {
                $deploymentIdPart = Get-SafeFileNamePart -Value ([string]$ExistingBaselineDocument.metadata.deploymentId) -Fallback 'unknown-deployment'
            }

            if ($null -ne $ExistingBaselineDocument.metadata -and -not [string]::IsNullOrWhiteSpace($ExistingBaselineDocument.metadata.createdAtUtc)) {
                try {
                    $timestampSource = [System.DateTime]::Parse($ExistingBaselineDocument.metadata.createdAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                }
                catch {
                    $timestampSource = $null
                }
            }
        }

        if ($null -eq $timestampSource) {
            $timestampSource = (Get-Item -LiteralPath $CurrentBaselinePath -ErrorAction Stop).LastWriteTimeUtc
        }

        $archiveTimestamp = $timestampSource.ToString('yyyyMMdd-HHmmssfffZ')
        $archiveFileName = '{0}_{1}.baseline.json' -f $archiveTimestamp, $deploymentIdPart
        $archivePath = Join-Path -Path $archiveDirectory -ChildPath $archiveFileName
        $collisionIndex = 1
        while (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            $archiveFileName = '{0}_{1}_{2}.baseline.json' -f $archiveTimestamp, $deploymentIdPart, $collisionIndex
            $archivePath = Join-Path -Path $archiveDirectory -ChildPath $archiveFileName
            $collisionIndex++
        }

        return $archivePath
    }

    function Invoke-ArchiveRetention {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArchiveDirectory,

            [Parameter(Mandatory = $true)]
            [int]$RetentionCount
        )

        if ($RetentionCount -le 0) {
            Write-Host "$($MyInvocation.MyCommand.Name):: Archive retention disabled; keeping all archived baselines."
            return
        }

        $archivedBaselines = @(Get-ChildItem -LiteralPath $ArchiveDirectory -Filter '*.baseline.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)

        if ($archivedBaselines.Count -le $RetentionCount) {
            return
        }

        $toRemove = @($archivedBaselines | Select-Object -Skip $RetentionCount)
        foreach ($archiveFile in $toRemove) {
            Write-Host "$($MyInvocation.MyCommand.Name):: Removing archived baseline due to retention policy: $($archiveFile.FullName)"
            Remove-Item -LiteralPath $archiveFile.FullName -Force -ErrorAction Stop
        }
    }

    function Resolve-ArchiveRetentionCount {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ConfigPath,

            [Parameter(Mandatory = $true)]
            [int]$DefaultArchiveRetentionCount,

            [Parameter(Mandatory = $false)]
            [bool]$IsArchiveRetentionCountBound
        )

        if ($IsArchiveRetentionCountBound) {
            return $DefaultArchiveRetentionCount
        }

        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            try {
                $configDocument = Read-JsonFile -Path $ConfigPath
                if ($null -ne $configDocument.ArchiveRetentionCount) {
                    $configuredCount = 0
                    if ([int]::TryParse([string]$configDocument.ArchiveRetentionCount, [ref]$configuredCount)) {
                        if ($configuredCount -ge 0 -and $configuredCount -le 1000) {
                            return $configuredCount
                        }
                    }
                }
            }
            catch {
                Write-Host "$($MyInvocation.MyCommand.Name):: WARNING: Unable to read ArchiveRetentionCount from config '$ConfigPath'. Using default $DefaultArchiveRetentionCount."
            }
        }

        return $DefaultArchiveRetentionCount
    }

    $effectiveArchiveRetentionCount = Resolve-ArchiveRetentionCount -ConfigPath $ConfigPath -DefaultArchiveRetentionCount $ArchiveRetentionCount -IsArchiveRetentionCountBound ($PSBoundParameters.ContainsKey('ArchiveRetentionCount'))

    Write-Host "$($MyInvocation.MyCommand.Name):: RootPath        : $RootPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: BaselinePath    : $BaselinePath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ConfigPath      : $ConfigPath"
    Write-Host "$($MyInvocation.MyCommand.Name):: ArchiveRetentionCount : $effectiveArchiveRetentionCount"
    Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns : $($IncludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns : $($ExcludePatterns -join ', ')"
    Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm   : $HashAlgorithm"

    # Ensure patterns are arrays (avoid null/singleton issues)
    if ($null -eq $IncludePatterns) { $IncludePatterns = @() }
    elseif (-not ($IncludePatterns -is [System.Array])) { $IncludePatterns = @($IncludePatterns) }
    if ($null -eq $ExcludePatterns) { $ExcludePatterns = @() }
    elseif (-not ($ExcludePatterns -is [System.Array])) { $ExcludePatterns = @($ExcludePatterns) }

    $archivedBaselinePath = $null
    if (Test-Path -LiteralPath $BaselinePath -PathType Leaf) {
        Write-Host "$($MyInvocation.MyCommand.Name):: Existing baseline detected. Archiving previous version before overwrite."
        $existingBaselineDocument = $null
        try {
            $existingBaselineDocument = Read-JsonFile -Path $BaselinePath
        }
        catch {
            $existingBaselineDocument = $null
        }

        $archivedBaselinePath = Get-BaselineArchivePath -CurrentBaselinePath $BaselinePath -ExistingBaselineDocument $existingBaselineDocument
        Copy-Item -LiteralPath $BaselinePath -Destination $archivedBaselinePath -Force -ErrorAction Stop
        Write-Host "$($MyInvocation.MyCommand.Name):: Archived existing baseline to $archivedBaselinePath"

        if ($effectiveArchiveRetentionCount -gt 0) {
            $archiveDirectory = Split-Path -Path $archivedBaselinePath -Parent
            Invoke-ArchiveRetention -ArchiveDirectory $archiveDirectory -RetentionCount $effectiveArchiveRetentionCount
        }
    }

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
        archivedBaselinePath = $archivedBaselinePath
        configPath = $ConfigPath
        archiveRetentionCount = $effectiveArchiveRetentionCount
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
