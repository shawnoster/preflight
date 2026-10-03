# Preflight.psm1 — entry point for the Preflight PowerShell module.
#
# Loads configuration, dot-sources every lib/*.ps1 file, and exports the
# public surface declared in Preflight.psd1.
#
# Layout (mirrors the bash side at github.com/shawnoster/preflight):
#   ~/.preflight/pwsh/Preflight.psm1   <- this file
#   ~/.preflight/pwsh/Preflight.psd1   <- manifest (canonical export list)
#   ~/.preflight/pwsh/lib/*.ps1        <- one file per concern (1password, aws, ...)
#   $PREFLIGHT_CONFIG_DIR/config.json  <- your settings (outside the clone; see docs/config.md)
#   $PREFLIGHT_CONFIG_DIR/envsets/     <- your env sets: VAR -> op:// references

Set-StrictMode -Version 3.0

# Module root — used by lib files to find sibling resources.
$script:PreflightRoot = $PSScriptRoot

# ---- Settings and env sets --------------------------------------------------
# Settings come from $env:PREFLIGHT_CONFIG_DIR\config.json and the secret map from
# $env:PREFLIGHT_CONFIG_DIR\envsets\*.tsv (lib/00-paths.ps1, 01-config.ps1, 02-envsets.ps1),
# loaded after the libs below. Nothing here may set a setting's environment variable at
# import time: a value set before the loader runs looks like one you set yourself, and
# config.json could never change it.

# ---- Dot-source every lib file ---------------------------------------------
$libDir = Join-Path $PSScriptRoot 'lib'
if (Test-Path -LiteralPath $libDir) {
    Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File |
        Sort-Object Name |
        ForEach-Object {
            try {
                . $_.FullName
            } catch {
                Write-Warning "Preflight: failed to load $($_.Name): $_"
            }
        }
}

# ---- Load settings ----------------------------------------------------------
# Never fails the import: a bad layout, a missing file or invalid JSON warns and the
# built-in defaults apply (Invoke-Preflight reports it as a failed check).
if (Resolve-PreflightDirs) {
    Import-PreflightConfig
    Write-PreflightLegacyWarning
} else {
    $script:PreflightConfigStatus = 'invalid'
    $script:PreflightConfigError  = 'the config or state directory overlaps the install directory'
}

# Functions and aliases are exported via the manifest's FunctionsToExport /
# AliasesToExport — no Export-ModuleMember calls needed here.
