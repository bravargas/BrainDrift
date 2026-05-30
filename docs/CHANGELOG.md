# Changelog

## Unreleased

- Added a reusable PowerShell drift detection solution for Windows deployment workflows.
- Added baseline generation, drift testing, and file manifest export scripts.
- Added a shared PowerShell module for inventory, JSON, pattern matching, and drift report generation.
- Added example configuration and Harness-friendly usage examples.
- Added controlled handling and documentation for deployment-zero scenarios where the baseline file does not yet exist.
- Added `.nupkg` simulator support and a pre-deployment conflict gate that stops deployment when the drift report flags a conflict.
- Added a single-command conflict trigger helper for the sample deployment package.
- Aligned `_sample/deploy-package/package-content/web.config` with `C:\Architect\2251_MU\Portal\Web.config`.
- Defaulted `_sample/deploy-package/pack-nupkg.ps1` to the bundled `tools\nuget.exe`.