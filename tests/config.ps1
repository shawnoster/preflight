# tests/config.ps1 - the PowerShell side of config.json, env sets and the installer.
#
# Run by tests/config.sh when pwsh is installed (HOME is redirected to a scratch dir there), or
# by hand:  HOME=$(mktemp -d) pwsh -NoProfile -File tests/config.ps1
#
# A plain script like the bash suites, not Pester. Touches nothing outside a temp dir.
# Not covered (no Windows here): the ';' PATH separator, drive letters, a real $PROFILE, op.exe.

param([string]$Repo = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:passes = 0
$script:fails  = 0
function chk([string]$Name, [scriptblock]$Test) {
    $ok = $false
    try { $ok = [bool](& $Test) } catch { Write-Host "  error: $($_.Exception.Message)" }
    if ($ok) { $script:passes++ } else { $script:fails++; Write-Host "FAIL: $Name" }
}

$T = Join-Path ([System.IO.Path]::GetTempPath()) "pf-pwsh-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $T | Out-Null
try {
    # The whole suite must run inside the redirected HOME, or it would read a real config.
    if (-not $HOME.StartsWith([System.IO.Path]::GetTempPath().TrimEnd('/', '\'))) {
        throw "HOME ($HOME) is not under the temp directory: run through tests/config.sh or set HOME first."
    }

    $managedVars = 'OP_ACCOUNT', 'PROJ_DIRS', 'AWS_PROFILE_DEFAULT', 'GIT_MAIN_BRANCH', 'GITEA_USERNAME', 'GITEA_HOST', 'OWL_OMP_CONFIG'
    function Reset-Env {
        foreach ($v in $managedVars + 'PREFLIGHT_CONFIG_DIR', 'PREFLIGHT_STATE_DIR', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME') {
            Remove-Item -LiteralPath "Env:$v" -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name PreflightConfigManaged -Scope Global -ErrorAction SilentlyContinue
        $env:PREFLIGHT_CONFIG_DIR = Join-Path $T 'cfg'
        $env:PREFLIGHT_STATE_DIR  = Join-Path $T 'state'
    }
    function Get-Var([string]$n) { if (Test-Path -LiteralPath "Env:$n") { (Get-Item -LiteralPath "Env:$n").Value } else { $null } }

    $script:PreflightRoot = Join-Path $Repo 'pwsh'
    $loadLibs = {
        . (Join-Path $Repo 'pwsh/lib/00-paths.ps1')
        . (Join-Path $Repo 'pwsh/lib/01-config.ps1')
        . (Join-Path $Repo 'pwsh/lib/02-envsets.ps1')
    }
    . $loadLibs

    Reset-Env
    New-Item -ItemType Directory -Path $env:PREFLIGHT_CONFIG_DIR -Force | Out-Null
    $cfgFile = Join-Path (Join-Path $T 'cfg') 'config.json'
    function Put([string]$json) { Set-Content -LiteralPath $cfgFile -Value $json -NoNewline }
    $sep = [System.IO.Path]::PathSeparator

    # ---- the table matches the bash table, row by row ----------------------
    $bashSrc  = Get-Content -LiteralPath (Join-Path $Repo 'lib/config.sh') -Raw
    $bashRows = ([regex]::Match($bashSrc, "(?s)_PF_CONFIG_TABLE='(.*?)'")).Groups[1].Value -split "`r?`n" | Where-Object { $_ }
    $psRows   = $script:PreflightConfigTable -split "`r?`n" | Where-Object { $_ }
    chk 'table: same number of rows as bash' { $bashRows.Count -gt 0 -and $bashRows.Count -eq $psRows.Count }
    chk 'table: every row identical to bash' { -not (Compare-Object $bashRows $psRows) }

    # ---- directories --------------------------------------------------------
    Reset-Env; Remove-Item Env:PREFLIGHT_CONFIG_DIR, Env:PREFLIGHT_STATE_DIR
    $inst = Join-Path $T 'install'
    $d = Get-PreflightDir -InstallRoot $inst
    chk 'dirs: default config dir'  { $d.ConfigDir -eq (Join-Path (Join-Path $HOME '.config') 'preflight') }
    chk 'dirs: default state dir'   { $d.StateDir -eq (Join-Path (Join-Path (Join-Path $HOME '.local') 'state') 'preflight') }
    $env:XDG_CONFIG_HOME = Join-Path $T 'xc'; $env:XDG_STATE_HOME = Join-Path $T 'xs'
    $d = Get-PreflightDir -InstallRoot $inst
    chk 'dirs: XDG_CONFIG_HOME / XDG_STATE_HOME are used' { $d.ConfigDir -eq (Join-Path $env:XDG_CONFIG_HOME 'preflight') -and $d.StateDir -eq (Join-Path $env:XDG_STATE_HOME 'preflight') }
    $env:PREFLIGHT_CONFIG_DIR = (Join-Path $T 'oc') + '/'
    $d = Get-PreflightDir -InstallRoot $inst
    chk 'dirs: override beats XDG, trailing slash dropped' { $d.ConfigDir -eq (Join-Path $T 'oc') }
    foreach ($bad in @($inst, "$inst/", "$inst/.", "$inst/sub/..", "$inst/config", "$inst/not/yet/created")) {
        Reset-Env; $env:PREFLIGHT_CONFIG_DIR = $bad
        $r = Get-PreflightDir -InstallRoot $inst -WarningAction SilentlyContinue
        chk "dirs: config dir '$bad' inside the install root is refused" { $null -eq $r }
        Reset-Env; $env:PREFLIGHT_STATE_DIR = $bad
        $r = Get-PreflightDir -InstallRoot $inst -WarningAction SilentlyContinue
        chk "dirs: state dir '$bad' inside the install root is refused" { $null -eq $r }
    }
    Reset-Env; $env:PREFLIGHT_CONFIG_DIR = "$inst-sibling"
    chk 'dirs: a sibling sharing a prefix is allowed' { $null -ne (Get-PreflightDir -InstallRoot $inst) }
    Reset-Env; $env:PREFLIGHT_CONFIG_DIR = $inst
    chk 'dirs: Resolve-PreflightDirs refuses and sets nothing new' {
        $before = $env:PREFLIGHT_STATE_DIR
        $ok = Resolve-PreflightDirs -InstallRoot $inst -WarningAction SilentlyContinue
        (-not $ok) -and $env:PREFLIGHT_STATE_DIR -eq $before
    }

    # ---- defaults and profiles ---------------------------------------------
    Reset-Env; Remove-Item -LiteralPath $cfgFile -ErrorAction SilentlyContinue
    Import-PreflightConfig
    chk 'no file: status is missing'          { $script:PreflightConfigStatus -eq 'missing' }
    chk 'no file: built-in OP_ACCOUNT'        { $env:OP_ACCOUNT -eq 'my.1password.com' }
    chk 'no file: PROJ_DIRS expanded and joined with the path separator' { $env:PROJ_DIRS -eq ((@('projects', 'work', 'src') | ForEach-Object { Join-Path $HOME $_ }) -join $sep) }
    chk 'no file: OWL_OMP_CONFIG is the bundled theme' { $env:OWL_OMP_CONFIG -eq (Join-Path (Join-Path $env:PREFLIGHT_STATE_DIR 'owl') 'theme-catppuccin.omp.json') }
    chk 'no file: _CHECK_* flags are not put in the environment' { $null -eq (Get-Var '_CHECK_AWS') }

    Reset-Env; Copy-Item (Join-Path $Repo 'defaults/config.company.json') $cfgFile
    Import-PreflightConfig
    chk 'company: string value'  { $env:AWS_PROFILE_DEFAULT -eq 'my-dev-profile' }
    chk 'company: status ok'     { $script:PreflightConfigStatus -eq 'ok' }
    Reset-Env; Copy-Item (Join-Path $Repo 'defaults/config.general.json') $cfgFile
    Import-PreflightConfig
    chk 'general: empty aws.default_profile leaves the variable unset' { $null -eq (Get-Var 'AWS_PROFILE_DEFAULT') }

    # ---- value handling -----------------------------------------------------
    Reset-Env
    Put '{"op":{"account":"it''s \"x\" $(Get-Date) `n"},"projects":{"dirs":["~/a","$HOME/b","/c","$OTHER/d"]},"git":{"main_branch":"trunk"}}'
    Import-PreflightConfig
    chk 'quotes, $() and backticks survive verbatim' { $env:OP_ACCOUNT -eq 'it''s "x" $(Get-Date) `n' }
    chk 'path expansion: ~/, $HOME/, absolute; other $VAR untouched' { $env:PROJ_DIRS -eq (((Join-Path $HOME 'a'), (Join-Path $HOME 'b'), '/c', '$OTHER/d') -join $sep) }

    Reset-Env; Put '{"op":{"account":"acct"},"checks":{"aws":"yes"},"projects":{"dirs":"nope"},"git":"flat"}'
    Import-PreflightConfig
    chk 'wrong type: status still ok'        { $script:PreflightConfigStatus -eq 'ok' }
    chk 'wrong type: bad list -> default'    { $env:PROJ_DIRS -like '*projects*' }
    chk 'wrong type: bad parent -> default'  { $env:GIT_MAIN_BRANCH -eq 'main' }
    chk 'wrong type: good keys still load'   { $env:OP_ACCOUNT -eq 'acct' }

    Reset-Env; Put '{"projects":{"dirs":["~/custom",7]}}'
    Import-PreflightConfig
    chk 'mixed list: falls back as a whole' { $env:PROJ_DIRS -like '*projects*' -and $env:PROJ_DIRS -notlike '*custom*' }
    chk 'mixed list: check reports a wrong type' { (@(Test-PreflightConfig)) -contains 'wrong type for projects.dirs' }

    # Pipeline unrolling must not change a list's shape.
    Reset-Env; Put '{"projects":{"dirs":[]}}'; Import-PreflightConfig
    chk 'empty list: loads as empty (not the default, not an error)' { $null -eq (Get-Var 'PROJ_DIRS') -and $script:PreflightConfigStatus -eq 'ok' }
    Reset-Env; Put '{"projects":{"dirs":["~/one"]}}'; Import-PreflightConfig
    chk 'one-element list: still a list' { $env:PROJ_DIRS -eq (Join-Path $HOME 'one') }

    # ---- bad file -----------------------------------------------------------
    Reset-Env; Put '{ not json'
    $w = $null; Import-PreflightConfig -WarningVariable w -WarningAction SilentlyContinue
    chk 'invalid JSON: warns with the path'  { "$w" -like "*$cfgFile*" }
    chk 'invalid JSON: status invalid, defaults in use, never throws' { $script:PreflightConfigStatus -eq 'invalid' -and $env:OP_ACCOUNT -eq 'my.1password.com' -and $script:PreflightConfigError }
    Reset-Env; Put '[1,2]'; Import-PreflightConfig -WarningAction SilentlyContinue
    chk 'top-level array: invalid, defaults in use' { $script:PreflightConfigStatus -eq 'invalid' -and $env:OP_ACCOUNT -eq 'my.1password.com' }

    # ---- environment wins, and reloads ------------------------------------
    Reset-Env; Put '{"op":{"account":"from-file"},"git":{"main_branch":"file-branch"}}'
    $env:OP_ACCOUNT = 'from-env'
    Import-PreflightConfig
    chk 'env wins over the file' { $env:OP_ACCOUNT -eq 'from-env' -and $env:GIT_MAIN_BRANCH -eq 'file-branch' }
    Put '{"op":{"account":"edited"},"git":{"main_branch":"edited-branch"}}'
    . $loadLibs      # what Import-Module -Force does: the libs are loaded again
    Import-PreflightConfig
    chk 'reload: user-set value stays'               { $env:OP_ACCOUNT -eq 'from-env' }
    chk 'reload after re-sourcing: loader-set value follows the file' { $env:GIT_MAIN_BRANCH -eq 'edited-branch' }
    Put '{"op":{"account":"edited"}}'; Import-PreflightConfig
    chk 'key removed from the file -> built-in default' { $env:GIT_MAIN_BRANCH -eq 'main' }

    # ---- check ----------------------------------------------------------------
    Reset-Env; Put '{"$schema":"x","version":1,"op":{"account":"a","typo":"b"},"checks":{"aws":"yes"},"projcts":{"dirs":[]}}'
    $p = @(Test-PreflightConfig)
    chk 'check ignores $schema and version' { -not ($p -match 'schema|version') }
    chk 'check reports unknown keys'        { ($p -contains 'unknown key: op.typo') -and ($p -match '^unknown key: projcts') }
    chk 'check reports a wrong type'        { $p -contains 'wrong type for checks.aws' }
    Copy-Item (Join-Path $Repo 'defaults/config.company.json') $cfgFile -Force
    chk 'check passes a shipped profile'    { @(Test-PreflightConfig).Count -eq 0 }
    foreach ($prof in (Get-ChildItem (Join-Path $Repo 'defaults') -Filter 'config.*.json' | Where-Object { $_.Name -ne 'config.schema.json' })) {
        Copy-Item $prof.FullName $cfgFile -Force
        chk "profile $($prof.Name) passes check" { @(Test-PreflightConfig).Count -eq 0 }
    }

    # ---- env sets -------------------------------------------------------------
    $fix = Join-Path $Repo 'tests/fixtures'
    $got = ((Get-PreflightEnvEntry -Dir (Join-Path $fix 'envsets') | ForEach-Object { $_.Line }) -join "`n") + "`n"
    chk 'shared fixture: merged entries match the expected file, byte for byte' { $got -ceq [System.IO.File]::ReadAllText((Join-Path $fix 'envsets.expected')) }
    $e = @(Get-PreflightEnvEntry -Dir (Join-Path $fix 'envsets'))
    chk 'fixture: a line with an account carries it'   { ($e | Where-Object Name -eq 'GITEA_TOKEN').Account -eq 'personal.1password.com' }
    chk 'fixture: a two-column line has no account'    { ($e | Where-Object Name -eq 'NPM_TOKEN').Account -eq '' }

    $sets = Join-Path $T 'sets'; New-Item -ItemType Directory -Path $sets | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sets 'b.tsv'), "B_VAR`top://v/i/f`n")
    [System.IO.File]::WriteAllText((Join-Path $sets 'a.tsv'), "A_VAR`top://v/i/f`nB_VAR`top://other/i/f`n")
    [System.IO.File]::WriteAllText((Join-Path $sets 'Bad.tsv'), "UPPER`top://v/i/f`n")
    $e = @(Get-PreflightEnvEntry -Dir $sets)
    chk 'no .active: sets are read alphabetically, an invalid set name is ignored' { ($e.Name -join ',') -eq 'A_VAR,B_VAR' }
    chk 'first definition wins across sets' { ($e | Where-Object Name -eq 'B_VAR').Ref -eq 'op://other/i/f' }
    [System.IO.File]::WriteAllText((Join-Path $sets '.active'), "b`r`n`r`n  `r`n")
    $e = @(Get-PreflightEnvEntry -Dir $sets)
    chk '.active (CRLF, blank lines): only listed sets, in that order' { ($e.Name -join ',') -eq 'B_VAR' }
    chk 'no config dir: no entries, no error' { Remove-Item Env:PREFLIGHT_CONFIG_DIR; $n = @(Get-PreflightEnvEntry).Count; $n -eq 0 }

    # ---- Import-OpEnv with a stub op (POSIX only) ------------------------------
    if (-not $IsWindows) {
        Reset-Env
        . (Join-Path $Repo 'pwsh/lib/00-helpers.ps1')
        . (Join-Path $Repo 'pwsh/lib/1password.ps1')
        $bin = Join-Path $T 'bin'; New-Item -ItemType Directory -Path $bin | Out-Null
        $log = Join-Path $T 'op.log'
        $stub = @'
#!/bin/sh
# Stub op: whoami succeeds (unless the account is "down"); run resolves {vault/item/field} to
# val-of-field and execs the command after --; read does the same for one reference.
echo "$*" >> "$OP_STUB_LOG"
cmd=$1; shift
[ "$cmd" = vault ] && shift   # `vault list`
acct=""; envfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --account) acct=$2; shift 2 ;;
    --env-file=*) envfile=${1#--env-file=}; shift ;;
    --no-masking) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$cmd" in
  whoami) [ "$acct" = down ] && exit 1; echo ok; exit 0 ;;
  run)
    while IFS='=' read -r k v; do
      [ -n "$k" ] || continue
      case "$v" in *broken*) exit 1 ;; esac
      field=${v##*/}
      export "$k=val-of-$field@$acct"
    done < "$envfile"
    exec "$@" ;;
  read) case "$1" in *broken*) exit 1 ;; esac; echo "val-of-${1##*/}@$acct" ;;
  vault) [ "$acct" = down ] && exit 1; exit 0 ;;
  signin) exit 1 ;;
esac
'@
        $opPath = Join-Path $bin 'op'
        [System.IO.File]::WriteAllText($opPath, $stub.Replace("`r`n", "`n"))
        chmod +x $opPath
        $env:OP_STUB_LOG = $log
        $env:PATH = $bin + $sep + (Split-Path -Parent (Get-Process -Id $PID).Path) + $sep + $env:PATH
        $env:OP_ACCOUNT = 'main.1password.com'
        $vars = 'ONE', 'TWO', 'THREE'

        function Set-Sets([string]$tsv) {
            $d = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
            Remove-Item -LiteralPath $d -Recurse -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 's.tsv'), $tsv)
            Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
            foreach ($v in $vars) { Remove-Item -LiteralPath "Env:$v" -ErrorAction SilentlyContinue }
        }
        function Get-OpCalls { if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() } }

        Set-Sets "ONE`top://v/i/one`nTWO`top://v/i/two`n"
        $out = Import-OpEnv *>&1 | Out-String
        chk 'Import-OpEnv: single account loads both, one op run' { $env:ONE -eq 'val-of-one@main.1password.com' -and $env:TWO -eq 'val-of-two@main.1password.com' -and (@(Get-OpCalls) -match '^run ').Count -eq 1 }
        chk 'Import-OpEnv: no account label with a single account' { $out -notmatch 'via ' }

        Set-Sets "ONE`top://v/i/one`nTWO`top://v/i/two`tother.1password.com`nTHREE`top://v/i/three`n"
        $out = Import-OpEnv *>&1 | Out-String
        chk 'Import-OpEnv: a second account is resolved against that account' { $env:TWO -eq 'val-of-two@other.1password.com' -and $env:ONE -eq 'val-of-one@main.1password.com' -and $env:THREE -eq 'val-of-three@main.1password.com' }
        chk 'Import-OpEnv: one op run per account' { (@(Get-OpCalls) -match '^run ').Count -eq 2 }
        chk 'Import-OpEnv: secrets are labelled with their account when there are several' { $out -match 'TWO \(via other.1password.com\)' }

        Set-Sets "ONE`top://v/i/one`nTWO`top://v/i/two`tdown`n"
        $out = Import-OpEnv -ErrorAction SilentlyContinue *>&1 | Out-String
        chk 'Import-OpEnv: a sign-in failure stops before any variable is set' { $null -eq (Get-Var 'ONE') -and (@(Get-OpCalls) -match '^run ').Count -eq 0 }

        Set-Sets "ONE`top://v/i/one`nTWO`top://v/i/broken`n"
        $out = Import-OpEnv -WarningAction SilentlyContinue *>&1 | Out-String
        chk 'Import-OpEnv: a failed batch falls back to per-secret reads' { $env:ONE -eq 'val-of-one@main.1password.com' }
        chk 'Import-OpEnv: ...and names the secret that failed' { $out -match 'TWO \(failed to load' }

        Set-Sets ''
        chk 'Import-OpEnv: no secrets configured: no op calls' { $null -eq (Import-OpEnv) -and (@(Get-OpCalls)).Count -eq 0 }
    } else {
        Write-Host 'skipped: Import-OpEnv stub tests (Windows)'
    }

    # ---- installer ---------------------------------------------------------------
    $ih = Join-Path $T 'ihome'; New-Item -ItemType Directory -Path $ih | Out-Null
    $prof = Join-Path $T 'profile.ps1'
    [System.IO.File]::WriteAllText($prof, "# mine`r`n# preflight:begin Import-Module guard`r`nif (-not (Test-Path -LiteralPath 'Env:OWL_OMP_CONFIG')) {`r`n    `$env:OWL_OMP_CONFIG = '/old/theme.json'`r`n}`r`nImport-Module x`r`n# preflight:end Import-Module guard`r`n")
    $pwshExe = (Get-Process -Id $PID).Path
    $inst = { & $pwshExe -NoProfile -File (Join-Path $Repo 'pwsh/install.ps1') -Force -InstallRoot (Join-Path $ih '.preflight') -ProfilePath $prof 2>&1 | Out-String }
    Reset-Env; $env:PREFLIGHT_CONFIG_DIR = Join-Path $ih 'cfg'; $env:PREFLIGHT_STATE_DIR = Join-Path $ih 'state'
    $o = & $inst
    chk 'install: seeds config.json from the general profile' { (Get-Content (Join-Path $ih 'cfg/config.json') -Raw) -ceq (Get-Content (Join-Path $Repo 'defaults/config.general.json') -Raw) }
    chk 'install: seeds the owl theme into the state dir' { Test-Path (Join-Path $ih 'state/owl/theme-catppuccin.omp.json') }
    $pc = Get-Content -LiteralPath $prof -Raw
    chk 'install: the profile guard sets no OWL_ variable, and an old one is replaced' { $pc -notmatch 'OWL_' -and $pc -match 'Import-Module' -and $pc -notmatch 'Import-Module x' }
    $before = $pc; $o = & $inst
    chk 'install: a second run changes nothing and keeps config.json' { (Get-Content -LiteralPath $prof -Raw) -ceq $before -and $o -match 'Config exists, kept' }
    Set-Content (Join-Path $ih 'cfg/config.json') '{"version":1,"op":{"account":"mine"}}' -NoNewline
    $o = & $inst
    chk 'install: an edited config.json is never overwritten' { (Get-Content (Join-Path $ih 'cfg/config.json') -Raw) -match 'mine' }
    $env:PREFLIGHT_CONFIG_DIR = Join-Path $ih '.preflight/inside'
    $o = & $inst
    chk 'install: refuses a config dir inside the install root, before touching anything' { $o -match 'Refusing' -and -not (Test-Path (Join-Path $ih '.preflight/inside')) }

    # ---- upgrade path: an install from before config.json -----------------------
    # Update-Preflight must ship install.ps1 and defaults\, or re-running the (old) installer from the
    # install directory cannot seed config.json. The "upstream" is a throwaway git repo holding this
    # working tree, so uncommitted changes are tested too.
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $up = Join-Path $T 'upstream'
        New-Item -ItemType Directory -Path $up | Out-Null
        foreach ($d in 'pwsh', 'defaults', 'lib', 'tests') { Copy-Item -Recurse -LiteralPath (Join-Path $Repo $d) -Destination (Join-Path $up $d) }
        $gitEnv = @{ GIT_AUTHOR_NAME = 't'; GIT_AUTHOR_EMAIL = 't@t'; GIT_COMMITTER_NAME = 't'; GIT_COMMITTER_EMAIL = 't@t' }
        foreach ($k in $gitEnv.Keys) { Set-Item -LiteralPath "Env:$k" -Value $gitEnv[$k] }
        git -C $up init -q 2>&1 | Out-Null
        git -C $up add -A 2>&1 | Out-Null
        git -C $up commit -q -m up 2>&1 | Out-Null

        $uh = Join-Path $T 'uhome/.preflight'
        New-Item -ItemType Directory -Path (Join-Path $uh 'pwsh') -Force | Out-Null
        Copy-Item -Recurse -Path (Join-Path $Repo 'pwsh/*') -Destination (Join-Path $uh 'pwsh')
        # Make it look like an install from before: a legacy installer, no defaults, an accounts.ps1.
        Set-Content (Join-Path $uh 'pwsh/install.ps1') '# LEGACY INSTALLER'
        New-Item -ItemType Directory -Path (Join-Path $uh 'pwsh/config') -Force | Out-Null
        Set-Content (Join-Path $uh 'pwsh/config/accounts.ps1') '$env:OP_ACCOUNT = "x"'
        $ucfg = Join-Path $T 'ucfg'; $ust = Join-Path $T 'ust'

        $run = {
            param([string]$Command)
            & $pwshExe -NoProfile -Command ("`$env:PREFLIGHT_CONFIG_DIR = '$ucfg'; `$env:PREFLIGHT_STATE_DIR = '$ust'; " +
                "Import-Module '$(Join-Path $uh 'pwsh/Preflight.psd1')' -Force; $Command") 2>&1 | Out-String
        }
        $o = & $run "Update-Preflight -RepoUrl '$up' -DryRun"
        chk 'update: a dry run lists install.ps1 and the defaults' { $o -match 'would update: install.ps1' -and $o -match 'defaults.config.general.json' }
        chk 'update: a dry run changes nothing' { (Get-Content (Join-Path $uh 'pwsh/install.ps1') -Raw) -match 'LEGACY' -and -not (Test-Path (Join-Path $uh 'defaults')) }

        $o = & $run "Update-Preflight -RepoUrl '$up'"
        chk 'update: install.ps1 is replaced by the current installer' { (Get-Content (Join-Path $uh 'pwsh/install.ps1') -Raw) -ceq (Get-Content (Join-Path $Repo 'pwsh/install.ps1') -Raw) }
        chk 'update: the bundled defaults are delivered beside pwsh\' { (Test-Path (Join-Path $uh 'defaults/config.general.json')) -and (Test-Path (Join-Path $uh 'defaults/theme-catppuccin.omp.json')) }
        chk 'update: it tells you to run the installer once' { $o -match 'Settings moved to config.json' -and $o -match 'install.ps1' }
        chk 'update: user config is never written by an update' { -not (Test-Path (Join-Path $ucfg 'config.json')) }

        # Now the documented step works from the installed tree, with no checkout.
        $uprof = Join-Path $T 'uprofile.ps1'
        [System.IO.File]::WriteAllText($uprof, "# mine`r`n# preflight:begin Import-Module guard`r`nif (-not (Test-Path -LiteralPath 'Env:OWL_OMP_CONFIG')) {`r`n    `$env:OWL_OMP_CONFIG = '/old/theme.json'`r`n}`r`nImport-Module x`r`n# preflight:end Import-Module guard`r`n")
        $o = & $pwshExe -NoProfile -Command ("`$env:PREFLIGHT_CONFIG_DIR = '$ucfg'; `$env:PREFLIGHT_STATE_DIR = '$ust'; " +
            "& '$(Join-Path $uh 'pwsh/install.ps1')' -Force -InstallRoot '$uh' -ProfilePath '$uprof'") 2>&1 | Out-String
        chk 'update then install: config.json is seeded from the delivered defaults' { Test-Path (Join-Path $ucfg 'config.json') }
        chk 'update then install: the owl theme is seeded into the state dir' { Test-Path (Join-Path $ust 'owl/theme-catppuccin.omp.json') }
        chk 'update then install: the old profile guard is replaced by one that sets no OWL_ variable' { $pc = Get-Content $uprof -Raw; $pc -match 'Import-Module' -and $pc -notmatch 'OWL_' -and $pc -notmatch 'Import-Module x' }
        $o = & $run 'Write-Output ready'
        chk 'after the upgrade the old-installer warning is gone' { $o -notmatch 'old installer' }
    } else {
        Write-Host 'skipped: upgrade-path tests (git not installed)'
    }
} finally {
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$script:passes passed, $script:fails failed"
exit ([int]($script:fails -gt 0))
