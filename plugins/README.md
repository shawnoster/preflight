# Plugins

Opt-in extras. The core of preflight (paths, settings, env sets / `op-env`, 1Password, AWS, Git, Docker, project
navigation, the `preflight` health check) never changes how your shell looks. A plugin does, so nothing in this
directory loads unless you ask for it.

## Enabling

```bash
preflight config set plugins owl        # one or more names, separated by ':'  (owl:other)
```

or in `config.json`: `"plugins": ["owl"]`. Open a new terminal (or `source ~/.bashrc`). To turn one off, remove it from
the list (`preflight config set plugins -` clears it) or edit the file. A name that is not a plugin, or is not a valid name
(lowercase letters, digits and `-`), is skipped with a warning; it never stops the shell from starting.

PowerShell reads the same `plugins` list.

## Available

| Plugin | What it adds |
|---|---|
| `owl` | The OOO theme engine: `owl-theme`, the once-per-session MOTD splash, and Oh My Posh prompt integration (`owl.omp_config`). Seeds `~/.local/state/preflight/owl/theme-catppuccin.omp.json` on first load. |

## Writing one

- **bash/zsh:** `plugins/<name>/plugin.sh`. `init.sh` sources it after the libraries and after the settings are loaded,
  so it can read any setting variable. It runs in the user's shell: keep it portable to Bash and zsh (see AGENTS.md),
  guard anything interactive with `[[ $- == *i* ]]`, and never assign a setting variable at load time.
- **PowerShell:** `pwsh/plugins/<name>.ps1`, dot-sourced by `Preflight.psm1` after the settings load. List its public
  functions and aliases in `Preflight.psd1`; a name whose plugin is not loaded is simply not exported.
- Keep a plugin self-contained: the core must not call into it (the health check falls back to neutral colors when
  `owl` is off, for instance).
- A plugin's own settings go under their own key in `config.json` (see `owl.omp_config`).
