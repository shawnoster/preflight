# tests/config-dump.ps1 - print the settings the PowerShell loader produces, as NAME=VALUE lines,
# for tests/config.sh to compare with what the bash loader produces from the same config.json.
# Reads $env:PREFLIGHT_CONFIG_DIR / PREFLIGHT_STATE_DIR; writes nothing.

param([string]$Repo = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version 3.0
$script:PreflightRoot = Join-Path $Repo 'pwsh'
. (Join-Path $Repo 'pwsh/lib/00-paths.ps1')
. (Join-Path $Repo 'pwsh/lib/01-config.ps1')

Import-PreflightConfig -WarningAction SilentlyContinue
foreach ($row in (Get-PreflightConfigRow)) {
    if ($row.Export -ne 'x') { continue }
    $v = if (Test-Path -LiteralPath "Env:$($row.Var)") { (Get-Item -LiteralPath "Env:$($row.Var)").Value } else { '' }
    "$($row.Var)=$v"
}
