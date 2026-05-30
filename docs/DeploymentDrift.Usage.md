# Deployment Drift Examples

## Pre-deployment drift check

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Test-DeploymentDrift.ps1 `
  -ApplicationName "MyApp" `
  -EnvironmentName "QA" `
  -RootPath "C:\inetpub\MyApp" `
  -BaselinePath "C:\Deployments\MyApp\baseline\last-successful-deployment.json" `
  -IncomingPackagePath "C:\Deployments\MyApp\incoming" `
  -ReportPath "C:\Deployments\MyApp\reports" `
  -FailOnDrift `
  -IncludePatterns "web.config","*.config","*.json","*.xml","*.dll" `
  -ExcludePatterns "logs*","temp*","App_Data\cache*"
```

## Post-deployment baseline update

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\New-DeploymentBaseline.ps1 `
  -ApplicationName "MyApp" `
  -DeploymentId "$env:HARNESS_EXECUTION_ID" `
  -EnvironmentName "QA" `
  -ServerName $env:COMPUTERNAME `
  -RootPath "C:\inetpub\MyApp" `
  -BaselinePath "C:\Deployments\MyApp\baseline\last-successful-deployment.json" `
  -IncludePatterns "web.config","*.config","*.json","*.xml","*.dll" `
  -ExcludePatterns "logs*","temp*","App_Data\cache*"
```

## Manifest export for an incoming package

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Export-DeploymentFileManifest.ps1 `
  -SourcePath "C:\Deployments\MyApp\incoming" `
  -ManifestPath "C:\Deployments\MyApp\manifests\incoming-manifest.json" `
  -IncludePatterns "web.config","*.config","*.json","*.xml","*.dll" `
  -ExcludePatterns "logs*","temp*","App_Data\cache*"
```

## Expected conflict outcome

If Deployment 1 installed `web.config` with hash `AAA`, the server was later edited to `XXX`, and Deployment 2 brings `web.config` with hash `CCC`, the drift check reports:

- `web.config` is modified on the server relative to the last successful deployment baseline.
- `web.config` also has an incoming official change.
- The file is classified as a potential conflict.
- The recommended action is to stop deployment and review the file before overwriting it.

## Deployment zero behavior

When `BaselinePath` does not exist yet, the drift check should not try to compare the server against an unknown reference. That scenario represents the first deployment bootstrap.

Recommended operational flow:

1. Manually build and validate the server.
2. Run `scripts\\New-DeploymentBaseline.ps1` to create the first trusted baseline.
3. Only then enable `scripts\\Test-DeploymentDrift.ps1` in the normal pre-deployment flow.

In the current implementation, a missing baseline returns exit code `3` and a clear message that initialization is required.

## Sample local deployment package (integration example)

The repository includes a minimal, standalone example deployment package under `_sample\deploy-package`. It demonstrates how to keep deployment logic separate from BrainDrift while calling BrainDrift scripts for manifest generation, pre-deployment checks and post-deployment baseline promotion.

Files:
- `_sample\deploy-package\predeploy.ps1` — prepares staging and exports an incoming manifest (calls `Export-DeploymentFileManifest.ps1`).
- `_sample\deploy-package\deploy.ps1` — simple dry-run and apply copy of incoming files to a target path.
- `_sample\deploy-package\run-deploy.ps1` — orchestration script: runs `predeploy.ps1`, runs `deploy.ps1` (apply), then calls `Test-DeploymentDrift.ps1` to validate the deployment; optionally promotes the deployed server state to a new baseline if requested.
- `_sample\deploy-package\trigger-conflict.ps1` — creates a controlled target/incoming mismatch and verifies that `run-deploy.ps1` stops on the pre-deployment conflict gate.

Usage example (copy package to the server or run from a CI agent):

```powershell
# prepare variables
$incoming = 'C:\temp\incoming-package'
$target = 'C:\inetpub\MyApp'
$baseline = 'C:\Deployments\MyApp\baseline\last-successful-deployment.json'
$reports = 'C:\Deployments\MyApp\reports'

# dry run
powershell -NoProfile -ExecutionPolicy Bypass -File _sample\deploy-package\deploy.ps1 -IncomingPath $incoming -TargetPath $target

# real run, orchestrated with BrainDrift check and optional baseline promotion
powershell -NoProfile -ExecutionPolicy Bypass -File _sample\deploy-package\run-deploy.ps1 `
  -IncomingPath $incoming -TargetPath $target -BaselinePath $baseline -ReportsPath $reports -PromoteBaselineOnSuccess
```

Notes:
- The example keeps BrainDrift scripts out of the deployment package internals; integration occurs by invoking BrainDrift's entry scripts from the deploy orchestration.
- Customize `IncludePatterns` / `ExcludePatterns` and hash algorithm by editing the example scripts or calling the BrainDrift scripts directly from your pipeline.
- The orchestration script treats a missing baseline as an initial deployment and will promote the current state to baseline if `-PromoteBaselineOnSuccess` is provided.

Conflict demo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _sample\deploy-package\trigger-conflict.ps1
```

That helper leaves the target and incoming package in a conflicting state, runs the simulator, and reports the conflict report path.
