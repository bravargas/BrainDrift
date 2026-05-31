@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'DeploymentDrift.Common.psm1'

    # Version number of this module.
    ModuleVersion     = '1.0.0'

    # ID used to uniquely identify this module
    GUID              = '6f8b3d7a-5b2a-4c9e-9c1f-2e7b4a1c2d3e'

    # Author and company information
    Author            = 'Brainer'
    CompanyName       = ''

    Copyright         = '(c) 2026 Brainer'
    Description       = 'Common helpers and comparison engine for DeploymentDrift scripts.'

    # PowerShell engine and edition compatibility
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop')

    # Exported functions
    FunctionsToExport = @(
        'Get-NormalizedRelativePath',
        'Test-PathMatchesPattern',
        'Get-FileInventory',
        'Read-JsonFile',
        'Write-JsonFile',
        'Compare-FileInventories',
        'New-DriftReport'
    )

    # Private data used by the module (left empty for now)
    PrivateData       = @{
        PSData = @{
            Tags = @('deployment','drift','hashing')
            LicenseUri = ''
            ProjectUri = ''
        }
    }
}
