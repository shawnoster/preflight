# lib/00-paths.ps1 — where Preflight keeps the user's own data.
#
# ~\.preflight is a disposable clone: code and defaults. Everything the user owns lives
# outside it, so Update-Preflight and an uninstall cannot touch it. Same layout and the
# same resolution order as the bash side (lib/paths.sh):
#
#   PREFLIGHT_CONFIG_DIR   config.json, envsets\      $env override, then $env:XDG_CONFIG_HOME\preflight,
#                                                     then ~\.config\preflight
#   PREFLIGHT_STATE_DIR    owl\ (theme state, patched OMP)   likewise with XDG_STATE_HOME and
#                                                     ~\.local\state\preflight
#
# "Same layout" is not "one shared file": Windows PowerShell reads the Windows home, and a
# WSL bash reads the WSL home. Both read the same *format*.

function Test-PreflightPathInside {
    <#
    .SYNOPSIS
        $true when $Path is $Root itself or lies inside it (lexical comparison).
    .DESCRIPTION
        Case-insensitive on Windows, case-sensitive elsewhere. Symlinks are not resolved here,
        unlike the bash guard: a link that points into the install root is not detected.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$Root)

    $sep  = [System.IO.Path]::DirectorySeparatorChar
    $alt  = [System.IO.Path]::AltDirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd($sep, $alt)
    $base = [System.IO.Path]::GetFullPath($Root).TrimEnd($sep, $alt)
    $cmp  = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($full.Equals($base, $cmp)) { return $true }
    return $full.StartsWith($base + $sep, $cmp)
}

function Get-PreflightDir {
    <#
    .SYNOPSIS
        The resolved config and state directories as an object (ConfigDir, StateDir), or $null.
    .DESCRIPTION
        Pure: sets nothing. Returns $null (with a warning) when either directory is the install
        root or inside it: code and user data must not share a directory.
    .PARAMETER InstallRoot
        The directory the module is installed under (the parent of pwsh\). Defaults to the
        parent of the running module.
    #>
    [CmdletBinding()]
    param([string]$InstallRoot)

    if (-not $InstallRoot) { $InstallRoot = Split-Path -Parent $script:PreflightRoot }

    $cfg = if ($env:PREFLIGHT_CONFIG_DIR) { $env:PREFLIGHT_CONFIG_DIR }
           elseif ($env:XDG_CONFIG_HOME)  { Join-Path $env:XDG_CONFIG_HOME 'preflight' }
           else { Join-Path (Join-Path $HOME '.config') 'preflight' }
    $state = if ($env:PREFLIGHT_STATE_DIR) { $env:PREFLIGHT_STATE_DIR }
             elseif ($env:XDG_STATE_HOME)  { Join-Path $env:XDG_STATE_HOME 'preflight' }
             else { Join-Path (Join-Path (Join-Path $HOME '.local') 'state') 'preflight' }

    $trim = @([char]'\', [char]'/')
    if ($cfg.Length   -gt 1) { $cfg   = $cfg.TrimEnd($trim) }
    if ($state.Length -gt 1) { $state = $state.TrimEnd($trim) }

    if ((Test-PreflightPathInside -Path $cfg -Root $InstallRoot) -or
        (Test-PreflightPathInside -Path $state -Root $InstallRoot)) {
        Write-Warning ("Preflight: the config or state directory is the install directory ($InstallRoot) or inside it. " +
            "Set PREFLIGHT_CONFIG_DIR / PREFLIGHT_STATE_DIR to somewhere outside it.")
        return $null
    }
    return [pscustomobject]@{ ConfigDir = $cfg; StateDir = $state }
}

function Resolve-PreflightDirs {
    <#
    .SYNOPSIS
        Resolve PREFLIGHT_CONFIG_DIR and PREFLIGHT_STATE_DIR into $env: and return $true, or return
        $false (setting nothing) when the layout is refused.
    #>
    [CmdletBinding()]
    param([string]$InstallRoot)

    $dirs = Get-PreflightDir -InstallRoot $InstallRoot
    if (-not $dirs) { return $false }
    $env:PREFLIGHT_CONFIG_DIR = $dirs.ConfigDir
    $env:PREFLIGHT_STATE_DIR  = $dirs.StateDir
    return $true
}
