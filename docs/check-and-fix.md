# Check and fix model

Status: proposed. Nothing described here is implemented. Current behavior is documented in `docs/config.md` and the README.

## Problem

Verifying that a machine is set up correctly and repairing it are spread over four surfaces, with the recommended state written down more than once.

| Surface | Job | Writes |
|---|---|---|
| `preflight` | Report problems across settings, secrets, AWS, SSH, git, tools | Nothing, apart from session effects (see open question 2) |
| `preflight config check` | Validate `config.json` | Nothing |
| `preflight config init` | Walk every `config.json` key | `config.json` |
| `preflight config apply` | Walk recommended git, SSH bridge and AWS settings | `~/.gitconfig`, `~/.ssh`, systemd units, `config.json` |

Consequences:

1. **The recommended state is encoded twice and has drifted.** `_pf_config_apply` recommends 18 git globals (`fetch.pruneTags`, `push.followTags`, `rebase.autoSquash`, `diff.colorMoved`, `branch.sort` and the delta group among them). The Git Configuration section of `preflight` checks 8 and does not check those. It also warns on `push.default = matching`, which `config apply` never sets. A machine can pass `preflight` and still have `config apply` offer changes, and the reverse.
2. **`preflight` is a single function of roughly 840 lines** that mutates `issues` and `issue_msgs` inline. No test runs it; the suites cover config, paths and env sets. Checks cannot be exercised on their own.
3. **A user must choose between three verbs** (`check`, `init`, `apply`) for one question: is my setup right, and if not, fix it. `config init` asks about every key whether or not it needs attention.

## Goals

1. One model: `preflight` reports, `preflight fix` repairs what it reported.
2. One definition of each recommended state, used by both the check and the fix.
3. Checks are read-only and testable without a terminal, a network or real tools.
4. Every change to the machine is explicit and consented to, per item.

Non-goals:

- Changing what is checked or what is recommended.
- Changing the `config.json` format or the `config get|set|edit|path|check` commands.
- The PowerShell module. It has no `config apply` or `config init` (its README says to edit the file by hand), so it is unaffected.
- Migration code. Upgrade notes tell the user which command replaces which.

## Model

A **check item** is a named unit of recommended state.

| Field | Meaning |
|---|---|
| `id` | Dotted name, for example `git.fetch.prune`, `ssh.bridge.units`, `settings.keys` |
| `group` | What `checks.*` can switch off: `settings`, `git`, `ssh`, `aws`, `tools` |
| `tier` | `fast` (local files and config), `slow` (network, `op`, `aws`), `updates` (only with `-u`) |
| `applies` | Predicate, for example WSL only or `aws` installed; a false predicate reports `skipped` |
| `check` | Read-only. Sets a status and a one-line message |
| `fix` | Optional. Makes the machine match, idempotently |
| `fix_class` | `auto` (no input), `input` (needs a choice or value), `manual` (instructions only) |

A check reports one status: `ok`, `drift` (present but different), `missing`, `skipped` or `error` (the check could not run). Everything except `ok` and `skipped` counts as an issue, as it does today.

A fix is safe to run twice, and running the check after it reports `ok`. A fix that cannot make that true is `manual`.

Table-driven items keep the definition in one place. The git globals become rows in one list (`key|value|reason|severity`). Both the check and the fix read the row, so they cannot disagree.

Items live in `lib/items/<group>.sh` and register in one ordered list. The runner is `lib/items.sh`. Items use only constructs the shell already allows (no associative arrays, no `mapfile`, no 0-based array indexes) so they work in bash and zsh.

## Commands

| Command | Behavior |
|---|---|
| `preflight` | Runs every enabled `fast` item and the `-u` and `slow` tiers as today. Read-only. Same summary as now, plus `N fixable: run preflight fix` |
| `preflight --only git,ssh` | Limits the run to those groups |
| `preflight fix [ID...]` | Shows each failing item with a fix, what will change and why, and asks per item. With IDs, only those items |
| `preflight fix --yes` | Applies every `auto` item; `input` items are listed and skipped |
| `preflight fix --dry-run` | Prints what each fix would change and writes nothing |
| `config get\|set\|edit\|path\|check` | Unchanged. `config check` is the `settings.*` items |
| `config init`, `config apply` | Removed |

`preflight fix` without a terminal and without `--yes` prints the fixable items and exits non-zero without prompting. Existing flags `-v`, `-u` and `--no-login` keep their meaning.

The settings walkthrough disappears into the model: a key missing from `config.json` is a `settings.keys` item with status `missing`, and its fix writes the default through the same atomic write as `config set`. Choosing a non-default value is `config set`.

## Item inventory

| Today | Items | Fix class |
|---|---|---|
| Settings section, `config check` | `settings.valid` | `manual` (`config edit`) |
| `config init` | `settings.keys` | `auto` |
| Git Configuration, `_pf_config_apply` globals | `git.identity` | `input` |
| | one `git.<key>` per recommended global | `auto` |
| | `git.pager.delta` group | `auto`, only when `delta` is installed |
| SSH section, WSL SSH bridge | `ssh.agent` | `manual` |
| | `ssh.bridge.prereq` (systemd, interop) | `manual` |
| | `ssh.bridge.npiperelay`, `.units`, `.socket`, `.profile`, `.ssh-config`, `.host-keys`, `.op-exe` | `auto` |
| AWS Profile | `aws.default-profile` | `input` |
| AWS Session | `aws.session` | `manual` (`aws-login`), `slow` |
| Secrets, Installed Tools, Node.js, Python | `secrets.*`, `tools.*`, `node`, `python` | `manual` |

Each bridge item takes over one numbered step of the current WSL section. `_pf_unit_directives` becomes the comparison in `ssh.bridge.units`.

## Testing

- Each `check` reads state through a small accessor (`git config --global` for git, file reads for units) and runs in a temp `HOME` with a controlled `PATH`. No terminal is needed.
- Every `auto` fix has an idempotency test: check reports `drift`, fix runs, check reports `ok`, fix runs again and changes nothing.
- The runner has its own tests: status counting, `--only`, `skipped` predicates, and that `fix` without a terminal and without `--yes` does not prompt.
- A single parity test asserts that the git rows are the only place a recommended global is named.

## Migration

Each step is a separate PR, and `preflight` keeps working after each.

1. Runner, registry and item contract. Port `settings.*` and the git globals. The legacy Git Configuration section is removed, and the runner appends to the same `issues` and `issue_msgs` counters.
2. Port the SSH check and the WSL bridge items from `_pf_config_apply`.
3. Add `preflight fix`. Port `aws.default-profile` and the delta group. Remove `config apply`. Upgrade note: `preflight config apply` is now `preflight fix`.
4. Add `settings.keys`. Remove `config init`. Upgrade note: use `preflight fix` for missing keys and `config set` for values.
5. Port the remaining sections (AWS session, tools, node, python, secrets) and delete the monolithic function.

## Alternatives

| Alternative | Why not |
|---|---|
| Keep both commands, trim `config init` to missing keys | Leaves the duplicated recommended state and the untestable health run |
| `preflight --fix` flag instead of a subcommand | A fix takes its own options (`--yes`, `--dry-run`, IDs); a subcommand keeps `preflight` itself read-only and obvious |
| A separate `preflight doctor` | `preflight` already is the diagnosis; a second report command would duplicate it |

## Open questions

1. Should `preflight` exit non-zero when issues exist? Any caller that runs it from a prompt or script would see the change.
2. Three things in the health run act on the session rather than report drift: storing the Gitea credential, exporting `AWS_PROFILE`, and the AWS login prompt. Should they stay in `preflight` as a separate `session` kind, or move to a startup step?
3. Should `fix` handle `input` items (git identity, AWS profile) or only list them and point to `config set`?
4. Is a per-item ignore list needed, or are the four `checks.*` group switches enough?
5. Is machine-readable output (`--json`) in scope for the runner?
