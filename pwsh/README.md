# Preflight — PowerShell

The PowerShell sibling of [github.com/shawnoster/preflight](https://github.com/shawnoster/preflight).
Drop it in `$HOME\.preflight\`, import the module from `$PROFILE`, and get
the same 1Password / AWS / project helpers you have on the bash side, with
PowerShell-native parameter validation and tab completion.

## Quick start

```powershell
# From this checkout (preferred while developing)
.\pwsh\install.ps1 -DryRun        # preview every change
.\pwsh\install.ps1                # apply (prompts before editing $PROFILE)
.\pwsh\install.ps1 -Force         # apply without prompts

# From a release (once published)
iwr https://raw.githubusercontent.com/shawnoster/preflight/main/pwsh/install.ps1 -OutFile install.ps1
.\install.ps1
```

After install, reload your shell:

```powershell
. $PROFILE
Get-OpStatus
```

## Requirements

- **PowerShell 7.0+** (`pwsh`). Windows PowerShell 5.1 is not supported — the
  module uses `$IsWindows`, `[Diagnostics.Process].ArgumentList`, and other
  PS-Core-only features. Install from
  [aka.ms/powershell](https://aka.ms/powershell).
- **1Password CLI** (`op`). Install from
  [developer.1password.com/docs/cli](https://developer.1password.com/docs/cli/get-started/).
- **AWS CLI v2** (optional, for the `Invoke-Preflight` AWS section).

## What's in the box

The 1Password layer, AWS helpers, project utilities, git workflow helpers,
and a session-startup orchestrator. Function names follow PowerShell
`Verb-Noun` convention; kebab/lowercase aliases match the bash side for
muscle memory.

| Function | Alias | Bash equivalent |
|---|---|---|
| `Invoke-Preflight` | `preflight` | `preflight` |
| `Get-OpStatus` | `op-status` | `op-status` |
| `Connect-Op` | `op-signin` | `op-signin` |
| `Import-OpEnv` | `op-load-env` | `op-load-env` |
| `Clear-OpEnv` | `op-clear-env` | `op-clear-env` |
| `New-OpItem` | `op-new` | `op-new` |
| `Import-OpCsv` | `op-import-csv` | `op-import-csv` |
| `Set-AwsProfile` | `awsp`, `switch-aws-profile` | `awsp` |
| `Get-AwsIdentity` | `aws-whoami` | `aws-whoami` |
| `Connect-Aws` | `aws-login` | `aws-login` |
| `Invoke-Make` | `bake` | `bake` |
| `Invoke-NpmScript` | `yak` | `yak` |
| `Invoke-PoetryScript` | `poet` | `poet` |
| `Set-LocationProject` | `proj` | `proj` |
| `Start-LocalServer` | `serve` | `serve` |
| `Switch-GitBranch` | `gco` | `gco` |
| `Show-GitLog` | `glog` | `glog` |
| `Pop-GitStash` | `gstash` | `gstash` |
| `New-GitHubPullRequest` | `gpr` | `gpr` |
| `Save-GitWip` | `gwip` | `gwip` |
| `Undo-GitWip` | `gunwip` | `gunwip` |
| `Remove-MergedGitBranches` | `gclean` | `gclean` |
| `Sync-GitFork` | `gsync` | `gsync` |
| `gs` / `ga` / `gpl` / `gd` / `gds` | — | `gs` / `ga` / `gpl` / `gd` / `gds` |
| `Get-PreflightHelp` | `op-help`, `dev-help` | `dev-help` |

`Invoke-Preflight` runs 10 session-startup checks: 1Password sign-in and
secrets, AWS profile and SSO session, env-sanity (NPM_TOKEN + `gh` auth),
SSH agent reachability, installed-tool versions (with `-CheckUpdates` to
fetch latest from GitHub releases in parallel and flag drift, with winget
or choco update hints), git global config audit, and Node.js / Python /
uv version reports. Quiet by default; `-Verbose` streams every section.

Interactive selection uses `Out-GridView` when available (Windows GUI), falling
back to `fzf` if installed, then a numbered prompt — so commands like `awsp`,
`bake`, or `gco` with no argument give you a familiar picker no matter what
you've installed.

**Two bash aliases are intentionally not ported:** `gc` and `gp` collide with
PowerShell's built-in aliases for `Get-Content` and `Get-ItemProperty`. Users
who want them can override with `Set-Alias gc git -Force` in their
`accounts.ps1` (and accept the loss of the built-ins).

**Note on `gclean`:** the PowerShell version is *more conservative* than bash
`gclean`. It only deletes a local branch when both (a) it's merged into HEAD
and (b) it no longer exists on `origin`. This matches the safer behavior of
the `Remove-MergedBranches` function from the legacy profile, and avoids
deleting branches that are still active on the remote but happened to be
merged locally for testing.

Run `Get-Help Invoke-Preflight -Examples` (or any of the above) for usage.

## Configuration

Edit `$HOME\.preflight\pwsh\config\accounts.ps1` (gitignored, copied from
`accounts.ps1.template` by the installer) to override defaults like
`$env:OP_ACCOUNT`.

## Uninstall

```powershell
.\pwsh\install.ps1 -Uninstall          # reverses every $PROFILE edit
.\pwsh\install.ps1 -Uninstall -Force   # also removes ~\.preflight\pwsh\
```

The installer tags every line it adds or comments out with a
`# preflight:` marker, so uninstall is deterministic.
