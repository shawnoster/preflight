# Preflight.psm1 — entry point for the Preflight PowerShell module.
#
# Loads configuration, dot-sources every lib/*.ps1 file, and exports the
# public surface declared in Preflight.psd1.
#
# Layout (mirrors the bash side at github.com/shawnoster/preflight):
#   ~/.preflight/pwsh/Preflight.psm1   <- this file
#   ~/.preflight/pwsh/Preflight.psd1   <- manifest (canonical export list)
#   ~/.preflight/pwsh/lib/*.ps1        <- one file per concern (1password, aws, ...)
#   ~/.preflight/pwsh/config/*.ps1     <- gitignored user config (accounts.ps1)

Set-StrictMode -Version 3.0

# Module root — used by lib files to find sibling resources.
$script:PreflightRoot = $PSScriptRoot

# ---- Default configuration --------------------------------------------------
# Anything user-tunable lives in config/accounts.ps1 (gitignored, copied
# from accounts.ps1.template by install.ps1). Defaults here are safe to ship.

if (-not $env:OP_ACCOUNT) {
    # Default 1Password account shorthand. Override in config/accounts.ps1.
    # Set this to your sign-in address (e.g. "my.1password.com") or shorthand.
    $env:OP_ACCOUNT = 'change-me'
}

# ---- Load user config (if present) ------------------------------------------
# accounts.ps1 defines $script:OpEnvMap (the op:// secret map). Initialize
# it to an empty map first so lib files can reference it safely even when
# accounts.ps1 is absent.
$script:OpEnvMap = [ordered]@{}
$configFile = Join-Path $PSScriptRoot 'config/accounts.ps1'
if (Test-Path -LiteralPath $configFile) {
    . $configFile
}

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

# Functions and aliases are exported via the manifest's FunctionsToExport /
# AliasesToExport — no Export-ModuleMember calls needed here.
