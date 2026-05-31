# BrainDrift - Deployment Drift Detection (PowerShell)

BrainDrift compares three states:
- A = last successful baseline
- B = current server state
- C = incoming package

## What’s included
- `src/DeploymentDrift.Common.psm1` - shared helpers and comparison engine
- `src/DeploymentDrift.Common.psd1` - module manifest
- `scripts/New-DeploymentBaseline.ps1` - create a baseline from a trusted server
- `scripts/Test-DeploymentDrift.ps1` - run the pre-deployment drift check
- `scripts/Export-DeploymentFileManifest.ps1` - generate an incoming package manifest
- `_sample/deploy-package/` - standalone deployment simulator and conflict demo
- `tests/DeploymentDrift.Tests.ps1` - Pester integration tests

## Quick start

```powershell
Import-Module .\src\DeploymentDrift.Common.psd1 -Scope Local -Force
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-DeploymentDrift.ps1 `
  -ApplicationName 'MyApp' -EnvironmentName 'Prod' `
  -RootPath 'C:\inetpub\wwwroot' `
  -BaselinePath 'C:\deploy\baseline\last-successful-deployment.json' `
  -IncomingPackagePath 'C:\staging\pkg' `
  -ReportPath 'C:\deploy\reports'
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\_sample\deploy-package\trigger-conflict.ps1
```

## Exit codes
- `0` - no drift
- `1` - drift detected and `-FailOnDrift` is enabled
- `2` - script error
- `3` - baseline missing

## Docs
- [Usage guide](docs/DeploymentDrift.Usage.md)
- [Windows server drift overview](docs/Configuration-Drift-Detection-for-Windows-Server-Deployments.md)
- [Changelog](docs/CHANGELOG.md)

## Testing

```powershell
Import-Module Pester
Invoke-Pester -Script .\tests\DeploymentDrift.Tests.ps1
```
