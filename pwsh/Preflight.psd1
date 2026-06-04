@{
    # Module identity
    RootModule        = 'Preflight.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3a12e1b-332f-4ada-8340-a6ae2f40c86a'
    Author            = 'Shawn Oster'
    CompanyName       = 'shawnoster'
    Copyright         = '(c) Shawn Oster. MIT License.'
    Description       = 'Developer environment helpers for PowerShell — the PowerShell sibling of github.com/shawnoster/preflight. 1Password, AWS, Git, and project utilities.'

    # Compatibility — works in Windows PowerShell 5.1 and PowerShell 7+.
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # Public surface — additions go here as new lib files are ported.
    FunctionsToExport = @(
        'Get-OpStatus'
        'Connect-Op'
        'Import-OpEnv'
        'Clear-OpEnv'
        'New-OpItem'
        'Import-OpCsv'
        'Get-PreflightHelp'
    )

    AliasesToExport   = @(
        'op-status'
        'op-signin'
        'op-load-env'
        'op-clear-env'
        'op-new'
        'op-import-csv'
        'op-help'
        'dev-help'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Preflight', '1Password', 'op', 'AWS', 'DevTools', 'Productivity')
            LicenseUri   = 'https://github.com/shawnoster/preflight/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shawnoster/preflight'
            ReleaseNotes = 'Phase 1: 1Password helpers ported from bash preflight (Get-OpStatus, Connect-Op, Import-OpEnv, Clear-OpEnv, New-OpItem, Import-OpCsv).'
        }
    }
}
