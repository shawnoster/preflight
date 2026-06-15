# WSL 1Password CLI with the Windows desktop app

Authorize 1Password secret reads inside WSL2 using the **Windows** 1Password desktop app — so `op-load-env` (and `preflight`) unlock via Windows Hello / desktop approval instead of a password typed in WSL.

## Why this setup

1Password's CLI-to-app integration (the bit that gives you biometric/desktop unlock) requires the CLI and the desktop app to run on the **same OS**. There is no 1Password desktop app inside WSL, so the *native Linux* `op` cannot use desktop integration there.

The fix: call the **Windows `op.exe`** from WSL. It talks to the Windows desktop app over the app's named-pipe IPC and authorizes reads through Windows Hello / desktop unlock. WSL invokes Windows binaries transparently via interop, and `op.exe` writes secrets to stdout that your WSL shell captures normally.

```text
WSL shell ──> op.exe (Windows) ──> 1Password desktop app (Windows)
                                        └─ Windows Hello / desktop unlock
```

`lib/1password.sh` resolves the binary automatically: it prefers `op.exe` and falls back to the native `op` only when `op.exe` isn't found.

## Prerequisites

1. **1Password desktop app** installed on Windows and signed in to your account(s).
2. **Windows 1Password CLI** (`op.exe`):

   ```powershell
   winget install AgileBits.1Password.CLI
   ```

3. **CLI integration enabled** in the desktop app: **Settings → Developer → "Integrate with 1Password CLI"** (checked).
4. **WSL interop enabled** (default). Verify with `cat /etc/wsl.conf` — `[interop] enabled` should be present, or interop is on by default.

## Configure preflight

In `config/accounts.sh`, set `OP_ACCOUNT` to your **sign-in address**, not a shorthand. The desktop-fed `op.exe` lists accounts by address and does not carry the manual `op account add` shorthand:

```bash
export OP_ACCOUNT="my-team.1password.com"
```

Find your address with:

```bash
op.exe account list
```

Then point the secret references in `op-load-env` (in `lib/1password.sh`) at your items. Each is a per-secret `op read`; the first triggers the desktop unlock and the rest are authorized automatically.

## Verify

```bash
op-status      # reports the resolved binary and account
op-load-env    # first read prompts a desktop unlock, then loads all secrets
```

A successful run prints `✅ <VAR>` for each secret. A one-off read to sanity-check a single reference — use `$OP_BIN` (set by `op-signin`) so it goes through the same binary the helpers resolved, not a bare `op` that would pick the native Linux CLI and skip desktop integration:

```bash
op-signin && "$OP_BIN" read --account "$OP_ACCOUNT" "op://<Vault>/<Item>/<field>"
```

## Notes and gotchas

- **Account reference:** use the sign-in address (`my-team.1password.com`) under desktop integration, not a shorthand. A stale `op account add` shorthand silently fails every read (errors are swallowed, vars come back empty).
- **No batch `op run`:** the efficient `op run --env-file -- bash -c …` trick does **not** work with `op.exe` — being a Windows binary, its `-- bash -c` child is a Windows process, not WSL bash. `op-load-env` therefore uses per-secret reads. With the app unlocked they are authorized without re-prompting.
- **First-read prompt:** the desktop app prompts on the first authorized call per session; subsequent reads are silent per the app's "remember" policy.
- **op.exe not on PATH:** the resolver also globs the WinGet package and `Program Files` locations, so PATH setup is optional.

## Related

- [WSL SSH Setup with 1Password](./wsl-ssh-setup.md) — the SSH-agent counterpart (Git/SSH auth via the Windows 1Password SSH agent).
