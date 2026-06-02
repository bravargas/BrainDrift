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
- `docs/Production-Usage.md` - production integration block for pipelines

`scripts/Test-DeploymentDrift.ps1` can fall back to `config/deployment-drift.config.json` for defaults when parameters are omitted, and it can bootstrap a missing baseline when `-CreateBaselineIfMissing` is supplied.

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
