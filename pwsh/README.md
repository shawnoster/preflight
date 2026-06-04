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

## Phase 1 — what's in the box

The 1Password layer plus a session-startup orchestrator. Function names follow
PowerShell `Verb-Noun` convention; kebab/lowercase aliases match the bash side
for muscle memory.

| Function | Alias | Bash equivalent |
|---|---|---|
| `Invoke-Preflight` | `preflight` | `preflight` |
| `Get-OpStatus` | `op-status` | `op-status` |
| `Connect-Op` | `op-signin` | `op-signin` |
| `Import-OpEnv` | `op-load-env` | `op-load-env` |
| `Clear-OpEnv` | `op-clear-env` | `op-clear-env` |
| `New-OpItem` | `op-new` | `op-new` |
| `Import-OpCsv` | `op-import-csv` | `op-import-csv` |
| `Get-PreflightHelp` | `op-help`, `dev-help` | `dev-help` |

`Invoke-Preflight` covers Phase 1 sections only: secrets, AWS detect-and-warn,
and an env sanity sweep (NPM_TOKEN + `gh` auth). Phase 2 will add SSH/1Password
agent integration, git globals, Node/Volta, Python/uv, and version-drift checks.

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
