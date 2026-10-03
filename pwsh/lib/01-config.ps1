# lib/01-config.ps1 — settings live in $env:PREFLIGHT_CONFIG_DIR\config.json
#
# Same file format, key table and rules as the bash loader (lib/config.sh):
#   * your environment wins: a variable already set is not overwritten, except one this loader
#     set itself (tracked in $global:PreflightConfigManaged, so a re-import follows the file);
#   * a missing key, or a wrong-typed one, takes that key's built-in default alone;
#   * a bad file never fails the import: it warns, uses the defaults, and Invoke-Preflight
#     reports it as a failed check.
#
# Rows marked '-' in the table (the bash-only _CHECK_* flags) are shell variables there. This
# side has no such thing as an unexported variable, so it does not set them at all rather than
# leak them into every child process.
#
# tests/config.sh checks this table against lib/config.sh's, row by row.

# key|variable|type|export|built-in default   (type: s string, p path, b boolean, pl path list)
$script:PreflightConfigTable = @'
op.account|OP_ACCOUNT|s|x|my.1password.com
projects.dirs|PROJ_DIRS|pl|x|~/projects:~/work:~/src
aws.default_profile|AWS_PROFILE_DEFAULT|s|x|
git.main_branch|GIT_MAIN_BRANCH|s|x|main
gitea.username|GITEA_USERNAME|s|x|
gitea.host|GITEA_HOST|s|x|
checks.aws|_CHECK_AWS|b|-|1
checks.gh|_CHECK_GH|b|-|1
checks.ssh|_CHECK_SSH|b|-|1
checks.git_config|_CHECK_GIT_CONFIG|b|-|1
owl.omp_config|OWL_OMP_CONFIG|p|x|$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json
'@

# ok | missing | invalid, with the reason in PreflightConfigError. Invoke-Preflight reports it.
$script:PreflightConfigStatus = 'ok'
$script:PreflightConfigError  = ''

function Get-PreflightConfigRow {
    # The table as objects: Key, Var, Type, Export, Default.
    foreach ($line in ($script:PreflightConfigTable -split "`r?`n")) {
        if (-not $line) { continue }
        $f = $line.Split('|')
        [pscustomobject]@{ Key = $f[0]; Var = $f[1]; Type = $f[2]; Export = $f[3]; Default = $f[4] }
    }
}

function Get-PreflightConfigPath {
    if (-not $env:PREFLIGHT_CONFIG_DIR) { return $null }
    return (Join-Path $env:PREFLIGHT_CONFIG_DIR 'config.json')
}

function ConvertTo-PreflightPath {
    # A leading ~/ or $HOME/ becomes $HOME, and a leading $PREFLIGHT_STATE_DIR/ or
    # $PREFLIGHT_CONFIG_DIR/ the resolved directory. Nothing else is expanded.
    param([string]$Value)

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $map = @(
        @{ Prefix = '~/';                      Root = $HOME }
        @{ Prefix = '$HOME/';                  Root = $HOME }
        @{ Prefix = '$PREFLIGHT_STATE_DIR/';   Root = $env:PREFLIGHT_STATE_DIR }
        @{ Prefix = '$PREFLIGHT_CONFIG_DIR/';  Root = $env:PREFLIGHT_CONFIG_DIR }
    )
    foreach ($m in $map) {
        if ($Value.StartsWith($m.Prefix, [System.StringComparison]::Ordinal)) {
            $rest = $Value.Substring($m.Prefix.Length).Replace('/', [string]$sep)
            return ([string]$m.Root).TrimEnd('\', '/') + $sep + $rest
        }
    }
    return $Value
}

function ConvertTo-PreflightPathList {
    # Entries joined with the platform's path separator (';' on Windows, ':' elsewhere), which is
    # what project.ps1 splits on. $Entries must already be known to be strings.
    param([System.Collections.IEnumerable]$Entries)

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Entries) { if ($e.Length -gt 0) { $out.Add((ConvertTo-PreflightPath $e)) } }
    return ($out -join [System.IO.Path]::PathSeparator)
}

function Get-PreflightConfigDefault {
    param($Row)
    switch ($Row.Type) {
        'pl' { return (ConvertTo-PreflightPathList ($Row.Default.Split(':'))) }
        'p'  { return (ConvertTo-PreflightPath $Row.Default) }
        default { return $Row.Default }
    }
}

function Get-PreflightConfigValue {
    # The value for one row from the parsed file, as the string to put in the environment. A key
    # that is absent, or has the wrong type, gets its default. Type tests run on the raw value:
    # an empty or one-element array loses its shape once it goes through a pipeline.
    param($Config, $Row)

    $cur = $Config
    $present = $true
    foreach ($seg in $Row.Key.Split('.')) {
        if ($cur -is [System.Collections.IDictionary] -and $cur.Contains($seg)) {
            $cur = $cur[$seg]
        } else {
            $present = $false
            break
        }
    }
    if (-not $present -or $null -eq $cur) { return (Get-PreflightConfigDefault $Row) }

    switch ($Row.Type) {
        's' { if ($cur -is [string]) { return $cur } }
        'p' { if ($cur -is [string]) { return (ConvertTo-PreflightPath $cur) } }
        'b' { if ($cur -is [bool])   { return $(if ($cur) { '1' } else { '0' }) } }
        'pl' {
            if ($cur -is [System.Collections.IList] -and $cur -isnot [string]) {
                $allStrings = $true
                foreach ($e in $cur) { if ($e -isnot [string]) { $allStrings = $false } }
                if ($allStrings) { return (ConvertTo-PreflightPathList $cur) }
            }
        }
    }
    return (Get-PreflightConfigDefault $Row)
}

function Set-PreflightConfigVariable {
    # The only place a setting becomes an environment variable. $global: so the managed list
    # outlives `Import-Module -Force`; child processes do not inherit it, like bash's unexported list.
    param([string]$Name, [AllowEmptyString()][string]$Value)

    if (-not (Test-Path -LiteralPath 'variable:global:PreflightConfigManaged')) {
        $global:PreflightConfigManaged = [System.Collections.Generic.HashSet[string]]::new()
    }
    if (-not $global:PreflightConfigManaged.Contains($Name)) {
        if (Test-Path -LiteralPath "Env:$Name") { return }   # set by you: it wins
        [void]$global:PreflightConfigManaged.Add($Name)
    }
    # An environment variable cannot hold an empty string: setting one removes it.
    if ($Value) { Set-Item -LiteralPath "Env:$Name" -Value $Value }
    elseif (Test-Path -LiteralPath "Env:$Name") { Remove-Item -LiteralPath "Env:$Name" }
}

function Import-PreflightConfig {
    <#
    .SYNOPSIS
        Read config.json into environment variables.
    .DESCRIPTION
        Never throws: a missing file, invalid JSON or anything unexpected warns (where it matters),
        falls back to the built-in defaults, and is recorded for Invoke-Preflight.
    #>
    [CmdletBinding()]
    param()

    $script:PreflightConfigStatus = 'ok'
    $script:PreflightConfigError  = ''
    $config = $null
    try {
        $file = Get-PreflightConfigPath
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $script:PreflightConfigStatus = 'missing'
            $script:PreflightConfigError  = "$file does not exist"
        } else {
            try {
                $config = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($config -isnot [System.Collections.IDictionary]) { throw 'the top level must be a JSON object' }
            } catch {
                $config = $null
                $script:PreflightConfigStatus = 'invalid'
                $script:PreflightConfigError  = "${file}: $($_.Exception.Message)"
                Write-Warning "Preflight: could not read $file (built-in defaults in use): $($_.Exception.Message)"
            }
        }

        foreach ($row in (Get-PreflightConfigRow)) {
            if ($row.Export -ne 'x') { continue }
            Set-PreflightConfigVariable -Name $row.Var -Value (Get-PreflightConfigValue -Config $config -Row $row)
        }
    } catch {
        $script:PreflightConfigStatus = 'invalid'
        $script:PreflightConfigError  = "unexpected error loading settings: $($_.Exception.Message)"
        Write-Warning "Preflight: $script:PreflightConfigError"
    }
}

function Test-PreflightConfig {
    <#
    .SYNOPSIS
        Report problems with config.json: invalid JSON, unknown keys, wrongly typed values.
    .DESCRIPTION
        Returns one string per problem, nothing when the file is fine. Mirrors `preflight config check`.
    #>
    [CmdletBinding()]
    param()

    $file = Get-PreflightConfigPath
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return "$file does not exist" }
    try {
        $config = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($config -isnot [System.Collections.IDictionary]) { throw 'the top level must be a JSON object' }
    } catch {
        return "invalid JSON: $($_.Exception.Message)"
    }

    $rows  = @(Get-PreflightConfigRow)
    $known = [System.Collections.Generic.HashSet[string]]::new([string[]]($rows | ForEach-Object { $_.Key }))
    $group = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $rows) {
        $parts = $r.Key.Split('.')
        for ($i = 1; $i -lt $parts.Length; $i++) { [void]$group.Add(($parts[0..($i - 1)] -join '.')) }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    # Leaves are scalars, lists and empty objects. A key above the table is walked into; a known
    # key's value is a leaf. An empty group ("op": {}) or a group holding a non-object is not
    # reported, which is what the bash check does.
    $walk = $null
    $walk = {
        param($Node, [string]$Prefix)
        foreach ($k in @($Node.Keys)) {
            $path = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
            if ($path -eq 'version' -or $path -eq '$schema') { continue }
            $v = $Node[$k]
            if ($known.Contains($path)) { continue }
            if ($v -is [System.Collections.IDictionary] -and $v.Count -gt 0) { & $walk $v $path; continue }
            if ($group.Contains($path)) { continue }
            $problems.Add("unknown key: $path")
        }
    }
    & $walk $config ''

    foreach ($row in $rows) {
        $cur = $config; $present = $true
        foreach ($seg in $row.Key.Split('.')) {
            if ($cur -is [System.Collections.IDictionary] -and $cur.Contains($seg)) { $cur = $cur[$seg] } else { $present = $false; break }
        }
        if (-not $present -or $null -eq $cur) { continue }
        $bad = switch ($row.Type) {
            { $_ -in 's', 'p' } { $cur -isnot [string] }
            'b'  { $cur -isnot [bool] }
            'pl' {
                if ($cur -isnot [System.Collections.IList] -or $cur -is [string]) { $true }
                else { $nonString = $false; foreach ($e in $cur) { if ($e -isnot [string]) { $nonString = $true } }; $nonString }
            }
        }
        if ($bad) { $problems.Add("wrong type for $($row.Key)") }
    }
    return $problems.ToArray()
}

function Write-PreflightLegacyWarning {
    # An install updated in place still has accounts.ps1 (and owl state) inside the clone, where
    # nothing reads them any more. Say so rather than silently starting from built-in defaults.
    [CmdletBinding()]
    param()

    $legacy = Join-Path (Join-Path $script:PreflightRoot 'config') 'accounts.ps1'
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        Write-Warning ("Preflight: $legacy is no longer read. Settings now live in $(Get-PreflightConfigPath) " +
            "and the secret map in $(Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets') (VAR<TAB>op://ref lines, one file per set). " +
            "See pwsh\README.md, then delete the old file.")
    }
    $oldState = Join-Path (Join-Path (Split-Path -Parent $script:PreflightRoot) 'state') 'owl'
    if ((Test-Path -LiteralPath $oldState -PathType Container) -and
        -not (Test-Path -LiteralPath (Join-Path $env:PREFLIGHT_STATE_DIR 'owl') -PathType Container)) {
        Write-Warning "Preflight: owl theme state moved out of the clone. Move $oldState to $(Join-Path $env:PREFLIGHT_STATE_DIR 'owl')."
    }
}
