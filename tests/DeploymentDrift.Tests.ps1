Describe 'DeploymentDrift Suite' {
    BeforeAll {
        $script:repoRoot = 'd:\users\Brainer\Documents\Code\BrainDrift'
        $envServer = $env:BD_SERVER_ROOT
        $script:scripts = Join-Path $script:repoRoot 'scripts'

        if ([string]::IsNullOrWhiteSpace($envServer)) {
            # use isolated test sample (default)
            $script:testSample = Join-Path $script:repoRoot '_sample\testrun'
            Remove-Item -LiteralPath $script:testSample -Recurse -Force -ErrorAction SilentlyContinue

            $script:server = Join-Path $script:testSample 'server'
            $script:incoming = Join-Path $script:testSample 'incoming'
            $script:baseline = Join-Path $script:testSample 'baseline\last-successful-deployment.json'
            $script:reports = Join-Path $script:testSample 'reports'

            New-Item -ItemType Directory -Path $script:server -Force | Out-Null
            New-Item -ItemType Directory -Path $script:incoming -Force | Out-Null
            New-Item -ItemType Directory -Path (Split-Path $script:baseline -Parent) -Force | Out-Null
            New-Item -ItemType Directory -Path $script:reports -Force | Out-Null

            # create deterministic test files
            Set-Content -LiteralPath (Join-Path $script:server 'file1.dll') -Value 'DLL_CONTENT_A' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value 'SERVER_ORIG' -Encoding UTF8

            Set-Content -LiteralPath (Join-Path $script:incoming 'file1.dll') -Value 'DLL_CONTENT_B' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $script:incoming 'web.config') -Value 'INCOMING_ORIG' -Encoding UTF8

            $script:useRealServer = $false
        }
        else {
            # run tests against a real server path (non-destructive)
            $script:useRealServer = $true
            $script:server = $envServer

            $ts = (Get-Date).ToString('yyyyMMddHHmmss')
            $script:testRoot = Join-Path $env:TEMP "BrainDriftTest_$ts"
            New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
            $script:incoming = Join-Path $script:testRoot 'incoming'
            $script:reports = Join-Path $script:testRoot 'reports'
            $baselineDir = Join-Path $script:testRoot 'baseline'
            New-Item -ItemType Directory -Path $script:incoming -Force | Out-Null
            New-Item -ItemType Directory -Path $script:reports -Force | Out-Null
            New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null
            $script:baseline = Join-Path $baselineDir 'last-successful-deployment.json'

            # Create a safe incoming package area for tests (do not touch the real server)
            # We will not modify the real server; tests that require server modification are skipped.
            Set-Content -LiteralPath (Join-Path $script:incoming 'web.config') -Value 'INCOMING_TEST' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $script:incoming 'file1.dll') -Value 'DLL_INCOMING_TEST' -Encoding ASCII
        }

        $script:pw = 'powershell'
    }

    It 'Creates baseline from sample server' {
        Remove-Item -LiteralPath $script:baseline -ErrorAction SilentlyContinue
        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'New-DeploymentBaseline.ps1') `
            -ApplicationName 'Sample' -DeploymentId 'TEST' -EnvironmentName 'TEST' -ServerName 'LOCAL' `
            -RootPath $script:server -BaselinePath $script:baseline -IncludePatterns '*' | Out-Null

        Test-Path $script:baseline | Should -BeTrue
        $script:baselineInitial = Join-Path (Split-Path $script:baseline -Parent) 'initial-last-successful-deployment.json'
        Copy-Item -Path $script:baseline -Destination $script:baselineInitial -Force
    }

    It 'Reports no drift when baseline equals server' {
        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'Test-DeploymentDrift.ps1') `
            -ApplicationName 'Sample' -EnvironmentName 'TEST' -RootPath $script:server `
            -BaselinePath $script:baseline -ReportPath $script:reports -IncludePatterns '*' | Out-Null

        $report = Get-ChildItem -Path $script:reports -Filter 'drift-report-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Test-Path $report.FullName | Should -BeTrue
        $reportObj = Get-Content -Path $report.FullName -Raw | ConvertFrom-Json
        $reportObj.classification.hasDrift | Should -BeFalse
    }

    It 'Fails when server drifts and FailOnDrift is enabled' {
        if ($script:useRealServer) {
            Write-Host 'Skipping server drift test when using a real server path to avoid modifying production files.'
            return
        }

        Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value 'SERVER_DRIFTED' -Encoding UTF8

        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'Test-DeploymentDrift.ps1') `
            -ApplicationName 'Sample' -EnvironmentName 'TEST' -RootPath $script:server `
            -BaselinePath $script:baseline -ReportPath $script:reports -FailOnDrift -IncludePatterns '*' | Out-Null

        $LASTEXITCODE | Should -Be 1

        $report = Get-ChildItem -Path $script:reports -Filter 'drift-report-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Test-Path $report.FullName | Should -BeTrue
        $reportObj = Get-Content -Path $report.FullName -Raw | ConvertFrom-Json
        $reportObj.classification.hasDrift | Should -BeTrue
        $reportObj.classification.hasConflict | Should -BeFalse
    }

    It 'Aborts run-deploy when baseline is missing and FailOnDrift is enabled' {
        if ($script:useRealServer) {
            Write-Host 'Skipping bootstrap test when using a real server path to avoid modifying production files.'
            return
        }

        Remove-Item -LiteralPath $script:baseline -ErrorAction SilentlyContinue

        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:repoRoot '_sample\deploy-package\run-deploy.ps1') `
            -IncomingPackagePath $script:incoming `
            -RootPath $script:server `
            -BaselinePath $script:baseline `
            -ReportPath $script:reports `
            -ApplicationName 'Sample' `
            -EnvironmentName 'TEST' `
            -FailOnDrift `
            -CreateBaselineIfMissing `
            -IncludePatterns '*' | Out-Null

        $LASTEXITCODE | Should -Be 3
        Test-Path -LiteralPath $script:baseline | Should -BeFalse
    }

    It 'Aborts run-deploy when baseline is missing by default (no auto-bootstrap)' {
        if ($script:useRealServer) {
            Write-Host 'Skipping bootstrap-default test when using a real server path.'
            return
        }

        Remove-Item -LiteralPath $script:baseline -ErrorAction SilentlyContinue

        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:repoRoot '_sample\deploy-package\run-deploy.ps1') `
            -IncomingPackagePath $script:incoming `
            -RootPath $script:server `
            -BaselinePath $script:baseline `
            -ReportPath $script:reports `
            -ApplicationName 'Sample' `
            -EnvironmentName 'TEST' `
            -IncludePatterns '*' | Out-Null

        $LASTEXITCODE | Should -Be 3
        Test-Path -LiteralPath $script:baseline | Should -BeFalse
    }

    It 'Detects conflict when incoming package changes files' {
        if ($script:useRealServer) {
            Write-Host 'Skipping conflict test when using a real server path to avoid modifying production files.'
            return
        }

        # ensure incoming has a different content than baseline
        Set-Content -LiteralPath (Join-Path $script:incoming 'web.config') -Value 'INCOMING' -Encoding UTF8

        # modify server to create a drift vs baseline (only for local test sample)
        Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value 'SERVER_MODIFIED' -Encoding UTF8

        # generate manifest for incoming package
        $manifest = Join-Path $script:reports 'incoming-manifest.json'
        Remove-Item -LiteralPath $manifest -ErrorAction SilentlyContinue
        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'Export-DeploymentFileManifest.ps1') -SourcePath $script:incoming -ManifestPath $manifest -IncludePatterns '*' | Out-Null

        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'Test-DeploymentDrift.ps1') `
            -ApplicationName 'Sample' -EnvironmentName 'TEST' -RootPath $script:server `
            -BaselinePath $script:baselineInitial -ReportPath $script:reports -IncludePatterns '*' | Out-Null

        $report2 = Get-ChildItem -Path $script:reports -Filter 'drift-report-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Test-Path $report2.FullName | Should -BeTrue
        $reportObj2 = Get-Content -Path $report2.FullName -Raw | ConvertFrom-Json
        $reportObj2.classification.hasConflict | Should -BeTrue
    }

    It 'Archives the previous baseline when it is regenerated' {
        if ($script:useRealServer) {
            Write-Host 'Skipping archive test when using a real server path to avoid modifying production files.'
            return
        }

        if (-not (Test-Path -LiteralPath $script:baseline -PathType Leaf)) {
            if ($null -ne $script:baselineInitial -and (Test-Path -LiteralPath $script:baselineInitial -PathType Leaf)) {
                Copy-Item -LiteralPath $script:baselineInitial -Destination $script:baseline -Force
            }
            else {
                & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'New-DeploymentBaseline.ps1') `
                    -ApplicationName 'Sample' -DeploymentId 'TEST-BASELINE' -EnvironmentName 'TEST' -ServerName 'LOCAL' `
                    -RootPath $script:server -BaselinePath $script:baseline -IncludePatterns '*' | Out-Null

                $LASTEXITCODE | Should -Be 0
            }
        }

        if ($null -eq $script:baselineInitial -or -not (Test-Path -LiteralPath $script:baselineInitial -PathType Leaf)) {
            $script:baselineInitial = Join-Path (Split-Path -Path $script:baseline -Parent) 'initial-last-successful-deployment.json'
            Copy-Item -LiteralPath $script:baseline -Destination $script:baselineInitial -Force
        }

        $configDirectory = Join-Path (Split-Path -Path $script:baseline -Parent) 'config'
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        $configPath = Join-Path $configDirectory 'deployment-drift.config.json'
        Set-Content -LiteralPath $configPath -Value (@{ ArchiveRetentionCount = 1 } | ConvertTo-Json) -Encoding UTF8

        $archiveFolder = Join-Path (Split-Path -Path $script:baseline -Parent) 'archive'
        $archiveFolder = Join-Path $archiveFolder ([System.IO.Path]::GetFileNameWithoutExtension($script:baseline))
        if (Test-Path -LiteralPath $archiveFolder) {
            Remove-Item -LiteralPath $archiveFolder -Recurse -Force -ErrorAction SilentlyContinue
        }

        $originalBaselineContent = Get-Content -LiteralPath $script:baseline -Raw
        $originalServerWebConfig = Get-Content -LiteralPath (Join-Path $script:server 'web.config') -Raw

        try {
            Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value 'SERVER_REFRESHED_1' -Encoding UTF8

            & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'New-DeploymentBaseline.ps1') `
                -ApplicationName 'Sample' -DeploymentId 'TEST-REFRESH-1' -EnvironmentName 'TEST' -ServerName 'LOCAL' `
                -RootPath $script:server -BaselinePath $script:baseline -ConfigPath $configPath -IncludePatterns '*' | Out-Null

            Test-Path -LiteralPath $archiveFolder | Should -BeTrue

            Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value 'SERVER_REFRESHED_2' -Encoding UTF8

            & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'New-DeploymentBaseline.ps1') `
                -ApplicationName 'Sample' -DeploymentId 'TEST-REFRESH-2' -EnvironmentName 'TEST' -ServerName 'LOCAL' `
                -RootPath $script:server -BaselinePath $script:baseline -ConfigPath $configPath -IncludePatterns '*' | Out-Null

            Test-Path -LiteralPath $script:baseline | Should -BeTrue

            $archivedBaselines = Get-ChildItem -Path $archiveFolder -Filter '*.baseline.json' -File | Sort-Object LastWriteTime -Descending
            $archivedBaselines.Count | Should -Be 1

            $archivedBaselineObj = Get-Content -LiteralPath $archivedBaselines[0].FullName -Raw | ConvertFrom-Json
            $archivedBaselineObj.metadata.deploymentId | Should -Be 'TEST-REFRESH-1'

            $refreshedBaselineObj = Get-Content -LiteralPath $script:baseline -Raw | ConvertFrom-Json
            $refreshedBaselineObj.metadata.deploymentId | Should -Be 'TEST-REFRESH-2'
            $refreshedBaselineObj.files | Should -Not -BeNullOrEmpty
        }
        finally {
            Set-Content -LiteralPath $script:baseline -Value $originalBaselineContent -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value $originalServerWebConfig -Encoding UTF8
        }
    }

    AfterAll {
        if ($null -ne $script:testSample -and -not [string]::IsNullOrWhiteSpace($script:testSample) -and (Test-Path -LiteralPath $script:testSample)) {
            Remove-Item -LiteralPath $script:testSample -Recurse -Force -ErrorAction SilentlyContinue
        }
        elseif ($null -ne $script:testRoot -and -not [string]::IsNullOrWhiteSpace($script:testRoot) -and (Test-Path -LiteralPath $script:testRoot)) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
