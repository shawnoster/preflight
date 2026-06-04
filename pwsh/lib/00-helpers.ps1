# lib/00-helpers.ps1 — shared internal helpers used across the module.
#
# Loaded first (alphabetical sort by filename) so other lib files can rely
# on these primitives. Nothing here is exported to the public surface.

# Suppress Write-Host warnings module-wide here; user-facing CLI helpers
# defined in this file all print directly.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI output; Write-Host is appropriate.'
)]
param()

function Find-FileUpward {
    <#
    .SYNOPSIS
        Walk up from $StartDirectory looking for the first ancestor that
        contains a file named $FileName.
    .DESCRIPTION
        Returns the full path to the matching file, or $null if no ancestor
        has it. Used by Invoke-NpmScript / Invoke-PoetryScript to find the
        nearest package.json / pyproject.toml when run from a sub-directory
        of the project root.

        Mirrors the bash _find_up helper in lib/project.sh.
    .PARAMETER FileName
        Name of the file to look for (e.g. 'package.json', 'pyproject.toml').
    .PARAMETER StartDirectory
        Directory to start searching from. Defaults to $PWD.
    .EXAMPLE
        $pkg = Find-FileUpward -FileName package.json
        if ($pkg) { Set-Location (Split-Path -Parent $pkg) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$FileName,

        [string]$StartDirectory = $PWD.Path
    )

    # If the start directory doesn't exist, return null rather than throw.
    # The function's contract is "returns the matching path or $null"; callers
    # rely on that ($null check) instead of a try/catch around the call site.
    if (-not (Test-Path -LiteralPath $StartDirectory -PathType Container)) {
        Write-Verbose "Find-FileUpward: start directory does not exist: $StartDirectory"
        return $null
    }
    $dir = (Resolve-Path -LiteralPath $StartDirectory).Path
    while ($dir) {
        $candidate = Join-Path $dir $FileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
        $parent = Split-Path -Parent $dir
        # Top of the filesystem: Split-Path returns '' on Linux/macOS roots
        # and the same drive root (e.g. 'C:\') on Windows.
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Select-FromList {
    <#
    .SYNOPSIS
        Pick one item from a list, using whatever interactive UI is available.
    .DESCRIPTION
        Cascade order:
          1. Out-GridView -OutputMode Single (Windows-only, GUI)
          2. fzf (cross-platform, terminal-based)
          3. numbered Read-Host fallback (works in any TTY)
          4. error if non-interactive

        Returns the selected string, or $null if nothing was chosen.
    .PARAMETER Items
        The list of strings to choose from. Pipeline-friendly.
    .PARAMETER Prompt
        Prompt string shown to the user.
    .EXAMPLE
        $profile = aws configure list-profiles | Select-FromList -Prompt 'AWS profile'
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string[]]$Items,

        [string]$Prompt = 'Select item'
    )
    begin { $all = New-Object System.Collections.Generic.List[string] }
    process { foreach ($i in $Items) { if ($i) { $all.Add($i) } } }
    end {
        if ($all.Count -eq 0) {
            Write-Verbose "Select-FromList: no items provided"
            return
        }
        if ($all.Count -eq 1) { return $all[0] }

        # 1) Out-GridView when available (Windows GUI).
        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            try {
                $sel = $all | Out-GridView -Title $Prompt -OutputMode Single
                # Cancel and "no selection" both return $null. Treat that as
                # "user said no" — don't fall through to fzf or a numbered
                # prompt, which would feel like the picker is repeating itself.
                # Callers that get $null can decide what to do (Set-AwsProfile
                # prints "No profile selected" and exits, for example).
                return $sel
            } catch {
                # Out-GridView itself failed to load (e.g. headless host with
                # no GUI subsystem). Fall through to the next picker.
                Write-Verbose "Out-GridView unavailable, trying fzf: $_"
            }
        }

        # 2) fzf when on PATH.
        if (Get-Command fzf -ErrorAction SilentlyContinue) {
            $sel = $all | & fzf --prompt "$Prompt > "
            return $sel
        }

        # 3) Numbered Read-Host fallback. Requires interactive stdin.
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
            Write-Error "Cannot select interactively in non-TTY context. Pass an explicit value."
            return
        }

        Write-Host "$Prompt`:"
        for ($i = 0; $i -lt $all.Count; $i++) {
            Write-Host ("  {0,3}) {1}" -f ($i + 1), $all[$i])
        }
        $answer = Read-Host "Choose [1-$($all.Count)]"
        # Capture the parsed integer with a real out variable so we don't
        # have to parse twice. (`[ref]$null` does work in PS 7+ — it
        # silently discards the out value — but binding to a real variable
        # makes the intent obvious and avoids the redundant `[int]$answer`
        # cast that followed in earlier revisions.)
        $idx = 0
        if ([int]::TryParse($answer, [ref]$idx)) {
            $idx -= 1  # 1-based input → 0-based array index
            if ($idx -ge 0 -and $idx -lt $all.Count) { return $all[$idx] }
        }
        return $null
    }
}

function Format-WrappedText {
    <#
    .SYNOPSIS
        Word-wrap a single string so continuation lines align at $IndentColumn.
    .DESCRIPTION
        Mirrors the bash `_owl_wrap` helper. Returns one string with embedded
        line breaks; no trailing newline. Continuation lines are prefixed
        with $IndentColumn spaces so the wrapped text aligns under the first
        word's column when written to a host that's already at column $IndentColumn.

        Used by Show-OwlSplash (and historically the bash preflight banner)
        to wrap quote text under the owl's right-side body column.

        Note: the wrap counts characters, not graphemes. Embedded ANSI escape
        sequences would inflate the perceived width; pass plain text.
    .PARAMETER Text
        The text to wrap. Whitespace-collapsed before wrapping.
    .PARAMETER IndentColumn
        Column where continuation lines should align. Pad width in spaces.
    .PARAMETER MaxWidth
        Total terminal width. Defaults to $Host.UI.RawUI.WindowSize.Width
        when available, else 80.
    .EXAMPLE
        Format-WrappedText 'A long sentence that needs to wrap.' 12 60
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Text,

        [Parameter(Mandatory = $true, Position = 1)]
        [int]$IndentColumn,

        [int]$MaxWidth = 0
    )

    if ($MaxWidth -le 0) {
        # Try the raw host width; fall back to 80 if the host doesn't
        # expose one (redirected output, headless contexts, etc.).
        try {
            $w = $Host.UI.RawUI.WindowSize.Width
            if ($w -gt 0) { $MaxWidth = $w } else { $MaxWidth = 80 }
        } catch {
            $MaxWidth = 80
        }
    }

    $available = $MaxWidth - $IndentColumn
    # Minimum sane width guard — if the indent eats most of the terminal,
    # wrap at 20 chars rather than producing single-word lines forever.
    if ($available -lt 20) { $available = 20 }

    $pad = ' ' * $IndentColumn
    $words = $Text -split '\s+' | Where-Object { $_ }

    $sb = New-Object System.Text.StringBuilder
    $line = ''
    foreach ($word in $words) {
        if (-not $line) {
            $line = $word
        } elseif ($line.Length + 1 + $word.Length -le $available) {
            $line = "$line $word"
        } else {
            if ($sb.Length -gt 0) { [void]$sb.Append("`n").Append($pad) }
            [void]$sb.Append($line)
            $line = $word
        }
    }
    if ($line) {
        if ($sb.Length -gt 0) { [void]$sb.Append("`n").Append($pad) }
        [void]$sb.Append($line)
    }
    return $sb.ToString()
}
