# BrainDrift 1.0.0 Production Usage

This package is intentionally minimal. It includes only the scripts and module needed to run BrainDrift in production:

- `src\DeploymentDrift.Common.psd1`
- `src\DeploymentDrift.Common.psm1`
- `scripts\Test-DeploymentDrift.ps1`
- `scripts\New-DeploymentBaseline.ps1`
- `scripts\Export-DeploymentFileManifest.ps1`
- `config\deployment-drift.config.json`

No sample apps, sample deployment package, or test files are included in the production package.

## What to insert in your script block

Use the block below as the pipeline step that runs BrainDrift before deployment, and again after deployment if you want to refresh the baseline.

```powershell
$brainDriftRoot = $env:BRAINDRIFT_ROOT
if ([string]::IsNullOrWhiteSpace($brainDriftRoot)) {
    $brainDriftRoot = $PSScriptRoot
}

$scriptsPath = Join-Path $brainDriftRoot 'scripts'
$configPath = Join-Path $brainDriftRoot 'config\deployment-drift.config.json'
$reportPath = $env:BRAINDRIFT_REPORT_PATH
$baselinePath = $env:BRAINDRIFT_BASELINE_PATH
$rootPath = $env:BRAINDRIFT_ROOT_PATH
$applicationName = $env:BRAINDRIFT_APPLICATION_NAME
$environmentName = $env:BRAINDRIFT_ENVIRONMENT_NAME

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'Test-DeploymentDrift.ps1') `
  -ApplicationName $applicationName `
  -EnvironmentName $environmentName `
  -RootPath $rootPath `
  -BaselinePath $baselinePath `
  -ReportPath $reportPath `
  -ConfigPath $configPath `
  -FailOnDrift

switch ($LASTEXITCODE) {
    0 { }
    1 { throw "BrainDrift detected server drift. Review the report in $reportPath." }
    3 { throw "BrainDrift baseline is missing at $baselinePath. Create the first trusted baseline before deploying." }
    default { throw "BrainDrift failed with exit code $LASTEXITCODE." }
}

# Run your deployment logic here.

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'New-DeploymentBaseline.ps1') `
  -ApplicationName $applicationName `
  -DeploymentId $env:HARNESS_EXECUTION_ID `
  -EnvironmentName $environmentName `
  -ServerName $env:COMPUTERNAME `
  -RootPath $rootPath `
  -BaselinePath $baselinePath `
  -ConfigPath $configPath

if ($LASTEXITCODE -ne 0) {
    throw "BrainDrift baseline refresh failed with exit code $LASTEXITCODE."
}
```

## Optional incoming manifest for direct analysis

The production gate shown above does not need the incoming package. It checks the trusted baseline against the current server. If you intentionally want direct three-way analysis with `Test-DeploymentDrift.ps1`, you can generate an incoming manifest and place it at `$reportPath\incoming-manifest.json`; the script will use it when present.

```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'Export-DeploymentFileManifest.ps1') `
  -SourcePath $env:BRAINDRIFT_SOURCE_PATH `
  -ManifestPath (Join-Path $reportPath 'incoming-manifest.json')
```

## Required inputs

- `BRAINDRIFT_ROOT`: path where the BrainDrift package was unpacked.
- `BRAINDRIFT_ROOT_PATH`: application root on the target server.
- `BRAINDRIFT_BASELINE_PATH`: path to the baseline directory or explicit `.json` file (defaults to `C:\Deployments\baselines`). If a directory is supplied, the active baseline file is named `ApplicationName[.EnvironmentName].baseline.json`.
- `BRAINDRIFT_REPORT_PATH`: folder where drift reports will be written.
- `BRAINDRIFT_APPLICATION_NAME`: logical application name.
- `BRAINDRIFT_ENVIRONMENT_NAME`: logical environment name.

If you prefer, you can replace the environment variables with hard-coded paths in the script block.
