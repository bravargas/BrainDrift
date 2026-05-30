# Configuration Drift Detection for Windows Server Deployments

## Executive Summary

Windows Server deployments often combine automated delivery from GitHub Actions, package orchestration through Harness, and file copy steps that place application binaries and configuration files on target servers. That workflow is reliable for delivery, but it creates a common operational risk: files on the server can be changed manually after a successful deployment, especially configuration files such as `web.config`, `appsettings.json`, XML settings, or other environment-specific content.

The core problem is not whether the incoming deployment package differs from the current server state. Of course it does, because a later release is expected to contain official changes. The real question is whether the server has drifted away from the last successful official deployment baseline.

The correct solution is to compare three versions:

- A = the last successful official deployment baseline.
- B = the current server state.
- C = the incoming deployment package.

If B differs from A, then the server was modified after the last successful deployment. That is drift. If C also differs from A, that is normal for an updated release. The process must detect both conditions at the same time so it can identify a potential conflict before the new package overwrites server-side changes.

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

## Core Concept: Three-Way Comparison

The drift detection process uses three file states.

- `LastDeployedBaseline` captures the hash and metadata of the file that was last known to be successfully deployed.
- `CurrentServerState` captures the actual file currently present on the server before the new deployment starts.
- `IncomingPackageState` captures the file from the new release package that is about to be deployed.

The baseline is the control point. The current server file is compared against it first. The incoming package is compared against it as well, but only to classify whether the upcoming deployment is introducing a change or colliding with an existing manual edit.

| Comparison | Meaning |
|---|---|
| `CurrentServer == LastDeployed` | No server-side drift |
| `CurrentServer != LastDeployed` | Server-side drift detected |
| `IncomingPackage != LastDeployed` | Official deployment contains changes |
| `CurrentServer != LastDeployed` and `IncomingPackage != LastDeployed` | Potential conflict |

The important point is that a change in the incoming package is not a problem by itself. The process only flags a conflict when the server has already drifted away from the baseline and the new deployment also changes the same file.

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

- Validate the manually built server first.
- Create the initial baseline from that trusted state.
- Enable normal drift detection only after the baseline exists.

In the current PowerShell implementation, a missing baseline is treated as a controlled condition with exit code `3`. The deployment process should stop and require a baseline bootstrap step before continuing.

## Process Overview

### After Successful Deployment

1. Generate a new baseline file from the deployed files on the server.
2. Store file hashes and metadata.
3. Save the baseline as JSON.

The baseline should only be updated after the deployment has completed successfully and validation has passed.

### Before the Next Deployment

1. Load the previous baseline.
2. Calculate hashes for the current server files.
3. Optionally calculate hashes for the incoming package.
4. Compare baseline versus current server state.
5. Detect drift, missing files, new unexpected files, and conflicts.
6. Generate a JSON report.

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
- Returns a PowerShell object for automation or troubleshooting.

### `Test-DeploymentDrift.ps1`

This script performs the pre-deployment drift check.

It:

- Loads the baseline JSON file.
- Recalculates hashes from the current server files.
- Optionally scans the incoming package.
- Compares the baseline with the current server state.
- Detects modified files, missing files, and unexpected files.
- Performs three-way classification when the incoming package is supplied.
- Writes a JSON drift report.
- Returns a useful object for pipeline consumption.

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

The drift report records what changed, how it was classified, and what action is recommended. A simplified example for the conflict scenario looks like this:

```json
{
  "metadata": {
    "applicationName": "MyApp",
    "environmentName": "QA",
    "rootPath": "C:\\inetpub\\MyApp",
    "baselinePath": "C:\\Deployments\\MyApp\\baseline\\last-successful-deployment.json",
    "incomingPackagePath": "C:\\Deployments\\MyApp\\incoming",
    "generatedAtUtc": "2026-05-30T17:30:00Z",
    "generatedBy": "DOMAIN\\DeployUser",
    "hashAlgorithm": "SHA256"
  },
  "summary": {
    "baselineFileCount": 2,
    "currentFileCount": 2,
    "incomingFileCount": 2,
    "modifiedCount": 1,
    "missingCount": 0,
    "newUnexpectedCount": 0,
    "incomingChangeCount": 2,
    "conflictCount": 1,
    "unchangedCount": 0
  },
  "classification": {
    "hasDrift": true,
    "hasConflict": true,
    "recommendedAction": "Stop deployment and review conflicting files."
  },
  "files": [
    {
      "relativePath": "web.config",
      "baselineHash": "AAA",
      "currentHash": "XXX",
      "incomingHash": "CCC",
      "isMissing": false,
      "isNewUnexpected": false,
      "isModified": true,
      "isConflict": true,
      "classification": "PotentialConflict",
      "recommendedAction": "Stop deployment and review the conflicting file."
    },
    {
      "relativePath": "file1.dll",
      "baselineHash": "BBB",
      "currentHash": "BBB",
      "incomingHash": "DDD",
      "isMissing": false,
      "isNewUnexpected": false,
      "isModified": false,
      "isConflict": false,
      "classification": "IncomingChangeOnly",
      "recommendedAction": "Proceed with deployment."
    }
  ],
  "recommendedAction": "Stop deployment and review conflicting files."
}
```

This example shows the intended behavior clearly:

- `web.config` was changed on the server after the last successful deployment.
- `web.config` also changed in the incoming package.
- `file1.dll` changed only in the incoming package.

## Recommended Harness Integration

The following flow is recommended for Harness-based deployments.

1. Download or extract the deployment package.
2. Run the pre-deployment drift check by calling `Test-DeploymentDrift.ps1`.
3. If drift is detected, stop the deployment or pause for manual approval.
4. Deploy the files only after the drift decision is made.
5. Run smoke tests and any application validation steps.
6. If the deployment succeeds, run `New-DeploymentBaseline.ps1` to create the new baseline.

This sequence ensures that the baseline always represents the last successful deployment, not the last attempted deployment.

For production environments, a manual approval step in Harness is strongly recommended when drift is detected or when a deployment affects critical configuration files.

## Recommended Exit Codes

Use the following exit code convention for automation and pipeline handling:

- `0` = No drift detected.
- `1` = Drift detected and `FailOnDrift` was enabled.
- `2` = Script error or invalid input.
- `3` = Baseline file missing.

For deployment zero, exit code `3` is the expected outcome until the first trusted baseline has been created.

These exit codes make it easier for Harness or other orchestration tooling to route the result to failure handling, manual approval, or operational alerting.

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

- `web.config`
- `*.config`
- `*.json`
- `*.xml`
- `*.dll`

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

- `web.config`: server-side drift detected and the incoming package also changed the file. This is a potential conflict.
- `file1.dll`: no server-side drift. The incoming package changes the file. This is normal.
- Recommended action: stop deployment and review `web.config`.

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