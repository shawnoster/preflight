# lib/help.ps1 — auto-generated help / command reference for Preflight.
#
# Replaces the previous hand-rolled Write-Host block that was prone to
# drifting from the actual implementation (the tmux finding in PR #14
# was the canary). Both functions introspect the live module via
# Get-Command + Get-Help, so adding a new function to any lib/*.ps1
# automatically updates the help output.
#
# Public surface:
#   Get-PreflightHelp     (op-help, dev-help, devhelp)
#   Get-PreflightCommands (dev-commands)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Get-PreflightHelp is intentionally a colorized status panel, not a pipeline-emitter. Get-PreflightCommands returns objects via the pipeline; consumers who want plain text use it instead.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns', '',
    Justification = 'Get-PreflightCommands returns the full set of exported commands as a stream by design (plural noun reads naturally to consumers piping into Where-Object / Out-GridView).'
)]
param()

# ---- Internal: build the catalog ------------------------------------------

function Get-PreflightCommandCatalog {
    <#
    .SYNOPSIS
        Internal helper: introspect the Preflight module and return a list of
        @{ Name; Aliases; Synopsis; Category } records, one per exported function.
    .DESCRIPTION
        The Category is derived from which lib/*.ps1 file declared the function.
        The mapping is computed by parsing the lib files (PowerShell AST) so
        adding a new lib file or function lights up automatically — no manual
        category table to keep in sync.

        Returns nothing if the Preflight module isn't loaded.
    #>
    [CmdletBinding()]
    param()

    $module = Get-Module Preflight -ErrorAction SilentlyContinue
    if (-not $module) { return @() }

    # Build a (function-name -> lib-file-stem) map by parsing each lib file's AST.
    # PSScriptAnalyzer's AST tools are available in PS 7+; using
    # System.Management.Automation.Language directly avoids any dependency.
    $libDir = Join-Path $module.ModuleBase 'lib'
    $declaredIn = @{}
    if (Test-Path -LiteralPath $libDir) {
        foreach ($file in Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$errors
            )
            if ($errors -and $errors.Count -gt 0) { continue }

            $functions = $ast.FindAll(
                { param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                },
                $true
            )
            foreach ($fn in $functions) {
                if (-not $declaredIn.ContainsKey($fn.Name)) {
                    $declaredIn[$fn.Name] = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                }
            }
        }
    }

    # Pretty category names per lib filename. Anything not listed gets a
    # title-cased version of the filename (so `lib/docker.ps1` → "Docker"
    # appears automatically when that file lands).
    $categoryNames = @{
        '00-helpers' = 'Internal'
        '1password'  = '1Password'
        'aws'        = 'AWS'
        'git'        = 'Git'
        'help'       = 'Help'
        'preflight'  = 'Session'
        'project'    = 'Project'
    }

    # Sort key per category so the panel reads top-down sensibly. Anything
    # else falls to the end alphabetically.
    $categoryOrder = @{
        'Session'   = 1
        '1Password' = 2
        'AWS'       = 3
        'Project'   = 4
        'Git'       = 5
        'Help'      = 99   # always last
    }

    # For each exported function, look up:
    #   - synopsis from comment-based help
    #   - aliases that resolve to the function
    #   - category from the parsed AST map
    $allAliases = Get-Command -Module Preflight -CommandType Alias -ErrorAction SilentlyContinue
    $aliasesByTarget = @{}
    foreach ($a in $allAliases) {
        $target = $a.Definition
        if (-not $aliasesByTarget.ContainsKey($target)) {
            $aliasesByTarget[$target] = New-Object System.Collections.Generic.List[string]
        }
        [void]$aliasesByTarget[$target].Add($a.Name)
    }

    $catalog = New-Object System.Collections.Generic.List[object]
    foreach ($fn in $module.ExportedFunctions.Values | Sort-Object Name) {
        # Get-Help against the live function; .Synopsis is the trimmed first
        # paragraph of the .SYNOPSIS comment-based-help block.
        $synopsis = ''
        try {
            $h = Get-Help -Name $fn.Name -ErrorAction SilentlyContinue
            if ($h -and $h.Synopsis) {
                $synopsis = "$($h.Synopsis)".Trim()
                # Get-Help returns various flavors of "no real help":
                #   - empty / whitespace
                #   - the parameterized auto-help signature ("Foo [-Bar]")
                #   - just the bare function name (PowerShell's "synthetic"
                #     synopsis when comment-based help is absent — common for
                #     one-line wrapper functions).
                # Treat all three as "no synopsis available".
                if ($synopsis -match '^\s*$' -or
                    $synopsis -match ('^' + [regex]::Escape($fn.Name) + '\s*\[') -or
                    $synopsis -ceq $fn.Name) {
                    $synopsis = ''
                }
            }
        } catch {
            # Get-Help can fail on dynamic / proxy functions; safe to skip,
            # the row just shows an empty synopsis. Verbose for debugging.
            Write-Verbose "Get-PreflightCommandCatalog: Get-Help failed for $($fn.Name): $_"
        }

        # If the function has no useful synopsis but its body is a one-line
        # external-command wrapper (e.g. `gs { & git status @args }`), build
        # a synopsis from the command-line that's actually invoked. This
        # keeps the manifest-driven listing useful for the bash-style git
        # aliases without forcing a docstring on each.
        if (-not $synopsis -and $fn.Definition) {
            $body = "$($fn.Definition)".Trim()
            # Strip wrapping braces/whitespace and look for a bare invocation
            # like `& git status @args` — capture everything between the
            # ampersand and the @args/$args sentinel.
            if ($body -match '^\s*&\s+(\S+(?:\s+[^&|;\r\n]*?)?)\s+@args\s*$') {
                $synopsis = "Wrapper for ``$($matches[1].Trim())``."
            }
        }

        $libStem = $declaredIn[$fn.Name]
        $category = if ($libStem -and $categoryNames.ContainsKey($libStem)) {
            $categoryNames[$libStem]
        } elseif ($libStem) {
            # Title-case the stem for files we don't have an explicit name for.
            (Get-Culture).TextInfo.ToTitleCase($libStem)
        } else {
            'Other'
        }
        $order = if ($categoryOrder.ContainsKey($category)) {
            $categoryOrder[$category]
        } else {
            50  # between known and Help
        }

        $aliases = if ($aliasesByTarget.ContainsKey($fn.Name)) {
            @($aliasesByTarget[$fn.Name]) | Sort-Object
        } else {
            @()
        }

        [void]$catalog.Add([PSCustomObject]@{
            Name        = $fn.Name
            Aliases     = $aliases
            Synopsis    = $synopsis
            Category    = $category
            CategoryOrder = $order
        })
    }

    return $catalog
}

# ---- Get-PreflightHelp -----------------------------------------------------

function Get-PreflightHelp {
    <#
    .SYNOPSIS
        Show a categorized quick reference for all Preflight commands.
    .DESCRIPTION
        Prints the public surface of the Preflight module grouped by area
        (Session, 1Password, AWS, Project, Git, …). Synopsis lines come
        from each function's comment-based help, and aliases are resolved
        against the live module — there's no hand-maintained category
        table to drift out of sync.

        For full per-command help, use:
            Get-Help <function-name> -Examples
            Get-Help <function-name> -Full

        For a flat searchable list (good for piping), use Get-PreflightCommands.
    .EXAMPLE
        Get-PreflightHelp
    .EXAMPLE
        dev-help
    #>
    [CmdletBinding()]
    param()

    $catalog = Get-PreflightCommandCatalog
    if (-not $catalog -or $catalog.Count -eq 0) {
        Write-Warning 'Preflight module not loaded.'
        return
    }

    Write-Host ''
    Write-Host 'Preflight (PowerShell) — quick reference' -ForegroundColor Cyan
    Write-Host "Use 'Get-Help <name> -Examples' for full per-command docs." -ForegroundColor DarkGray
    Write-Host '(or Get-PreflightCommands for a flat searchable list)' -ForegroundColor DarkGray
    Write-Host ''

    # Compute column widths so the table lines up regardless of which
    # functions/aliases happen to be loaded. Compute the lengths first then
    # measure — passing a script block as `-Property` happens to work in
    # PowerShell 7+ but is undocumented and surprises readers; explicit
    # compute-then-measure is unambiguous.
    $nameLengths = $catalog | ForEach-Object { $_.Name.Length }
    $aliasLengths = $catalog | ForEach-Object {
        if (@($_.Aliases).Count -gt 0) {
            ("({0})" -f ($_.Aliases -join ', ')).Length
        } else {
            0
        }
    }
    $longestName  = ($nameLengths  | Measure-Object -Maximum).Maximum
    $longestAlias = ($aliasLengths | Measure-Object -Maximum).Maximum

    $groups = $catalog |
        Group-Object Category |
        Sort-Object { ($_.Group | Select-Object -First 1).CategoryOrder }, Name

    foreach ($group in $groups) {
        Write-Host $group.Name -ForegroundColor Yellow
        foreach ($cmd in $group.Group | Sort-Object Name) {
            $aliasStr = if (@($cmd.Aliases).Count -gt 0) {
                "({0})" -f ($cmd.Aliases -join ', ')
            } else {
                ''
            }
            # Synopses can span multiple lines (PowerShell .SYNOPSIS allows
            # multi-paragraph blocks). For the panel view, collapse to a
            # single line and truncate to keep alignment readable. Use
            # Get-PreflightCommands for the full text.
            $rawSyn = if ($cmd.Synopsis) { $cmd.Synopsis } else { '(no synopsis)' }
            $oneLine = ($rawSyn -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) -join ' '
            $maxSynLen = 90
            if ($oneLine.Length -gt $maxSynLen) {
                $oneLine = $oneLine.Substring(0, $maxSynLen - 1).TrimEnd() + '…'
            }
            $line = "  {0,-$longestName}  {1,-$longestAlias}  — {2}" -f
                $cmd.Name, $aliasStr, $oneLine
            Write-Host $line
        }
        Write-Host ''
    }

    $module = Get-Module Preflight
    Write-Host "Default 1Password account: $(Get-OpAccount)" -ForegroundColor DarkGray
    Write-Host ("Module version: {0}" -f $module.Version) -ForegroundColor DarkGray
    Write-Host 'Override defaults via $env:OP_ACCOUNT or pwsh\config\accounts.ps1.' -ForegroundColor DarkGray
    Write-Host ''
}

# ---- Get-PreflightCommands -------------------------------------------------

function Get-PreflightCommands {
    <#
    .SYNOPSIS
        Return a flat object stream of all Preflight commands — pipeline-friendly.
    .DESCRIPTION
        PowerShell sibling of bash `dev-commands`. Emits one [PSCustomObject]
        per exported function with Name, Aliases, Synopsis, and Category
        properties so callers can pipe into Where-Object, Out-GridView, etc.

        Use Get-PreflightHelp instead when you want a colorized summary
        printed to the host.
    .EXAMPLE
        Get-PreflightCommands

        # Default formatted table.
    .EXAMPLE
        Get-PreflightCommands | Where-Object Synopsis -match 'aws'

        # Find any command whose synopsis mentions AWS.
    .EXAMPLE
        Get-PreflightCommands | Where-Object { 'gco' -in $_.Aliases }

        # Find the command behind a kebab alias. Aliases is a string[]
        # so -in / -contains work without splitting a joined string.
    .EXAMPLE
        Get-PreflightCommands | Out-GridView -Title 'Preflight commands'

        # Searchable GUI grid (Windows only).
    .EXAMPLE
        Get-PreflightCommands | Group-Object Category | Format-Table Count, Name

        # Tally how many functions live in each category.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $catalog = Get-PreflightCommandCatalog
    foreach ($cmd in $catalog | Sort-Object CategoryOrder, Category, Name) {
        # Re-emit a clean projection — drop the internal CategoryOrder field
        # so users don't see implementation detail. Aliases stays as a
        # string[] so callers can do `Where-Object { $_.Aliases -contains 'gco' }`
        # without parsing a comma-joined string.
        [PSCustomObject]@{
            Name     = $cmd.Name
            Aliases  = [string[]]@($cmd.Aliases)
            Synopsis = $cmd.Synopsis
            Category = $cmd.Category
        }
    }
}

# ---- Aliases ---------------------------------------------------------------
# The op-help alias was historically attached to Get-PreflightHelp from
# lib/1password.ps1; keep it here now that the function lives in this file.

Set-Alias -Name 'op-help'       -Value Get-PreflightHelp     -Force -Scope Script
Set-Alias -Name 'dev-help'      -Value Get-PreflightHelp     -Force -Scope Script
Set-Alias -Name 'devhelp'       -Value Get-PreflightHelp     -Force -Scope Script
Set-Alias -Name 'dev-commands'  -Value Get-PreflightCommands -Force -Scope Script
