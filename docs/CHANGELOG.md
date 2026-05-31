# Changelog

## Unreleased

- Added a reusable PowerShell drift detection solution for Windows deployment workflows.
- Added baseline generation, drift testing, and file manifest export scripts.
- Added a shared PowerShell module for inventory, JSON, pattern matching, and drift report generation.
- Added example configuration and Harness-friendly usage examples.
- Added a production NuGet manifest (`BrainDrift.nuspec`) and a minimal production usage guide for direct script-block integration.
- Added controlled handling and documentation for deployment-zero scenarios where the baseline file does not yet exist.
- Added `.nupkg` simulator support and a pre-deployment conflict gate that stops deployment when the drift report flags a conflict.
- Added a single-command conflict trigger helper for the sample deployment package.
- Aligned `_sample/deploy-package/package-content/web.config` with `C:\Architect\2251_MU\Portal\Web.config`.
- Defaulted `_sample/deploy-package/pack-nupkg.ps1` to the bundled `tools\nuget.exe`.
 - [2026-05-30] Detected server drift during manual test: `Portal/Web.config` was modified on the server compared to the baseline (see report). Report: `C:\Users\Brainer\AppData\Local\Temp\BrainDriftReports\drift-report-20260530-211926.json`. Recommended action: investigar la modificación del `web.config` o restaurar desde el backup antes de desplegar.
- Updated `_sample/deploy-package/run-deploy.ps1` behavior for missing baselines and baseline refresh:
	- Default behavior now aborts the run (exit code 3) when the configured baseline file is missing. This prevents unsafe deployments when no trusted baseline exists.
	- To allow bootstrap creation of a baseline, callers may pass `-CreateBaselineIfMissing`.
	- To explicitly continue the deployment without a baseline (unsafe), callers may pass `-SkipBaselineCreation` or the alias `-ContinueWithoutBaseline`.
	- Baseline refresh after a successful deployment is now opt-in and occurs only when `-PromoteBaselineOnSuccess` is supplied.
- Removed `IgnoreDrift` from the drift-test and deployment orchestration scripts so `FailOnDrift` is the only switch that changes drift exit behavior.
- Added a regression test that verifies server-side `web.config` drift returns exit code `1` when `-FailOnDrift` is enabled.
- Updated `_sample/deploy-package/run-deploy.ps1` so `-FailOnDrift` blocks the bootstrap path when the baseline file is missing instead of auto-creating a baseline and continuing.
- 2026-05-30: Renamed and standardized CLI parameter names across tools to the canonical `Test-DeploymentDrift.ps1` interface:
	- `RootPath`, `BaselinePath`, `ReportPath` are canonical parameter names used by `run-deploy.ps1`.
	- Sample package scripts (`deploy.ps1`, `predeploy.ps1`) now use `SourcePath` for the incoming package content.

- 2026-05-31: Removed `IncomingPackagePath` from `scripts/Test-DeploymentDrift.ps1`. The script now detects an `incoming-manifest.json` in the configured `ReportPath` (if present) to use as incoming inventory for comparison. Sample deploy scripts were updated to accept `SourcePath` for package content; orchestration via `run-deploy.ps1` continues to accept `-IncomingPackagePath` and forwards the extracted content to `predeploy.ps1`/`deploy.ps1` as `-SourcePath`.
- 2026-05-31: Added baseline archival to `scripts/New-DeploymentBaseline.ps1`. When a baseline is regenerated, the previous file is copied to `archive\<baseline-name>\` with timestamped filenames so historical baselines remain available for root cause analysis.
- 2026-05-31: Added baseline archive retention to `scripts/New-DeploymentBaseline.ps1`. By default, each baseline archive keeps the 10 most recent historical copies; callers can pass `-ArchiveRetentionCount` to tune or disable cleanup.
- 2026-05-31: Moved the default archive retention setting into `config/deployment-drift.config.json` as `ArchiveRetentionCount`. `New-DeploymentBaseline.ps1` now reads that value by default and still allows `-ArchiveRetentionCount` to override it.
	- Removed backwards-compatibility aliases; all examples and orchestration use the new names.
- 2026-05-30: Hardened `scripts\New-DeploymentBaseline.ps1` to normalize `IncludePatterns`/`ExcludePatterns` to arrays and ensure inventory results are array-wrapped so `fileCount` calculations do not fail on singleton results.
- 2026-05-30: Updated sample scripts (`deploy.ps1`, `predeploy.ps1`, `trigger-conflict.ps1`) and docs to use the new parameter names, and updated `docs/DeploymentDrift.Usage.md` examples accordingly.