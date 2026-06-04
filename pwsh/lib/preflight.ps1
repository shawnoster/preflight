# lib/preflight.ps1 — session startup orchestrator (PowerShell sibling of bash `preflight`).
#
# Phase 1 sections:
#   1. Secrets       — calls Import-OpEnv to load all op:// references
#   2. AWS Profile   — apply $env:AWS_PROFILE_DEFAULT if AWS_PROFILE unset
#   3. AWS Session   — detect identity / token expiry; warn (don't auto-refresh)
#   4. Environment   — sanity-check NPM_TOKEN; verify `gh` auth
#   5. Summary       — pass / N issue(s) found
#
# Future phases will add: SSH/1Password agent, git globals, Node/Volta, Python/uv,
# `preflight update`, `preflight configure`, version-drift checks for installed tools.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI orchestrator; Write-Host is appropriate.'
)]
param()

function Invoke-Preflight {
    <#
    .SYNOPSIS
        Run session startup checks: sign in to 1Password, load secrets,
        verify AWS, and report a summary. PowerShell sibling of bash `preflight`.
    .DESCRIPTION
        By default runs in "quiet" mode — section progress overwrites a single
        status line, only the final summary remains visible. Use -Verbose for
        full streaming output of every check.

        Phase 1 covers secrets, AWS, and a basic env-sanity sweep. Future
        phases will add SSH/1Password agent integration, git globals,
        Node/Volta, Python/uv, and version drift checks.
    .PARAMETER Verbose
        Print every section as it runs (matches bash `preflight -v`).
        Without it, only the summary is shown unless something fails.
    .PARAMETER SkipSecrets
        Don't call Import-OpEnv. Useful when you only want the AWS/env checks.
    .PARAMETER SkipAws
        Don't poke at AWS. Useful when you're offline or working without SSO.
    .EXAMPLE
        Invoke-Preflight
    .EXAMPLE
        preflight
    .EXAMPLE
        preflight -Verbose
    .EXAMPLE
        preflight -SkipAws
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipSecrets,
        [switch]$SkipAws
    )

    # The PowerShell common parameter -Verbose populates $VerbosePreference;
    # we use it directly to gate the streaming output instead of inventing
    # our own switch (matches PS conventions).
    $verbose = ($VerbosePreference -ne 'SilentlyContinue')

    # ---- Output helpers (closures over $verbose) ---------------------------

    $hasTty = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected

    $writeStatus = {
        param([string]$msg)
        # Quiet mode: overwrite a single line on the same row. No newline.
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
        # Verbose mode only: section header.
        if ($verbose) {
            Write-Host ''
            Write-Host "--- $title ---"
            Write-Host ''
        }
    }
    $writeLine = {
        param([string]$msg)
        # Verbose mode only: streaming progress line.
        if ($verbose) { Write-Host $msg }
    }

    $issues   = New-Object System.Collections.Generic.List[string]

    # ---- Header ------------------------------------------------------------
    Write-Host ''
    Write-Host '  ── preflight ──' -ForegroundColor Cyan
    Write-Host ''

    # ---- 1. Secrets --------------------------------------------------------
    & $writeSection 'Secrets'
    & $writeStatus 'Secrets: loading...'

    if ($SkipSecrets) {
        & $writeLine '  (skipped: -SkipSecrets)'
    } elseif (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        $issues.Add('1Password CLI (op) not installed') | Out-Null
        & $writeLine '❌ op CLI not installed'
    } else {
        # Tell Import-OpEnv to skip its own "--- Secrets ---" header — we
        # already printed our section header (in verbose mode) above.
        $env:_PREFLIGHT_NESTED = '1'
        try {
            if ($verbose) {
                Import-OpEnv
            } else {
                # Quiet mode: capture per-secret output, surface only failures
                # as issues. Import-OpEnv writes via Write-Host, so we redirect
                # the success stream (1) and information stream (6) — though
                # Write-Host writes to host UI not the streams, the cleanest
                # capture is to wrap with $(). Failures show as "⚠️  X (failed
                # to load)" lines which we pattern-match.
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

    # ---- 2. AWS Profile ----------------------------------------------------
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

        # ---- 3. AWS Session -------------------------------------------------
        & $writeSection 'AWS Session'
        & $writeStatus 'AWS: checking session...'

        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
            $issues.Add('AWS CLI not installed') | Out-Null
            & $writeLine '❌ AWS CLI not installed'
        } else {
            # `aws sts get-caller-identity` returns 0 + JSON if creds are good,
            # non-zero with a descriptive error otherwise. We don't auto-refresh
            # (per the design choice) — just report and suggest aws-login.
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
                # Distinguish recoverable categories so the suggested fix is right:
                #   - SSO token never fetched ("Token for X does not exist") -> aws sso login
                #   - SSO token expired ("ExpiredToken", "session has expired") -> aws sso login
                #   - No creds at all (no profile, no env) -> aws configure / aws sso login
                #   - Anything else -> dump first line, suggest -Verbose for detail
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

    # ---- 4. Environment Variables -----------------------------------------
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
        # gh stores its token in ~/.config/gh/hosts.yml; auth status returns 0
        # if at least one host is authenticated.
        $null = & gh auth status --hostname github.com 2>&1
        if ($LASTEXITCODE -eq 0) {
            & $writeLine '✅ GitHub auth active (gh CLI)'
        } else {
            $issues.Add("GitHub auth not found — run: gh auth login") | Out-Null
            & $writeLine "⚠️  GitHub auth not found — run: gh auth login"
        }
    }

    # ---- 5. Summary --------------------------------------------------------
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
    Write-Host '  ─────────────────────────────────' -ForegroundColor DarkGray
    if (-not $verbose) {
        Write-Host '  (run preflight -Verbose for full output)' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---- Aliases ---------------------------------------------------------------
# The single defining match for muscle memory: bare `preflight` runs the
# orchestrator. Lowercase to match bash exactly.
Set-Alias -Name 'preflight' -Value Invoke-Preflight -Force -Scope Script
