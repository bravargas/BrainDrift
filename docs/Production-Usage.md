# BrainDrift 1.0.0 Production Usage

This package is intentionally minimal. It includes only the scripts and module needed to run BrainDrift in production:

- `src\DeploymentDrift.Common.psd1`
- `src\DeploymentDrift.Common.psm1`
- `scripts\Test-DeploymentDrift.ps1`
- `scripts\New-DeploymentBaseline.ps1`
- `scripts\Export-DeploymentFileManifest.ps1`
- `config\deployment-drift.config.json`

No sample apps, sample deployment package, or test files are included in the production package.

## Standalone script block

Use the block below when you control the deployment from one PowerShell wrapper script. For Harness pipelines with separate command steps, use the multi-step Harness example in the next section.

This direct `Test-DeploymentDrift.ps1` pattern is intentionally strict: if the baseline is missing, it exits with code `3`. For a first deployment, either handle code `3` as deployment zero in your orchestrator and create the baseline after successful deployment, or create an optional pre-deployment snapshot first with `New-DeploymentBaseline.ps1`.

```powershell
$brainDriftRoot = $env:BRAINDRIFT_ROOT
if ([string]::IsNullOrWhiteSpace($brainDriftRoot)) {
    $brainDriftRoot = $PSScriptRoot
}

$scriptsPath = Join-Path $brainDriftRoot 'scripts'
$configPath = Join-Path $brainDriftRoot 'config\deployment-drift.config.json'
$reportPath = $env:BRAINDRIFT_REPORT_PATH
$baselinePath = $env:BRAINDRIFT_BASELINE_PATH
$rootPath = $env:BRAINDRIFT_ROOT_PATH
$applicationName = $env:BRAINDRIFT_APPLICATION_NAME
$environmentName = $env:BRAINDRIFT_ENVIRONMENT_NAME

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'Test-DeploymentDrift.ps1') `
  -ApplicationName $applicationName `
  -EnvironmentName $environmentName `
  -RootPath $rootPath `
  -BaselinePath $baselinePath `
  -ReportPath $reportPath `
  -ConfigPath $configPath `
  -FailOnDrift

switch ($LASTEXITCODE) {
    0 { }
    1 { throw "BrainDrift detected server drift. Review the report in $reportPath." }
    3 { throw "BrainDrift baseline is missing at $baselinePath. Create the first trusted baseline before deploying." }
    default { throw "BrainDrift failed with exit code $LASTEXITCODE." }
}

# Run your deployment logic here.

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'New-DeploymentBaseline.ps1') `
  -ApplicationName $applicationName `
  -DeploymentId $env:HARNESS_EXECUTION_ID `
  -EnvironmentName $environmentName `
  -ServerName $env:COMPUTERNAME `
  -RootPath $rootPath `
  -BaselinePath $baselinePath `
  -ConfigPath $configPath

if ($LASTEXITCODE -ne 0) {
    throw "BrainDrift baseline refresh failed with exit code $LASTEXITCODE."
}
```

`Test-DeploymentDrift.ps1` prints a highlighted `DEPLOYMENT DRIFT SUMMARY` table on every completed drift check. The table includes the final status, exit code, machine, baseline path, report path, drift/conflict flags, key file counts, and the recommended action so the result stands out in production logs.

## Harness command steps example

In Harness, keep BrainDrift as separate `Command` steps around your existing deployment flow:

1. Run BrainDrift verification before `predeploy`.
2. Run your normal `predeploy` and `deploy` steps.
3. Create or refresh the baseline only after deployment succeeds.
4. Continue with cleanup/finalization steps.

That sequence keeps the baseline tied to the last successful deployment, not to a deployment attempt that may fail midway.

### Step 1: BrainDrift verification

This step should run before `Run Pre-Deploy`. It fails the pipeline on drift when `-FailOnDrift` is enabled. If the baseline is missing, it treats the run as deployment zero and lets the pipeline continue so the first baseline can be created after deploy.

```yaml
- step:
    type: Command
    name: BrainDrift Verify
    identifier: braindrift_verify
    spec:
      onDelegate: false
      commandUnits:
        - identifier: braindrift_verify_script
          name: braindrift_verify_script
          type: Script
          spec:
            shell: PowerShell
            source:
              type: Inline
              spec:
                script: |
                  $ErrorActionPreference = 'Stop'

                  $brainDriftRoot = 'C:\Tools\BrainDrift'
                  $scriptsPath = Join-Path $brainDriftRoot 'scripts'
                  $configPath = Join-Path $brainDriftRoot 'config\deployment-drift.config.json'

                  $applicationName = 'XD'
                  $environmentName = 'PDX'
                  $rootPath = 'C:\Architect\2251_MU'
                  $baselinePath = 'C:\Deployments\baselines'
                  $reportPath = 'C:\Deployments\reports'

                  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'Test-DeploymentDrift.ps1') `
                    -ApplicationName $applicationName `
                    -EnvironmentName $environmentName `
                    -RootPath $rootPath `
                    -BaselinePath $baselinePath `
                    -ReportPath $reportPath `
                    -ConfigPath $configPath `
                    -FailOnDrift

                  switch ($LASTEXITCODE) {
                      0 { Write-Host 'BrainDrift precheck passed.' }
                      1 { throw "BrainDrift detected server drift. Review reports in $reportPath." }
                      3 {
                          Write-Warning "BrainDrift baseline is missing at $baselinePath. Continuing as deployment zero."
                      }
                      default { throw "BrainDrift precheck failed with exit code $LASTEXITCODE." }
                  }
      outputVariables: []
      environmentVariables: []
    timeout: 10m
    when:
      stageStatus: Success
      condition: "\"<+repeat.item>\".contains(\"<+pipeline.variables.deploySite.split('\\-')[3]>\")"
    strategy:
      repeat:
        items: <+infra.hosts>
```

After this step, keep your existing steps, for example:

```yaml
- step:
    type: Command
    name: Run Pre-Deploy
    identifier: run_pre_deploy
    spec: ...
    timeout: 10m
    when:
      stageStatus: Success
      condition: "\"<+repeat.item>\".contains(\"<+pipeline.variables.deploySite.split('\\-')[3]>\")"
    strategy:
      repeat:
        items: <+infra.hosts>

- step:
    type: Command
    name: Run Deploy
    identifier: run_deploy
    spec: ...
    timeout: 10m
    when:
      stageStatus: Success
      condition: "\"<+repeat.item>\".contains(\"<+pipeline.variables.deploySite.split('\\-')[3]>\")"
    strategy:
      repeat:
        items: <+infra.hosts>
```

### Step 2: BrainDrift baseline refresh

Run this step immediately after the deployment step succeeds, before cleanup. It creates the first baseline during deployment zero or refreshes the existing baseline after a successful deployment.

```yaml
- step:
    type: Command
    name: BrainDrift Refresh Baseline
    identifier: braindrift_refresh_baseline
    spec:
      onDelegate: false
      commandUnits:
        - identifier: braindrift_refresh_baseline_script
          name: braindrift_refresh_baseline_script
          type: Script
          spec:
            shell: PowerShell
            source:
              type: Inline
              spec:
                script: |
                  $ErrorActionPreference = 'Stop'

                  $brainDriftRoot = 'C:\Tools\BrainDrift'
                  $scriptsPath = Join-Path $brainDriftRoot 'scripts'
                  $configPath = Join-Path $brainDriftRoot 'config\deployment-drift.config.json'

                  $applicationName = 'XD'
                  $environmentName = 'PDX'
                  $rootPath = 'C:\Architect\2251_MU'
                  $baselinePath = 'C:\Deployments\baselines'
                  $deploymentId = '<+pipeline.executionId>'

                  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'New-DeploymentBaseline.ps1') `
                    -ApplicationName $applicationName `
                    -DeploymentId $deploymentId `
                    -EnvironmentName $environmentName `
                    -ServerName $env:COMPUTERNAME `
                    -RootPath $rootPath `
                    -BaselinePath $baselinePath `
                    -ConfigPath $configPath

                  if ($LASTEXITCODE -ne 0) {
                      throw "BrainDrift baseline refresh failed with exit code $LASTEXITCODE."
                  }

                  Write-Host 'BrainDrift baseline was created or refreshed after successful deployment.'
      outputVariables: []
      environmentVariables: []
    timeout: 10m
    when:
      stageStatus: Success
      condition: "\"<+repeat.item>\".contains(\"<+pipeline.variables.deploySite.split('\\-')[3]>\")"
    strategy:
      repeat:
        items: <+infra.hosts>
```

Keep the folder selection in `config\deployment-drift.config.json`. For the `C:\Architect\2251_MU` layout, use:

```json
"IncludePatterns": [
  "HostAdapters/*",
  "Portal/*"
]
```

## Deployment zero handling

For the first deployment, there may be no previous baseline. In that case, do not compare the server against an unknown reference. Let the deployment run, then create the first trusted baseline after the deployment succeeds.

One simple production pattern is to change only the `3` branch in the precheck switch:

```powershell
$deploymentZero = $false

switch ($LASTEXITCODE) {
    0 { }
    1 { throw "BrainDrift detected server drift. Review the report in $reportPath." }
    3 {
        $deploymentZero = $true
        Write-Warning "BrainDrift baseline is missing at $baselinePath. Continuing as deployment zero."
    }
    default { throw "BrainDrift failed with exit code $LASTEXITCODE." }
}

# Run your deployment logic here.

# After successful deployment, create the first trusted baseline.
```

If you need an audit snapshot of the server state before deployment zero, run `New-DeploymentBaseline.ps1` before the deployment as an explicit pre-deployment bootstrap step. Otherwise, prefer creating the first trusted baseline after the successful deployment.

## Multiple folders under one root

When the application content lives under a shared parent but only some child folders should be checked, set `RootPath` to the shared parent and configure folder include patterns.

For example, to verify only these folders:

```text
C:\Architect\2251_MU\HostAdapters
C:\Architect\2251_MU\Portal
```

use this configuration:

```json
{
  "RootPath": "C:\\Architect\\2251_MU",
  "IncludePatterns": [
    "HostAdapters/*",
    "Portal/*"
  ]
}
```

`HostAdapters/*` includes nested files such as `HostAdapters/Dna/adapter.dll`. Sibling folders such as `Other Folder` are ignored. BrainDrift inventories files, so empty folders are not recorded in the baseline.

## Optional incoming manifest for direct analysis

The production gate shown above does not need the incoming package. It checks the trusted baseline against the current server. If you intentionally want direct three-way analysis with `Test-DeploymentDrift.ps1`, you can generate an incoming manifest and place it at `$reportPath\incoming-manifest.json`; the script will use it when present.

```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsPath 'Export-DeploymentFileManifest.ps1') `
  -SourcePath $env:BRAINDRIFT_SOURCE_PATH `
  -ManifestPath (Join-Path $reportPath 'incoming-manifest.json')
```

## Required inputs

- `BRAINDRIFT_ROOT`: path where the BrainDrift package was unpacked.
- `BRAINDRIFT_ROOT_PATH`: application root on the target server. For multiple selected folders under one parent, use the common parent, such as `C:\Architect\2251_MU`.
- `BRAINDRIFT_BASELINE_PATH`: path to the baseline directory or explicit `.json` file (defaults to `C:\Deployments\baselines`). If a directory is supplied, the active baseline file is named `ApplicationName[.EnvironmentName].baseline.json`.
- `BRAINDRIFT_REPORT_PATH`: folder where drift reports will be written.
- `BRAINDRIFT_APPLICATION_NAME`: logical application name.
- `BRAINDRIFT_ENVIRONMENT_NAME`: logical environment name.

Configure include and exclude patterns in `config\deployment-drift.config.json`. If you prefer, you can replace the environment variables with hard-coded paths in the script block.
