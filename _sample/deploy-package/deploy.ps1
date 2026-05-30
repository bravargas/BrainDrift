[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$IncomingPath,

    [Parameter(Mandatory=$true)]
    [string]$TargetPath,

    [Parameter(Mandatory=$false)]
    [string]$StagingPath,

    [Parameter(Mandatory=$false)]
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "deploy:: START"

function Get-TargetRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $normalized = $RelativePath.TrimStart('\', '/')
    switch -Regex ($normalized) {
        '^web\.config$' { return 'Portal\Web.config' }
        '^file1\.dll$' { return 'Portal\hlm\mylibrary\bin\file1.dll' }
        default { return $normalized }
    }
}

function Copy-DeploymentFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    $relativePath = $SourceFile.Substring($SourceRoot.Length).TrimStart('\', '/')
    $targetRelativePath = Get-TargetRelativePath -RelativePath $relativePath
    $targetFile = Join-Path $TargetRoot $targetRelativePath
    $targetDirectory = Split-Path -Path $targetFile -Parent

    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        New-Item -Path $targetDirectory -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $SourceFile -Destination $targetFile -Force
    return [pscustomobject]@{
        SourcePath = $SourceFile
        RelativePath = $relativePath
        TargetPath = $targetFile
    }
}

if (-not (Test-Path -LiteralPath $IncomingPath -PathType Container)) {
    Write-Host "deploy:: ERROR: Incoming path not found: $IncomingPath"
    exit 2
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
    Write-Host "deploy:: Target path does not exist, creating: $TargetPath"
    New-Item -Path $TargetPath -ItemType Directory -Force | Out-Null
}

if (-not $Apply.IsPresent) {
    Write-Host "deploy:: Dry run - files that would be copied from ${IncomingPath} to ${TargetPath}:"
    Get-ChildItem -Path $IncomingPath -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($IncomingPath.Length).TrimStart('\', '/')
        $targetRel = Get-TargetRelativePath -RelativePath $rel
        Write-Host "  $rel -> $targetRel"
    }
    Write-Host "deploy:: To perform actual deployment, re-run with -Apply"
    exit 0
}

try {
    Write-Host "deploy:: Applying deployment (copying files)"
    Get-ChildItem -Path $IncomingPath -Recurse -File | ForEach-Object {
        $result = Copy-DeploymentFile -SourceFile $_.FullName -SourceRoot $IncomingPath -TargetRoot $TargetPath
        Write-Host "deploy:: Copied $($result.RelativePath) -> $($result.TargetPath)"
    }
    Write-Host "deploy:: Deployment completed successfully"
    exit 0
}
catch {
    Write-Host "deploy:: ERROR during copy: $($_.Exception.Message)"
    exit 2
}