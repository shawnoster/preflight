## Summary

<!-- What changes and why, in a few lines. Lead with the user-visible effect. -->

## Type of change

<!-- Tick what applies. "Breaking" here means an existing install has to do something
     after `preflight update`, or a command or behavior changed incompatibly (a rename,
     a removed command, a template or config change that does not reach live files on
     its own). If you tick it, fill in Upgrade notes below. -->

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Refactor / tech debt
- [ ] Docs / config only

## Changes

<!-- Bullet the notable pieces. Name files/functions where it helps a reviewer. -->

-

## Upgrade notes

<!-- Keep this section so every PR has the same shape. If nothing here affects an
     existing install, write "None".
     init.sh copies a defaults/ profile to the live config.json only when that file is
     missing, so a profile change does not reach an existing install on its own, and
     preflight carries no migration code. So if you change a profile, add or rename a
     setting, or rename/move a tracked file or anything under the user's config or
     state directory, say what an existing install must do. -->

## Test plan

<!-- What you ran and what you saw. Be specific; tick only what you actually did. -->

- [ ]

## Checklist

- [ ] PR title follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) (`type(scope): subject` or `type: subject`, e.g. `fix(preflight): ...` or `chore: ...`; the scope is optional); PRs are squash-merged, so the title becomes the commit message
- [ ] If this is a breaking change, Upgrade notes say what an existing install must do
- [ ] Tracked files stay generic: no secrets, work-specific account references, or machine-specific paths
- [ ] Works when sourced from both Bash and zsh (`_pf_ask`, not `read -p`; no `read -a`, `mapfile`/`readarray`, or 0-based array indexes)
- [ ] Edited the `defaults/` profiles, not the generated live copy (and added any new setting to the table in `lib/config.sh`, the schema, both profiles and `docs/config.md`)
- [ ] README / AGENTS.md / `--help` text updated where behavior changed
