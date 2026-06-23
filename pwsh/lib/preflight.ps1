# lib/preflight.ps1 — session startup orchestrator (PowerShell sibling of bash `preflight`).
#
# Sections:
#   1. Secrets         — calls Import-OpEnv to load all op:// references
#   2. AWS Profile     — apply $env:AWS_PROFILE_DEFAULT if AWS_PROFILE unset
#   3. AWS Session     — detect identity / token expiry; warn (don't auto-refresh)
#   4. Environment     — sanity-check NPM_TOKEN; verify `gh` auth
#   5. SSH             — verify 1Password (or built-in) ssh agent is reachable
#   6. Installed Tools — versions of sam/docker/kubectl/terraform/gh/op/jq/fzf/claude/uv
#                        with optional -CheckUpdates to compare against latest releases.
#   7. Git config      — required + recommended global git settings
#   8. Node.js         — version reports for node + npm (info-only)
#   9. Python          — version reports for python + uv (uv missing = issue)
#  10. Summary         — pass / N issue(s) found

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI orchestrator; Write-Host is appropriate.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'ScriptBlock closures are invoked via & — analyzer cannot trace closure-bound params (verbose/hasTty).'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseUsingScopeModifierInNewRunspaces', '',
    Justification = 'Start-Job uses param() + -ArgumentList for parameter passing, not the $using: modifier (which is for Invoke-Command and ForEach-Object -Parallel). The analyzer does not distinguish.'
)]
param()

function Invoke-Preflight {
    <#
    .SYNOPSIS
        Run session startup checks: sign in to 1Password, load secrets,
        verify AWS, check SSH/git/Node/Python health, and report a summary.
        PowerShell sibling of bash `preflight`.
    .DESCRIPTION
        By default runs in "quiet" mode — section progress overwrites a single
        status line, only the final summary remains visible. Use -Verbose for
        full streaming output of every check.

        Sections:
          1. Secrets — Import-OpEnv if op CLI is available
          2. AWS Profile — set $env:AWS_PROFILE if unset
          3. AWS Session — sts get-caller-identity, warn on expiry
          4. Environment Variables — NPM_TOKEN + gh auth
          5. SSH — 1Password / built-in ssh agent has keys loaded
          6. Installed Tools — versions of sam, docker, kubectl, terraform,
             gh, op, jq, fzf, claude, uv. With -CheckUpdates, fetches latest
             from GitHub releases (in parallel) and flags drift.
          7. Git Configuration — user.email/name, fetch.prune,
             push.default/autoSetupRemote, pull.rebase, rebase.autoStash,
             diff.algorithm, merge.conflictstyle, core.excludesFile
          8. Node.js — node + npm version (info-only)
          9. Python — python + uv. uv missing raises an issue (the team's
             Python toolchain).
    .PARAMETER SkipSecrets
        Don't call Import-OpEnv. Useful when you only want the AWS/env checks.
    .PARAMETER SkipAws
        Don't poke at AWS. Useful when you're offline or working without SSO.
    .PARAMETER CheckUpdates
        For installed tools, fetch the latest release tag from GitHub and
        flag drift. Adds a few seconds in the common path; up to 30 seconds
        if the network is slow or GitHub is rate-limiting (`Wait-Job
        -Timeout 30` caps the per-batch wait).
    .EXAMPLE
        Invoke-Preflight
    .EXAMPLE
        preflight
    .EXAMPLE
        preflight -Verbose
    .EXAMPLE
        preflight -CheckUpdates
    .EXAMPLE
        preflight -SkipAws -SkipSecrets
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipSecrets,
        [switch]$SkipAws,
        [Alias('u', 'Updates')]
        [switch]$CheckUpdates
    )

    # The PowerShell common parameter -Verbose populates $VerbosePreference;
    # we use it directly to gate the streaming output instead of inventing
    # our own switch (matches PS conventions).
    $verbose = ($VerbosePreference -ne 'SilentlyContinue')

    # ---- Output helpers (closures over $verbose) ---------------------------

    $hasTty = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected

    $writeStatus = {
        param([string]$msg)
        if (-not $verbose -and $hasTty) {
            $line = "  {0,-60}" -f $msg
            [Console]::Write("`r$line")
        }
    }
    $clearStatus = {
        if (-not $verbose -and $hasTty) {
            [Console]::Write("`r" + (' ' * 70) + "`r")
        }
    }
    $writeSection = {
        param([string]$title)
        if ($verbose) {
            Write-Host ''
            Write-Host "--- $title ---"
            Write-Host ''
        }
    }
    $writeLine = {
        param([string]$msg)
        if ($verbose) { Write-Host $msg }
    }

    $issues          = New-Object System.Collections.Generic.List[string]
    $updatesAvail    = New-Object System.Collections.Generic.List[string]

    # ---- Header ------------------------------------------------------------
    Write-Host ''
    Write-Host '  ── preflight ──' -ForegroundColor Cyan
    Write-Host ''

    # ====================================================================
    # 1. Secrets
    # ====================================================================
    & $writeSection 'Secrets'
    & $writeStatus 'Secrets: loading...'

    if ($SkipSecrets) {
        & $writeLine '  (skipped: -SkipSecrets)'
    } elseif (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        $issues.Add('1Password CLI (op) not installed') | Out-Null
        & $writeLine '❌ op CLI not installed'
    } else {
        # Tell Import-OpEnv to skip its own header — we already printed our
        # section header (in verbose mode) above.
        $env:_PREFLIGHT_NESTED = '1'
        try {
            if ($verbose) {
                Import-OpEnv
            } else {
                $opOutput = & {
                    Import-OpEnv 2>&1
                } 6>&1 | Out-String
                $missing = $opOutput -split "`r?`n" | Where-Object { $_ -match 'failed to load' }
                foreach ($m in $missing) {
                    $issues.Add(($m -replace '^\s*[⚠❌]+\s*', '').Trim()) | Out-Null
                }
            }
        } finally {
            Remove-Item Env:_PREFLIGHT_NESTED -ErrorAction SilentlyContinue
        }
    }

    # ====================================================================
    # 2 + 3. AWS Profile + Session
    # ====================================================================
    if (-not $SkipAws) {
        & $writeSection 'AWS Profile'
        & $writeStatus 'AWS: setting profile...'

        if (-not $env:AWS_PROFILE) {
            $default = if ($env:AWS_PROFILE_DEFAULT) { $env:AWS_PROFILE_DEFAULT } else { 'guild-dev' }
            $env:AWS_PROFILE = $default
            & $writeLine "✅ AWS_PROFILE set to $default (default)"
        } else {
            & $writeLine "✅ AWS_PROFILE already set: $env:AWS_PROFILE"
        }

        & $writeSection 'AWS Session'
        & $writeStatus 'AWS: checking session...'

        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
            $issues.Add('AWS CLI not installed') | Out-Null
            & $writeLine '❌ AWS CLI not installed'
        } else {
            $awsOut = & aws sts get-caller-identity --output json 2>&1
            $awsRc  = $LASTEXITCODE
            if ($awsRc -eq 0) {
                try {
                    $identity = $awsOut | ConvertFrom-Json
                    & $writeLine "✅ AWS session active (account $($identity.Account), $($identity.Arn -replace '^arn:aws:[^:]*::\d+:', ''))"
                } catch {
                    & $writeLine '✅ AWS session active'
                }
            } else {
                $awsErr = ($awsOut | Out-String).Trim()
                $loginCmd = "aws sso login --profile $env:AWS_PROFILE"
                if ($awsErr -match 'Token for [^ ]+ does not exist|SSO Token|sso session') {
                    $issues.Add("AWS SSO not signed in — run: $loginCmd") | Out-Null
                    & $writeLine "⚠️  AWS SSO not signed in — run: $loginCmd"
                } elseif ($awsErr -match 'ExpiredToken|session.*expired|expired') {
                    $issues.Add("AWS SSO token expired — run: $loginCmd") | Out-Null
                    & $writeLine "⚠️  AWS SSO token expired — run: $loginCmd"
                } elseif ($awsErr -match 'NoCredentials|Unable to locate credentials') {
                    $issues.Add("AWS not signed in — run: $loginCmd") | Out-Null
                    & $writeLine "⚠️  AWS not signed in — run: $loginCmd"
                } else {
                    $issues.Add("AWS check failed: " + (($awsErr -split "`n")[0])) | Out-Null
                    & $writeLine "⚠️  AWS check failed (run with -Verbose for details)"
                }
            }
        }
    }

    # ====================================================================
    # 4. Environment Variables
    # ====================================================================
    & $writeSection 'Environment Variables'
    & $writeStatus 'Env: checking tokens...'

    if ($env:NPM_TOKEN) {
        & $writeLine '✅ NPM_TOKEN is set'
    } else {
        $issues.Add('NPM_TOKEN is not set (run Import-OpEnv or check accounts.ps1)') | Out-Null
        & $writeLine '⚠️  NPM_TOKEN is not set'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $issues.Add('gh CLI not installed — install from https://cli.github.com/') | Out-Null
        & $writeLine '⚠️  gh CLI not installed'
    } else {
        $null = & gh auth status --hostname github.com 2>&1
        if ($LASTEXITCODE -eq 0) {
            & $writeLine '✅ GitHub auth active (gh CLI)'
        } else {
            $issues.Add("GitHub auth not found — run: gh auth login") | Out-Null
            & $writeLine "⚠️  GitHub auth not found — run: gh auth login"
        }
    }

    # ====================================================================
    # 5. SSH
    # ====================================================================
    & $writeSection 'SSH'
    & $writeStatus 'SSH: checking agent...'

    # On Windows the canonical ssh agent path is OpenSSH's `ssh-agent` service
    # OR 1Password's SSH agent (if the user has it enabled). Either way we
    # query the agent via `ssh-add -l` — the difference is which agent answers.
    # 1Password's agent registers a named pipe; OpenSSH's registers a Windows
    # service. ssh-add doesn't care which, it just connects to the configured
    # SSH_AUTH_SOCK / Windows pipe.
    if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
        $issues.Add('ssh-add not found — install Windows OpenSSH (Settings > Optional Features) or Git for Windows') | Out-Null
        & $writeLine '⚠️  ssh-add not found in PATH'
    } else {
        $sshOut = & ssh-add -l 2>&1
        $sshRc  = $LASTEXITCODE
        # Count fingerprint lines. Wrap with @() AFTER the filter so a single
        # match (which Where-Object would unwrap to a scalar) still has .Count.
        $keyCount = @($sshOut | Where-Object { $_ -match 'SHA256:' }).Count

        if ($keyCount -gt 0) {
            & $writeLine "✅ SSH agent active ($keyCount key(s) loaded)"
        } elseif ($sshRc -ne 0 -and ($sshOut -match 'no identities')) {
            $issues.Add('SSH agent running but no keys loaded — open 1Password ▸ Developer ▸ SSH Agent or `ssh-add ~/.ssh/id_ed25519`') | Out-Null
            & $writeLine '⚠️  SSH agent running but no keys loaded'
        } else {
            $issues.Add('SSH agent not reachable — is 1Password running with SSH Agent enabled, or the OpenSSH service started?') | Out-Null
            & $writeLine '⚠️  SSH agent not reachable'
        }
    }

    # ====================================================================
    # 6. Installed Tools (with optional -CheckUpdates)
    # ====================================================================
    if ($CheckUpdates) {
        & $writeSection 'Installed Tools (checking latest versions...)'
        & $writeStatus 'Tools: fetching latest versions...'
    } else {
        & $writeSection 'Installed Tools'
        & $writeStatus 'Tools: checking...'
    }

    # cmd, label, gh-api-repo (or '' for no upstream check), winget id, choco id
    $tools = @(
        @{ Cmd = 'sam';       Label = 'AWS SAM CLI';       Repo = 'aws/aws-sam-cli';   Winget = 'Amazon.SAM-CLI';        Choco = 'aws-sam-cli'      }
        @{ Cmd = 'docker';    Label = 'Docker';            Repo = 'moby/moby';         Winget = 'Docker.DockerDesktop';  Choco = 'docker-desktop'   }
        @{ Cmd = 'kubectl';   Label = 'Kubernetes kubectl'; Repo = '';                 Winget = 'Kubernetes.kubectl';    Choco = 'kubernetes-cli'   }
        @{ Cmd = 'terraform'; Label = 'Terraform';         Repo = 'hashicorp/terraform'; Winget = 'Hashicorp.Terraform'; Choco = 'terraform'        }
        @{ Cmd = 'gh';        Label = 'GitHub CLI';        Repo = 'cli/cli';           Winget = 'GitHub.cli';            Choco = 'gh'               }
        @{ Cmd = 'op';        Label = '1Password CLI';     Repo = '';                  Winget = 'AgileBits.1PasswordCLI';Choco = '1password-cli'    }
        @{ Cmd = 'jq';        Label = 'jq';                Repo = 'jqlang/jq';         Winget = 'jqlang.jq';             Choco = 'jq'               }
        @{ Cmd = 'fzf';       Label = 'fzf';               Repo = 'junegunn/fzf';      Winget = 'junegunn.fzf';          Choco = 'fzf'              }
        @{ Cmd = 'claude';    Label = 'Claude Code';       Repo = '';                  Winget = '';                      Choco = ''                 }
        @{ Cmd = 'uv';        Label = 'uv';                Repo = 'astral-sh/uv';      Winget = 'astral-sh.uv';          Choco = ''                 }
    )

    # Resolve installed versions first so we know what to compare against.
    foreach ($t in $tools) {
        $cmd = Get-Command $t.Cmd -ErrorAction SilentlyContinue
        if ($cmd) {
            try {
                # Some CLIs (sam, docker on WSL paths) print warnings to stderr
                # before the version line. Find the first line that contains a
                # version-like token, AVOIDING lines that look like file paths
                # (e.g. WSL UNC warnings: '\\wsl.localhost\Ubuntu-24.04\...').
                $output = & $t.Cmd --version 2>&1
                $raw = ''
                foreach ($line in @($output)) {
                    $s = "$line"
                    # Skip path-like lines (Windows or POSIX) — heuristic but
                    # specific enough that it never eats real version output.
                    if ($s -match '^\s*[\\/]' -or $s -match '\\\\') { continue }
                    if ($s -match '\d+\.\d+') { $raw = $s; break }
                }
                if (-not $raw) { $raw = "$output" }
            } catch {
                $raw = 'installed'
            }
            $t['Raw'] = "$raw".Trim()
            if ($t['Raw'] -match '\d+\.\d+(\.\d+)*') {
                $t['Installed'] = $matches[0]
            } else {
                $t['Installed'] = $t['Raw']
            }
        }
    }

    # If -CheckUpdates: fan out gh API calls in parallel via PS jobs. claude is
    # special-cased — it ships via npm, not GitHub releases.
    $latest = @{}
    if ($CheckUpdates -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $jobs = @()
        foreach ($t in $tools) {
            if ($t.Repo) {
                $jobs += Start-Job -Name "pf-$($t.Cmd)" -ScriptBlock {
                    param($repo)
                    $tag = & gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        # Extract a semver-ish substring from the tag. Repos use
                        # varied conventions: 'v1.2.3', 'jq-1.8.1', 'docker-v29.5.3',
                        # '0.11.19'. We just pull out the longest digit-and-dot
                        # run we can find.
                        if ("$tag" -match '\d+\.\d+(\.\d+)*') {
                            $clean = $matches[0]
                        } else {
                            $clean = "$tag".Trim()
                        }
                        return @{ Cmd = $repo.Split('/')[1]; Tag = $clean }
                    }
                    return $null
                } -ArgumentList $t.Repo
            }
        }
        # claude — npm registry
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            $jobs += Start-Job -Name 'pf-claude' -ScriptBlock {
                $v = & npm view '@anthropic-ai/claude-code' version 2>$null
                if ($LASTEXITCODE -eq 0 -and $v) {
                    return @{ Cmd = 'claude'; Tag = "$v".Trim() }
                }
                return $null
            }
        }

        $jobs | Wait-Job -Timeout 30 | Out-Null
        foreach ($job in $jobs) {
            try {
                $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
                if ($result -and $result.Tag) {
                    $latest[$result.Cmd] = $result.Tag
                }
            } catch {
                # Job failed (network, gh auth, rate limit). Record under
                # Verbose for debugging but don't block — the comparison
                # just falls through to "no upstream version available".
                Write-Verbose "preflight: $($job.Name) version-check job failed: $_"
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($t in $tools) {
        if (-not $t.ContainsKey('Installed')) {
            & $writeLine ("❌ {0} not installed" -f $t.Label)
            continue
        }

        # Map the tool's repo name to its key in $latest. e.g. cli/cli -> 'cli'
        $latestKey = if ($t.Repo) { $t.Repo.Split('/')[-1] } else { $t.Cmd }
        $latestVer = $latest[$latestKey]

        # Compare versions: prefer parsed [Version] semantics so users on a
        # dev build NEWER than the latest tagged release don't see a bogus
        # "X → Y available" downgrade nag. Fall back to string -ne if either
        # side doesn't parse cleanly (rare — a few tools like jq emit
        # non-semver, but the regex extractor in $tools normalizes most).
        $isUpdate = $false
        if ($latestVer) {
            $parsedInstalled = $null
            $parsedLatest    = $null
            if ([Version]::TryParse($t.Installed, [ref]$parsedInstalled) -and
                [Version]::TryParse($latestVer,   [ref]$parsedLatest)) {
                $isUpdate = ($parsedInstalled -lt $parsedLatest)
            } else {
                # Couldn't parse one or both; fall back to string inequality.
                # This is more permissive but still useful as a heads-up.
                $isUpdate = ($t.Installed -ne $latestVer)
            }
        }

        if ($isUpdate) {
            $hint = if ($t.Winget) {
                "winget upgrade $($t.Winget)"
            } elseif ($t.Choco) {
                "choco upgrade $($t.Choco)"
            } else {
                ''
            }
            $msg = "{0}: {1} → {2} available" -f $t.Label, $t.Installed, $latestVer
            if ($hint) { $msg += "  ($hint)" }
            $updatesAvail.Add($msg) | Out-Null
            & $writeLine ("⚠️  {0}: {1} → {2} available" -f $t.Label, $t.Installed, $latestVer)
            if ($hint -and $verbose) {
                & $writeLine "    Update: $hint"
            }
        } else {
            & $writeLine ("✅ {0}: {1}" -f $t.Label, $t.Raw)
        }
    }

    # ====================================================================
    # 7. Git Configuration
    # ====================================================================
    & $writeSection 'Git Configuration'
    & $writeStatus 'Git: checking config...'

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $issues.Add('git not installed') | Out-Null
        & $writeLine '❌ git not installed'
    } else {
        $gitVersion = (& git --version 2>$null) -replace '^git version\s*', ''
        & $writeLine "✅ git installed: $gitVersion"

        # Helper: read a global config; null if unset or git fails.
        $readCfg = {
            param([string]$key)
            $v = & git config --global $key 2>$null
            if ($LASTEXITCODE -eq 0) { return "$v".Trim() }
            return $null
        }

        # ---- Identity (required) ----
        $email = & $readCfg 'user.email'
        if ($email) {
            & $writeLine "✅ user.email: $email"
        } else {
            $issues.Add('git user.email not set — run: git config --global user.email "you@example.com"') | Out-Null
            & $writeLine '⚠️  git user.email not set'
        }
        $name = & $readCfg 'user.name'
        if ($name) {
            & $writeLine "✅ user.name: $name"
        } else {
            $issues.Add('git user.name not set — run: git config --global user.name "Your Name"') | Out-Null
            & $writeLine '⚠️  git user.name not set'
        }

        # ---- Fetch hygiene ----
        if ((& $readCfg 'fetch.prune') -eq 'true') {
            & $writeLine '✅ fetch.prune = true'
        } else {
            $issues.Add('fetch.prune not set — run: git config --global fetch.prune true') | Out-Null
            & $writeLine '⚠️  fetch.prune not set — stale remote branches accumulate'
        }

        # ---- Push safety ----
        $pushDefault = & $readCfg 'push.default'
        if ($pushDefault -eq 'matching') {
            $issues.Add('push.default = matching — run: git config --global push.default simple') | Out-Null
            & $writeLine '⚠️  push.default = matching — can push unintended branches'
        }
        if ((& $readCfg 'push.autoSetupRemote') -eq 'true') {
            & $writeLine '✅ push.autoSetupRemote = true'
        } else {
            $issues.Add('push.autoSetupRemote not set — run: git config --global push.autoSetupRemote true') | Out-Null
            & $writeLine '⚠️  push.autoSetupRemote not set — new branches need manual upstream'
        }

        # ---- Pull / rebase strategy ----
        $pullRebase = & $readCfg 'pull.rebase'
        if ($pullRebase -in @('true', 'merges', 'interactive')) {
            & $writeLine "✅ pull.rebase = $pullRebase"
        } else {
            $issues.Add('pull.rebase not set — run: git config --global pull.rebase true') | Out-Null
            & $writeLine '⚠️  pull.rebase not set — diverged pulls create merge commits'
        }
        if ((& $readCfg 'rebase.autoStash') -eq 'true') {
            & $writeLine '✅ rebase.autoStash = true'
        } else {
            $issues.Add('rebase.autoStash not set — run: git config --global rebase.autoStash true') | Out-Null
            & $writeLine '⚠️  rebase.autoStash not set — rebase aborts on dirty tree'
        }

        # ---- Diff / merge quality (info-only, not blocking) ----
        $diffAlgo = & $readCfg 'diff.algorithm'
        if ($diffAlgo -eq 'histogram') {
            & $writeLine '✅ diff.algorithm = histogram'
        } else {
            & $writeLine '💡 diff.algorithm not set to histogram — diffs on reordered code can be misleading'
        }
        $conflictStyle = & $readCfg 'merge.conflictstyle'
        if ($conflictStyle -in @('diff3', 'zdiff3')) {
            & $writeLine "✅ merge.conflictstyle = $conflictStyle"
        } else {
            & $writeLine '💡 merge.conflictstyle not set — conflict markers hide the common ancestor'
        }
        $excludesFile = & $readCfg 'core.excludesFile'
        if ($excludesFile -and (Test-Path -LiteralPath $excludesFile -ErrorAction SilentlyContinue)) {
            & $writeLine "✅ core.excludesFile = $excludesFile"
        } else {
            & $writeLine '💡 core.excludesFile not set — OS/editor artifacts need per-repo .gitignore entries'
        }
    }

    # ====================================================================
    # 8. Node.js
    # ====================================================================
    & $writeSection 'Node.js'
    & $writeStatus 'Node.js: checking...'

    if (Get-Command node -ErrorAction SilentlyContinue) {
        & $writeLine "✅ Node.js: $(& node --version 2>$null)"
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            & $writeLine "✅ npm: $(& npm --version 2>$null)"
        }
    } else {
        & $writeLine '❌ Node.js not installed'
    }

    # ====================================================================
    # 9. Python
    # ====================================================================
    & $writeSection 'Python'
    & $writeStatus 'Python: checking...'

    # Same launcher cascade Start-LocalServer uses — `py` first on Windows.
    $pyCandidates = if ($IsWindows) { 'py', 'python', 'python3' } else { 'python3', 'python' }
    $pyCmd = $null
    foreach ($candidate in $pyCandidates) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            $pyCmd = $candidate
            break
        }
    }
    if ($pyCmd) {
        $pyVer = & $pyCmd --version 2>$null
        & $writeLine "✅ ${pyCmd}: $pyVer"
    } else {
        & $writeLine '❌ Python not installed'
    }

    if (Get-Command uv -ErrorAction SilentlyContinue) {
        & $writeLine "✅ uv: $(& uv --version 2>$null)"
    } else {
        $issues.Add('uv not installed — install from https://docs.astral.sh/uv/') | Out-Null
        & $writeLine '❌ uv not installed'
    }

    # ====================================================================
    # 10. Summary
    # ====================================================================
    & $clearStatus

    Write-Host ''
    Write-Host '  ─────────────────────────────────' -ForegroundColor DarkGray
    if ($issues.Count -eq 0) {
        Write-Host '  ✅ All systems go' -ForegroundColor Green
    } else {
        Write-Host ("  ⚠️  {0} issue(s) found" -f $issues.Count) -ForegroundColor Yellow
        foreach ($msg in $issues) {
            Write-Host "      • $msg" -ForegroundColor DarkGray
        }
    }
    if ($updatesAvail.Count -gt 0) {
        Write-Host ("  📦 {0} tool update(s) available" -f $updatesAvail.Count) -ForegroundColor Yellow
        if ($verbose) {
            foreach ($u in $updatesAvail) {
                Write-Host "      • $u" -ForegroundColor DarkGray
            }
        } else {
            Write-Host '      (run preflight -Verbose -CheckUpdates to see details)' -ForegroundColor DarkGray
        }
    }
    Write-Host '  ─────────────────────────────────' -ForegroundColor DarkGray
    if (-not $verbose) {
        Write-Host '  (run preflight -Verbose for full output)' -ForegroundColor DarkGray
    }
    if (-not $CheckUpdates) {
        Write-Host "  (run preflight -CheckUpdates to check for tool updates)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Update-Preflight {
    <#
    .SYNOPSIS
        Update the Preflight module to the latest version from GitHub.
    .DESCRIPTION
        Clones shawnoster/preflight into a temp directory, copies the updated
        lib/*.ps1, Preflight.psd1, and Preflight.psm1 into the module root
        ($script:PreflightRoot — wherever the module was imported from), then
        reloads the module.

        Files that must survive updates untouched:
          - config/accounts.ps1  (gitignored user config — NEVER overwritten)

        Requires git in PATH.
    .PARAMETER DryRun
        Show what would be copied without writing anything.
    .EXAMPLE
        Update-Preflight
    .EXAMPLE
        Update-Preflight -DryRun
    #>
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    $installRoot = $script:PreflightRoot   # ~/.preflight/pwsh
    $repoUrl     = 'https://github.com/shawnoster/preflight.git'

    Write-Host ''
    Write-Host '  ── preflight update ──' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "git not found in PATH — cannot update Preflight."
        return
    }

    # Clone into a temp directory. The try/finally guarantees cleanup even if
    # git clone fails partway through and leaves a partially-populated dir.
    $tmpBase = [System.IO.Path]::GetTempPath()
    $tmpDir  = Join-Path $tmpBase "preflight-update-$([guid]::NewGuid())"

    try {
        Write-Host "  Cloning $repoUrl ..." -ForegroundColor DarkGray
        $cloneOut = & git clone --depth 1 --quiet $repoUrl $tmpDir 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git clone failed: $cloneOut"
            return
        }

        $srcPwsh = Join-Path $tmpDir 'pwsh'
        if (-not (Test-Path -LiteralPath $srcPwsh)) {
            Write-Error "Cloned repo missing expected pwsh/ directory — aborting."
            return
        }
        # Collect files to copy: lib/*.ps1, Preflight.psd1, Preflight.psm1.
        # config/accounts.ps1 is intentionally excluded — it is the gitignored
        # user config file and must never be overwritten by an update.
        $srcFiles = @(
            Get-ChildItem -LiteralPath (Join-Path $srcPwsh 'lib') -Filter '*.ps1' -File |
                ForEach-Object { @{ Src = $_.FullName; Rel = "lib\$($_.Name)" } }
            @{ Src = Join-Path $srcPwsh 'Preflight.psd1'; Rel = 'Preflight.psd1' }
            @{ Src = Join-Path $srcPwsh 'Preflight.psm1'; Rel = 'Preflight.psm1' }
        )

        $copied = 0
        $skipped = 0
        foreach ($f in $srcFiles) {
            $dest = Join-Path $installRoot $f.Rel
            if (-not (Test-Path -LiteralPath $f.Src)) { continue }

            $srcHash  = (Get-FileHash -LiteralPath $f.Src  -Algorithm SHA256).Hash
            $destHash = if (Test-Path -LiteralPath $dest) {
                (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            } else { '' }

            if ($srcHash -eq $destHash) {
                $skipped++
                Write-Verbose "  unchanged: $($f.Rel)"
                continue
            }

            if ($DryRun) {
                Write-Host "  would update: $($f.Rel)" -ForegroundColor Yellow
            } else {
                $destDir = Split-Path -Parent $dest
                if (-not (Test-Path -LiteralPath $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $f.Src -Destination $dest -Force
                Write-Host "  updated: $($f.Rel)" -ForegroundColor Green
            }
            $copied++
        }

        Write-Host ''
        if ($DryRun) {
            Write-Host ("  (dry run) {0} file(s) would be updated, {1} unchanged" -f $copied, $skipped) -ForegroundColor Yellow
        } else {
            Write-Host ("  {0} file(s) updated, {1} unchanged" -f $copied, $skipped) -ForegroundColor Green

            if ($copied -gt 0) {
                Write-Host '  Reloading module...' -ForegroundColor DarkGray
                $manifest = Join-Path $installRoot 'Preflight.psd1'
                Remove-Module Preflight -Force -ErrorAction SilentlyContinue
                Import-Module $manifest -Force -Global
                Write-Host '  ✅ Preflight reloaded' -ForegroundColor Green
            }
        }
        Write-Host ''
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

# ---- Aliases ---------------------------------------------------------------
# The single defining match for muscle memory: bare `preflight` runs the
# orchestrator. Lowercase to match bash exactly.
Set-Alias -Name 'preflight'        -Value Invoke-Preflight  -Force -Scope Script
Set-Alias -Name 'preflight-update' -Value Update-Preflight  -Force -Scope Script
