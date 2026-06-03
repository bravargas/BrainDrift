# Changelog

## Unreleased

- Updated `_sample/deploy-package/run-deploy.ps1` to preserve a Harness-like multi-step orchestration shape: prepare incoming package, verify baseline vs current server, deploy, optionally refresh baseline after success, and clean temporary artifacts.
- Updated `_sample/deploy-package/run-deploy.ps1` deployment-zero behavior so a missing baseline skips the pre-deployment drift gate by default and can create the first trusted baseline after successful deployment when `-PromoteBaselineOnSuccess` is supplied.
- Kept `-CreateBaselineIfMissing` as an explicit optional pre-deployment baseline snapshot for first-run audit scenarios.
- Added final run statuses for successful-but-not-clean executions: `SucceededWithDriftWarning` when drift was allowed and `SucceededDeploymentZero` when the first run proceeds without a baseline.
- Updated `config/deployment-drift.config.json` to use a shared root with folder-scoped includes: `RootPath = C:\Architect\2251_MU` and `IncludePatterns = ["HostAdapters/*", "Portal/*"]`.
- Added regression coverage that verifies `HostAdapters/*` and `Portal/*` include nested files such as `HostAdapters/Dna/...` while ignoring sibling folders such as `Other Folder`.
- Updated production documentation with Harness multi-step command examples: BrainDrift verification before predeploy/deploy and baseline refresh after successful deploy, before cleanup.
- Updated docs to distinguish direct `Test-DeploymentDrift.ps1` missing-baseline exit code `3` from `run-deploy.ps1` deployment-zero orchestration.
- Updated `_sample/deploy-package/run-deploy.ps1` so its pre-deployment gate compares only the trusted baseline against the current server state. The incoming package is extracted and deployed, but it is not used for drift detection in the orchestrated sample flow.
- Updated `_sample/deploy-package/run-deploy.ps1` so `-CreateBaselineIfMissing` takes precedence over `-FailOnDrift` when the configured baseline file is missing.
- Added a prominent `DEPLOYMENT DRIFT SUMMARY` table to `scripts/Test-DeploymentDrift.ps1` so production usage gets the highlighted result directly from the core drift check.
- Added `-ConfigPath` support to `_sample/deploy-package/run-deploy.ps1`; omitted values now resolve from `config/deployment-drift.config.json` before sample fallback defaults are used.
- Added regression coverage for `run-deploy.ps1` config-default resolution.
- Updated documentation to describe the current baseline-vs-server gate and to mark incoming manifests as optional direct-analysis input for `Test-DeploymentDrift.ps1`, not part of the sample `run-deploy.ps1` gate.
- Removed `_sample/deploy-package/predeploy.ps1` from the sample flow because incoming package manifests are no longer part of the orchestrated deployment gate.
- `_sample/deploy-package/run-deploy.ps1` now defaults to the bundled sample package, sample server, baseline, and reports paths so it can be used directly for local validation without passing parameters.
- `scripts/Test-DeploymentDrift.ps1` and `scripts/New-DeploymentBaseline.ps1` now use a shared configuration resolution helper, including `BaselinePath` fallback in drift checks when it is not supplied explicitly, and they continue to match the baseline filename pattern used by the baseline generator so existing baselines are reused instead of being recreated.
- Added a reusable PowerShell drift detection solution for Windows deployment workflows.
- Added baseline generation, drift testing, and file manifest export scripts.
- Added a shared PowerShell module for inventory, JSON, pattern matching, and drift report generation.
- Added example configuration and Harness-friendly usage examples.
- Added a production NuGet manifest (`BrainDrift.nuspec`) and a minimal production usage guide for direct script-block integration.
- Added controlled handling and documentation for deployment-zero scenarios where the baseline file does not yet exist.
- Added `.nupkg` simulator support to the sample deployment package.
- Aligned `_sample/deploy-package/package-content/web.config` with `C:\Architect\2251_MU\Portal\Web.config`.
- Defaulted `_sample/deploy-package/pack-nupkg.ps1` to the bundled `tools\nuget.exe`.
 - [2026-05-30] Detected server drift during manual test: `Portal/Web.config` was modified on the server compared to the baseline (see report). Report: `C:\Users\Brainer\AppData\Local\Temp\BrainDriftReports\drift-report-20260530-211926.json`. Recommended action: investigar la modificación del `web.config` o restaurar desde el backup antes de desplegar.
- Updated `_sample/deploy-package/run-deploy.ps1` behavior for missing baselines and baseline refresh:
	- Default behavior treats a missing baseline as deployment zero and skips the pre-deployment drift gate because no trusted reference exists yet.
	- To create an optional pre-deployment baseline snapshot, callers may pass `-CreateBaselineIfMissing`.
	- To create the first trusted baseline after a successful deployment, callers may pass `-PromoteBaselineOnSuccess`.
	- Baseline refresh after a successful deployment is now opt-in and occurs only when `-PromoteBaselineOnSuccess` is supplied.
- Removed `IgnoreDrift` from the drift-test and deployment orchestration scripts so `FailOnDrift` is the only switch that changes drift exit behavior.
- Added a regression test that verifies server-side `web.config` drift returns exit code `1` when `-FailOnDrift` is enabled.
- 2026-05-30: Renamed and standardized CLI parameter names across tools to the canonical `Test-DeploymentDrift.ps1` interface:
	- `RootPath`, `BaselinePath`, `ReportPath` are canonical parameter names used by `run-deploy.ps1`.
	- Sample package scripts now use `SourcePath` for the incoming package content.

- 2026-05-31: Removed `IncomingPackagePath` from `scripts/Test-DeploymentDrift.ps1`. The script now detects an `incoming-manifest.json` in the configured `ReportPath` (if present) to use as incoming inventory for direct three-way analysis. Sample deploy scripts were updated to accept `SourcePath` for package content; orchestration via `run-deploy.ps1` continues to accept `-IncomingPackagePath` and forwards the extracted content to `deploy.ps1` as `-SourcePath`.
- 2026-05-31: Added baseline archival to `scripts/New-DeploymentBaseline.ps1`. When a baseline is regenerated, the previous file is copied to `archive\<baseline-name>\` with timestamped filenames so historical baselines remain available for root cause analysis.
- 2026-05-31: Added baseline archive retention to `scripts/New-DeploymentBaseline.ps1`. By default, each baseline archive keeps the 10 most recent historical copies; callers can pass `-ArchiveRetentionCount` to tune or disable cleanup.
- 2026-05-31: Moved the default archive retention setting into `config/deployment-drift.config.json` as `ArchiveRetentionCount`. `New-DeploymentBaseline.ps1` now reads that value by default and still allows `-ArchiveRetentionCount` to override it.

- 2026-06-01: Drift reports now include only changed files by default to keep reports focused; callers may pass `-IncludeUnchangedFiles` to include all files (previous behavior).
	- Removed backwards-compatibility aliases; all examples and orchestration use the new names.
- 2026-05-30: Hardened `scripts\New-DeploymentBaseline.ps1` to normalize `IncludePatterns`/`ExcludePatterns` to arrays and ensure inventory results are array-wrapped so `fileCount` calculations do not fail on singleton results.
- 2026-05-30: Updated sample scripts and docs to use the new parameter names, and updated `docs/DeploymentDrift.Usage.md` examples accordingly.
