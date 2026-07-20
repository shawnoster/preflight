# lib/1password.ps1 — 1Password CLI helpers for Preflight.
#
# Functions defined here are exported via Preflight.psd1's FunctionsToExport.
# Phase 1 surface:
#   Get-OpStatus     (alias: op-status)
#   Connect-Op       (alias: op-signin)
#   Import-OpEnv     (alias: op-load-env)
#   Clear-OpEnv      (alias: op-clear-env)
#   New-OpItem       (alias: op-new)
#   Import-OpCsv     (alias: op-import-csv)
#
# Get-PreflightHelp / dev-commands moved to lib/help.ps1 in 0.6.0.
#
# Note: these are user-facing CLI helpers — Write-Host is intentional
# throughout (preserves color, doesn't pollute the pipeline output of
# callers, and matches the bash side's `echo`/`printf`). The
# PSAvoidUsingWriteHost analyzer rule is suppressed at file level via
# the SuppressMessageAttribute on the param() block below.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI output; Write-Host is appropriate.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'ArgumentCompleter scriptblocks must accept the standard 5-arg signature ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters); analyzer flags those we don''t reference.'
)]
param()

# ---- Shared helpers --------------------------------------------------------

function Get-OpAccount {
    <#
    .SYNOPSIS
        Resolve the 1Password account shorthand to use for op invocations.
        Defaults to $env:OP_ACCOUNT (set by Preflight.psm1 / config/accounts.ps1).
    #>
    if ($env:OP_ACCOUNT) { return $env:OP_ACCOUNT }
    return 'change-me'
}

function Test-OpCli {
    if (Get-Command op -ErrorAction SilentlyContinue) { return $true }
    Write-Error "1Password CLI ('op') not found in PATH. Install from https://developer.1password.com/docs/cli/get-started/"
    return $false
}

# ---- Get-OpStatus ----------------------------------------------------------

function Get-OpStatus {
    <#
    .SYNOPSIS
        Check whether you're signed in to 1Password.
    .DESCRIPTION
        Calls `op whoami` for the configured account. Returns $true and writes
        a success message if signed in; returns $false and writes a status line
        if not. Mirrors the bash op-status function.
    .PARAMETER Account
        1Password account shorthand. Defaults to $env:OP_ACCOUNT.
    .EXAMPLE
        Get-OpStatus
    .EXAMPLE
        if (-not (Get-OpStatus -Quiet)) { Connect-Op }
    .OUTPUTS
        [bool] $true if signed in.
    #>
    [CmdletBinding()]
    param(
        [string]$Account = (Get-OpAccount),
        [switch]$Quiet
    )

    if (-not (Test-OpCli)) { return $false }

    $null = & op whoami --account $Account 2>&1
    $signedIn = ($LASTEXITCODE -eq 0)

    if (-not $Quiet) {
        if ($signedIn) {
            Write-Host "✅ Signed in to 1Password ($Account)"
        } else {
            Write-Host "❌ Not signed in to 1Password ($Account)"
        }
    }
    return $signedIn
}

# ---- Connect-Op ------------------------------------------------------------

function Connect-Op {
    <#
    .SYNOPSIS
        Sign in to 1Password.
    .DESCRIPTION
        If already signed in, returns immediately. Otherwise calls `op signin`
        and applies the resulting OP_SESSION_* environment variables to the
        current shell so subsequent op commands inherit the session.

        Mirrors the bash op-signin function.
    .PARAMETER Account
        1Password account shorthand. Defaults to $env:OP_ACCOUNT.
    .EXAMPLE
        Connect-Op
    #>
    [CmdletBinding()]
    param(
        [string]$Account = (Get-OpAccount)
    )

    if (-not (Test-OpCli)) { return $false }

    if (Get-OpStatus -Account $Account -Quiet) {
        Write-Host "✅ Already signed in to 1Password ($Account)"
        return $true
    }

    Write-Host "🔐 Signing in to 1Password ($Account)..."

    # `op signin` prints `export OP_SESSION_xxx="…"` to stdout, intended to be
    # eval'd by a POSIX shell. PowerShell can't `eval`; instead we capture the
    # output and translate `export NAME="VALUE"` into Set-Item env:NAME VALUE.
    #
    # Note: the *interactive* prompt (master password / biometrics) goes to
    # the controlling TTY directly, so we don't capture stderr.
    $output = & op signin --account $Account
    if ($LASTEXITCODE -ne 0) {
        Write-Error "❌ Failed to sign in to 1Password"
        return $false
    }

    foreach ($line in $output) {
        if ($line -match '^\s*export\s+(OP_SESSION_[A-Za-z0-9_]+)\s*=\s*"(.*)"\s*$') {
            Set-Item -Path "env:$($matches[1])" -Value $matches[2]
        } elseif ($line -match '^\s*\$env:(OP_SESSION_[A-Za-z0-9_]+)\s*=\s*"(.*)"\s*$') {
            # Future-proof: in case op ever emits PowerShell-formatted output.
            Set-Item -Path "env:$($matches[1])" -Value $matches[2]
        }
    }

    if (Get-OpStatus -Account $Account -Quiet) {
        Write-Host "✅ Signed in to 1Password ($Account)"
        return $true
    }

    Write-Error "❌ Failed to sign in to 1Password"
    return $false
}

# ---- Import-OpEnv ----------------------------------------------------------
# $script:OpEnvMap (env var → op:// path) is defined entirely in
# config/accounts.ps1, which is loaded by Preflight.psm1 before this file.
# Edit that file to add, remove, or change secret mappings.

function Get-OpEnvMap {
    <#
    .SYNOPSIS
        Return the op:// secret map defined in config/accounts.ps1.
    #>
    return $script:OpEnvMap
}

function Import-OpEnv {
    <#
    .SYNOPSIS
        Load secrets from 1Password into environment variables.
    .DESCRIPTION
        Resolves every op:// reference in the Preflight env map by handing
        a temporary env-file to `op run`, then exports each value as
        $env:VAR in the current shell.

        Falls back to per-secret `op read` if `op run` fails — slower but
        survives partial-resolution scenarios. Mirrors the bash op-load-env.

        GitHub auth is intentionally NOT loaded here. `gh` manages its own
        token at ~/.config/gh/hosts.yml; loading GITHUB_TOKEN here would
        shadow it with a narrower-scoped PAT. This matches the bash side.
    .PARAMETER Account
        1Password account shorthand. Defaults to $env:OP_ACCOUNT.
    .EXAMPLE
        Import-OpEnv
    .EXAMPLE
        Import-OpEnv -Account my-account
    #>
    [CmdletBinding()]
    param(
        [string]$Account = (Get-OpAccount)
    )

    $envMap = Get-OpEnvMap
    if ($envMap.Count -eq 0) {
        Write-Verbose "Import-OpEnv: secret map is empty — nothing to load (check config/accounts.ps1)."
        return
    }

    if (-not (Test-OpCli)) { return }

    if (-not (Get-OpStatus -Account $Account -Quiet)) {
        if (-not (Connect-Op -Account $Account)) { return }
    }

    # Header — skipped when called from Invoke-Preflight, which prints its own.
    if (-not $env:_PREFLIGHT_NESTED) {
        Write-Host "--- Secrets ---"
    }

    # Strategy A: `op run --env-file` resolves every op:// reference in one
    # authenticated round-trip (matches the bash implementation).
    $envFile = New-TemporaryFile
    try {
        $lines = $envMap.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        Set-Content -LiteralPath $envFile -Value $lines -Encoding UTF8

        # `op run` injects resolved values into the child process env. The
        # cleanest way to fish them back out is to launch a child PowerShell
        # that reads its own env and prints `VAR=VALUE` lines, which we
        # parse back into $env: in our process.
        $printer = "foreach (`$v in '$($envMap.Keys -join ',')'.Split(',')) { Write-Output (`"{0}={1}`" -f `$v, [Environment]::GetEnvironmentVariable(`$v)) }"

        $resolved = & op run --account $Account --env-file=$envFile --no-masking -- pwsh -NoProfile -Command $printer 2>&1
        $opRc     = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $envFile -ErrorAction SilentlyContinue
    }

    if ($opRc -ne 0) {
        Write-Warning "op run failed (exit $opRc), falling back to individual reads (slow)..."
        foreach ($entry in $envMap.GetEnumerator()) {
            $value = & op read --account $Account $entry.Value 2>$null
            if ($LASTEXITCODE -eq 0 -and $value) {
                Set-Item -Path "env:$($entry.Key)" -Value $value
                Write-Host "✅ $($entry.Key)"
            } else {
                Write-Host "⚠️  $($entry.Key) (failed to load)"
            }
        }
        return
    }

    foreach ($key in $envMap.Keys) {
        $line = $resolved | Where-Object { $_ -match "^$([regex]::Escape($key))=" } | Select-Object -First 1
        if ($line) {
            $value = $line.Substring($key.Length + 1)
            if ($value) {
                Set-Item -Path "env:$key" -Value $value
                Write-Host "✅ $key"
                continue
            }
        }
        Write-Host "⚠️  $key (failed to load)"
    }
}

# ---- Clear-OpEnv -----------------------------------------------------------

function Clear-OpEnv {
    <#
    .SYNOPSIS
        Clear sensitive environment variables loaded by Import-OpEnv.
    .DESCRIPTION
        Removes every var Import-OpEnv sets, plus the legacy GitHub token
        names in case they were set by hand (matching bash op-clear-env).
    .EXAMPLE
        Clear-OpEnv
    #>
    [CmdletBinding()]
    param()

    $extras = @('GITHUB_TOKEN', 'GITHUB_PERSONAL_ACCESS_TOKEN')
    $allVars = @((Get-OpEnvMap).Keys) + $extras

    foreach ($var in $allVars) {
        if (Test-Path -LiteralPath "env:$var") {
            Remove-Item -LiteralPath "env:$var"
        }
    }

    Write-Host "🧹 Secure environment variables cleared."
}

# ---- New-OpItem ------------------------------------------------------------

function New-OpItem {
    <#
    .SYNOPSIS
        Interactively create a new 1Password item.
    .DESCRIPTION
        Prompts for a title, vault, and item category (Login,
        API Credential, Password, or Secure Note), then calls
        `op item create` with the appropriate fields.

        Sensitive field values (passwords, credentials) are read with
        Read-Host -AsSecureString so they don't end up in PSReadLine
        history. Mirrors the bash op-new function.
    .PARAMETER DryRun
        Print the op command that would be run, without executing it.
    .PARAMETER Account
        1Password account shorthand. Defaults to $env:OP_ACCOUNT.
    .EXAMPLE
        New-OpItem
    .EXAMPLE
        op-new -DryRun
    .EXAMPLE
        New-OpItem -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$Account = (Get-OpAccount),
        [switch]$DryRun
    )

    if (-not (Test-OpCli)) { return }
    if (-not (Get-OpStatus -Account $Account -Quiet)) {
        if (-not (Connect-Op -Account $Account)) { return }
    }

    $title = Read-Host -Prompt 'Item title'
    if (-not $title) { Write-Error 'Title required'; return }

    $vault = Read-Host -Prompt 'Vault [Employee]'
    if (-not $vault) { $vault = 'Employee' }

    Write-Host 'Type:'
    Write-Host '  1) login           (username + password)'
    Write-Host '  2) api-credential  (single credential field)'
    Write-Host '  3) password        (password only)'
    Write-Host '  4) secure-note'
    $choice = Read-Host -Prompt 'Choice [2]'
    if (-not $choice) { $choice = '2' }

    $category   = $null
    $fields     = @()
    $genPassword = $false

    function _readSecret([string]$prompt) {
        # Use SecureString to keep the secret off the line buffer,
        # then convert back for the op CLI.
        $secure = Read-Host -Prompt $prompt -AsSecureString
        if (-not $secure -or $secure.Length -eq 0) { return '' }
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    switch ($choice) {
        '1' {
            $category = 'Login'
            $username = Read-Host -Prompt 'Username (blank = REPLACE_ME)'
            if (-not $username) { $username = 'REPLACE_ME' }
            $passwordPlain = _readSecret "Password (blank = REPLACE_ME, type 'generate' to auto-generate)"
            if ($passwordPlain -eq 'generate') {
                $genPassword = $true
                $fields += "username[text]=$username"
            } elseif (-not $passwordPlain) {
                $fields += "username[text]=$username", 'password[concealed]=REPLACE_ME'
            } else {
                $fields += "username[text]=$username", "password[concealed]=$passwordPlain"
            }
        }
        '2' {
            $category = 'API Credential'
            $credPlain = _readSecret 'Credential value (blank = REPLACE_ME)'
            if (-not $credPlain) { $credPlain = 'REPLACE_ME' }
            $fields += "credential[concealed]=$credPlain"
        }
        '3' {
            $category = 'Password'
            $pwdPlain = _readSecret 'Password value (blank = REPLACE_ME)'
            if (-not $pwdPlain) { $pwdPlain = 'REPLACE_ME' }
            $fields += "password[concealed]=$pwdPlain"
        }
        '4' {
            $category = 'Secure Note'
            $notes = Read-Host -Prompt 'Notes (optional)'
            if ($notes) { $fields += "notesPlain[text]=$notes" }
        }
        default {
            Write-Error 'Invalid choice'
            return
        }
    }

    $opArgs = @(
        'item', 'create'
        '--account', $Account
        '--category', $category
        '--title', $title
        '--vault', $vault
    )
    if ($genPassword) { $opArgs += '--generate-password' }
    $opArgs += $fields

    if ($DryRun) {
        Write-Host 'Would run:'
        # Surround any arg containing whitespace with quotes for readability.
        $printable = $opArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }
        Write-Host ('  op ' + ($printable -join ' '))
        return
    }

    Write-Host 'Creating item...'
    if (-not $PSCmdlet.ShouldProcess("$title in vault $vault", "op item create")) {
        return
    }
    $output = & op @opArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("Failed to create item: " + ($output | Out-String))
        return
    }

    Write-Host "✅ Created: $title (vault: $vault)"
    Write-Host ''
    Write-Host 'Reference paths — paste into Import-OpEnv config:'
    switch ($choice) {
        '1' {
            Write-Host "  op://$vault/$title/username"
            Write-Host "  op://$vault/$title/password"
        }
        '2' { Write-Host "  op://$vault/$title/credential" }
        '3' { Write-Host "  op://$vault/$title/password" }
    }
}

# ---- Import-OpCsv ----------------------------------------------------------

function Import-OpCsv {
    <#
    .SYNOPSIS
        Bulk-import a CSV of Login items into a 1Password vault.
    .DESCRIPTION
        Each row becomes a Login item. Default column layout matches
        a common 1Password export format:

            title, url, username, password, notes

        Pass -Columns to remap. Valid column names are:
            title, url, username, password, notes, skip

        Secrets are passed via temporary JSON templates (chmod 0600 on POSIX,
        ACL-restricted on Windows) so that values never appear in the
        op CLI's argv (which is visible to other processes and PSReadLine).
        This mirrors the bash op-import-csv approach.

        The PowerShell version does NOT need python3 or jq — Import-Csv
        and ConvertTo-Json handle parsing and serialization natively.
    .PARAMETER Path
        Path to the CSV file.
    .PARAMETER Vault
        Destination vault. Defaults to 'Testing Credentials' (most common
        target for shared/test creds). Use 'Employee' for personal items.
    .PARAMETER Tag
        Tag(s) to apply to every imported item. Pass as an array:
        `-Tag staging,meijer` (PowerShell array syntax — not `-Tag x -Tag y`).
    .PARAMETER Columns
        Comma list mapping CSV columns to fields.
        Default: title,url,username,password,notes
    .PARAMETER HasHeader
        Treat row 1 as a header. If neither -HasHeader nor -NoHeader is
        passed, the function auto-detects: row 1 is treated as a header
        if its first cell is a known column name (title, name, item, label).
    .PARAMETER NoHeader
        Force-treat row 1 as data.
    .PARAMETER DryRun
        Show what would be created without calling op.
    .PARAMETER Account
        1Password account shorthand. Defaults to $env:OP_ACCOUNT.
    .EXAMPLE
        Import-OpCsv 'C:\Users\Me\Downloads\creds.csv' -Vault 'Testing Credentials' -DryRun
    .EXAMPLE
        Import-OpCsv .\meijer.csv -Vault Employee -Tag staging,meijer
    .EXAMPLE
        Import-OpCsv .\export.csv -Columns 'title,skip,username,password'
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        # Any string is allowed — the function verifies the vault is visible
        # at runtime via `op vault get`. ValidateSet would block legitimate
        # non-interactive paths to vaults outside the common set.
        # ArgumentCompleter just gives Tab-completion for the most-used names.
        [ArgumentCompleter({
            param($cmd, $param, $word, $ast, $bound)
            @('Employee', 'Testing Credentials') |
                Where-Object { $_ -like "$word*" } |
                ForEach-Object { "'$_'" }
        })]
        [string]$Vault,

        [string[]]$Tag = @(),

        [string]$Columns = 'title,url,username,password,notes',

        [switch]$HasHeader,
        [switch]$NoHeader,
        [switch]$DryRun,

        [string]$Account = (Get-OpAccount)
    )

    if (-not (Test-OpCli)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "CSV not found: $Path"
        return
    }

    if (-not (Get-OpStatus -Account $Account -Quiet)) {
        if (-not (Connect-Op -Account $Account)) { return }
    }

    # ---- Resolve destination vault -----------------------------------------
    if (-not $Vault) {
        Write-Host 'Choose destination vault:'
        Write-Host '  1) Testing Credentials  (default - shared/test creds)'
        Write-Host '  2) Employee             (your private employee vault)'
        Write-Host '  3) <other>              (type a vault name)'
        $sel = Read-Host -Prompt 'Choice [1]'
        switch ($sel) {
            '' { $Vault = 'Testing Credentials' }
            '1' { $Vault = 'Testing Credentials' }
            '2' { $Vault = 'Employee' }
            '3' { $Vault = Read-Host -Prompt 'Vault name' }
            default { $Vault = $sel }
        }
    }
    if (-not $Vault) { Write-Error 'Vault required'; return }

    # Verify the vault is visible.
    $null = & op vault get $Vault --account $Account 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Vault '$Vault' not visible to account '$Account'"
        return
    }

    # ---- Validate columns spec ---------------------------------------------
    $validCols = @('title', 'url', 'username', 'password', 'notes', 'skip')
    $cols = $Columns -split ','
    foreach ($c in $cols) {
        if ($c -notin $validCols) {
            Write-Error "Invalid column '$c' in -Columns. Valid: $($validCols -join ', ')"
            return
        }
    }

    # ---- Read CSV ----------------------------------------------------------
    # Always read with a synthetic header so Import-Csv returns objects we
    # can address by position (Col1..ColN), then map them onto our slot
    # names per the -Columns spec.
    $maxCols = [Math]::Max($cols.Count, 16)
    $syntheticHeader = 1..$maxCols | ForEach-Object { "Col$_" }

    $rows = @(Import-Csv -LiteralPath $Path -Header $syntheticHeader -Encoding UTF8)

    if ($rows.Count -eq 0) {
        Write-Warning "No rows found in $Path"
        return
    }

    # Auto-detect / honor header switches.
    $skipFirst = $false
    if ($HasHeader) {
        $skipFirst = $true
    } elseif (-not $NoHeader) {
        $first = $rows[0].Col1
        if ($first) {
            $headerHints = @('title', 'name', 'item', 'label')
            if ($first.Trim().ToLower() -in $headerHints) { $skipFirst = $true }
        }
    }
    if ($skipFirst) { $rows = $rows | Select-Object -Skip 1 }

    # ---- Per-row processing ------------------------------------------------
    Write-Host ''
    Write-Host "📥 Importing into vault: $Vault"
    if ($DryRun) { Write-Host '   (dry-run - no items will be created)' }
    Write-Host ''

    $total = 0; $created = 0; $failed = 0; $skipped = 0
    foreach ($row in $rows) {
        $total++

        # Map positional cols onto slots per -Columns spec.
        $slot = @{ title = ''; url = ''; username = ''; password = ''; notes = '' }
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $name = $cols[$i]
            if ($name -eq 'skip') { continue }
            $colKey = "Col$($i + 1)"
            $value = $row.$colKey
            if ($null -eq $value) { $value = '' }
            $slot[$name] = $value
        }

        # Skip blank rows.
        $hasContent = ($slot.title -or $slot.username -or $slot.password)
        if (-not $hasContent) {
            Write-Host "  [$total] (skipped - empty row)"
            $skipped++
            continue
        }

        if (-not $slot.title) {
            $slot.title = "Imported $(Get-Date -Format 'yyyy-MM-dd') #$total"
        }

        # Build a 1Password Login template object.
        $fields = @(
            @{ id = 'username'; type = 'STRING';    purpose = 'USERNAME'; label = 'username'; value = $slot.username }
            @{ id = 'password'; type = 'CONCEALED'; purpose = 'PASSWORD'; label = 'password'; value = $slot.password }
        )
        if ($slot.notes) {
            $fields += @{ id = 'notesPlain'; type = 'STRING'; purpose = 'NOTES'; label = 'notesPlain'; value = $slot.notes }
        }
        $urls = @()
        if ($slot.url) {
            $urls += @{ label = 'website'; primary = $true; href = $slot.url }
        }

        $template = [ordered]@{
            title    = $slot.title
            category = 'LOGIN'
            tags     = @($Tag)
            fields   = $fields
            urls     = $urls
        }

        if ($DryRun) {
            Write-Host "  [$total] would create: $($slot.title)"
            if ($slot.url)      { Write-Host "         url:      $($slot.url)" }
            if ($slot.username) { Write-Host "         username: $($slot.username)" }
            if ($slot.password) { Write-Host "         password: ********" }
            if ($slot.notes) {
                $preview = if ($slot.notes.Length -gt 80) {
                    $slot.notes.Substring(0, 80) + '…'
                } else { $slot.notes }
                Write-Host "         notes:    $preview"
            }
            $created++
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("$($slot.title) in vault $Vault", "op item create")) {
            $skipped++
            continue
        }

        # Write JSON template to a tempfile, then hand it to op via --template.
        # Use ACL-restriction on Windows or chmod 600 on POSIX so the file
        # isn't readable by other users while it briefly exists on disk.
        $tmpl = New-TemporaryFile
        try {
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                # Restrict to current user only.
                $acl = Get-Acl -LiteralPath $tmpl
                $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, drop inherited rules
                $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $userSid, 'FullControl', 'Allow'
                )
                $acl.AddAccessRule($rule)
                Set-Acl -LiteralPath $tmpl -AclObject $acl
            } else {
                & chmod 600 $tmpl
            }

            $json = $template | ConvertTo-Json -Depth 6 -Compress
            Set-Content -LiteralPath $tmpl -Value $json -Encoding UTF8

            # Run `op item create --template <file>` with stdin redirected
            # to NUL. Without this, op fails with:
            #   "cannot create an item from template and stdin at the same time"
            # Same root cause as the bash </dev/null fix in op-import-csv.
            #
            # Empirically, neither `$null | op …` nor System.Diagnostics.Process
            # with StandardInput.Close() work — op reads stdin readiness
            # directly from the OS handle and treats any non-TTY handle as
            # a piped template payload. The only reliable cross-platform
            # solution from PowerShell is to shell out via cmd.exe /c with
            # `< NUL`, or via `/dev/null` redirection on POSIX.
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                $opPath = (Get-Command op).Source
                # Quote each arg for cmd.exe.
                $quoted = @(
                    "`"$opPath`""
                    'item', 'create'
                    '--account', $Account
                    '--vault', "`"$Vault`""
                    '--template', "`"$tmpl`""
                    '--format', 'json'
                ) -join ' '
                $opOut = & cmd.exe /c "$quoted < NUL 2>&1"
                $opRc = $LASTEXITCODE
            } else {
                $opOut = & sh -c "op item create --account `"$Account`" --vault `"$Vault`" --template `"$tmpl`" --format json </dev/null 2>&1"
                $opRc = $LASTEXITCODE
            }
        } finally {
            # Best-effort overwrite-then-delete. We don't have shred on
            # Windows; overwriting the tempfile with zeros first reduces
            # the chance of recovery from filesystem free space.
            try {
                $size = (Get-Item -LiteralPath $tmpl).Length
                if ($size -gt 0) {
                    [System.IO.File]::WriteAllBytes($tmpl, [byte[]]::new($size))
                }
            } catch {
                # Tempfile may already be gone or locked; we still try to
                # remove it below. Best-effort overwrite is non-critical.
                Write-Verbose "Could not zero-overwrite template tempfile: $_"
            }
            Remove-Item -LiteralPath $tmpl -Force -ErrorAction SilentlyContinue
        }

        if ($opRc -eq 0) {
            Write-Host "  [$total] ✅ created: $($slot.title)"
            $created++
        } else {
            $firstLine = ($opOut | Out-String) -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1
            Write-Host "  [$total] ❌ FAILED:  $($slot.title)"
            Write-Host "         $firstLine"
            $failed++
        }
    }

    Write-Host ''
    Write-Host '──────────────────────────────'
    Write-Host "Total rows:  $total"
    Write-Host "Created:     $created"
    Write-Host "Skipped:     $skipped"
    Write-Host "Failed:      $failed"
    Write-Host "Vault:       $Vault"
    if ($DryRun) { Write-Host 'Mode:        dry-run (nothing was sent to 1Password)' }
    Write-Host '──────────────────────────────'

    if ($failed -gt 0) { return }
}

# ---- Aliases ---------------------------------------------------------------
# Mirror the bash kebab names. Aliases are exported via the manifest.
# Note: op-help / dev-help / dev-commands aliases now live in lib/help.ps1
# alongside the help functions themselves (since 0.6.0).

Set-Alias -Name 'op-status'     -Value Get-OpStatus      -Force -Scope Script
Set-Alias -Name 'op-signin'     -Value Connect-Op        -Force -Scope Script
Set-Alias -Name 'op-load-env'   -Value Import-OpEnv      -Force -Scope Script
Set-Alias -Name 'op-clear-env'  -Value Clear-OpEnv       -Force -Scope Script
Set-Alias -Name 'op-new'        -Value New-OpItem        -Force -Scope Script
Set-Alias -Name 'op-import-csv' -Value Import-OpCsv      -Force -Scope Script
