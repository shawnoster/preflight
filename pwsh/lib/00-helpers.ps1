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
