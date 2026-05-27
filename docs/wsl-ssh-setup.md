# WSL SSH Setup with 1Password

Use the 1Password SSH agent on Windows to authenticate SSH and Git commands in WSL — no local key files needed.

## How it works

1Password runs on Windows and exposes its SSH agent on a named pipe (`\\.\pipe\openssh-ssh-agent`). WSL can call `ssh.exe` (the Windows OpenSSH binary) directly, which forwards authentication requests to that pipe. The result: your SSH keys never leave 1Password, and WSL gets seamless SSH auth through Windows Hello / biometric unlock.

```
WSL git push
  └─ ssh.exe (Windows binary, called by git via core.sshCommand)
       └─ \\.\pipe\openssh-ssh-agent  (1Password SSH agent on Windows)
            └─ Your SSH key in 1Password vault
```

## Prerequisites (manual — one time per machine)

These steps require GUI interaction or admin access and can't be automated by `preflight configure`.

### 1. Enable the 1Password SSH Agent

In the **1Password Windows app**:

1. Settings → Developer
2. Check **Use the SSH Agent** — the badge should show **running**
3. Optional but recommended: check **Display key names when authorizing connections**

> If you see a warning about the OpenSSH Authentication Agent service, follow the prompt to disable it. The Windows built-in agent and 1Password's agent can't both listen on the same pipe.

### 2. Disable the competing Windows OpenSSH service (if needed)

If 1Password shows a conflict with the built-in OpenSSH Authentication Agent:

1. Press `Win + R`, type `services.msc`, press Enter
2. Find **OpenSSH Authentication Agent**
3. Double-click → Startup type: **Disabled**, Status: **Stopped**
4. Click Apply → OK

### 3. Add an SSH key to 1Password (if you don't have one)

In **1Password**:

1. New Item → **SSH Key**
2. Add Private Key → **Generate New Key** → Ed25519 → Generate → Save
3. Copy the public key and add it to [GitHub SSH keys](https://github.com/settings/ssh/new) (or wherever needed)

### 4. Check WSL interop is enabled

Confirm `/etc/wsl.conf` has interop enabled (it should be `true` by default):

```ini
[interop]
enabled = true
```

> Note: `appendWindowsPath=false` is fine — it prevents Windows binaries from polluting your PATH, but doesn't affect `/mnt/c/...` file access or calling specific `.exe` files by full path.

---

## Automated steps (`preflight configure`)

Once the prerequisites above are done, run:

```bash
preflight configure
```

This will offer to configure the following automatically:

| What | Where |
|------|-------|
| `alias ssh='ssh.exe'` + `alias ssh-add='ssh-add.exe'` | `~/.bashrc` |
| `export SSH_AUTH_SOCK=$HOME/.1password/agent.sock` | `~/.bashrc` |
| `git config --global core.sshCommand /mnt/c/Windows/System32/OpenSSH/ssh.exe` | `~/.gitconfig` |
| `Host * IdentityAgent ~/.1password/agent.sock` | `~/.ssh/config` |
| `Host * IdentityAgent \\.\pipe\openssh-ssh-agent` | `C:\Users\<you>\.ssh\config` |

Or to apply all without prompting:

```bash
preflight configure --yes
```

---

## Verifying it works

After running `preflight configure` and reloading your shell:

```bash
# Should list your 1Password SSH keys
ssh-add.exe -l

# Should print "Hi <username>! You've successfully authenticated..."
ssh.exe -T git@github.com

# Full git workflow through 1Password
git push
```

1Password will prompt for Windows Hello / biometric approval on first use per session.

---

## Git commit signing (optional)

To also sign Git commits with your SSH key via 1Password:

1. In **1Password**, open your SSH Key item
2. `···` menu → **Configure Commit Signing**
3. Check **Configure for Windows Subsystem for Linux (WSL)**
4. Copy the snippet and paste it into `~/.gitconfig` in WSL

This sets `gpg.format = ssh`, `user.signingkey`, and `gpg.ssh.program` to 1Password's signing binary.

---

## Troubleshooting

**`ssh-add.exe: command not found`**
- Check `/mnt/c/Windows/System32/OpenSSH/ssh-add.exe` exists
- If not, install OpenSSH: Windows Settings → Apps → Optional Features → OpenSSH Client
- If `appendWindowsPath=false` is set, use the full path or add an explicit alias

**`sign_and_send_pubkey: signing failed`**
- 1Password is locked — unlock it and try again
- Check 1Password Developer settings show SSH Agent as **running**

**`Too many authentication failures`**
- You have more than 6 SSH keys in 1Password — OpenSSH servers reject after 6 attempts
- Fix: add a `~/.ssh/config` entry specifying which key to use per host:
  ```
  Host github.com
    IdentityFile ~/.ssh/your-github-key.pub
    IdentitiesOnly yes
  ```
  Download the public key from the 1Password item and place it in `~/.ssh/`.

**Keys not showing after WSL restart**
- 1Password may have locked — unlock it on Windows
- Confirm the SSH agent still shows **running** in 1Password Developer settings
