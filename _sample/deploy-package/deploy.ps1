[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,

    [Parameter(Mandatory=$true)]
    [string]$RootPath,

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

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    Write-Host "deploy:: ERROR: Source path not found: $SourcePath"
    exit 2
}
if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    Write-Host "deploy:: Target path does not exist, creating: $RootPath"
    New-Item -Path $RootPath -ItemType Directory -Force | Out-Null
}

    if (-not $Apply.IsPresent) {
    Write-Host "deploy:: Dry run - files that would be copied from ${SourcePath} to ${RootPath}:"
    Get-ChildItem -Path $SourcePath -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($SourcePath.Length).TrimStart('\', '/')
        $targetRel = Get-TargetRelativePath -RelativePath $rel
        Write-Host "  $rel -> $targetRel"
    }
    Write-Host "deploy:: To perform actual deployment, re-run with -Apply"
    exit 0
}

    try {
    Write-Host "deploy:: Applying deployment (copying files)"
    Get-ChildItem -Path $SourcePath -Recurse -File | ForEach-Object {
        $result = Copy-DeploymentFile -SourceFile $_.FullName -SourceRoot $SourcePath -TargetRoot $RootPath
        Write-Host "deploy:: Copied $($result.RelativePath) -> $($result.TargetPath)"
    }
    Write-Host "deploy:: Deployment completed successfully"
    exit 0
}
catch {
    Write-Host "deploy:: ERROR during copy: $($_.Exception.Message)"
    exit 2
}