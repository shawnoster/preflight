# Plugins

Opt-in extras. The core of preflight (paths, settings, env sets / `op-env`, 1Password, AWS, Git, Docker, project
navigation, the `preflight` health check) never changes how your shell looks. A plugin does, so nothing in this
directory loads unless you ask for it.

## Enabling

```bash
preflight config set plugins owl        # one or more names, separated by ':'  (owl:other)
```

or in `config.json`: `"plugins": ["owl"]`. Open a new terminal (or `source ~/.bashrc`). To turn one off, remove it from
the list (`preflight config set plugins ''` clears it) or edit the file. A name that is not valid (lowercase letters, digits and `-`), or has no `plugins/<name>/plugin.sh`, is skipped
with a warning in bash/zsh; it never stops the shell from starting. The list is per user, not per shell, so
PowerShell skips a plugin with no PowerShell side (like `nanoleaf`) without a warning.

PowerShell reads the same `plugins` list.

## Disabling

Remove the name from the list and open a new terminal: the plugin's functions, `PATH` entries, hooks and colors are gone from new shells (a shell that is already open keeps them until it closes). What a plugin wrote is left alone:

- `owl`: `~/.local/state/preflight/owl/` (your theme choice and the patched Oh My Posh config). Delete the directory to start over.
- `wsl-browser`: `~/.local/share/applications/winbrowser.desktop` and the `winbrowser.desktop` entries in `~/.config/mimeapps.list`, if you ran `wsl-browser-doctor --fix`, and the block between `# >>> preflight wsl-browser >>>` and `# <<< preflight wsl-browser <<<` in `~/.profile`. Disabling the plugin does not remove that block, so login shells keep exporting `$BROWSER` until you delete it (the block checks the wrapper still exists, so removing preflight itself is safe). Remove all of these to go back to the distro's own browser.
- `nanoleaf`: `~/.config/nanoleaf-direct/env` keeps the last `NANOLEAF_TOKEN` (kept on purpose so cron jobs still work). **Delete that file to revoke it** once you no longer want it on disk.

## Available

| Plugin | What it adds |
|---|---|
| `nanoleaf` | Hands `NANOLEAF_TOKEN` to cron on every `op-env load` (copies it to `~/.config/nanoleaf-direct/env`, mode 600), and puts `light-remind`, `nanoleaf-kitt` and `nanoleaf-streak` on `PATH`. bash/zsh only. |
| `wsl-browser` | On WSL, points `$BROWSER` at `plugins/wsl-browser/bin/winbrowser`, which opens links in the Windows default browser (via `rundll32.exe`) instead of a Linux browser inside the distro. Adds `wsl-browser-doctor [--fix]`, which checks interop, `$BROWSER`, `winbrowser.desktop`, the XDG (freedesktop.org desktop standard, which `xdg-open` follows) http/https/html defaults, a marked `BROWSER` block in `~/.profile` (so hooks, cron and scripts get it too) and a dangling `env.BROWSER` pin in Claude Code's settings; `--fix` repairs all but the settings pin, which it only reports. Inert outside WSL. bash/zsh only; the `~/.profile` block is read by bash and POSIX `sh` login shells, not by zsh. |
| `owl` | The OOO theme engine: `owl-theme`, a MOTD splash (shown once per session in bash/zsh; in PowerShell call `Show-OwlSplash` yourself) and Oh My Posh prompt integration (`owl.omp_config`). Seeds `~/.local/state/preflight/owl/theme-catppuccin.omp.json` on first load. |

## Writing one

- **bash/zsh:** `plugins/<name>/plugin.sh`; a plugin that ships scripts keeps them in `plugins/<name>/bin` and adds that to `PATH` itself. `init.sh` sources it after the libraries and after the settings are loaded,
  so it can read any setting variable. It runs in the user's shell: keep it portable to Bash and zsh (see AGENTS.md),
  guard anything interactive with `[[ $- == *i* ]]`, and never assign a setting variable at load time.
- **PowerShell:** `pwsh/plugins/<name>.ps1`, dot-sourced by `Preflight.psm1` after the settings load. List its public
  functions and aliases in `Preflight.psd1`; a name whose plugin is not loaded is simply not exported.
- Keep a plugin self-contained: the core must not call into it (the health check falls back to neutral colors when
  `owl` is off, for instance).
- A plugin's own settings go under their own key in `config.json` (see `owl.omp_config`).
