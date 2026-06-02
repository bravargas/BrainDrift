# Deployment Drift Examples

## Pre-deployment drift check

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Test-DeploymentDrift.ps1 `
  -ApplicationName "MyApp" `
  -EnvironmentName "QA" `
  -RootPath "$env:TEMP\BrainDriftDeployTarget" `
  -BaselinePath "$env:TEMP\bd-baseline.json" `
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
  -RootPath "$env:TEMP\BrainDriftDeployTarget" `
  -BaselinePath "$env:TEMP\bd-baseline.json" `
  -IncludePatterns "web.config","*.config","*.json","*.xml","*.dll"
```

## Manifest export for an incoming package

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Export-DeploymentFileManifest.ps1 `
  -SourcePath ".\_sample\deploy-package\packages\mybank_2251.1.0.0.nupkg" `
  -ManifestPath "$env:TEMP\BrainDriftIncoming\incoming-manifest.json" `
  -IncludePatterns "web.config","*.config","*.json","*.xml","*.dll" `
  -ExcludePatterns "logs*","temp*","App_Data\cache*"
```

## Expected conflict outcome

If Deployment 1 installed `web.config` with hash `AAA`, the server was later edited to `XXX`, and Deployment 2 brings `web.config` with hash `CCC`, the drift check reports:

baseline = "$env:TEMP\\bd-baseline"
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
The repository includes a minimal, standalone example deployment package under `_sample\deploy-package`. It demonstrates how to keep deployment logic separate from BrainDrift while calling BrainDrift scripts for manifest generation, pre-deployment checks, baseline creation, and optional baseline refresh.

For local validation, `run-deploy.ps1` in that folder now has sensible defaults for the sample package, sample server, baseline, and reports paths, so you can run it without arguments from within `_sample\deploy-package`.

Usage example (copy package to the server or run from a CI agent):

```powershell
# prepare variables (example using local test paths)
$incoming = '.\\_sample\\deploy-package\\packages\\mybank_2251.1.0.0.nupkg'
$target = "$env:TEMP\\BrainDriftDeployTarget"
$baseline = "$env:TEMP\\bd-baseline.json"
$reports = "$env:TEMP\\BrainDriftReports"

# dry run
powershell -NoProfile -ExecutionPolicy Bypass -File _sample\deploy-package\deploy.ps1 -SourcePath $incoming -RootPath $target

# real run, orchestrated with BrainDrift drift gate and optional baseline refresh
powershell -NoProfile -ExecutionPolicy Bypass -File _sample\deploy-package\run-deploy.ps1 `
  -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports `
  -PromoteBaselineOnSuccess
```


Notes:
- The example keeps BrainDrift scripts out of the deployment package internals; integration occurs by invoking BrainDrift's entry scripts from the deploy orchestration.
- Customize `IncludePatterns` / `ExcludePatterns` and hash algorithm by editing the example scripts or calling the BrainDrift scripts directly from your pipeline.
- `Test-DeploymentDrift.ps1` now falls back to `config\deployment-drift.config.json` when `-ConfigPath` is not supplied, and `New-DeploymentBaseline.ps1` uses the same file for `ArchiveRetentionCount` unless the caller overrides it.
- If `BaselinePath` points to a directory instead of a `.json` file, the active baseline file is named `ApplicationName[.EnvironmentName].baseline.json`.
- The orchestration script aborts if the configured baseline is missing by default; to allow safe bootstrap baseline creation pass `-CreateBaselineIfMissing`.
- If a baseline exists and drift is detected, `run-deploy.ps1` stops before `predeploy` and `deploy`.
- If `-PromoteBaselineOnSuccess` is supplied, `run-deploy.ps1` refreshes the baseline after a successful deployment and archives the previous baseline version for root cause analysis.

Passing the `-FailOnDrift` option
-------------------------------

The `run-deploy.ps1` script accepts `-FailOnDrift` as a switch. Behaviour:

- If you include the switch (`-FailOnDrift`) the orchestrator will abort the deployment when drift is detected during the pre-deployment gate.
- If you omit the switch, the orchestrator will log a visible warning when drift is detected but will continue with `predeploy`/`deploy` and then refresh the baseline.

Examples:

```powershell
# Abort on drift (switch present)
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -ApplicationName 'mybank' -EnvironmentName 'prod' -FailOnDrift

# Continue on drift (switch omitted)
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -ApplicationName 'mybank' -EnvironmentName 'prod'
```

Baseline promotion now keeps history by copying the prior baseline to an `archive\<baseline-name>\` folder before the active file is overwritten. By default, `New-DeploymentBaseline.ps1` reads `ArchiveRetentionCount` from `config\deployment-drift.config.json`; the repository sample sets that value to `10`. You can override it with `-ArchiveRetentionCount` or set it to `0` to keep all archived copies.

Integration notes:

- When calling PowerShell from external wrappers or CI systems, be careful not to pass the literal string "True"/"False" for a switch parameter - that can cause a conversion error. The safest approaches are:
  - Include the switch to enable it: `-FailOnDrift` (preferred), or
  - Use PowerShell's explicit form when invoking from another process: `-FailOnDrift:$true` / `-FailOnDrift:$false` inside a `-Command "& { ... }"` call so the boolean literal is evaluated by PowerShell.

This ensures the orchestrator behavior is explicit and avoids subtle integration bugs.

Creating a baseline when missing
--------------------------------

The `run-deploy.ps1` script accepts a `-CreateBaselineIfMissing` switch to control behavior when the configured `BaselinePath` does not exist.

- Default: if you do not bind the parameter, the orchestrator will NOT create a baseline automatically and will abort the run to avoid unsafe deployments.

- To allow automatic baseline creation at bootstrap, explicitly pass the switch: `-CreateBaselineIfMissing`.

Examples:

```powershell
# Allow automatic baseline creation at bootstrap (safe - creates baseline if missing)
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -CreateBaselineIfMissing

# Create baseline at bootstrap (recommended for safe initial deployment)
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -CreateBaselineIfMissing

# Refresh baseline only when requested after a successful deploy
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -PromoteBaselineOnSuccess
```
  To explicitly disable automatic baseline creation from an external wrapper, pass `-CreateBaselineIfMissing:$false`.

Examples:

```powershell
# Create baseline automatically when missing (default behavior)
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports

# Do not create baseline if missing
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -CreateBaselineIfMissing:$false
```

Conflict demo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _sample\deploy-package\trigger-conflict.ps1
```

That helper leaves the target and incoming package in a conflicting state, runs the simulator, and reports the conflict report path.

## Configuration example

The sample config file at `config\deployment-drift.config.json` can control the default archive retention used by `New-DeploymentBaseline.ps1`, and it can also supply defaults that `Test-DeploymentDrift.ps1` consumes when its own parameters are omitted.

```json
{
  "ApplicationName": "MyApp",
  "EnvironmentName": "QA",
  "RootPath": "C:\\inetpub\\MyApp",
  "BaselinePath": "C:\\Deployments\\MyApp\\baseline\\last-successful-deployment.json",
  "ReportPath": "C:\\Deployments\\MyApp\\reports",
  "IncludePatterns": ["web.config", "*.config", "*.json", "*.xml", "*.dll"],
  "ExcludePatterns": ["logs*", "temp*", "App_Data\\cache*"],
  "HashAlgorithm": "SHA256",
  "ArchiveRetentionCount": 10
}
```

Set `ArchiveRetentionCount` to `0` if you want to keep every archived baseline version.
