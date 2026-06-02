[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Get-NormalizedRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: RootPath  : $RootPath"
        Write-Host "$($MyInvocation.MyCommand.Name):: FullPath  : $FullPath"

        $normalizedRootPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
        $normalizedFullPath = [System.IO.Path]::GetFullPath($FullPath)

        if (-not $normalizedFullPath.StartsWith($normalizedRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [System.Exception]::new("Path '$FullPath' is not under root '$RootPath'.")
        }

        $relativePath = $normalizedFullPath.Substring($normalizedRootPath.Length).TrimStart('\', '/')
        $relativePath = $relativePath -replace '\\', '/'

        Write-Host "$($MyInvocation.MyCommand.Name):: Result : $relativePath"
        return $relativePath
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to normalize relative path"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function Test-PathMatchesPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: Path     : $Path"
        Write-Host "$($MyInvocation.MyCommand.Name):: Patterns : $($Patterns -join ', ')"

        $normalizedPath = $Path -replace '\\', '/'
        $normalizedPath = $normalizedPath -replace '/+', '/'
        $isMatch = $false

        # Support patterns passed as a single comma-separated string or as an array
        $expandedPatterns = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if ($p -like '*,*') {
                foreach ($part in ($p -split ',')) {
                    if (-not [string]::IsNullOrWhiteSpace($part)) { $expandedPatterns.Add($part.Trim()) }
                }
            }
            else {
                $expandedPatterns.Add($p)
            }
        }

        foreach ($pattern in $expandedPatterns) {
            $normalizedPattern = $pattern -replace '\\', '/'
            $normalizedPattern = $normalizedPattern -replace '/+', '/'

            if ($normalizedPath -like $normalizedPattern) {
                $isMatch = $true
                break
            }
        }

        Write-Host "$($MyInvocation.MyCommand.Name):: Result : $isMatch"
        return $isMatch
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to evaluate path pattern match"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function Get-FileInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [string[]]$IncludePatterns,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludePatterns,

        [Parameter(Mandatory = $false)]
        [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
        [string]$HashAlgorithm = 'SHA256'
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: RootPath        : $RootPath"
        Write-Host "$($MyInvocation.MyCommand.Name):: IncludePatterns  : $($IncludePatterns -join ', ')"
        Write-Host "$($MyInvocation.MyCommand.Name):: ExcludePatterns  : $($ExcludePatterns -join ', ')"
        Write-Host "$($MyInvocation.MyCommand.Name):: HashAlgorithm    : $HashAlgorithm"

        if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new("Root path '$RootPath' does not exist or is not a directory.")
        }

        $files = Get-ChildItem -LiteralPath $RootPath -File -Recurse -ErrorAction Stop | Sort-Object FullName
        $inventory = New-Object System.Collections.Generic.List[object]

        foreach ($file in $files) {
            $relativePath = Get-NormalizedRelativePath -RootPath $RootPath -FullPath $file.FullName

            $includeMatch = $true
            if ($null -ne $IncludePatterns -and $IncludePatterns.Count -gt 0) {
                $includeMatch = Test-PathMatchesPattern -Path $relativePath -Patterns $IncludePatterns
            }

            $excludeMatch = $false
            if ($null -ne $ExcludePatterns -and $ExcludePatterns.Count -gt 0) {
                $excludeMatch = Test-PathMatchesPattern -Path $relativePath -Patterns $ExcludePatterns
            }

            if (-not $includeMatch -or $excludeMatch) {
                Write-Host "$($MyInvocation.MyCommand.Name):: Skipping file: $relativePath"
                continue
            }

            Write-Host "$($MyInvocation.MyCommand.Name):: Hashing file: $relativePath"
            $fileHash = Get-FileHash -LiteralPath $file.FullName -Algorithm $HashAlgorithm -ErrorAction Stop

            $inventory.Add([pscustomobject]@{
                relativePath = $relativePath
                fullPath = $file.FullName
                hash = $fileHash.Hash
                fileSize = [int64]$file.Length
                lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                hashAlgorithm = $HashAlgorithm
            })
        }

        $result = $inventory.ToArray()
        Write-Host "$($MyInvocation.MyCommand.Name):: Result count : $($result.Count)"
        return $result
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to build file inventory"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function Resolve-DeploymentDriftConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = $null,

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
        [string[]]$IncludePatterns,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludePatterns,

        [Parameter(Mandatory = $false)]
        [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
        [string]$HashAlgorithm = 'SHA256',

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 1000)]
        [int]$ArchiveRetentionCount = 10,

        [Parameter(Mandatory = $false)]
        [bool]$IsArchiveRetentionCountBound = $false
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: ConfigPath : $ConfigPath"

        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
            $ConfigPath = Join-Path $moduleRoot 'config\deployment-drift.config.json'
        }

        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            try {
                $configDocument = Read-JsonFile -Path $ConfigPath
                if ($null -ne $configDocument) {
                    if ([string]::IsNullOrWhiteSpace($ApplicationName) -and ($configDocument.PSObject.Properties.Name -contains 'ApplicationName') -and $null -ne $configDocument.ApplicationName) { $ApplicationName = $configDocument.ApplicationName }
                    if ([string]::IsNullOrWhiteSpace($EnvironmentName) -and ($configDocument.PSObject.Properties.Name -contains 'EnvironmentName') -and $null -ne $configDocument.EnvironmentName) { $EnvironmentName = $configDocument.EnvironmentName }
                    if ([string]::IsNullOrWhiteSpace($RootPath) -and ($configDocument.PSObject.Properties.Name -contains 'RootPath') -and $null -ne $configDocument.RootPath) { $RootPath = $configDocument.RootPath }
                    if ([string]::IsNullOrWhiteSpace($BaselinePath) -and ($configDocument.PSObject.Properties.Name -contains 'BaselinePath') -and $null -ne $configDocument.BaselinePath) { $BaselinePath = $configDocument.BaselinePath }
                    if ([string]::IsNullOrWhiteSpace($ReportPath) -and ($configDocument.PSObject.Properties.Name -contains 'ReportPath') -and $null -ne $configDocument.ReportPath) { $ReportPath = $configDocument.ReportPath }
                    if ($null -eq $IncludePatterns -and ($configDocument.PSObject.Properties.Name -contains 'IncludePatterns') -and $null -ne $configDocument.IncludePatterns) { $IncludePatterns = @($configDocument.IncludePatterns) }
                    if ($null -eq $ExcludePatterns -and ($configDocument.PSObject.Properties.Name -contains 'ExcludePatterns') -and $null -ne $configDocument.ExcludePatterns) { $ExcludePatterns = @($configDocument.ExcludePatterns) }
                    if ([string]::IsNullOrWhiteSpace($HashAlgorithm) -and ($configDocument.PSObject.Properties.Name -contains 'HashAlgorithm') -and $null -ne $configDocument.HashAlgorithm) { $HashAlgorithm = $configDocument.HashAlgorithm }

                    if (-not $IsArchiveRetentionCountBound -and ($configDocument.PSObject.Properties.Name -contains 'ArchiveRetentionCount') -and $null -ne $configDocument.ArchiveRetentionCount) {
                        $configuredCount = 0
                        if ([int]::TryParse([string]$configDocument.ArchiveRetentionCount, [ref]$configuredCount)) {
                            if ($configuredCount -ge 0 -and $configuredCount -le 1000) {
                                $ArchiveRetentionCount = $configuredCount
                            }
                        }
                    }
                }
            }
            catch {
                Write-Host "$($MyInvocation.MyCommand.Name):: WARNING: Unable to read config '$ConfigPath' : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
            $BaselinePath = 'C:\Deployments\baselines'
        }

        $result = [pscustomobject]@{
            ConfigPath            = $ConfigPath
            ApplicationName       = $ApplicationName
            EnvironmentName       = $EnvironmentName
            RootPath              = $RootPath
            BaselinePath          = $BaselinePath
            ReportPath            = $ReportPath
            IncludePatterns       = @($IncludePatterns)
            ExcludePatterns       = @($ExcludePatterns)
            HashAlgorithm         = $HashAlgorithm
            ArchiveRetentionCount = $ArchiveRetentionCount
        }

        Write-Host "$($MyInvocation.MyCommand.Name):: Result : Configuration resolved"
        return $result
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to resolve deployment drift configuration"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: Path : $Path"

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("JSON file '$Path' was not found.")
        }

        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw [System.Exception]::new("JSON file '$Path' is empty.")
        }

        $result = $content | ConvertFrom-Json -ErrorAction Stop
        Write-Host "$($MyInvocation.MyCommand.Name):: Result : JSON loaded"
        return $result
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to read JSON file"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function Write-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [int]$Depth = 50
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: Path  : $Path"
        Write-Host "$($MyInvocation.MyCommand.Name):: Depth : $Depth"

        $directoryPath = Split-Path -Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            New-Item -Path $directoryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $json = $InputObject | ConvertTo-Json -Depth $Depth -Compress:$false -ErrorAction Stop
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -ErrorAction Stop

        Write-Host "$($MyInvocation.MyCommand.Name):: Result : JSON written"
        return $Path
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to write JSON file"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function Compare-FileInventories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$BaselineInventory,

        [Parameter(Mandatory = $true)]
        [object[]]$CurrentInventory,

        [Parameter(Mandatory = $false)]
        [object[]]$IncomingInventory
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: BaselineInventory count : $($BaselineInventory.Count)"
        Write-Host "$($MyInvocation.MyCommand.Name):: CurrentInventory count   : $($CurrentInventory.Count)"
        $incomingCount = if ($null -ne $IncomingInventory) { $IncomingInventory.Count } else { 0 }
        Write-Host "$($MyInvocation.MyCommand.Name):: IncomingInventory count  : $incomingCount"

        $baselineMap = @{}
        $currentMap = @{}
        $incomingMap = @{}

        foreach ($entry in $BaselineInventory) {
            $baselineMap[$entry.relativePath.ToLowerInvariant()] = $entry
        }

        foreach ($entry in $CurrentInventory) {
            $currentMap[$entry.relativePath.ToLowerInvariant()] = $entry
        }

        if ($null -ne $IncomingInventory) {
            foreach ($entry in $IncomingInventory) {
                $incomingMap[$entry.relativePath.ToLowerInvariant()] = $entry
            }
        }

        $allKeys = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $baselineMap.Keys) { [void]$allKeys.Add($key) }
        foreach ($key in $currentMap.Keys) { [void]$allKeys.Add($key) }
        foreach ($key in $incomingMap.Keys) { [void]$allKeys.Add($key) }

        $entries = New-Object System.Collections.Generic.List[object]
        $baselineChangedCount = 0
        $missingCount = 0
        $newUnexpectedCount = 0
        $incomingChangeCount = 0
        $conflictCount = 0
        $unchangedCount = 0

        foreach ($key in $allKeys) {
            $baselineEntry = $null
            $currentEntry = $null
            $incomingEntry = $null

            if ($baselineMap.ContainsKey($key)) { $baselineEntry = $baselineMap[$key] }
            if ($currentMap.ContainsKey($key)) { $currentEntry = $currentMap[$key] }
            if ($incomingMap.ContainsKey($key)) { $incomingEntry = $incomingMap[$key] }

            $baselineHash = if ($null -ne $baselineEntry) { $baselineEntry.hash } else { $null }
            $currentHash = if ($null -ne $currentEntry) { $currentEntry.hash } else { $null }
            $incomingHash = if ($null -ne $incomingEntry) { $incomingEntry.hash } else { $null }

            $baselineExists = $null -ne $baselineEntry
            $currentExists = $null -ne $currentEntry
            $incomingExists = $null -ne $incomingEntry

            $isMissing = $baselineExists -and -not $currentExists
            $isNewUnexpected = -not $baselineExists -and $currentExists
            $isModified = $baselineExists -and $currentExists -and ($baselineHash -ne $currentHash)
            $incomingDiffersFromBaseline = $incomingExists -and $baselineExists -and ($incomingHash -ne $baselineHash)
            $incomingDiffersFromCurrent = $incomingExists -and $currentExists -and ($incomingHash -ne $currentHash)

            $isConflict = $false
            $classification = 'Unchanged'
            $recommendedAction = 'Proceed with deployment.'

            if ($isMissing) {
                $classification = 'MissingOnCurrentServer'
                $recommendedAction = 'Investigate the missing file before deploying.'
                if ($incomingDiffersFromBaseline) {
                    $isConflict = $true
                    $classification = 'MissingOnCurrentServerWithIncomingChange'
                    $recommendedAction = 'Stop deployment and review the missing file and incoming change.'
                }
                $missingCount++
            }
            elseif ($isNewUnexpected) {
                $classification = 'NewUnexpectedFileOnCurrentServer'
                $recommendedAction = 'Review the unexpected file before deploying.'
                $newUnexpectedCount++
            }
            elseif ($isModified) {
                $baselineChangedCount++
                if ($incomingExists) {
                    if ($incomingDiffersFromBaseline) {
                        $incomingChangeCount++
                    }

                    if ($incomingDiffersFromBaseline -and $incomingDiffersFromCurrent) {
                        $isConflict = $true
                        $classification = 'PotentialConflict'
                        $recommendedAction = 'Stop deployment and review the conflicting file.'
                    }
                    elseif ($incomingDiffersFromBaseline -and -not $incomingDiffersFromCurrent) {
                        $classification = 'ServerDriftMatchesIncoming'
                        $recommendedAction = 'Review drift, then continue only if the incoming change is approved.'
                    }
                    else {
                        $classification = 'ServerDrift'
                        $recommendedAction = 'Investigate server drift before deploying.'
                    }
                }
                else {
                    $classification = 'ServerDrift'
                    $recommendedAction = 'Investigate server drift before deploying.'
                }
            }
            elseif ($baselineExists -and $currentExists -and $baselineHash -eq $currentHash) {
                if ($incomingDiffersFromBaseline) {
                    $incomingChangeCount++
                    if ($incomingDiffersFromCurrent) {
                        $classification = 'IncomingChangeOnly'
                        $recommendedAction = 'Proceed with deployment.'
                    }
                    else {
                        $classification = 'IncomingChangeAlreadyPresentOnServer'
                        $recommendedAction = 'Proceed with deployment.'
                    }
                }
                else {
                    $unchangedCount++
                    $classification = 'Unchanged'
                    $recommendedAction = 'Proceed with deployment.'
                }
            }
            elseif (-not $baselineExists -and $incomingExists -and -not $currentExists) {
                $classification = 'IncomingOnlyFile'
                $recommendedAction = 'Proceed with deployment.'
            }
            elseif (-not $baselineExists -and $incomingExists -and $currentExists) {
                $classification = 'NewFileNotInBaseline'
                $recommendedAction = 'Review the file before deploying.'
            }

            $entries.Add([pscustomobject]@{
                relativePath = if ($null -ne $baselineEntry) { $baselineEntry.relativePath } elseif ($null -ne $currentEntry) { $currentEntry.relativePath } else { $incomingEntry.relativePath }
                baseline = $baselineEntry
                currentServer = $currentEntry
                incomingPackage = $incomingEntry
                baselineHash = $baselineHash
                currentHash = $currentHash
                incomingHash = $incomingHash
                isMissing = $isMissing
                isNewUnexpected = $isNewUnexpected
                isModified = $isModified
                isConflict = $isConflict
                classification = $classification
                recommendedAction = $recommendedAction
            })

            if ($isConflict) {
                $conflictCount++
            }
        }

        $result = [pscustomobject]@{
            files = $entries.ToArray()
            summary = [pscustomobject]@{
                baselineFileCount = $BaselineInventory.Count
                currentFileCount = $CurrentInventory.Count
                incomingFileCount = if ($null -ne $IncomingInventory) { $IncomingInventory.Count } else { 0 }
                modifiedCount = $baselineChangedCount
                missingCount = $missingCount
                newUnexpectedCount = $newUnexpectedCount
                incomingChangeCount = $incomingChangeCount
                conflictCount = $conflictCount
                unchangedCount = $unchangedCount
            }
            hasDrift = ($baselineChangedCount -gt 0) -or ($missingCount -gt 0) -or ($newUnexpectedCount -gt 0) -or ($conflictCount -gt 0)
            hasConflict = ($conflictCount -gt 0)
        }

        Write-Host "$($MyInvocation.MyCommand.Name):: Result : Comparison completed"
        return $result
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to compare file inventories"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

function New-DriftReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter(Mandatory = $true)]
        [object]$ComparisonResult
        ,[Parameter(Mandatory = $false)]
        [switch]$IncludeUnchangedFiles
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: Metadata provided        : $($null -ne $Metadata)"
        Write-Host "$($MyInvocation.MyCommand.Name):: ComparisonResult provided : $($null -ne $ComparisonResult)"

        $recommendedAction = 'Proceed with deployment.'
        if ($ComparisonResult.hasConflict) {
            $recommendedAction = 'Stop deployment and review conflicting files.'
        }
        elseif ($ComparisonResult.hasDrift) {
            $recommendedAction = 'Investigate drift before deploying.'
        }

        # By default, only include files that are not classified as 'Unchanged'.
        # Callers may request the previous behavior by passing -IncludeUnchangedFiles.
        if ($IncludeUnchangedFiles.IsPresent) {
            $files = $ComparisonResult.files
        }
        else {
            $files = @()
            if ($null -ne $ComparisonResult.files) {
                $files = $ComparisonResult.files | Where-Object { $_.classification -ne 'Unchanged' }
            }
        }

        $report = [pscustomobject]@{
            metadata = $Metadata
            summary = $ComparisonResult.summary
            classification = [pscustomobject]@{
                hasDrift = $ComparisonResult.hasDrift
                hasConflict = $ComparisonResult.hasConflict
                recommendedAction = $recommendedAction
            }
            files = $files
            recommendedAction = $recommendedAction
        }

        Write-Host "$($MyInvocation.MyCommand.Name):: Result : Drift report created"
        return $report
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to build drift report"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}

Export-ModuleMember -Function Get-NormalizedRelativePath, Test-PathMatchesPattern, Get-FileInventory, Resolve-DeploymentDriftConfiguration, Read-JsonFile, Write-JsonFile, Compare-FileInventories, New-DriftReport