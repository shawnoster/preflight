# lib/02-envsets.ps1 — which secrets load: named env sets in $env:PREFLIGHT_CONFIG_DIR\envsets\<set>.tsv
#
# Same files, same rules as the bash side (lib/envsets.sh, `_op_env_entries`). Sets are plain text,
# one `VAR<TAB>op://vault/item/field[<TAB>account]` line each. `op-env` (lib/03-op-env.ps1) manages
# them; hand-editing stays fine.
#
# tests/fixtures/envsets/ plus envsets.expected are the shared contract. Both implementations
# must produce that merged output, byte for byte.

$script:OpRefPattern     = '^op://[^/]+/[^/]+/.+'
$script:OpAccountPattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$script:OpVarPattern     = '^[A-Za-z_][A-Za-z0-9_]*$'
$script:OpSetPattern     = '^[a-z0-9][a-z0-9_-]*$'

function Get-PreflightEnvSetName {
    # Active sets, in order. With a .active file, exactly its lines (CRs stripped, blanks skipped);
    # without one, every *.tsv, sorted ordinally (the bash side sorts plain ASCII names).
    [CmdletBinding()]
    param([string]$Dir)

    $active = Join-Path $Dir '.active'
    if (Test-Path -LiteralPath $active -PathType Leaf) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($l in ((Get-Content -LiteralPath $active -Raw) -replace "`r", '' -split "`n")) {
            if ($l.Trim().Length -gt 0) { $names.Add($l) }
        }
        return $names.ToArray()
    }
    $found = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Dir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $Dir -Filter '*.tsv' -File -Force) {
            $found.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
    }
    $arr = $found.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Get-PreflightEnvEntry {
    <#
    .SYNOPSIS
        The merged secret entries from the active env sets, or from just the named sets.
    .DESCRIPTION
        One object per variable: Name, Ref, Account (empty when the set line names none), and Line (the
        line as written, CRs stripped). The first definition of a name wins; a line is skipped unless it
        has at most three TAB-separated fields, a valid variable name, an op://vault/item/field reference
        and, if present, a valid account.

        With -Set, only those sets are read, in the order given and whether or not they are active (the
        plain call reads the active sets in their order). The plain call's output is the contract the
        shared fixture checks, byte for byte.
    #>
    [CmdletBinding()]
    param([string]$Dir, [string[]]$Set)

    if (-not $Dir) {
        if (-not $env:PREFLIGHT_CONFIG_DIR) { return }
        $Dir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $setNames = if ($PSBoundParameters.ContainsKey('Set')) { @($Set) } else { @(Get-PreflightEnvSetName -Dir $Dir) }

    foreach ($setName in $setNames) {
        if ($setName -cnotmatch $script:OpSetPattern) { continue }
        $file = Join-Path $Dir "$setName.tsv"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

        foreach ($line in ((Get-Content -LiteralPath $file -Raw) -replace "`r", '' -split "`n")) {
            $f = $line.Split("`t")
            if ($f.Length -gt 3) { continue }
            if ($f[0] -cnotmatch $script:OpVarPattern) { continue }
            if ($f.Length -lt 2 -or $f[1] -cnotmatch $script:OpRefPattern) { continue }
            $acct = if ($f.Length -eq 3) { $f[2] } else { '' }
            if ($acct -ne '' -and $acct -cnotmatch $script:OpAccountPattern) { continue }
            if (-not $seen.Add($f[0])) { continue }
            [pscustomobject]@{ Name = $f[0]; Ref = $f[1]; Account = $acct; Line = $line }
        }
    }
}

function Test-PreflightEnvSet {
    <#
    .SYNOPSIS
        Check the set names given to `op-env load` / `clear`: each must be a valid name with a file.
    .DESCRIPTION
        Returns $null when every name is fine, otherwise the first problem as a message, before anything
        has been changed or signed in. Mirrors bash's _op_env_check_sets. Names are matched
        case-sensitively, like the loader does.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Set, [string]$Dir)

    if (-not $Dir) {
        if (-not $env:PREFLIGHT_CONFIG_DIR) { return 'No config directory is resolved, so there are no env sets.' }
        $Dir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
    }
    foreach ($s in $Set) {
        if ($s -cnotmatch $script:OpSetPattern) {
            return "Invalid set name '$s' (use lowercase letters, digits, - or _). Nothing was changed."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Dir "$s.tsv") -PathType Leaf)) {
            return "No env set '$s'. See: op-env list. Nothing was changed."
        }
    }
    return $null
}

function Get-PreflightEnvInactiveNote {
    # A note per named set that is not active: naming it is an explicit request, so it loads anyway.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Set, [string]$Dir)

    if (-not $Dir) { $Dir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets' }
    $active = @(Get-PreflightEnvSetName -Dir $Dir)
    foreach ($s in $Set) {
        if ($active -cnotcontains $s) {
            "Set '$s' is not active; loading it anyway. A plain op-env load will unset its variables again (op-env use $s keeps it)."
        }
    }
}

function Get-PreflightEnvSource {
    <#
    .SYNOPSIS
        Which set supplies each variable: Name and Set, for the named sets in the order given (or the
        active sets in their order). The first set with a valid definition wins, decided by
        Get-PreflightEnvEntry itself. This is what lets `op-env clear b` leave alone a variable that
        `a` supplied when both define it.
    #>
    [CmdletBinding()]
    param([string[]]$Set, [string]$Dir)

    if (-not $Dir) {
        if (-not $env:PREFLIGHT_CONFIG_DIR) { return }
        $Dir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
    }
    $names = if ($PSBoundParameters.ContainsKey('Set')) { @($Set) } else { @(Get-PreflightEnvSetName -Dir $Dir) }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($setName in $names) {
        if ($setName -cnotmatch $script:OpSetPattern) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Dir "$setName.tsv") -PathType Leaf)) { continue }
        foreach ($e in @(Get-PreflightEnvEntry -Dir $Dir -Set $setName)) {
            if ($seen.Add($e.Name)) { [pscustomobject]@{ Name = $e.Name; Set = $setName } }
        }
    }
}
