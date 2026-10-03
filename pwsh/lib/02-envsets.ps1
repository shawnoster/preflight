# lib/02-envsets.ps1 — which secrets load: named env sets in $env:PREFLIGHT_CONFIG_DIR\envsets\<set>.tsv
#
# Same files, same rules as the bash side (lib/envsets.sh, `_op_env_entries`). There is no
# `op-env` command here: sets are plain text, one `VAR<TAB>op://vault/item/field[<TAB>account]` line
# each, edited by hand (or with `op-env` from WSL against the same format).
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
        The merged secret entries from the active env sets.
    .DESCRIPTION
        One object per variable: Name, Ref, Account (empty when the set line names none), and Line (the
        line as written, CRs stripped). The first definition of a name wins; a line is skipped unless it
        has at most three TAB-separated fields, a valid variable name, an op://vault/item/field reference
        and, if present, a valid account.
    #>
    [CmdletBinding()]
    param([string]$Dir)

    if (-not $Dir) {
        if (-not $env:PREFLIGHT_CONFIG_DIR) { return }
        $Dir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($set in (Get-PreflightEnvSetName -Dir $Dir)) {
        if ($set -cnotmatch $script:OpSetPattern) { continue }
        $file = Join-Path $Dir "$set.tsv"
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
