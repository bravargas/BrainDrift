[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$NuGetExe = '',

    [Parameter(Mandatory=$false)]
    [string]$Nuspec = '',

    [Parameter(Mandatory=$false)]
    [string]$OutDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# If the caller didn't provide a NuGetExe path, resolve a sensible default
if ([string]::IsNullOrWhiteSpace($NuGetExe)) {
    $scriptRoot = if ($PSScriptRoot -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }
    $NuGetExe = Join-Path $scriptRoot 'tools\nuget.exe'
}

# Resolve defaults for Nuspec and OutDir if they were not provided
if ([string]::IsNullOrWhiteSpace($Nuspec)) {
    $Nuspec = Join-Path $scriptRoot 'mybank_2251.nuspec'
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $scriptRoot 'packages'
}

if (-not (Test-Path -LiteralPath $NuGetExe -PathType Leaf)) {
    throw "nuget.exe not found: $NuGetExe"
}
if (-not (Test-Path -LiteralPath $Nuspec -PathType Leaf)) {
    throw "Nuspec not found: $Nuspec"
}

$resolvedOutDir = if ([System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir
} else {
    Join-Path (Get-Location).Path $OutDir
}
if (-not (Test-Path -LiteralPath $resolvedOutDir)) { New-Item -Path $resolvedOutDir -ItemType Directory -Force | Out-Null }

[xml]$nuspecXml = Get-Content -Path $Nuspec -Raw
$id = $nuspecXml.package.metadata.id
$version = $nuspecXml.package.metadata.version

$nupkgName = "{0}.{1}.nupkg" -f $id, $version
$nupkgPath = Join-Path $resolvedOutDir $nupkgName

if (Test-Path -LiteralPath $nupkgPath) { Remove-Item -LiteralPath $nupkgPath -Force }

$resolvedNuspec = (Resolve-Path -LiteralPath $Nuspec).Path
$nuspecDirectory = Split-Path -Path $resolvedNuspec -Parent
$originalLocation = Get-Location
try {
    Set-Location -LiteralPath $nuspecDirectory
    & $NuGetExe pack $resolvedNuspec -OutputDirectory $resolvedOutDir -NoPackageAnalysis | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "nuget.exe pack failed with exit code $LASTEXITCODE"
    }
}
finally {
    Set-Location -LiteralPath $originalLocation
}

Write-Host "Packaged $nupkgPath"
Write-Output $nupkgPath
exit 0
