# Configuration Drift Detection for Windows Server Deployments

## Executive Summary

Windows Server deployments often combine automated delivery from GitHub Actions, package orchestration through Harness, and file copy steps that place application binaries and configuration files on target servers. That workflow is reliable for delivery, but it creates a common operational risk: files on the server can be changed manually after a successful deployment, especially configuration files such as `web.config`, `appsettings.json`, XML settings, or other environment-specific content.

The core problem is not whether the incoming deployment package differs from the current server state. Of course it does, because a later release is expected to contain official changes. The real question is whether the server has drifted away from the last successful official deployment baseline.

The default deployment gate compares two versions:

- A = the last successful official deployment baseline.
- B = the current server state.

If B differs from A, then the server was modified after the last successful deployment. That is drift. The incoming package is not part of the default gate because deployment packages often have a different internal layout from the target server and normally contain legitimate release changes.

This repository implements that model with PowerShell scripts that can be run manually, scheduled, or called from Harness as part of a deployment pipeline.

## Problem Statement

Consider a simple release sequence.

Deployment 1 installs:

- `web.config`
- `file1.dll`

After Deployment 1 completes, a support engineer changes `web.config` directly on the server to address an urgent issue. That change is not committed back to GitHub.

Later, developers make official changes to `web.config` in GitHub and produce Deployment 2.

Before Deployment 2 overwrites `web.config` on the server, the deployment process must detect that the current server copy is no longer the same file that was officially installed by Deployment 1.

That means the process must answer this question:

- Is the current server file still the same as the last successful deployment baseline?

It must not answer this incorrect question:

- Is the incoming package different from the server?

That second check is too shallow. It would treat normal release changes as drift and would not distinguish between a legitimate new version and an unauthorized manual edit.

## Core Concept: Baseline-To-Server Comparison

The default drift detection process uses two file states.

- `LastDeployedBaseline` captures the hash and metadata of the file that was last known to be successfully deployed.
- `CurrentServerState` captures the actual file currently present on the server before the new deployment starts.

The baseline is the control point. The current server file is compared against it before deployment starts.

| Comparison | Meaning |
|---|---|
| `CurrentServer == LastDeployed` | No server-side drift |
| `CurrentServer != LastDeployed` | Server-side drift detected |

The important point is that a change in the incoming package is not drift by itself. BrainDrift's default orchestration only asks whether the current server still matches the last trusted baseline.

## Why a Simple Hash Comparison Against GitHub Is Not Enough

A direct comparison between the incoming package and the server is not sufficient because GitHub is not the deployment baseline. GitHub contains the source of truth for future builds, but not every commit is deployed immediately. Hotfixes may be merged, release branches may move independently, and multiple versions can exist in flight.

The correct baseline is the last successful official deployment state. That baseline represents what was actually installed and validated on the server. Drift detection must compare the current server file to that baseline, not to the latest repository revision.

This distinction matters because:

- The latest commit in GitHub may never have been deployed.
- A deployment package may intentionally include changes that are unrelated to drift.
- A support change on the server must be detected even when the new deployment also changes the same file.

The process therefore uses the last successful deployment as the authoritative reference for drift detection.

## Deployment Zero and Initial Baseline Bootstrap

Some servers are built manually for the first time before automated deployment controls are enabled. In that situation there is no trusted baseline yet, so the drift check cannot compare the current server state against a previous official deployment.

That case should be treated as initialization, not as drift.

Recommended handling:

- Run the first deployment without comparing against a missing reference.
- Create the first trusted baseline after the deployment succeeds.
- Optionally create an initial baseline before deployment only when an audit snapshot of the current server state is required.
- Enable normal drift detection after the baseline exists.

When `Test-DeploymentDrift.ps1` is called directly, a missing baseline is treated as a controlled condition with exit code `3`. The sample `run-deploy.ps1` handles that same condition as deployment zero: it skips the pre-deployment drift gate, runs the deployment, and creates the first trusted baseline after success when `-PromoteBaselineOnSuccess` is supplied. If `-CreateBaselineIfMissing` is supplied, it creates an optional pre-deployment baseline snapshot before deploying.

## Process Overview

### After Successful Deployment

1. Generate a new baseline file from the deployed files on the server.
2. Store file hashes and metadata.
3. Save the baseline as JSON.

The baseline should only be updated after the deployment has completed successfully and validation has passed.

### Before the Next Deployment

1. Load the previous baseline.
2. Calculate hashes for the current server files.
3. Compare baseline versus current server state.
4. Detect drift, missing files, and new unexpected files.
5. Generate a JSON report.

### If Drift Exists

1. Stop the deployment or require manual approval.
2. Review the drift report.
3. Decide whether the manual change should be preserved, merged, or overwritten.

### After the Deployment Succeeds

1. Create a new baseline from the deployed state.
2. Replace the previous baseline only when the deployment has been verified.

## Required Files and Scripts

### `src/DeploymentDrift.Common.psm1`

This shared module contains reusable helper functions so the entrypoint scripts stay small and consistent.

It provides functions such as:

- `Get-NormalizedRelativePath`
- `Test-PathMatchesPattern`
- `Get-FileInventory`
- `Read-JsonFile`
- `Write-JsonFile`
- `Compare-FileInventories`
- `New-DriftReport`

The module centralizes hashing, path normalization, pattern filtering, JSON handling, and drift classification.

### `New-DeploymentBaseline.ps1`

This script creates or updates the baseline JSON file after a successful deployment.

It:

- Scans files under the target root path.
- Filters by include and exclude patterns.
- Calculates hashes.
- Stores relative path, hash, file size, last write time, and hash algorithm.
- Saves the result as JSON.
- Archives any existing baseline to a versioned `archive\<baseline-name>\` folder before overwriting the active baseline file.
- Retains the 10 most recent archived baselines by default; callers can override this with `-ArchiveRetentionCount`.
- Returns a PowerShell object for automation or troubleshooting.

### `Test-DeploymentDrift.ps1`

This script performs the pre-deployment drift check.

It:

- Loads defaults from `config/deployment-drift.config.json` when values such as application name, environment name, root path, baseline path, report path, include/exclude patterns, or hash algorithm are not passed explicitly.
- Loads the baseline JSON file.
- Recalculates hashes from the current server files.
- Compares the baseline with the current server state.
- Detects modified files, missing files, and unexpected files.
- Can perform optional three-way classification only when `Test-DeploymentDrift.ps1` is called directly and an `incoming-manifest.json` already exists in the report folder.
- Writes a JSON drift report.
- Returns a useful object for pipeline consumption.

### `run-deploy.ps1`
This sample orchestration script demonstrates how to combine the BrainDrift scripts with a deployment package.

It:

- Extracts a `.nupkg` when supplied.
- Preserves a multi-step orchestration flow similar to Harness: prepare, verify, deploy, refresh baseline, and cleanup.
- Runs a pre-deployment baseline-vs-server drift check before copying files when a baseline exists.
- Treats a missing baseline as deployment zero and skips the pre-deployment drift gate.
- Can create an optional pre-deployment baseline snapshot with `-CreateBaselineIfMissing`.
- Runs the deployment copy step only after the drift decision is made.
- Optionally promotes the deployed server state to a new baseline and archives the previous baseline version.
- Reports `SucceededWithDriftWarning` when drift was detected but allowed, and `SucceededDeploymentZero` when the first run proceeds without a baseline.

### `Export-DeploymentFileManifest.ps1`

This script generates a manifest from an incoming package or deployment folder.

It:

- Recursively scans the source folder.
- Filters by include and exclude patterns.
- Calculates file hashes.
- Stores relative path, hash, file size, last write time, and hash algorithm.
- Saves the manifest as JSON.
- Returns a useful PowerShell object.

### `config/deployment-drift.config.json`

This JSON file provides example configuration values for a typical application.

It is intended as a reusable starting point for deployment teams and pipeline authors.

The same file is used in two places:

- `scripts/Test-DeploymentDrift.ps1` reads it as a fallback source for missing parameters.
- `scripts/New-DeploymentBaseline.ps1` reads `ArchiveRetentionCount` from it unless the caller passes `-ArchiveRetentionCount` explicitly.

It can also control baseline archive retention through `ArchiveRetentionCount`.

When several application folders live under the same parent, use the parent as `RootPath` and restrict the inventory with folder include patterns. For example, `RootPath = C:\Architect\2251_MU` with `IncludePatterns = ["HostAdapters/*", "Portal/*"]` includes files under `HostAdapters\Dna` and `Portal`, while ignoring sibling folders such as `Other Folder`.

## Baseline JSON Example

The baseline file records the last successful official deployment. A simplified example looks like this:

```json
{
  "metadata": {
    "applicationName": "MyApp",
    "deploymentId": "DEPLOY-001",
    "environmentName": "QA",
    "serverName": "WEB01",
    "rootPath": "C:\\inetpub\\MyApp",
    "createdAtUtc": "2026-05-30T17:22:00Z",
    "createdBy": "DOMAIN\\DeployUser",
    "hashAlgorithm": "SHA256"
  },
  "files": [
    {
      "relativePath": "web.config",
      "fullPath": "C:\\inetpub\\MyApp\\web.config",
      "hash": "AAA",
      "fileSize": 1204,
      "lastWriteTimeUtc": "2026-05-30T16:55:00Z",
      "hashAlgorithm": "SHA256"
    },
    {
      "relativePath": "file1.dll",
      "fullPath": "C:\\inetpub\\MyApp\\file1.dll",
      "hash": "BBB",
      "fileSize": 81920,
      "lastWriteTimeUtc": "2026-05-30T16:55:00Z",
      "hashAlgorithm": "SHA256"
    }
  ]
}
```

The important elements are the metadata and the file inventory. The baseline is the reference point for future drift checks.

## Drift Report JSON Example

The drift report records what changed, how it was classified, and what action is recommended. A simplified baseline-vs-server drift example looks like this:

```json
{
  "metadata": {
    "applicationName": "MyApp",
    "environmentName": "QA",
    "rootPath": "C:\\inetpub\\MyApp",
    "baselinePath": "C:\\Deployments\\MyApp\\baselines\\MyApp.baseline.json",
    "generatedAtUtc": "2026-05-30T17:30:00Z",
    "generatedBy": "DOMAIN\\DeployUser",
    "hashAlgorithm": "SHA256"
  },
  "summary": {
    "baselineFileCount": 2,
    "currentFileCount": 2,
    "incomingFileCount": 0,
    "modifiedCount": 1,
    "missingCount": 0,
    "newUnexpectedCount": 0,
    "incomingChangeCount": 0,
    "conflictCount": 0,
    "unchangedCount": 0
  },
  "classification": {
    "hasDrift": true,
    "hasConflict": false,
    "recommendedAction": "Investigate drift before deploying."
  },
  "files": [
    {
      "relativePath": "web.config",
      "baselineHash": "AAA",
      "currentHash": "XXX",
      "incomingHash": null,
      "isMissing": false,
      "isNewUnexpected": false,
      "isModified": true,
      "isConflict": false,
      "classification": "ModifiedOnCurrentServer",
      "recommendedAction": "Review the server-side change before deploying."
    }
  ],
  "recommendedAction": "Investigate drift before deploying."
}
```

This example shows the intended behavior clearly:

- `web.config` was changed on the server after the last successful deployment.
- The deployment gate does not need to inspect the incoming package to detect that drift.

## Recommended Harness Integration

The following flow is recommended for Harness-based deployments.

1. Download or extract the deployment package.
2. Run the pre-deployment drift check by calling `Test-DeploymentDrift.ps1`.
3. If drift is detected, stop the deployment or pause for manual approval.
4. Deploy the files only after the drift decision is made.
5. Run smoke tests and any application validation steps.
6. If the deployment succeeds, refresh the baseline so it represents the last successful deployment.

This sequence ensures that the baseline always represents the last successful deployment, not the last attempted deployment. In the sample `run-deploy.ps1`, baseline refresh is opt-in with `-PromoteBaselineOnSuccess`.

For production environments, a manual approval step in Harness is strongly recommended when drift is detected or when a deployment affects critical configuration files.

If you are implementing the initial deployment bootstrap, allow the framework to continue when the baseline is missing, then create the baseline after the first successful deployment. Use `-CreateBaselineIfMissing` only when you intentionally want to capture the pre-deployment server state before that first run.

## Recommended Exit Codes

Use the following exit code convention for automation and pipeline handling:

- `0` = No drift detected.
- `1` = Drift detected and `FailOnDrift` was enabled.
- `2` = Script error or invalid input.
- `3` = Baseline file missing.

For direct drift checks, exit code `3` is the expected outcome until the first trusted baseline has been created. In the sample `run-deploy.ps1`, deployment zero is handled by skipping the precheck instead of returning `3`.

These exit codes make it easier for Harness or other orchestration tooling to route the result to failure handling, manual approval, or operational alerting.

`Test-DeploymentDrift.ps1` also writes a prominent `DEPLOYMENT DRIFT SUMMARY` table before exiting. The table includes the final status, exit code, machine, baseline path, report path, drift/conflict flags, key file counts, and recommended action so operators can identify the result quickly in deployment logs.

## Operational Recommendations

The following practices make drift detection more reliable and easier to operate.

- Store the baseline per application, environment, and server.
- Protect the baseline directory with NTFS permissions so it cannot be casually edited.
- Keep historical drift reports for troubleshooting and audits.
- Start with critical files only, then expand the include list over time.
- Include `web.config`, `appsettings.json`, XML config files, JSON config files, and DLLs.
- Exclude logs, temp folders, caches, and generated runtime files.
- Do not update the baseline if the deployment failed.
- Update the baseline only after a successful deployment.
- Review drift reports before overwriting files.
- Use manual approval in Harness for production environments when drift is detected.

The example configuration file in this repository reflects these recommendations:

- Set `RootPath` to the shared application parent.
- Use folder includes such as `HostAdapters/*` and `Portal/*` when only selected child folders should be checked.
- Use file-type includes such as `*.config`, `*.json`, `*.xml`, and `*.dll` when the whole root should be scanned by file type.

Typical exclusions include:

- `logs*`
- `temp*`
- `App_Data\cache*`

## Example Scenario

Use the following scenario as the expected operational outcome.

### Deployment 1 baseline

- `web.config = AAA`
- `file1.dll = BBB`

### Current server before Deployment 2

- `web.config = XXX`
- `file1.dll = BBB`

### Incoming Deployment 2 package

- `web.config = CCC`
- `file1.dll = DDD`

### Expected result

- `web.config`: server-side drift detected.
- `file1.dll`: no server-side drift.
- Recommended action: stop deployment and review `web.config` before deploying.

This is the precise reason the process uses the A/B/C model. It separates ordinary release changes from unauthorized server-side edits.

## Limitations

This approach is effective, but it has limits.

- Hash comparison detects changes but does not explain semantic intent.
- Encrypted or machine-specific values may require special handling.
- Some files may legitimately change at runtime and should be excluded.
- The first baseline must be created from a trusted server state.
- If the baseline itself is manually modified, results cannot be trusted.

These limitations are normal for file-based drift detection. The process should be used as an operational guardrail, not as a substitute for application-specific validation.

## Future Enhancements

The current PowerShell implementation can be extended in several useful directions.

- Generate human-readable HTML reports.
- Compare XML and JSON semantically.
- Integrate with Teams or email notifications.
- Store baseline artifacts in a central repository.
- Add IIS configuration drift detection.
- Add Windows service configuration drift detection.
- Add registry key drift detection.
- Add certificate drift detection.

These enhancements would expand the solution from file drift detection into a broader Windows configuration compliance framework.
