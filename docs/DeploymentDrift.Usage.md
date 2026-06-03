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

## Optional manifest export

`Export-DeploymentFileManifest.ps1` can still generate an inventory for a folder when you call `Test-DeploymentDrift.ps1` directly and intentionally place `incoming-manifest.json` in the report folder. The sample `run-deploy.ps1` does not use this manifest; its deployment gate compares only the baseline against the current server.

## Multiple folders under one root

When a deployment needs to verify more than one folder under a shared parent, set `RootPath` to the common parent and use `IncludePatterns` for each folder. For example, to check only `HostAdapters` and `Portal` under `C:\Architect\2251_MU`:

```powershell
-RootPath 'C:\Architect\2251_MU' `
-IncludePatterns 'HostAdapters/*','Portal/*'
```

The pattern `HostAdapters/*` includes nested files such as `HostAdapters/Dna/adapter.dll`. Folders outside those patterns, such as `Other Folder`, are ignored. BrainDrift inventories files, so empty folders are not recorded in the baseline.

## Deployment zero behavior

When `BaselinePath` does not exist yet, the drift check should not try to compare the server against an unknown reference. That scenario represents the first deployment bootstrap.

Recommended operational flow:

1. Run the first deployment without comparing against a missing reference.
2. Create the first trusted baseline after the deployment succeeds by using `-PromoteBaselineOnSuccess`.
3. On later deployments, let the normal pre-deployment drift gate compare the baseline against the current server.

When called directly, `scripts\Test-DeploymentDrift.ps1` still returns exit code `3` for a missing baseline because it is only the drift check. The sample `run-deploy.ps1` treats a missing baseline as deployment zero, skips the precheck, and can create the first trusted baseline after a successful deployment.

`scripts\Test-DeploymentDrift.ps1` also writes a prominent `DEPLOYMENT DRIFT SUMMARY` table to the console/log output for completed checks, including the exit code, report path, drift status, conflict status, key file counts, and recommended action.

## Sample local deployment package (integration example)
The repository includes a minimal, standalone example deployment package under `_sample\deploy-package`. It demonstrates how to keep deployment logic separate from BrainDrift while calling BrainDrift scripts for the pre-deployment drift check, baseline creation, deployment copy, and optional baseline refresh.

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
- `run-deploy.ps1` reads omitted defaults from `config\deployment-drift.config.json` using the same precedence as the core scripts: explicit parameters first, then config values, then sample fallback values.
- `run-deploy.ps1` follows the same multi-step shape recommended for Harness: prepare incoming package, verify baseline vs current server, run deploy, optionally refresh the baseline after successful deploy, then clean temporary artifacts.
- `run-deploy.ps1` does not compare the incoming package to the server during the precheck. It only checks whether the current server still matches the trusted baseline.
- If `BaselinePath` points to a directory instead of a `.json` file, the active baseline file is named `ApplicationName[.EnvironmentName].baseline.json`.
- If the configured baseline is missing, `run-deploy.ps1` treats the run as deployment zero and skips the pre-deployment drift gate.
- To capture the current server state before deployment zero, explicitly pass `-CreateBaselineIfMissing`.
- When the baseline is missing, `-FailOnDrift` cannot apply because there is no trusted reference yet; it applies to future runs after the baseline exists.
- If a baseline exists and drift is detected, `run-deploy.ps1` stops before `deploy` when `-FailOnDrift` is supplied.
- If `-PromoteBaselineOnSuccess` is supplied, `run-deploy.ps1` creates or refreshes the baseline after a successful deployment and archives the previous baseline version when one exists.
- If drift is detected and allowed because `-FailOnDrift` was omitted, the run can still exit `0`, but the final summary status is `SucceededWithDriftWarning`.
- If no baseline exists and the run proceeds as deployment zero, the final summary status is `SucceededDeploymentZero`.

Passing the `-FailOnDrift` option
-------------------------------

The `run-deploy.ps1` script accepts `-FailOnDrift` as a switch. Behaviour:

- If you include the switch (`-FailOnDrift`) the orchestrator will abort the deployment when drift is detected during the pre-deployment gate.
- If you omit the switch, the orchestrator will log a visible warning when drift is detected but will continue with `deploy`.

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

- Default: if you do not bind the parameter, the orchestrator treats the run as deployment zero, skips the pre-deployment drift gate, and does not create a pre-deployment baseline.

- To create an initial baseline from the current server state before deployment, explicitly pass `-CreateBaselineIfMissing`. This is useful when you need an audit snapshot of the pre-deployment server state.

- To create the first trusted deployment baseline after the deployment succeeds, pass `-PromoteBaselineOnSuccess`. This is the preferred deployment zero path when the baseline should represent the first successful deployment.

Examples:

```powershell
# Deployment zero: deploy first, then create the first trusted baseline
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -PromoteBaselineOnSuccess

# Optional pre-deployment snapshot: create an initial baseline if missing
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -CreateBaselineIfMissing

# Optional pre-deployment snapshot plus final promotion
.\_sample\deploy-package\run-deploy.ps1 -IncomingPackagePath $incoming -RootPath $target -BaselinePath $baseline -ReportPath $reports -CreateBaselineIfMissing -PromoteBaselineOnSuccess
```
If you call `scripts\Test-DeploymentDrift.ps1` directly and the baseline is missing, it exits with code `3`.

## Configuration example

The sample config file at `config\deployment-drift.config.json` can control the default archive retention used by `New-DeploymentBaseline.ps1`, and it can also supply defaults that `Test-DeploymentDrift.ps1` and `_sample\deploy-package\run-deploy.ps1` consume when their own parameters are omitted.

```json
{
  "ApplicationName": "MyApp",
  "EnvironmentName": "QA",
  "RootPath": "C:\\inetpub\\MyApp",
  "BaselinePath": "C:\\Deployments\\MyApp\\baseline\\last-successful-deployment.json",
  "ReportPath": "C:\\Deployments\\MyApp\\reports",
  "IncludePatterns": ["HostAdapters/*", "Portal/*"],
  "ExcludePatterns": ["logs*", "temp*", "App_Data\\cache*"],
  "HashAlgorithm": "SHA256",
  "ArchiveRetentionCount": 10
}
```

Set `ArchiveRetentionCount` to `0` if you want to keep every archived baseline version.
