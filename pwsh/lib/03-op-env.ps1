# lib/03-op-env.ps1 — `op-env`: manage env sets and load / clear the secrets they define.
#
# The PowerShell twin of lib/envsets.sh. The same subcommands, the same rules, the same bytes on
# disk: tests/op-env.sh runs one sequence of add / rm / use through both implementations and compares
# every file. `migrate` is not ported (bash dropped it with the legacy OP_SECRETS array).
#
#   op-env load [set...]     Import-OpEnv   (lib/1password.ps1)
#   op-env clear [set...]    Clear-OpEnv
#   op-env add | list | rm | use | help      below
#
# The command is Invoke-OpEnv with `op-env` as its alias: a function literally named `op-env` makes
# Import-Module warn about an unapproved verb on every shell start.

# Every question goes through this one function, so tests (and anything scripted) can replace it.
# $null means no answer could be read (no terminal, or the input ended).
function Read-OpEnvAnswer {
    param([string]$Prompt)
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $null }
    try { return (Read-Host -Prompt $Prompt) } catch { return $null }
}

function Get-OpEnvSetsDir {
    if (-not $env:PREFLIGHT_CONFIG_DIR) { throw 'No config directory is resolved (PREFLIGHT_CONFIG_DIR), so there is nowhere to keep env sets.' }
    return (Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets')
}

function Set-OpEnvFileMode {
    # POSIX only: the secret map is private to you (directory 700, files 600), as on the bash side. On
    # Windows the profile directory's ACL is what protects it. chmod is called rather than
    # [File]::SetUnixFileMode, which needs a newer .NET than the module's PowerShell 7.0 floor.
    param([string]$Path, [string]$Mode)
    if ($IsWindows) { return }
    # A native command's non-zero exit does not throw, so check it: a failed chmod must abort the write
    # rather than leave the secret map at the default mode.
    & chmod $Mode -- $Path 2>$null
    if ($LASTEXITCODE -ne 0) { throw "chmod $Mode failed (exit $LASTEXITCODE) for $Path" }
}

function Initialize-OpEnvSetsDir {
    $dir = Get-OpEnvSetsDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-OpEnvFileMode -Path $dir -Mode 700
    }
    return $dir
}

function Write-OpEnvText {
    # LF line endings and UTF-8 without a BOM, explicitly: Set-Content would write CRLF on Windows,
    # and the files are shared with the bash side.
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function New-OpEnvTempPath {
    # Dot-prefixed, so it is "hidden" on POSIX: remove these with -Force or Remove-Item silently leaves them.
    param([string]$Dir)
    return (Join-Path $Dir ('.tmp.' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
}

# Registered rather than put in [ArgumentCompleter()] attributes: an attribute's scriptblock is not
# bound to this module, so it could not see the private Get-OpEnvCompletion. Both names, because
# a completer registered for a function does not apply to its alias.
Register-ArgumentCompleter -CommandName 'Invoke-OpEnv', 'op-env' -ParameterName Command -ScriptBlock {
    param($cmd, $param, $word)
    Get-OpEnvCompletion -Sub '' -Given 0 -Word $word
}
Register-ArgumentCompleter -CommandName 'Invoke-OpEnv', 'op-env' -ParameterName Arguments -ScriptBlock {
    param($cmd, $param, $word, $ast, $bound)
    # Earlier arguments are not in $bound, so count them from the command line: everything after the
    # command and the subcommand, less the word being completed when it is not empty.
    $given = $ast.CommandElements.Count - 2 - $(if ($word) { 1 } else { 0 })
    Get-OpEnvCompletion -Sub "$($bound['Command'])" -Given ([Math]::Max(0, $given)) -Word $word
}

function Get-OpEnvRawLines {
    # The file's lines as written (CRs kept, no trailing empty line), like `awk 1`.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -eq 0) { return @() }
    $lines = $text -split "`n"
    if ($lines[-1] -eq '') { $lines = $lines[0..($lines.Length - 2)] }
    return @($lines)
}

function Get-OpEnvSetNameList {
    # Existing sets: every *.tsv, sorted ordinally (an invalid name still lists, so it can be seen).
    $dir = Get-OpEnvSetsDir
    $found = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.tsv' -File -Force) {
            $found.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
    }
    $arr = $found.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Write-OpEnvSet {
    <#
    .SYNOPSIS
        Put lines into a set as ONE all-or-nothing change (a port of bash's _op_envsets_write).
    .DESCRIPTION
        $Lines are `VAR<TAB>ref[<TAB>account]`. Existing lines whose variable is being replaced are
        dropped; every other line is kept exactly as written; the new lines go last. When a brand-new
        set must be added to an explicit .active list, the new set file and the new .active are both
        staged first and only then renamed into place; if the second rename fails the first is rolled
        back. Editing a set the user deliberately deactivated does not reactivate it.
        Returns $true on success.
    #>
    [CmdletBinding()]
    param([string]$Set, [string[]]$Lines)

    $dir  = Initialize-OpEnvSetsDir
    $file = Join-Path $dir "$Set.tsv"
    $act  = Join-Path $dir '.active'
    $replace = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($l in $Lines) { [void]$replace.Add($l.Split("`t")[0]) }

    $isNew = -not (Test-Path -LiteralPath $file -PathType Leaf)
    $needAct = $false
    if ($isNew -and (Test-Path -LiteralPath $act -PathType Leaf)) {
        $listed = @(([System.IO.File]::ReadAllText($act) -replace "`r", '') -split "`n")
        if ($listed -cnotcontains $Set) {
            $needAct = $true
            # Detect an unwritable .active before touching anything.
            try { $h = [System.IO.File]::Open($act, 'Append', 'Write'); $h.Dispose() }
            catch {
                Write-Error "Can't activate set '$Set': $act is not writable. Nothing was changed. Fix the file's permissions, or run: op-env use"
                return $false
            }
        }
    }

    $keep = @(Get-OpEnvRawLines -Path $file | Where-Object { $replace -notcontains $_.Split("`t")[0] })
    $text = ((@($keep) + @($Lines)) -join "`n") + "`n"

    $tmp = New-OpEnvTempPath -Dir $dir; $tmpa = $null; $bak = $null
    try {
        Write-OpEnvText -Path $tmp -Text $text
        Set-OpEnvFileMode -Path $tmp -Mode 600

        if ($needAct) {
            $tmpa = New-OpEnvTempPath -Dir $dir
            [System.IO.File]::Copy($act, $tmpa, $true)
            $existing = [System.IO.File]::ReadAllText($tmpa)
            $add = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { "`n$Set`n" } else { "$Set`n" }
            [System.IO.File]::AppendAllText($tmpa, $add, [System.Text.UTF8Encoding]::new($false))
        }
        if (-not $isNew) {
            $bak = New-OpEnvTempPath -Dir $dir
            [System.IO.File]::Copy($file, $bak, $true)
        }

        [System.IO.File]::Move($tmp, $file, $true); $tmp = $null
        if ($needAct) {
            try { [System.IO.File]::Move($tmpa, $act, $true); $tmpa = $null }
            catch {
                # Roll the set file back so we leave exactly what was there before.
                if ($bak) { [System.IO.File]::Move($bak, $file, $true); $bak = $null } else { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
                Write-Error "Can't activate set '$Set' (replacing $act failed). Nothing was changed."
                return $false
            }
        }
        return $true
    } catch {
        Write-Error "Could not write set '$Set': $($_.Exception.Message)"
        return $false
    } finally {
        foreach ($t in @($tmp, $tmpa, $bak)) { if ($t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } }
    }
}

function Get-OpEnvAccountOf {
    # The account on the first line of a set that defines $Name (CRs stripped), or ''.
    param([string]$File, [string]$Name)
    foreach ($l in (Get-OpEnvRawLines -Path $File)) {
        $f = ($l -replace "`r", '').Split("`t")
        if ($f[0] -ceq $Name) { return $(if ($f.Length -ge 3) { $f[2] } else { '' }) }
    }
    return ''
}

function Resolve-OpEnvSetName {
    # The set to work on: the argument, or a pick from the existing sets (plus the usual
    # suggestions) with a "new set" choice. Returns the name, or $null after printing why not.
    param([string]$Set)
    if (-not $Set) {
        $choices = [System.Collections.Generic.List[string]]::new()
        foreach ($n in @(Get-OpEnvSetNameList) + @('guild', 'personal')) { if ($n -and -not $choices.Contains($n)) { $choices.Add($n) } }
        $choices.Add('+ new set...')
        $Set = @($choices | Select-FromList -Prompt 'Set') | Select-Object -First 1
        if (-not $Set) { return $null }
        if ($Set -ceq '+ new set...') {
            $Set = Read-OpEnvAnswer -Prompt '  New set name'
            if (-not $Set) { return $null }
        }
    }
    if ($Set -cnotmatch $script:OpSetPattern) {
        Write-Error "Invalid set name '$Set' (use lowercase letters, digits, - or _)"
        return $null
    }
    return $Set
}

function Add-OpEnvEntry {
    # op-env add [set] [VAR] [op://ref] [account]
    [CmdletBinding()]
    param([string]$Set, [string]$Name, [string]$Ref, [string]$Account)

    [void](Initialize-OpEnvSetsDir)
    $Set = Resolve-OpEnvSetName -Set $Set
    if (-not $Set) { return }

    if (-not $Name) { $Name = Read-OpEnvAnswer -Prompt '  Env var name' }
    if (-not $Name) { return }
    if ($Name -cnotmatch $script:OpVarPattern) { Write-Error "Invalid env var name '$Name'"; return }
    if ($Name -ceq 'GITHUB_TOKEN' -or $Name -ceq 'GH_TOKEN') {
        Write-Host "⚠️  $Name overrides gh CLI's stored auth for every gh call. Consider GH_PAT instead."
        $ok = Read-OpEnvAnswer -Prompt '  Use it anyway? [y/N]'
        if ("$ok" -notmatch '^[Yy]$') { return }   # no answer counts as no
    }

    if (-not $Ref) { $Ref = Read-OpEnvAnswer -Prompt '  1Password reference (op://vault/item/field)' }
    if (-not $Ref) { return }
    if ($Ref -cnotmatch $script:OpRefPattern) { Write-Error 'Reference must look like op://vault/item/field'; return }

    # The account is an optional 4th argument and is never prompted for. Left out on an update, it keeps
    # whatever the line already said: changing a reference must not quietly move the secret to another
    # account, or to the default one.
    if (-not $Account) { $Account = Get-OpEnvAccountOf -File (Join-Path (Get-OpEnvSetsDir) "$Set.tsv") -Name $Name }
    if ($Account -and $Account -cnotmatch $script:OpAccountPattern) {
        Write-Error "Invalid account '$Account' (letters, digits, dots, dashes and underscores)"
        return
    }

    $line = "$Name`t$Ref"
    if ($Account) { $line += "`t$Account" }
    if (-not (Write-OpEnvSet -Set $Set -Lines @($line))) { return }
    Write-Host "✅ [$Set] $Name -> $Ref"
    if ($Account) { Write-Host "   account: $Account" }
    Write-Host '   Load it now: op-env load'
}

function Get-OpEnvListing {
    # op-env list [set]
    [CmdletBinding()]
    param([string]$Only)

    $dir = Get-OpEnvSetsDir
    $active = @(Get-PreflightEnvSetName -Dir $dir)
    $found = $false
    foreach ($set in @(Get-OpEnvSetNameList)) {
        if ($Only -and $set -cne $Only) { continue }
        $found = $true
        if ($active -ccontains $set) { Write-Host "● $set (active)" } else { Write-Host "○ $set (inactive)" }
        foreach ($raw in (Get-OpEnvRawLines -Path (Join-Path $dir "$set.tsv"))) {
            $f = $raw.Split("`t")
            $name = $f[0]
            $ref  = if ($f.Length -ge 2) { $f[1].TrimEnd("`r") } else { '' }
            $acct = if ($f.Length -ge 3) { $f[2].TrimEnd("`r") } else { '' }
            if (-not $name) { continue }
            # The account only when it differs from the default, so a single-account install's output
            # is unchanged by that feature.
            if ($acct -and $acct -cne "$env:OP_ACCOUNT") { Write-Host ('    {0,-28} {1}  [account: {2}]' -f $name, $ref, $acct) }
            else { Write-Host ('    {0,-28} {1}' -f $name, $ref) }
        }
    }
    if (-not $found) {
        if ($Only) { Write-Error "No such set: $Only"; return }
        Write-Host 'No env sets yet. Create one with: op-env add'
    }
}

function Remove-OpEnvEntry {
    # op-env rm [set] [VAR]
    [CmdletBinding()]
    param([string]$Set, [string]$Name)

    $dir = Get-OpEnvSetsDir
    if (-not $Set) { $Set = @(@(Get-OpEnvSetNameList) | Select-FromList -Prompt 'Set') | Select-Object -First 1 }
    if (-not $Set) { return }
    if ($Set -cnotmatch $script:OpSetPattern) { Write-Error "Invalid set name '$Set'"; return }
    $file = Join-Path $dir "$Set.tsv"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Error "No such set: $Set"; return }
    $raw = @(Get-OpEnvRawLines -Path $file)
    if (-not $Name) {
        $names = @($raw | ForEach-Object { $_.Split("`t")[0].TrimEnd("`r") })
        $Name = @($names | Select-FromList -Prompt "Remove from $Set") | Select-Object -First 1
    }
    if (-not $Name) { return }
    if (@($raw | Where-Object { $_.Split("`t")[0].TrimEnd("`r") -ceq $Name }).Count -eq 0) { Write-Error "$Name not in $Set"; return }

    $keep = @($raw | Where-Object { $_.Split("`t")[0] -cne $Name })
    $tmp = New-OpEnvTempPath -Dir $dir
    try {
        Write-OpEnvText -Path $tmp -Text $(if ($keep.Count -gt 0) { ($keep -join "`n") + "`n" } else { '' })
        Set-OpEnvFileMode -Path $tmp -Mode 600
        [System.IO.File]::Move($tmp, $file, $true); $tmp = $null
    } catch {
        Write-Error "Could not update $Set`: $($_.Exception.Message)"
        return
    } finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    Write-Host "🗑️  Removed $Name from $Set"
    Write-Host "   It is unset on the next op-env load or op-env clear, or now with: Remove-Item Env:$Name"
}

function Set-OpEnvActive {
    # op-env use [set...]
    [CmdletBinding()]
    param([string[]]$Set)

    $dir = Initialize-OpEnvSetsDir
    if (@($Set).Count -gt 0) {
        $chosen = @($Set)
    } else {
        $available = @(Get-OpEnvSetNameList)
        $chosen = @($available | Select-FromList -Prompt 'Active sets' -Multiple)
    }
    $chosen = @($chosen | Where-Object { $_ })
    if ($chosen.Count -eq 0) { Write-Host 'No change.'; return }
    foreach ($s in $chosen) {
        if ($s -cnotmatch $script:OpSetPattern -or -not (Test-Path -LiteralPath (Join-Path $dir "$s.tsv") -PathType Leaf)) {
            Write-Error "No such set: $s"
            return
        }
    }
    $act = Join-Path $dir '.active'
    $tmp = New-OpEnvTempPath -Dir $dir
    try {
        # No chmod: bash writes .active with the default mode (it lists set names, not secrets), and the
        # two sides must produce the same files (tests/op-env.sh compares modes too).
        Write-OpEnvText -Path $tmp -Text (($chosen -join "`n") + "`n")
        [System.IO.File]::Move($tmp, $act, $true); $tmp = $null
    } catch {
        Write-Error "Could not save the active sets to $act`: $($_.Exception.Message)"
        return
    } finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    Write-Host "✅ Active sets: $($chosen -join ' ')"
}

function Get-OpEnvHelpText {
@'
op-env manages named env sets backed by 1Password references.

  op-env load [set...]                Load the active sets from 1Password (or only the named sets)
  op-env clear [set...]               Unset everything loaded (or only the named sets' variables)
  op-env add [set] [VAR] [op://ref] [account]   Add or update a key (prompts for a missing set/VAR/ref)
  op-env list [set]                   Show sets and keys (● active, ○ inactive)
  op-env rm [set] [VAR]               Remove a key
  op-env use [set...]                 Choose active sets (a multi-select picker if omitted)
  op-env help                         This message

Sets (e.g. guild, personal) are stored in envsets\<set>.tsv, one
VAR<TAB>op://vault/item/field per line, and are the only list of secrets
`op-env load` and `op-env clear` use.

`op-env load` with no set loads every active set, and is authoritative: a variable
whose definition is gone, or whose set is no longer active, is unset. `op-env load
guild` loads only that set, adds to what is already loaded and unsets nothing, and
works on a set that is not active (it says so). A later plain `op-env load` -- the one
`Invoke-Preflight` runs -- unsets such a set's variables again, as it does for any inactive
set; activate it with `op-env use` to keep it.

A line may add a third TAB-separated column: the 1Password account that holds the
reference (a sign-in address like my-team.1password.com, or an `op account add`
shorthand). Leave it out to use $env:OP_ACCOUNT. Use it when a reference lives in a
different account than your other secrets: op resolves each reference against one
account per call, so `op-env load` batches one `op run` per account:

  op-env add guild ATLASSIAN_TOKEN 'op://Employee/Some Item/credential' my-team.1password.com

Re-adding a key without an account keeps the one already on the line.

Examples:
  op-env add work NPM_TOKEN 'op://Private/npm/credential'   Put a secret in the "work" set
  op-env load work                                          Load just the work secrets
  op-env clear work                                         Unset just the work secrets again
  op-env use work personal                                  Make a plain op-env load use these two

Tab completes the subcommands and the set names.
'@
}

function Get-OpEnvCompletion {
    # What `op-env <TAB>` offers (mirrors bash _op_env_candidates): the subcommands, then set names
    # after load, clear, use, list or rm (list and rm take one). Never throws: a completer that errors
    # prints a stack trace into the user's prompt.
    param([string]$Sub, [int]$Given, [string]$Word)
    try {
        $names = switch ($Sub) {
            ''                                   { 'load', 'clear', 'add', 'list', 'rm', 'use', 'help' }
            { $_ -in 'load', 'clear', 'use' }    { Get-OpEnvSetNameList }
            { $_ -in 'list', 'ls', 'rm', 'remove' } { if ($Given -eq 0) { Get-OpEnvSetNameList } }
        }
        foreach ($n in @($names)) {
            if ($n -like "$Word*") { [System.Management.Automation.CompletionResult]::new($n, $n, 'ParameterValue', $n) }
        }
    } catch { Write-Verbose "op-env completion: $_" }
}

function Invoke-OpEnv {
    <#
    .SYNOPSIS
        Manage env sets of 1Password references and load / clear the secrets they define (alias: op-env).
    .DESCRIPTION
        The PowerShell twin of the bash `op-env`:

          op-env load [set...]      load the active sets, or only the named ones
          op-env clear [set...]     clear everything loaded, or only the named sets' variables
          op-env add [set] [VAR] [op://ref] [account]
          op-env list [set]
          op-env rm [set] [VAR]
          op-env use [set...]
          op-env help

        Run `op-env help` for the rules (authoritative plain load, additive named load, per-set clear).
    .PARAMETER Command
        The subcommand. Defaults to help.
    .PARAMETER Arguments
        What the subcommand takes: set names, a variable name, a reference, an account.
    .EXAMPLE
        op-env load work
    .EXAMPLE
        op-env add work NPM_TOKEN 'op://Private/npm/credential'
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'User-facing CLI output.')]
    param(
        [Parameter(Position = 0)]
        [string]$Command = 'help',

        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $rest = @($Arguments | Where-Object { $null -ne $_ })
    switch ($Command) {
        'load'  { if ($rest.Count -gt 0) { Import-OpEnv -Set $rest } else { Import-OpEnv } }
        'clear' { if ($rest.Count -gt 0) { Clear-OpEnv -Set $rest } else { Clear-OpEnv } }
        'add'   { Add-OpEnvEntry -Set ($rest | Select-Object -Index 0) -Name ($rest | Select-Object -Index 1) -Ref ($rest | Select-Object -Index 2) -Account ($rest | Select-Object -Index 3) }
        { $_ -in 'list', 'ls' }     { Get-OpEnvListing -Only ($rest | Select-Object -Index 0) }
        { $_ -in 'rm', 'remove' }   { Remove-OpEnvEntry -Set ($rest | Select-Object -Index 0) -Name ($rest | Select-Object -Index 1) }
        'use'   { if ($rest.Count -gt 0) { Set-OpEnvActive -Set $rest } else { Set-OpEnvActive } }
        { $_ -in 'help', '-h', '--help' } { Write-Host (Get-OpEnvHelpText) }
        default { Write-Error "Unknown op-env command: $Command"; Write-Host (Get-OpEnvHelpText) }
    }
}
