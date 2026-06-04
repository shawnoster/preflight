@{
    # Module identity
    RootModule        = 'Preflight.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'b3a12e1b-332f-4ada-8340-a6ae2f40c86a'
    Author            = 'Shawn Oster'
    CompanyName       = 'shawnoster'
    Copyright         = '(c) Shawn Oster. MIT License.'
    Description       = 'Developer environment helpers for PowerShell — the PowerShell sibling of github.com/shawnoster/preflight. 1Password, AWS, Git, and project utilities.'

    # Compatibility — requires PowerShell 7.0+. Windows PowerShell 5.1 is
    # not supported (uses $IsWindows automatic variable, ArgumentList on
    # ProcessStartInfo, and other PS Core-only features).
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')

    # Public surface — additions go here as new lib files are ported.
    FunctionsToExport = @(
        'Get-OpStatus'
        'Connect-Op'
        'Import-OpEnv'
        'Clear-OpEnv'
        'New-OpItem'
        'Import-OpCsv'
        'Get-PreflightHelp'
        'Invoke-Preflight'
        'Set-AwsProfile'
        'Get-AwsIdentity'
        'Connect-Aws'
        'Invoke-Make'
        'Invoke-NpmScript'
        'Invoke-PoetryScript'
        'Set-LocationProject'
        'Start-LocalServer'
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
        'preflight'
        'awsp'
        'switch-aws-profile'
        'aws-whoami'
        'aws-login'
        'bake'
        'yak'
        'poet'
        'proj'
        'serve'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Preflight', '1Password', 'op', 'AWS', 'DevTools', 'Productivity')
            LicenseUri   = 'https://github.com/shawnoster/preflight/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shawnoster/preflight'
            ReleaseNotes = @'
0.3.0 — Project layer ported from bash lib/project.sh:
  Invoke-Make (bake), Invoke-NpmScript (yak), Invoke-PoetryScript (poet),
  Set-LocationProject (proj), Start-LocalServer (serve).

0.2.0 — AWS layer ported from bash lib/aws.sh:
  Set-AwsProfile (awsp), Get-AwsIdentity (aws-whoami), Connect-Aws (aws-login).

0.1.0 — Phase 1: 1Password helpers (Get-OpStatus, Connect-Op, Import-OpEnv,
  Clear-OpEnv, New-OpItem, Import-OpCsv) and the Invoke-Preflight orchestrator.
'@
        }
    }
}
