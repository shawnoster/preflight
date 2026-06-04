<#
.SYNOPSIS
    Install (or reinstall, or uninstall) the Preflight PowerShell module.

.DESCRIPTION
    Mirrors the bash installer at install.sh, adapted for Windows / PowerShell.

    By default this will:
      1. Ensure $HOME\.preflight\ exists, with the pwsh/ tree populated
         from this checkout (or via `git clone` if running standalone).
      2. Copy pwsh/config/accounts.ps1.template -> pwsh/config/accounts.ps1
         (gitignored). Skipped if accounts.ps1 already exists.
      3. Back up your current $PROFILE to <profile>.bak.<timestamp>.
      4. Comment out functions in $PROFILE that are superseded by the
         Preflight module (Set-SecureEnv, Switch-AWSProfile,
         Switch-GitBranch, Remove-MergedBranches, bake), tagging each
         with a marker so
         uninstall can reverse the change.
      5. Append an Import-Module line that loads Preflight from
         $HOME\.preflight\pwsh\Preflight.psd1, guarded so reload is
         idempotent.

    Safe to run repeatedly. Use -DryRun to preview without writing.
    Use -Uninstall to reverse everything.

.PARAMETER DryRun
    Show every file that would be written and the diff that would be applied
    to $PROFILE, but make no changes. Read-only.

.PARAMETER Uninstall
    Reverse the install: uncomment any lines tagged with the Preflight marker
    in $PROFILE, remove the Import-Module guard block, and (optionally) delete
    $HOME\.preflight\pwsh\.

.PARAMETER Force
    Skip "are you sure" prompts.

.PARAMETER InstallRoot
    Override the install location. Defaults to $HOME\.preflight\.

.PARAMETER ProfilePath
    Override which $PROFILE file to edit. Defaults to $PROFILE
    (Microsoft.PowerShell_profile.ps1 in CurrentUserCurrentHost).

.EXAMPLE
    .\install.ps1 -DryRun
    Preview every change without touching anything.

.EXAMPLE
    .\install.ps1
    Install, with confirmation prompts before destructive steps.

.EXAMPLE
    .\install.ps1 -Force
    Install without prompts.

    .EXAMPLE
    .\install.ps1 -Uninstall
    Roll back the changes the installer made.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'DryRun, Force, InstallRoot, and ProfilePath are referenced inside Invoke-Install/Invoke-Uninstall via script scope.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing installer output; Write-Host is appropriate.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Internal helpers (New-ImportGuard, Remove-ImportGuard, Restore-CommentedFunctions) are pure string transforms — they don''t mutate state on their own.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns', '',
    Justification = 'Restore-CommentedFunctions intentionally plural — it operates on the set of all comment-marked functions in one pass.'
)]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Force,
    [string]$InstallRoot = (Join-Path $HOME '.preflight'),
    [string]$ProfilePath = $PROFILE
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Markers used to tag every line we touch in $PROFILE so that -Uninstall
# can find and reverse them deterministically.
$script:MarkerPrefix     = '# preflight: '
$script:GuardBegin       = '# preflight:begin Import-Module guard'
$script:GuardEnd         = '# preflight:end Import-Module guard'
$script:CommentMarker    = '# preflight:superseded'

# Functions we comment out in the user's existing $PROFILE because the
# module supersedes them. The module exports same-named functions/aliases
# so the user's muscle memory keeps working.
$script:SupersededFunctions = @(
    @{ Name = 'Set-SecureEnv';         SupersededBy = 'Import-OpEnv (alias: op-load-env)' }
    @{ Name = 'Switch-AWSProfile';     SupersededBy = 'Set-AwsProfile (alias: awsp)' }
    @{ Name = 'Switch-GitBranch';      SupersededBy = 'Switch-GitBranch (alias: gco) — same name, now from Preflight module' }
    @{ Name = 'Remove-MergedBranches'; SupersededBy = 'Remove-MergedGitBranches (alias: gclean)' }
    @{ Name = 'bake';                  SupersededBy = 'Invoke-Make (alias: bake)' }
)

# ---- Helpers ----------------------------------------------------------------

function Write-Step {
    param([string]$Message, [string]$Status = 'info')
    $glyph = switch ($Status) {
        'ok'   { '✅' }
        'warn' { '⚠️ ' }
        'err'  { '❌' }
        'dry'  { '🔎' }
        default { '·' }
    }
    Write-Host "$glyph $Message"
}

function Get-RepoSource {
    <#
    .SYNOPSIS
        Locate the pwsh/ directory we should copy into $InstallRoot.

        If install.ps1 is being run from inside a checkout (the normal case),
        return its parent. Otherwise return $null and the caller will
        `git clone` into place instead.
    #>
    $hereScript = $MyInvocation.PSCommandPath
    if (-not $hereScript) { $hereScript = $PSCommandPath }
    if (-not $hereScript) { return $null }

    $hereDir = Split-Path -Parent $hereScript
    # Sanity: confirm we're in pwsh/ — i.e. Preflight.psd1 is next to us.
    if (Test-Path (Join-Path $hereDir 'Preflight.psd1')) {
        return $hereDir
    }
    return $null
}

function Test-FunctionDefinition {
    <#
    .SYNOPSIS
        Return $true if $Content contains a "function <Name>" definition
        that is NOT already commented out by Preflight.
    #>
    param([string]$Content, [string]$Name)
    $escaped = [regex]::Escape($Name)
    # Match "function Name {" or "function Name(", optionally indented,
    # but only on uncommented lines.
    $pattern = "(?m)^(?!\s*#).*\bfunction\s+$escaped\b"
    return [regex]::IsMatch($Content, $pattern)
}

function Edit-ProfileContent {
    <#
    .SYNOPSIS
        Comment out any function definitions in $Content that match
        $SupersededFunctions, tagging the lines with $CommentMarker.

        Returns the modified content and a list of changes.
    #>
    param([string]$Content)
    $changes = New-Object System.Collections.Generic.List[string]

    # Detect dominant line ending so we re-emit the same flavor.
    $crlfCount = ([regex]::Matches($Content, "`r`n")).Count
    $lfOnly    = ([regex]::Matches($Content, "(?<!`r)`n")).Count
    $eol = if ($crlfCount -ge $lfOnly) { "`r`n" } else { "`n" }

    foreach ($entry in $script:SupersededFunctions) {
        $name         = $entry.Name
        $supersededBy = $entry.SupersededBy
        if (-not (Test-FunctionDefinition -Content $Content -Name $name)) { continue }

        # Walk the file line-by-line. When we hit a `function Name {` line,
        # we comment out that line and every subsequent line until braces
        # balance to zero. We also comment out the leading doc-comment
        # block immediately preceding the function (consecutive lines
        # starting with #), because PowerShell's convention is to write
        # "# Foo Bar" right above the function definition.
        # Use [regex]::Split for a deterministic split on either CRLF or LF;
        # PowerShell's -split with `r?`n has been observed to not split here
        # on profiles with mixed/unusual line endings.
        $lines = [regex]::Split($Content, "`r`n|`n|`r")
        $out   = New-Object System.Collections.Generic.List[string]

        $i = 0
        $matched = $false
        while ($i -lt $lines.Count) {
            $line = $lines[$i]

            # Detect `function <name>` on a non-comment line.
            $isFnLine = $line -match "^\s*function\s+$([regex]::Escape($name))\b" -and
                        $line -notmatch '^\s*#'

            if (-not $isFnLine) {
                $out.Add($line) | Out-Null
                $i++
                continue
            }

            $matched = $true

            # Walk backwards through $out to comment the preceding doc block.
            for ($j = $out.Count - 1; $j -ge 0; $j--) {
                $prev = $out[$j]
                if ($prev -match '^\s*#' -and $prev -notmatch [regex]::Escape($script:CommentMarker)) {
                    $out[$j] = "$script:CommentMarker $prev"
                } elseif ([string]::IsNullOrWhiteSpace($prev)) {
                    continue
                } else {
                    break
                }
            }

            # Comment the `function ... {` line. Track brace depth from this line.
            $out.Add("$script:CommentMarker $line  # superseded by $supersededBy") | Out-Null
            $depth = ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
            $i++

            while ($i -lt $lines.Count -and $depth -gt 0) {
                $bodyLine = $lines[$i]
                $out.Add("$script:CommentMarker $bodyLine") | Out-Null
                $depth += ([regex]::Matches($bodyLine, '\{')).Count
                $depth -= ([regex]::Matches($bodyLine, '\}')).Count
                $i++
            }

            $changes.Add("commented out function '$name' (superseded by $supersededBy)") | Out-Null
        }

        if ($matched) {
            $Content = $out -join $eol
        }
    }

    return @{ Content = $Content; Changes = $changes }
}

function Read-ProfileFile {
    <#
    .SYNOPSIS
        Read a profile file, preserving knowledge of its original encoding.
    .DESCRIPTION
        Returns @{ Content = <string>; Encoding = <Text.Encoding>; HasBom = <bool> }.
        Detects UTF-8 BOM, UTF-16 LE/BE BOM, and UTF-32 LE BOM. Falls back to
        UTF-8 without BOM for files with no BOM (the most common case for
        PowerShell profiles authored on modern systems).

        Necessary so install/uninstall can round-trip a profile byte-for-byte
        regardless of how it was originally encoded.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Content = ''; Encoding = [System.Text.UTF8Encoding]::new($false); HasBom = $false }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        return @{ Content = ''; Encoding = [System.Text.UTF8Encoding]::new($false); HasBom = $false }
    }

    # BOM sniff. Order matters: UTF-32 LE BOM is "FF FE 00 00" — check it
    # before UTF-16 LE ("FF FE") so we don't mis-classify.
    $encoding = $null
    $hasBom = $false
    $skip = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = [System.Text.UTF32Encoding]::new($false, $true)  # LE, with BOM
        $hasBom = $true
        $skip = 4
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = [System.Text.UTF32Encoding]::new($true, $true)   # BE, with BOM
        $hasBom = $true
        $skip = 4
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true)            # UTF-8 with BOM
        $hasBom = $true
        $skip = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true) # UTF-16 LE with BOM
        $hasBom = $true
        $skip = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true)  # UTF-16 BE with BOM
        $hasBom = $true
        $skip = 2
    } else {
        # No BOM — assume UTF-8 without BOM. (We can't reliably distinguish
        # ANSI/Windows-1252 from UTF-8 without ICU-style heuristics; UTF-8
        # is the modern default and round-trips ASCII regardless.)
        $encoding = [System.Text.UTF8Encoding]::new($false)
        $hasBom = $false
        $skip = 0
    }

    $content = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
    return @{ Content = $content; Encoding = $encoding; HasBom = $hasBom }
}

function Write-ProfileFile {
    <#
    .SYNOPSIS
        Write a profile file using the encoding info captured by Read-ProfileFile.
    .DESCRIPTION
        Reuses the original encoding (with BOM if it had one) so the file's
        byte signature matches what was there before. Required for round-trip
        guarantees on profiles authored as UTF-16LE (legacy Windows
        PowerShell ISE default) or UTF-8 with BOM.
    #>
    param(
        [string]$Path,
        [string]$Content,
        [System.Text.Encoding]$Encoding,
        [bool]$HasBom
    )
    # GetBytes never includes a BOM; we have to prepend it ourselves if the
    # original had one. (Encoding.GetPreamble() returns the BOM for encodings
    # constructed with the BOM-emitting flag.)
    $bodyBytes = $Encoding.GetBytes($Content)
    if ($HasBom) {
        $preamble = $Encoding.GetPreamble()
        $all = New-Object byte[] ($preamble.Length + $bodyBytes.Length)
        [Array]::Copy($preamble, 0, $all, 0, $preamble.Length)
        [Array]::Copy($bodyBytes, 0, $all, $preamble.Length, $bodyBytes.Length)
        [System.IO.File]::WriteAllBytes($Path, $all)
    } else {
        [System.IO.File]::WriteAllBytes($Path, $bodyBytes)
    }
}

function New-ImportGuard {
    param([string]$ManifestPath, [string]$Eol = "`r`n")
    $manifestPathLiteral = $ManifestPath -replace "'", "''"
    $lines = @(
        $script:GuardBegin
        "if (Test-Path -LiteralPath '$manifestPathLiteral') {"
        "    Import-Module '$manifestPathLiteral' -ErrorAction SilentlyContinue"
        '}'
        $script:GuardEnd
    )
    return ($lines -join $Eol)
}

function Test-ImportGuardPresent {
    param([string]$Content)
    return ($Content -match [regex]::Escape($script:GuardBegin))
}

function Add-ImportGuard {
    <#
    .SYNOPSIS
        Append the Import-Module guard to $Content, preserving line endings
        and trailing whitespace.
    .DESCRIPTION
        The append shape is:

            <original-content><eol><eol><guard-block><eol>

        where <eol> matches the dominant line ending of the existing content.
        We do NOT strip the user's trailing whitespace — Remove-ImportGuard
        is responsible for removing exactly what we added so the file
        round-trips byte-for-byte.
    #>
    param([string]$Content, [string]$ManifestPath)
    if (Test-ImportGuardPresent -Content $Content) { return $Content }

    # Match the dominant line ending of the existing content. Default to CRLF
    # for empty or eol-less files (Windows convention).
    $crlfCount = ([regex]::Matches($Content, "`r`n")).Count
    $lfOnly    = ([regex]::Matches($Content, "(?<!`r)`n")).Count
    $eol = if ($crlfCount -ge $lfOnly -and $crlfCount -gt 0) { "`r`n" }
           elseif ($lfOnly -gt 0)                            { "`n" }
           else                                              { "`r`n" }

    $guard = New-ImportGuard -ManifestPath $ManifestPath -Eol $eol

    # Append a blank line separator, the guard, and a final newline. Don't
    # touch any pre-existing trailing whitespace — Remove-ImportGuard knows
    # this exact shape and reverses it.
    return "$Content$eol$eol$guard$eol"
}

function Remove-ImportGuard {
    <#
    .SYNOPSIS
        Reverse Add-ImportGuard. Removes exactly the bytes Add-ImportGuard
        appended (separator newline + guard block + trailing newline) without
        touching unrelated trailing whitespace.
    .DESCRIPTION
        Add-ImportGuard appends "<eol><eol><guard><eol>" to the original
        content. We anchor the regex to the end of the file, capture
        any line ending preceding GuardBegin, and remove from that
        leading-eol through the trailing newline that follows GuardEnd.
        That preserves the original content's trailing characters byte-for-byte.
    #>
    param([string]$Content)

    # Anchored at end-of-string, with the leading separator newline.
    # The leading (\r\n|\r|\n){1,2} accounts for Add-ImportGuard's "<eol><eol>"
    # separator, while still matching guards inserted with only one separator
    # newline in legacy installs.
    $beginEsc = [regex]::Escape($script:GuardBegin)
    $endEsc   = [regex]::Escape($script:GuardEnd)
    $pattern  = "(?s)(\r\n|\r|\n){1,2}$beginEsc(\r\n|\r|\n).*?$endEsc(\r\n|\r|\n)?\z"

    return ($Content -replace $pattern, '')
}

function Restore-CommentedFunctions {
    param([string]$Content)
    # Strip the "# preflight:superseded " prefix from every tagged line and
    # also drop the trailing "  # superseded by ..." annotation we added.
    $prefixPattern = "(?m)^$([regex]::Escape($script:CommentMarker)) ?"
    $Content = $Content -replace $prefixPattern, ''
    $Content = $Content -replace '  # superseded by [^\r\n]*', ''
    return $Content
}

function Show-Diff {
    param([string]$Old, [string]$New, [string]$Label)
    Write-Host ""
    Write-Host "── diff: $Label ──" -ForegroundColor Cyan
    $oldLines = [regex]::Split($Old, "`r`n|`n|`r")
    $newLines = [regex]::Split($New, "`r`n|`n|`r")
    $max = [Math]::Max($oldLines.Count, $newLines.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $o = if ($i -lt $oldLines.Count) { $oldLines[$i] } else { $null }
        $n = if ($i -lt $newLines.Count) { $newLines[$i] } else { $null }
        if ($o -ne $n) {
            if ($null -ne $o) { Write-Host "- $o" -ForegroundColor Red }
            if ($null -ne $n) { Write-Host "+ $n" -ForegroundColor Green }
        }
    }
    Write-Host "── end diff ──" -ForegroundColor Cyan
}

function Confirm-ProfileEdit {
    <#
    .SYNOPSIS
        Prompt the user to confirm a destructive change to $PROFILE or the
        install directory, respecting -Force / -Confirm / -WhatIf semantics.
    .DESCRIPTION
        ShouldProcess on its own does NOT prompt unless the caller passes
        -Confirm explicitly (or ConfirmImpact is High and the
        $ConfirmPreference is set lower). For an installer that the docstring
        promises will "prompt before editing $PROFILE", we need a real
        interactive confirmation by default.

        Behavior:
          - $Force            -> proceed without prompting
          - -WhatIf           -> ShouldProcess returns false; we abort
          - -Confirm          -> ShouldProcess prompts (PowerShell native UX)
          - default           -> Read-Host yes/no prompt
          - non-interactive   -> proceed (with a notice), since prompting
                                  would hang a CI run

        Returns $true if the caller should proceed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Target,
        [string]$Action = 'modify'
    )

    if ($Force) { return $true }

    # -WhatIf / -Confirm path: ShouldProcess takes over.
    if ($WhatIfPreference -or ($PSBoundParameters.ContainsKey('Confirm') -or $ConfirmPreference -eq 'Low')) {
        return $PSCmdlet.ShouldProcess($Target, $Action)
    }

    # Non-interactive: proceed silently (matches `curl | bash`-style installs).
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Write-Step "Non-interactive shell — proceeding without prompt (use -Force to silence)" 'info'
        return $true
    }

    # Interactive default: explicit Read-Host prompt.
    Write-Host ''
    Write-Host "About to $Action $Target (a backup will be made first where applicable)." -ForegroundColor Yellow
    $answer = Read-Host 'Proceed? [Y/n]'
    return ($answer -eq '' -or $answer -match '^[Yy]')
}

# ---- Install / uninstall ----------------------------------------------------

function Invoke-Install {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-Step "Preflight PowerShell installer (install root: $InstallRoot)" 'info'
    if ($DryRun) { Write-Step "Dry-run: no files will be written." 'dry' }

    # 1) Locate or fetch the source tree.
    $source = Get-RepoSource
    $pwshSrc = $null
    if ($source) {
        $pwshSrc = $source
        Write-Step "Source: running from checkout at $source" 'ok'
    } else {
        Write-Step "Source: no local checkout detected — would `git clone` https://github.com/shawnoster/preflight.git" 'info'
        if (-not $DryRun) {
            $repoTmp = Join-Path ([System.IO.Path]::GetTempPath()) "preflight-install-$([guid]::NewGuid())"
            git clone --depth 1 https://github.com/shawnoster/preflight.git $repoTmp
            $pwshSrc = Join-Path $repoTmp 'pwsh'
        }
    }

    # 2) Populate $InstallRoot\pwsh\ from $pwshSrc.
    $destPwsh = Join-Path $InstallRoot 'pwsh'
    Write-Step "Target: $destPwsh" 'info'
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $InstallRoot)) {
            New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        }
        # Resolve canonical paths for the same-source-as-dest check.
        $srcResolved  = (Resolve-Path -LiteralPath $pwshSrc).Path
        $destResolved = if (Test-Path -LiteralPath $destPwsh) {
            (Resolve-Path -LiteralPath $destPwsh).Path
        } else { $destPwsh }
        if ($srcResolved -ne $destResolved) {
            # Always create $destPwsh first then copy CONTENTS of $pwshSrc
            # into it. This avoids the gotcha where Copy-Item -Recurse with
            # a directory source and an existing destination directory will
            # nest the source dir's name inside the destination (e.g.
            # creating `~/.preflight/preflight-validate/...` instead of
            # `~/.preflight/pwsh/...` when the source dir isn't named pwsh).
            if (-not (Test-Path -LiteralPath $destPwsh)) {
                New-Item -ItemType Directory -Path $destPwsh -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $pwshSrc '*') -Destination $destPwsh -Recurse -Force
            Write-Step "Copied pwsh/ tree into $destPwsh" 'ok'
        } else {
            Write-Step "Source and destination are the same — skipped copy" 'ok'
        }
    } else {
        Write-Step "Would copy contents of $pwshSrc -> $destPwsh" 'dry'
    }

    # 3) Seed config/accounts.ps1 from template.
    $cfgTemplate = Join-Path $destPwsh 'config\accounts.ps1.template'
    $cfgFile     = Join-Path $destPwsh 'config\accounts.ps1'
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $cfgFile)) {
            if (Test-Path -LiteralPath $cfgTemplate) {
                Copy-Item -LiteralPath $cfgTemplate -Destination $cfgFile
                Write-Step "Created $cfgFile from template" 'ok'
            }
        } else {
            Write-Step "Config exists, kept: $cfgFile" 'ok'
        }
    } else {
        Write-Step "Would seed $cfgFile from template (if missing)" 'dry'
    }

    # 4) Update $PROFILE.
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        Write-Step "No $ProfilePath yet — will create one" 'info'
        $original         = ''
        $originalEncoding = [System.Text.UTF8Encoding]::new($false)
        $originalHasBom   = $false
    } else {
        # Read with encoding detection so we can write back with the same
        # encoding (and BOM, if any). Profiles authored in older Windows
        # PowerShell ISE are commonly UTF-16LE; modern ones tend to be
        # UTF-8 without BOM. Forcing one or the other on write would
        # corrupt the file or break the bit-perfect round-trip claim.
        $profileRead      = Read-ProfileFile -Path $ProfilePath
        $original         = $profileRead.Content
        $originalEncoding = $profileRead.Encoding
        $originalHasBom   = $profileRead.HasBom
    }

    $edited = Edit-ProfileContent -Content $original
    $manifest = Join-Path $destPwsh 'Preflight.psd1'
    $newContent = Add-ImportGuard -Content $edited.Content -ManifestPath $manifest

    if ($newContent -eq $original) {
        Write-Step "$ProfilePath already up to date" 'ok'
    } else {
        if ($DryRun) {
            Show-Diff -Old $original -New $newContent -Label $ProfilePath
            foreach ($c in $edited.Changes) { Write-Step $c 'dry' }
            Write-Step "Would append Import-Module guard for $manifest" 'dry'
        } else {
            # Confirm: -Force skips, -Confirm/-WhatIf go through ShouldProcess,
            # otherwise we ask interactively via Read-Host. Without this the
            # bare `install.ps1` invocation modifies $PROFILE silently, which
            # the docstring promised it wouldn't.
            $confirmed = Confirm-ProfileEdit -Target $ProfilePath -Action 'apply Preflight changes to'
            if (-not $confirmed) {
                Write-Step "Skipped profile edits (declined by user)" 'warn'
            } else {
                # Backup first.
                if (Test-Path -LiteralPath $ProfilePath) {
                    $backup = "$ProfilePath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                    Copy-Item -LiteralPath $ProfilePath -Destination $backup
                    Write-Step "Backed up profile -> $backup" 'ok'
                } else {
                    $profileDir = Split-Path -Parent $ProfilePath
                    if (-not (Test-Path -LiteralPath $profileDir)) {
                        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
                    }
                }
                Write-ProfileFile -Path $ProfilePath -Content $newContent `
                    -Encoding $originalEncoding -HasBom $originalHasBom
                Write-Step "Updated $ProfilePath" 'ok'
                foreach ($c in $edited.Changes) { Write-Step $c 'ok' }
            }
        }
    }

    Write-Host ""
    Write-Step "Done. Reload your shell with:  . `$PROFILE" 'ok'
    Write-Step "Verify with:                   Get-OpStatus" 'ok'
}

function Invoke-Uninstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-Step "Preflight PowerShell uninstaller" 'info'

    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        Write-Step "No $ProfilePath to clean up" 'warn'
    } else {
        $profileRead      = Read-ProfileFile -Path $ProfilePath
        $original         = $profileRead.Content
        $originalEncoding = $profileRead.Encoding
        $originalHasBom   = $profileRead.HasBom

        $newContent = Restore-CommentedFunctions -Content $original
        $newContent = Remove-ImportGuard         -Content $newContent

        if ($newContent -eq $original) {
            Write-Step "$ProfilePath has no Preflight changes to remove" 'ok'
        } else {
            if ($DryRun) {
                Show-Diff -Old $original -New $newContent -Label $ProfilePath
            } elseif (Confirm-ProfileEdit -Target $ProfilePath -Action 'restore') {
                $backup = "$ProfilePath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Copy-Item -LiteralPath $ProfilePath -Destination $backup
                Write-Step "Backed up profile -> $backup" 'ok'
                Write-ProfileFile -Path $ProfilePath -Content $newContent `
                    -Encoding $originalEncoding -HasBom $originalHasBom
                Write-Step "Restored $ProfilePath" 'ok'
            } else {
                Write-Step "Skipped profile restoration (declined by user)" 'warn'
            }
        }
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        if ($DryRun) {
            Write-Step "Would delete $InstallRoot\pwsh (use -Force to skip prompt)" 'dry'
        } elseif (Confirm-ProfileEdit -Target "$InstallRoot\pwsh" -Action 'remove install directory') {
            # Only remove the pwsh\ subtree we own; leave config alone if user opts out.
            $pwshOnly = Join-Path $InstallRoot 'pwsh'
            if (Test-Path -LiteralPath $pwshOnly) {
                Remove-Item -LiteralPath $pwshOnly -Recurse -Force
                Write-Step "Removed $pwshOnly" 'ok'
            }
        }
    }

    Write-Host ""
    Write-Step "Uninstall complete. Reload your shell to drop the Preflight functions." 'ok'
}

# ---- Entry point ------------------------------------------------------------

try {
    if ($Uninstall) {
        Invoke-Uninstall
    } else {
        Invoke-Install
    }
} catch {
    Write-Step "Installer failed: $_" 'err'
    throw
}
