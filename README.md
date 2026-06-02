# BrainDrift - Deployment Drift Detection (PowerShell)

BrainDrift's deployment gate compares two states:
- A = last successful baseline
- B = current server state

The deployment package is not part of the default gate. This keeps drift detection focused on one question: did the server change after the last trusted deployment?

## What’s included
- `src/DeploymentDrift.Common.psm1` - shared helpers and comparison engine
- `src/DeploymentDrift.Common.psd1` - module manifest
- `scripts/New-DeploymentBaseline.ps1` - create a baseline from a trusted server
- `scripts/Test-DeploymentDrift.ps1` - run the pre-deployment drift check
- `scripts/Export-DeploymentFileManifest.ps1` - optional utility for direct three-way inventory analysis
- `docs/Production-Usage.md` - production integration block for pipelines

`scripts/Test-DeploymentDrift.ps1` and the sample `run-deploy.ps1` can fall back to `config/deployment-drift.config.json` for defaults when parameters are omitted. `run-deploy.ps1` validates baseline vs current server before deploying.

`scripts/Test-DeploymentDrift.ps1` prints a highlighted `DEPLOYMENT DRIFT SUMMARY` table so the final status, exit code, report path, drift counts, and recommended action stand out in production logs.

The production NuGet package is defined by [BrainDrift.nuspec](BrainDrift.nuspec) and intentionally excludes sample data, demo deploy scripts, and internal tests.

## Quick start

```powershell
Import-Module .\src\DeploymentDrift.Common.psd1 -Scope Local -Force
```

For production integration, see [docs/Production-Usage.md](docs/Production-Usage.md).

## Exit codes
- `0` - no drift
- `1` - drift detected and `-FailOnDrift` is enabled
- `2` - script error
- `3` - baseline missing

## Docs
- [Production usage](docs/Production-Usage.md)
- [Usage guide](docs/DeploymentDrift.Usage.md)
- [Windows server drift overview](docs/Configuration-Drift-Detection-for-Windows-Server-Deployments.md)
- [Changelog](docs/CHANGELOG.md)

## Testing

```powershell
Import-Module Pester
Invoke-Pester -Script .\tests\DeploymentDrift.Tests.ps1
```
