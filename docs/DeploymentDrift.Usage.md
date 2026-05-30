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