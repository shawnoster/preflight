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
| `Invoke-OpEnv` | `op-env` | `op-env` (`load`, `clear`, `add`, `list`, `rm`, `use`) |
| `Import-OpEnv` / `Clear-OpEnv` | (none; run by `op-env load` / `op-env clear`) | `op-env load` / `op-env clear` |
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
`$PROFILE` (and accept the loss of the built-ins).

**Note on `gclean`:** the PowerShell version is *more conservative* than bash
`gclean`. It only deletes a local branch when both (a) it's merged into HEAD
and (b) it no longer exists on `origin`. This matches the safer behavior of
the `Remove-MergedBranches` function from the legacy profile, and avoids
deleting branches that are still active on the remote but happened to be
merged locally for testing.

Run `Get-Help Invoke-Preflight -Examples` (or any of the above) for usage.

## Configuration

Settings and secrets live **outside** the clone, so an update never touches them. The layout and the
file formats are the same as on the bash side ([docs/config.md](../docs/config.md)); the files are not
shared, because Windows PowerShell reads the Windows home and a WSL bash reads the WSL home.

| What | Where | Override |
|---|---|---|
| Settings | `~\.config\preflight\config.json` | `$env:PREFLIGHT_CONFIG_DIR`, then `$env:XDG_CONFIG_HOME` |
| Secrets (env sets) | `~\.config\preflight\envsets\<set>.tsv`, `.active` | same |
| Owl state, patched OMP theme | `~\.local\state\preflight\owl\` | `$env:PREFLIGHT_STATE_DIR`, then `$env:XDG_STATE_HOME` |

Setting the config or state directory to the install directory (or inside it) is refused with a warning.

**Settings.** `config.json` has the same keys as bash (`op.account`, `projects.dirs`, `aws.default_profile`,
`git.main_branch`, `gitea.*`, `owl.omp_config`; see the table in docs/config.md). Edit it by hand: there is no
`preflight config` command here yet. `Test-PreflightConfig` reports invalid JSON, unknown keys and wrongly typed
values, and `Invoke-Preflight` reports a bad file as a failed check. A variable you have set in your own
environment wins over the file, and an invalid or missing file falls back to built-in defaults (including a
placeholder `OP_ACCOUNT`) instead of failing the import. Re-importing the module (`Import-Module ... -Force`)
picks up edits. Two differences from bash: `projects.dirs` is joined with `;` on Windows (what `project.ps1`
splits on), and a setting whose value is empty is simply left unset, because an environment variable cannot hold
an empty string. The bash-only `checks.*` flags are accepted and ignored.

**Secrets.** The secret map is the env sets, the same files bash's `op-env` writes, and PowerShell has the same
command: `op-env load [set...]`, `op-env clear [set...]`, `op-env add [set] [VAR] [op://ref] [account]`,
`op-env list [set]`, `op-env rm [set] [VAR]`, `op-env use [set...]` and `op-env help` (an alias of `Invoke-OpEnv`; a
function literally named `op-env` would make `Import-Module` warn about an unapproved verb on every shell). The
rules are bash's: a plain `op-env load` is authoritative (it unsets what is no longer defined or no longer active),
`op-env load work` is additive and works on an inactive set, `op-env clear work` unsets only what that set supplied,
and writes are atomic and validated. Both implementations write byte-identical files (tests compare them). The old
`op-load-env` and `op-clear-env` aliases are gone; `Import-OpEnv` and `Clear-OpEnv` remain as the commands behind
`load` and `clear`. Sets are one `VAR<TAB>op://vault/item/field[<TAB>account]` line each, in `envsets\<set>.tsv`,
and hand-editing stays fine. Without an `.active` file every
set is active; with one, only the sets it lists, in that order. The first definition of a variable wins, and
malformed lines are skipped (the exact rules are `tests/fixtures/envsets` plus `envsets.expected`, checked by
both implementations). An entry that names an account is resolved against that account: `op-env load` groups
entries by account, signs in to every account first, and runs one `op run` per account. `Invoke-Preflight` checks
that every variable in an active set ended up set.

**Owl theme (opt-in plugin).** Off by default: enable it with `"plugins": ["owl"]` in `config.json`
(see [plugins/README.md](../plugins/README.md)); until then `owl-theme` and `Show-OwlSplash` do not exist. When
enabled, it seeds a user-owned base theme at
`~\.local\state\preflight\owl\theme-catppuccin.omp.json` on load, and `owl.omp_config` points at it by default, so
`owl-theme <name>` patches a working OMP config instead of `$env:POSH_THEMES_PATH` (which the module refuses to
mutate). Set `owl.omp_config` to use your own theme, or to an empty string to turn Oh My Posh integration off.
The profile guard no longer exports `OWL_OMP_CONFIG` or `OWL_THEME_DIR` (a value set before the module loads would
override `config.json`); `OWL_THEME_DIR` remains an environment-only override.

For Windows desktop-app integration (Settings → Developer → "Integrate with
1Password CLI"), set `op.account` to your sign-in address
(for example `my-team.1password.com`). If you manually added an account with
`op account add --shorthand`, shorthand values still work.

WSL shell setup is documented separately in
[`docs/wsl-1password-cli.md`](../docs/wsl-1password-cli.md); PowerShell is
Windows-native, so it talks to the local desktop app directly.

## Uninstall

```powershell
.\pwsh\install.ps1 -Uninstall          # reverses every $PROFILE edit
.\pwsh\install.ps1 -Uninstall -Force   # also removes ~\.preflight\pwsh\
```

The installer tags every line it adds or comments out with a
`# preflight:` marker, so uninstall is deterministic.
