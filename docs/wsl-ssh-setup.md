# WSL SSH Setup with 1Password

Use the 1Password SSH agent on Windows for SSH and Git in Windows Subsystem for Linux (WSL). Your keys stay in 1Password, and every Linux tool (`ssh`, `scp`, `rsync`, `git`, scripts, hooks) can use them.

## How it works

1Password exposes its SSH agent on a Windows named pipe. WSL can't talk to that pipe directly, so a systemd user socket bridges it to a normal Unix socket:

```text
git / ssh (native Linux)
  → ~/.1password/agent.sock         (SSH_AUTH_SOCK, exported from ~/.profile)
  → 1password-agent.socket          (systemd user unit, Accept=yes)
  → 1password-agent@.service        (runs npiperelay.exe once per connection)
  → \\.\pipe\openssh-ssh-agent      (1Password agent on Windows)
```

systemd accepts each connection and hands it to `npiperelay.exe` as stdin/stdout. There is no `socat` and no long-running relay process.

### Comparison with the `ssh.exe` approach

1Password's [WSL guide](https://www.1password.dev/ssh/integrations/wsl/) tells you to alias `ssh` and `ssh-add` to the `.exe` versions and to set `git config --global core.sshCommand ssh.exe`. That works for interactive use, but:

- Native `ssh`, `scp`, `rsync` and scripts never get an agent. Aliases only apply to interactive shells.
- Windows `ssh.exe` reads the **Windows** `~/.ssh/config` and `known_hosts`, so your WSL SSH config is ignored.

The bridge avoids both. 1Password's guide doesn't cover a native Unix socket for WSL, so the bridge is how you get a native agent.

## Windows prerequisites

These steps need the 1Password or Windows interface, or administrator rights, so `preflight configure` can't do them. Every WSL distro on the machine shares them, so skip any you have already done.

1. **Enable the 1Password SSH agent.** In the Windows app: Settings → Developer → **Use the SSH agent**. The badge should read **running**.
   If 1Password warns about the *OpenSSH Authentication Agent* service, disable that service (`services.msc` → Startup type: Disabled → Stop). Both agents can't listen on the same pipe.
2. **Add an SSH key** to 1Password (New Item → SSH Key) and register its public key with GitHub.
3. **Install the 1Password CLI on Windows.** Preflight uses it for secrets, as described in [1Password CLI](./wsl-1password-cli.md). Run `winget install AgileBits.1Password.CLI`, then enable Settings → Developer → **Integrate with 1Password CLI**.

## WSL prerequisites

Enable systemd in `/etc/wsl.conf`, then restart WSL from PowerShell:

```ini
[boot]
systemd=true
```

```powershell
wsl --shutdown
```

> `appendWindowsPath=false` is fine. The bridge uses full paths and never needs Windows binaries on `PATH`.

## Automated setup

```bash
preflight configure
```

For the WSL SSH section it does the following, asking before each step (`--yes` applies all):

| Step | Where |
|------|-------|
| Install npiperelay (the [albertony fork](https://github.com/albertony/npiperelay), a Windows program that connects standard input and output to a named pipe, verified against a checksum) | `~/.local/bin/npiperelay.exe` |
| Write the socket and service units, enable the socket | `~/.config/systemd/user/1password-agent.socket`, `1password-agent@.service` |
| Export `SSH_AUTH_SOCK` | `~/.profile` |
| Point SSH at the agent | `~/.ssh/config`: `Host *` → `IdentityAgent "~/.1password/agent.sock"` |
| Trust GitHub's host keys (from `gh api meta`) | `~/.ssh/known_hosts` |
| Remove the old `ssh` and `ssh-add` aliases and `SSH_AUTH_SOCK` from `.bashrc`, and unset `core.sshCommand` | `~/.bashrc`, `~/.gitconfig` |
| Check for the Windows `op.exe` | reported only |

`SSH_AUTH_SOCK` goes in `~/.profile`, not `~/.bashrc`, because it is environment configuration and not interactive configuration. Git hooks, cron jobs and spawned scripts skip `.bashrc`, so with the export there only your own terminals get the agent. That gap is easy to miss because your terminals keep working. `~/.profile` does not reach zsh or non-login Bash shells either, so preflight's `init.sh` also exports it in interactive shells whenever the bridge socket exists and no other agent is configured.

Open a new terminal afterwards so the old aliases are dropped.

## Manual setup

If you'd rather not use `preflight configure`:

```bash
# 1. npiperelay: the albertony fork, not jstarks (upstream is frozen at 0.1.0)
V=v1.12.1
B=https://github.com/albertony/npiperelay/releases/download/$V
curl -fsSL -o /tmp/npiperelay.exe $B/npiperelay_windows_amd64.exe
curl -fsSL $B/npiperelay_checksums.txt | grep windows_amd64.exe
sha256sum /tmp/npiperelay.exe          # must match the line above
install -D -m 0755 /tmp/npiperelay.exe ~/.local/bin/npiperelay.exe
```

`~/.config/systemd/user/1password-agent.socket`:

```ini
[Unit]
Description=1Password SSH agent bridge (Windows named pipe -> WSL unix socket)

[Socket]
ListenStream=%h/.1password/agent.sock
SocketMode=0600
Accept=yes
RemoveOnStop=yes

[Install]
WantedBy=sockets.target
```

`~/.config/systemd/user/1password-agent@.service` (the `@` is required):

```ini
[Unit]
Description=1Password SSH agent bridge connection %i
Requires=1password-agent.socket

[Service]
Type=simple
ExecStart=%h/.local/bin/npiperelay.exe -ei -s //./pipe/openssh-ssh-agent
StandardInput=socket
StandardOutput=socket
StandardError=journal
```

```bash
mkdir -p ~/.1password && chmod 700 ~/.1password
systemctl --user daemon-reload
systemctl --user enable --now 1password-agent.socket

echo 'export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"' >> ~/.profile
mkdir -p ~/.ssh && chmod 700 ~/.ssh
printf 'Host *\n  IdentityAgent "~/.1password/agent.sock"\n' >> ~/.ssh/config && chmod 600 ~/.ssh/config
```

Do **not** set `ssh`/`ssh-add` aliases or `core.sshCommand`.

### npiperelay flags

- `-ei` makes the relay exit when its input closes, so each relay ends with its ssh client. Without it, `npiperelay.exe` processes accumulate.
- `-s` sends a zero-byte message after the end of input, so the agent sees a complete request.
- Never use `-p`. It polls until the pipe is free, but 1Password serves a single pipe instance, so the poll loops forever and leaves one orphaned process per SSH operation. Don't force-kill stuck relays either. Killing an in-flight pipe client can wedge the agent until you toggle the SSH agent setting in 1Password.

## Verification

```bash
systemctl --user is-active 1password-agent.socket   # active
/usr/bin/ssh-add -l                                 # lists your 1Password keys
ssh -T git@github.com                               # "Hi <user>! You've successfully authenticated…"
```

Listing keys needs no approval, but signing does. `ssh-add -l` returns immediately, while `ssh -T` waits for an approval click in the 1Password window on Windows. If nobody approves, you get `sign_and_send_pubkey: signing failed … agent refused operation`. That error means authorization was declined, not that the relay is broken. Unattended SSH, such as cron jobs and scripts, always needs an approval.

## Removal

`preflight uninstall` does not touch these, because the bridge works without preflight. To remove it:

```bash
systemctl --user disable --now 1password-agent.socket
rm ~/.config/systemd/user/1password-agent.socket ~/.config/systemd/user/1password-agent@.service
rm ~/.local/bin/npiperelay.exe
systemctl --user daemon-reload
```

Then delete the `SSH_AUTH_SOCK` line from `~/.profile` and the `IdentityAgent` entry from `~/.ssh/config`.

## Git commit signing

To sign commits with your 1Password SSH key (optional):

1. In 1Password, open your SSH Key item.
2. `···` menu → **Configure Commit Signing**.
3. Check **Configure for Windows Subsystem for Linux (WSL)**.
4. Paste the snippet into `~/.gitconfig` in WSL.

This sets `gpg.format = ssh`, `user.signingkey`, and `gpg.ssh.program` to 1Password's `op-ssh-sign-wsl` binary. 1Password app versions 8.11.18+ moved that binary to `…/Microsoft/WindowsApps/op-ssh-sign-wsl.exe`. If signing breaks after an app upgrade, re-copy the snippet.

## Fallback without systemd

If you can't enable systemd, use 1Password's interop approach instead. It only covers interactive shells and `git`:

```bash
# ~/.bashrc
export SSH_AUTH_SOCK=$HOME/.1password/agent.sock   # optional
alias ssh='/mnt/c/Windows/System32/OpenSSH/ssh.exe'
alias ssh-add='/mnt/c/Windows/System32/OpenSSH/ssh-add.exe'

git config --global core.sshCommand /mnt/c/Windows/System32/OpenSSH/ssh.exe
```

In this mode `preflight` still reports agent status, but `preflight configure` doesn't set anything up.

## Troubleshooting

Each heading below is a symptom, followed by its likely causes.

### `Host key verification failed`
- Native `ssh` uses the WSL `known_hosts`, not the Windows one. Run `preflight configure` (it adds GitHub's keys), or connect once interactively and accept the host key for other hosts.

### `ssh-add -l` says "Could not open a connection to your authentication agent"
- `SSH_AUTH_SOCK` isn't set in this shell. Open a new login shell, or `export SSH_AUTH_SOCK=$HOME/.1password/agent.sock`.
- Check the socket: `systemctl --user status 1password-agent.socket`.

### `ssh-add -l` hangs or returns nothing
- 1Password is locked, or the SSH agent shows stopped in Settings → Developer. Unlock it and confirm **Use the SSH agent** is on.
- Toggle the SSH agent setting off and on if relays were force-killed.

### `sign_and_send_pubkey: signing failed … agent refused operation`
- The approval prompt in 1Password on Windows was declined or missed. Retry and approve it, as described in [Verification](#verification).

### It authenticates but 1Password never prompted
- ssh may have fallen back to an on-disk key such as `~/.ssh/id_ed25519` after the agent refused. If 1Password should be authoritative, add `IdentitiesOnly yes` to the relevant `Host` block in `~/.ssh/config`, or move the key out, so a refusal fails loudly.

**`ssh_agent_bind_hostkey: agent refused operation`** (in `ssh -vv`)
- Harmless. 1Password doesn't implement host-key binding.

### Agent resolves to the wrong keys
- A competing agent (for example GNOME Keyring's `gcr-ssh-agent.socket`) may be serving `SSH_AUTH_SOCK`. Mask it: `systemctl --user mask gcr-ssh-agent.socket`.

### `Too many authentication failures`
- You have more than 6 SSH keys in 1Password, and OpenSSH servers reject after 6 attempts. Save the public key from the 1Password item to `~/.ssh/github-key.pub` and reference it **without** the `.pub` extension:
  ```
  Host github.com
    IdentityFile ~/.ssh/github-key
    IdentitiesOnly yes
  ```
  The private key stays in 1Password.

### Keys missing after a WSL or Windows restart
- 1Password may have locked. Unlock it on Windows and confirm the SSH agent still shows **running**.
