# lib/project.ps1 — project navigation and build helpers for Preflight.
#
# Mirrors lib/project.sh on the bash side:
#   Invoke-Make          (bake)   — Run a Makefile target with picker
#   Invoke-NpmScript     (yak)    — Run an npm script with picker
#   Invoke-PoetryScript  (poet)   — Run a poetry script with picker
#   Set-LocationProject  (proj)   — Jump to a project directory with picker
#   Start-LocalServer    (serve)  — Quick HTTP server (python -m http.server)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI output; Write-Host is appropriate.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'ArgumentCompleter scriptblocks must accept the standard 5-arg signature even when individual parameters are unused.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Set-LocationProject and Start-LocalServer follow the precedent of the built-in Set-Location and Start-Process cmdlets, which do not implement ShouldProcess. Adding -WhatIf semantics to a cd-equivalent or a foreground HTTP server would be theatrical, not useful.'
)]
param()

# ---- Invoke-Make -----------------------------------------------------------

function Invoke-Make {
    <#
    .SYNOPSIS
        Run a Makefile target — pass a target name or pick interactively.
    .DESCRIPTION
        PowerShell sibling of bash `bake`. Looks for ./Makefile, extracts
        target names from non-comment, non-pattern rules, and runs the
        chosen target with `make`. If no target is provided, prompts via
        Select-FromList (Out-GridView / fzf / numbered prompt).
    .PARAMETER Target
        Make target to run. If omitted, prompts.
    .EXAMPLE
        bake test
    .EXAMPLE
        Invoke-Make            # interactive picker
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            if (-not (Test-Path -LiteralPath './Makefile' -PathType Leaf)) { return }
            Get-MakeTargetList |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { $_ }
        })]
        [string]$Target
    )

    if (-not (Test-Path -LiteralPath './Makefile' -PathType Leaf)) {
        Write-Host '⚠️  No Makefile in current directory'
        return
    }
    if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
        Write-Error "'make' not found in PATH. Install via your package manager (e.g. choco install make, or use WSL)."
        return
    }

    if (-not $Target) {
        $targets = Get-MakeTargetList
        if ($targets.Count -eq 0) {
            Write-Host '⚠️  No targets found in Makefile'
            return
        }
        $Target = $targets | Select-FromList -Prompt 'Select make target'
    }

    if (-not $Target) { return }
    & make $Target
}

function Get-MakeTargetList {
    <#
    .SYNOPSIS
        Extract Make target names from the Makefile in the current directory.
    .DESCRIPTION
        Mirrors the awk pipeline in bash `bake`: skips indented (recipe) lines
        and the `.PHONY` declaration, splits multi-target rules, returns
        unique names sorted. Returns an empty array if there's no Makefile.

        Internal helper for Invoke-Make's tab-completer and interactive picker.
    #>
    if (-not (Test-Path -LiteralPath './Makefile' -PathType Leaf)) { return @() }
    $content = Get-Content -LiteralPath './Makefile'
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $content) {
        # Match `<targets>:` at column 0, where target names are
        # alphanumeric/underscore/dash and aren't .PHONY etc.
        if ($line -match '^([A-Za-z0-9][A-Za-z0-9_\-/. ]*?):') {
            $head = $matches[1]
            foreach ($name in $head -split '\s+') {
                if ($name -and $name -notmatch '^\.PHONY$' -and $name -notmatch '^\$\(') {
                    [void]$names.Add($name)
                }
            }
        }
    }
    return @($names | Sort-Object -Unique)
}

# ---- Invoke-NpmScript ------------------------------------------------------

function Invoke-NpmScript {
    <#
    .SYNOPSIS
        Run an npm script — pass a script name or pick interactively.
    .DESCRIPTION
        PowerShell sibling of bash `yak`. Walks up from $PWD to find the
        nearest package.json, extracts the `scripts` keys via
        ConvertFrom-Json, and runs the chosen script with `npm run`. If no
        script is provided, prompts via Select-FromList.
    .PARAMETER Script
        npm script to run. If omitted, prompts.
    .EXAMPLE
        yak test
    .EXAMPLE
        Invoke-NpmScript        # picker
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $pkg = Find-FileUpward -FileName 'package.json'
            if (-not $pkg) { return }
            Get-NpmScriptList -PackagePath $pkg |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { $_ }
        })]
        [string]$Script
    )

    $pkg = Find-FileUpward -FileName 'package.json'
    if (-not $pkg) {
        Write-Host '⚠️  No package.json in current or parent directories'
        return
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Error "'npm' not found in PATH. Install Node.js (e.g. via Volta or fnm)."
        return
    }

    if (-not $Script) {
        $scripts = Get-NpmScriptList -PackagePath $pkg
        if ($scripts.Count -eq 0) {
            Write-Host '⚠️  No scripts defined in package.json'
            return
        }
        $Script = $scripts | Select-FromList -Prompt 'Select npm script'
    }

    if (-not $Script) { return }

    # Run from the directory containing package.json so npm resolves paths
    # correctly (mirrors bash `(cd "$(dirname "$pkg_json")" && npm run ...)`)
    Push-Location -LiteralPath (Split-Path -Parent $pkg)
    try {
        & npm run $Script
    } finally {
        Pop-Location
    }
}

function Get-NpmScriptList {
    <#
    .SYNOPSIS
        Return script names from a package.json's `scripts` object.
    .PARAMETER PackagePath
        Full path to package.json. If omitted, walks up from $PWD.
    #>
    param([string]$PackagePath)
    if (-not $PackagePath) {
        $PackagePath = Find-FileUpward -FileName 'package.json'
    }
    if (-not $PackagePath -or -not (Test-Path -LiteralPath $PackagePath)) { return @() }
    try {
        $json = Get-Content -LiteralPath $PackagePath -Raw | ConvertFrom-Json
        if ($null -ne $json.scripts) {
            return @($json.scripts.PSObject.Properties.Name | Sort-Object -Unique)
        }
    } catch {
        Write-Verbose "Failed to parse $PackagePath as JSON: $_"
    }
    return @()
}

# ---- Invoke-PoetryScript ---------------------------------------------------

function Invoke-PoetryScript {
    <#
    .SYNOPSIS
        Run a Poetry script — pass a script name or pick interactively.
    .DESCRIPTION
        PowerShell sibling of bash `poet`. Walks up from $PWD to find the
        nearest pyproject.toml, parses the `[tool.poetry.scripts]` and
        `[project.scripts]` sections, and runs the chosen script with
        `poetry run`.
    .PARAMETER Script
        Script name to run. If omitted, prompts.
    .EXAMPLE
        poet lint
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $tom = Find-FileUpward -FileName 'pyproject.toml'
            if (-not $tom) { return }
            Get-PoetryScriptList -PyprojectPath $tom |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { $_ }
        })]
        [string]$Script
    )

    $tom = Find-FileUpward -FileName 'pyproject.toml'
    if (-not $tom) {
        Write-Host '⚠️  No pyproject.toml in current or parent directories'
        return
    }
    if (-not (Get-Command poetry -ErrorAction SilentlyContinue)) {
        Write-Error "'poetry' not found in PATH. Install via 'pipx install poetry' or your package manager."
        return
    }

    if (-not $Script) {
        $scripts = Get-PoetryScriptList -PyprojectPath $tom
        if ($scripts.Count -eq 0) {
            Write-Host '⚠️  No scripts defined under [tool.poetry.scripts] or [project.scripts]'
            return
        }
        $Script = $scripts | Select-FromList -Prompt 'Select poetry script'
    }

    if (-not $Script) { return }

    Push-Location -LiteralPath (Split-Path -Parent $tom)
    try {
        & poetry run $Script
    } finally {
        Pop-Location
    }
}

function Get-PoetryScriptList {
    <#
    .SYNOPSIS
        Return script names from pyproject.toml's [tool.poetry.scripts] or
        [project.scripts] section.
    .DESCRIPTION
        PowerShell 7 has no built-in TOML parser. We don't need full TOML
        support — just the two scripts table headers and the `name = ...`
        lines that follow them, until the next `[section]` header. This
        mirrors the bash `sed`/`grep`/`cut` pipeline and avoids a runtime
        dependency on a TOML module.

        Internal helper for Invoke-PoetryScript's tab-completer and picker.
    .PARAMETER PyprojectPath
        Full path to pyproject.toml. If omitted, walks up from $PWD.
    #>
    param([string]$PyprojectPath)
    if (-not $PyprojectPath) {
        $PyprojectPath = Find-FileUpward -FileName 'pyproject.toml'
    }
    if (-not $PyprojectPath -or -not (Test-Path -LiteralPath $PyprojectPath)) { return @() }

    $names = New-Object System.Collections.Generic.List[string]
    $inScripts = $false

    foreach ($line in Get-Content -LiteralPath $PyprojectPath) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(tool\.poetry\.scripts|project\.scripts)\]\s*$') {
            $inScripts = $true
            continue
        }
        if ($trimmed -match '^\[') {
            # Any other table header ends our scripts block.
            $inScripts = $false
            continue
        }
        if (-not $inScripts) { continue }
        # Match `name = <anything>` — stops at `=`. Skip blanks and comments.
        if ($trimmed -and $trimmed -notmatch '^\s*#' -and $trimmed -match '^([A-Za-z0-9_\-]+)\s*=') {
            [void]$names.Add($matches[1])
        }
    }

    return @($names | Sort-Object -Unique)
}

# ---- Set-LocationProject ---------------------------------------------------

function Set-LocationProject {
    <#
    .SYNOPSIS
        Jump to a project directory — pass a path or pick interactively.
    .DESCRIPTION
        PowerShell sibling of bash `proj`. Searches the directories listed
        in $env:PROJ_DIRS (semicolon-separated on Windows, colon-separated
        on POSIX — both are accepted) for sub-directories containing a `.git`
        folder, then `Set-Location`s into the chosen one.

        Default search list:
          $HOME\dev (Windows)
          $HOME/projects, $HOME/work, $HOME/src (POSIX-style)
    .PARAMETER Directory
        Directory to jump to. If omitted, prompts.
    .EXAMPLE
        proj                # picker
    .EXAMPLE
        proj C:\Users\Me\dev\preflight
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Directory
    )

    if (-not $Directory) {
        $Directory = Get-ProjectDirList | Select-FromList -Prompt 'Select project'
    }
    if (-not $Directory) { return }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        Write-Error "Not a directory: $Directory"
        return
    }
    Set-Location -LiteralPath $Directory
    Write-Host "📂 $($PWD.Path)"
}

function Get-ProjectDirList {
    <#
    .SYNOPSIS
        Enumerate git-repo project directories under $env:PROJ_DIRS.
    .DESCRIPTION
        For each colon/semicolon-separated path in $env:PROJ_DIRS, finds
        immediate sub-directories that contain a .git folder. Used by
        Set-LocationProject's interactive picker.
    #>
    $raw = if ($env:PROJ_DIRS) {
        $env:PROJ_DIRS
    } else {
        # Defaults: Windows convention first, POSIX names as fallback.
        @(
            (Join-Path $HOME 'dev')
            (Join-Path $HOME 'projects')
            (Join-Path $HOME 'work')
            (Join-Path $HOME 'src')
        ) -join [System.IO.Path]::PathSeparator
    }

    # Split on the platform's path separator: ';' on Windows, ':' on POSIX.
    # Earlier versions used `[;:]` to be permissive about pasting from bash,
    # but that shreds Windows drive letters (e.g. `C:\foo;D:\bar` would split
    # at the colons after C and D). PowerShell-on-Windows users who want to
    # set PROJ_DIRS by hand should use ';' between entries.
    $paths = $raw -split [regex]::Escape([System.IO.Path]::PathSeparator) |
        Where-Object { $_ }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($base in $paths) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        # Look two levels deep for .git, like bash `find -maxdepth 2`.
        Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                if (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) {
                    [void]$out.Add($_.FullName)
                } else {
                    # One level deeper.
                    Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            if (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) {
                                [void]$out.Add($_.FullName)
                            }
                        }
                }
            }
    }
    return @($out | Sort-Object -Unique)
}

# ---- Start-LocalServer -----------------------------------------------------

function Start-LocalServer {
    <#
    .SYNOPSIS
        Start a quick local HTTP server in the current directory.
    .DESCRIPTION
        PowerShell sibling of bash `serve`. Defaults to `python -m http.server`
        on port 8000; pass -Port to override. Use Ctrl+C to stop.

        Uses `python` (Windows) or `python3` (POSIX) — whichever resolves first.
    .PARAMETER Port
        TCP port to listen on. Defaults to 8000.
    .EXAMPLE
        serve
    .EXAMPLE
        serve 9000
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [int]$Port = 8000
    )

    # Find a usable Python. Order matters:
    #   1. `py` — the Windows Python launcher. When present, it's the
    #      authoritative entry point and knows how to find the active
    #      interpreter regardless of what's on PATH. Skipped on POSIX
    #      because `py` doesn't exist there.
    #   2. `python3` — the POSIX-canonical name.
    #   3. `python` — the Windows-canonical name; also POSIX where Python 3
    #      is the default.
    $candidates = if ($IsWindows) { 'py', 'python', 'python3' } else { 'python3', 'python' }
    $pyCmd = $null
    foreach ($candidate in $candidates) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            $pyCmd = $candidate
            break
        }
    }
    if (-not $pyCmd) {
        Write-Error "No python/python3/py interpreter found in PATH."
        return
    }

    Write-Host "🌐 Serving on http://localhost:$Port  (Ctrl+C to stop)"
    & $pyCmd -m http.server $Port
}

# ---- Aliases ---------------------------------------------------------------
# Match bash muscle memory: bake / yak / poet / proj / serve.

Set-Alias -Name 'bake'  -Value Invoke-Make         -Force -Scope Script
Set-Alias -Name 'yak'   -Value Invoke-NpmScript    -Force -Scope Script
Set-Alias -Name 'poet'  -Value Invoke-PoetryScript -Force -Scope Script
Set-Alias -Name 'proj'  -Value Set-LocationProject -Force -Scope Script
Set-Alias -Name 'serve' -Value Start-LocalServer   -Force -Scope Script
