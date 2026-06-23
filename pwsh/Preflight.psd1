@{
    # Module identity
    RootModule        = 'Preflight.psm1'
    ModuleVersion     = '0.7.0'
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
        'Get-PreflightCommands'
        'Invoke-Preflight'
        'Update-Preflight'
        'Set-AwsProfile'
        'Get-AwsIdentity'
        'Connect-Aws'
        'Invoke-Make'
        'Invoke-NpmScript'
        'Invoke-PoetryScript'
        'Set-LocationProject'
        'Start-LocalServer'
        'Switch-GitBranch'
        'Show-GitLog'
        'Pop-GitStash'
        'New-GitHubPullRequest'
        'Save-GitWip'
        'Undo-GitWip'
        'Remove-MergedGitBranches'
        'Sync-GitFork'
        'gs'
        'ga'
        'gpl'
        'gd'
        'gds'
        'Set-OwlTheme'
        'Show-OwlSplash'
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
        'devhelp'
        'dev-commands'
        'preflight'
        'preflight-update'
        'awsp'
        'switch-aws-profile'
        'aws-whoami'
        'aws-login'
        'bake'
        'yak'
        'poet'
        'proj'
        'serve'
        'gco'
        'glog'
        'gstash'
        'gpr'
        'gwip'
        'gunwip'
        'gclean'
        'gsync'
        'owl-theme'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Preflight', '1Password', 'op', 'AWS', 'DevTools', 'Productivity')
            LicenseUri   = 'https://github.com/shawnoster/preflight/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shawnoster/preflight'
            ReleaseNotes = @'
0.7.0 — Owl theme engine ported from bash lib/owl.sh:
  - Set-OwlTheme (alias: owl-theme) — list/switch/query 8 themes
    (catppuccin / honeypot / twilight / moonlit / autumn / rose /
    moss / parchment).
  - Show-OwlSplash — opt-in MOTD with 5 mood pools × 10 quotes each.
    Add to $PROFILE after Import-Module Preflight if you want it.
  - Theme state persists at $HOME\.preflight\state\owl\current.
  - OMP integration uses a USER-OWNED config (refuses to mutate
    Microsoft's shared $env:POSH_THEMES_PATH directory).
  - On module load, the saved theme's RGB triplets are exported as
    $env:OWL_BODY/EYES/TEXT/SUB so other surfaces can pick them up.

0.6.0 — Help refactor:
  - New Get-PreflightCommands (alias: dev-commands) — flat object-stream
    of every exported function with Name/Aliases/Synopsis/Category;
    pipeline-friendly for Where-Object / Out-GridView / Group-Object.
  - Get-PreflightHelp now auto-generates from the live module via AST
    parsing (function -> lib-file mapping) + Get-Help (synopsis lines)
    + Get-Command (aliases). No more hand-maintained category table to
    drift out of sync. New lib files appear automatically.
  - Both functions moved to lib/help.ps1 alongside their aliases.

0.5.0 — Invoke-Preflight Phase 2: SSH agent check, Installed Tools (with
  -CheckUpdates and winget/choco hints), Git Configuration audit, Node.js,
  Python (uv missing = issue). The orchestrator now mirrors all 10 sections
  of the bash `preflight` flow.

0.4.0 — Git layer ported from bash lib/git.sh:
  Switch-GitBranch (gco), Show-GitLog (glog), Pop-GitStash (gstash),
  New-GitHubPullRequest (gpr), Save-GitWip (gwip), Undo-GitWip (gunwip),
  Remove-MergedGitBranches (gclean), Sync-GitFork (gsync), plus
  gs/ga/gpl/gd/gds aliases. gclean adopts the safer "remote-gone"
  check from the user's existing Remove-MergedBranches profile function.

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
