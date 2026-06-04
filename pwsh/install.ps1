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
         Switch-GitBranch, bake), tagging each with a marker so
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
    @{ Name = 'Set-SecureEnv';     SupersededBy = 'Import-OpEnv (alias: op-load-env)' }
    @{ Name = 'Switch-AWSProfile'; SupersededBy = 'Set-AwsProfile (alias: awsp) — Phase 2' }
    @{ Name = 'Switch-GitBranch';  SupersededBy = 'Switch-Branch (alias: gco) — Phase 2' }
    @{ Name = 'bake';              SupersededBy = 'Invoke-Bake (alias: bake) — Phase 2' }
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

function New-ImportGuard {
    param([string]$ManifestPath)
    $manifestPathLiteral = $ManifestPath -replace "'", "''"
    return @"
$script:GuardBegin
if (Test-Path -LiteralPath '$manifestPathLiteral') {
    Import-Module '$manifestPathLiteral' -ErrorAction SilentlyContinue
}
$script:GuardEnd
"@
}

function Test-ImportGuardPresent {
    param([string]$Content)
    return ($Content -match [regex]::Escape($script:GuardBegin))
}

function Add-ImportGuard {
    param([string]$Content, [string]$ManifestPath)
    if (Test-ImportGuardPresent -Content $Content) { return $Content }

    # Match the dominant line ending of the existing content.
    $crlfCount = ([regex]::Matches($Content, "`r`n")).Count
    $lfOnly    = ([regex]::Matches($Content, "(?<!`r)`n")).Count
    $eol = if ($crlfCount -ge $lfOnly) { "`r`n" } else { "`n" }

    $guard = New-ImportGuard -ManifestPath $ManifestPath
    if ($eol -eq "`n") { $guard = $guard -replace "`r`n", "`n" }

    # Strip trailing whitespace, then append a blank line + guard + single newline.
    $Content = $Content -replace "\s+$", ""
    return "$Content$eol$eol$guard$eol"
}

function Remove-ImportGuard {
    param([string]$Content)
    # Match the guard block plus surrounding newlines on both sides, then
    # collapse to a single newline. This handles every shape the guard
    # might be in: appended at end-of-file, in the middle, with or without
    # leading/trailing blank lines.
    $pattern = "(?ms)(?:\r?\n)*$([regex]::Escape($script:GuardBegin))\r?\n.*?$([regex]::Escape($script:GuardEnd))(?:\r?\n)*"
    $Content = $Content -replace $pattern, "`r`n"
    # Strip any trailing whitespace beyond a single newline so the file
    # round-trips cleanly when paired with Add-ImportGuard.
    $Content = $Content -replace "\s+$", "`r`n"
    return $Content
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
        $original = ''
    } else {
        $original = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
        if ($null -eq $original) { $original = '' }
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
            $confirmed = $Force -or $PSCmdlet.ShouldProcess($ProfilePath, "Apply Preflight changes")
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
                Set-Content -LiteralPath $ProfilePath -Value $newContent -Encoding UTF8 -NoNewline
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
        $original = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
        $newContent = Restore-CommentedFunctions -Content $original
        $newContent = Remove-ImportGuard         -Content $newContent

        if ($newContent -eq $original) {
            Write-Step "$ProfilePath has no Preflight changes to remove" 'ok'
        } else {
            if ($DryRun) {
                Show-Diff -Old $original -New $newContent -Label $ProfilePath
            } else {
                $backup = "$ProfilePath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Copy-Item -LiteralPath $ProfilePath -Destination $backup
                Write-Step "Backed up profile -> $backup" 'ok'
                Set-Content -LiteralPath $ProfilePath -Value $newContent -Encoding UTF8 -NoNewline
                Write-Step "Restored $ProfilePath" 'ok'
            }
        }
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        if ($DryRun) {
            Write-Step "Would delete $InstallRoot (use -Force to skip prompt)" 'dry'
        } elseif ($Force -or $PSCmdlet.ShouldProcess($InstallRoot, 'Remove install directory')) {
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
