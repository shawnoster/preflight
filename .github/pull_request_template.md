## Summary

<!-- What changes and why, in a few lines. Lead with the user-visible effect. -->

## Changes

<!-- Bullet the notable pieces. Name files/functions where it helps a reviewer. -->

-

## Upgrade notes

<!-- Delete this section if nothing here affects an existing install.
     init.sh and install.sh normally copy a *.template into its live counterpart only
     when the live file is missing, so a template change does not reach an existing
     install on its own. The exception is an explicit migration in init.sh (today, the
     config/owl.sh check), which replaces a live file only when it is byte-for-byte a
     previously shipped template. So if you change a template, add or change such a
     migration, or rename/move a tracked or gitignored file, say what an existing
     install must do. -->

## Test plan

<!-- What you ran and what you saw. Be specific; tick only what you actually did. -->

- [ ]

## Checklist

- [ ] Tracked files stay generic: no secrets, work-specific account references, or machine-specific paths
- [ ] Works when sourced from both Bash and zsh (`_pf_ask`, not `read -p`; no `read -a`, `mapfile`/`readarray`, or 0-based array indexes)
- [ ] Edited the `*.template` files, not the generated live copies
- [ ] README / AGENTS.md / `--help` text updated where behavior changed
