Describe 'DeploymentDrift Suite' {
    BeforeAll {
        $script:repoRoot = 'd:\users\Brainer\Documents\Code\BrainDrift'
        $script:testSample = Join-Path $script:repoRoot '_sample\testrun'
        Remove-Item -LiteralPath $script:testSample -Recurse -Force -ErrorAction SilentlyContinue

        $script:scripts = Join-Path $script:repoRoot 'scripts'
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

    It 'Detects conflict when incoming package changes files' {
        # ensure incoming has a different content than baseline
        Set-Content -LiteralPath (Join-Path $script:incoming 'web.config') -Value 'INCOMING' -Encoding UTF8

        # modify server to create a drift vs baseline
        Set-Content -LiteralPath (Join-Path $script:server 'web.config') -Value 'SERVER_MODIFIED' -Encoding UTF8

        # generate manifest for incoming package
        $manifest = Join-Path $script:reports 'incoming-manifest.json'
        Remove-Item -LiteralPath $manifest -ErrorAction SilentlyContinue
        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'Export-DeploymentFileManifest.ps1') -SourcePath $script:incoming -ManifestPath $manifest -IncludePatterns '*' | Out-Null

        & $script:pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:scripts 'Test-DeploymentDrift.ps1') `
            -ApplicationName 'Sample' -EnvironmentName 'TEST' -RootPath $script:server `
            -BaselinePath $script:baselineInitial -IncomingPackagePath $script:incoming -ReportPath $script:reports -IncludePatterns '*' | Out-Null

        $report2 = Get-ChildItem -Path $script:reports -Filter 'drift-report-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Test-Path $report2.FullName | Should -BeTrue
        $reportObj2 = Get-Content -Path $report2.FullName -Raw | ConvertFrom-Json
        $reportObj2.classification.hasConflict | Should -BeTrue
    }

    AfterAll {
        Remove-Item -LiteralPath $script:testSample -Recurse -Force -ErrorAction SilentlyContinue
    }
}
