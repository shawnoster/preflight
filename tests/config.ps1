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

    $managedVars = 'OP_ACCOUNT', 'PROJ_DIRS', 'AWS_PROFILE_DEFAULT', 'GIT_MAIN_BRANCH', 'GITEA_USERNAME', 'GITEA_HOST', 'OWL_OMP_CONFIG', 'PREFLIGHT_PLUGINS'
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
        . (Join-Path $Repo 'pwsh/lib/03-op-env.ps1')
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
      case "$field" in
        multi) export "$k=$(printf 'first line\nTWO=forged\nlast line')" ;;
        *) export "$k=val-of-$field@$acct" ;;
      esac
    done < "$envfile"
    exec "$@" ;;
  read) case "$1" in
          *broken*) exit 1 ;;
          */multi) printf 'first line\nTWO=forged\nlast line\n' ;;
          *) echo "val-of-${1##*/}@$acct" ;;
        esac ;;
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

        # load succeeds -> reload fails -> definition removed: the old value must not outlive its definition.
        Set-Sets "ONE`top://v/i/one`nTWO`top://v/i/two`n"
        Import-OpEnv *>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets/s.tsv') -Value "ONE`top://v/i/one`nTWO`top://v/i/broken"
        Import-OpEnv -WarningAction SilentlyContinue *>&1 | Out-Null
        chk 'Import-OpEnv: a managed variable that fails to reload stays remembered' { $global:OpLoadedVars.Contains('TWO') -and $env:TWO }
        Set-Content -LiteralPath (Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets/s.tsv') -Value "ONE`top://v/i/one"
        Import-OpEnv *>&1 | Out-Null
        chk 'Import-OpEnv: ...and is unset once its definition is removed' { -not $env:TWO -and -not $global:OpLoadedVars.Contains('TWO') }

        # A multiline value must come back whole, and must not be able to forge another variable.
        Set-Sets "ONE`top://v/i/multi`nTWO`top://v/i/two`n"
        $out = Import-OpEnv *>&1 | Out-String
        chk 'Import-OpEnv: a multiline secret is loaded whole' { $env:ONE -ceq "first line`nTWO=forged`nlast line" }
        chk 'Import-OpEnv: ...and cannot overwrite another requested variable' { $env:TWO -eq 'val-of-two@main.1password.com' }
        chk 'Import-OpEnv: ...both reported as loaded' { $out -match 'ONE' -and $out -match 'TWO' -and $out -notmatch 'failed to load' }

        Set-Sets "ONE`top://v/i/multi`nTWO`top://v/i/broken`n"
        $out = Import-OpEnv -WarningAction SilentlyContinue *>&1 | Out-String
        chk 'Import-OpEnv: the per-secret fallback also keeps a multiline secret whole' { $env:ONE -ceq "first line`nTWO=forged`nlast line" }

        Set-Sets ''
        chk 'Import-OpEnv: no secrets configured: no op calls' { $null -eq (Import-OpEnv) -and (@(Get-OpCalls)).Count -eq 0 }

        # ---- op-env load / clear with set names (stub op) -----------------------------------------
        . (Join-Path $Repo 'pwsh/lib/03-op-env.ps1')
        $opSetsDir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
        function New-TestSet([string]$name, [string[]]$lines) {
            New-Item -ItemType Directory -Path $opSetsDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $opSetsDir "$name.tsv"), (($lines -join "`n") + "`n"))
        }
        function Reset-TestSets {
            Remove-Item -LiteralPath $opSetsDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $opSetsDir -Force | Out-Null
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
            foreach ($v in 'A1', 'B1', 'B2', 'SHARED', 'ONLY1', 'ONLY2', 'C1', 'N1', 'X1') { Remove-Item -LiteralPath "Env:$v" -ErrorAction SilentlyContinue }
            $global:OpLoadedVars.Clear(); $global:OpLoadedSrc.Clear()
        }
        # Run a command, collecting its console output and any errors (failures are errors here).
        function Invoke-Op([scriptblock]$Block) {
            $wrapper = { [CmdletBinding()] param([scriptblock]$B) & $B }
            $script:opErr = $null
            $script:opOut = (& $wrapper $Block -ErrorVariable script:opErr -ErrorAction SilentlyContinue 6>&1 | Out-String)
        }
        function Get-Mem { (@($global:OpLoadedVars) | Sort-Object) -join ',' }
        function Get-Src { (@($global:OpLoadedSrc.Keys) | Sort-Object | ForEach-Object { "$_=$($global:OpLoadedSrc[$_])" }) -join ',' }
        $env:OP_ACCOUNT = 'main.1password.com'

        Reset-TestSets
        New-TestSet 'a' @("A1`top://v/i/a1")
        New-TestSet 'b' @("B1`top://v/i/b1", "B2`top://v/i/b2")

        # Get-PreflightEnvEntry -Set reads only those sets, in the order given.
        New-TestSet 'c' @("B1`top://v/i/from-c", "C1`top://v/i/c1")
        $e = @(Get-PreflightEnvEntry -Set 'c', 'b')
        chk 'entries -Set: only the named sets, first one named wins a clash' { ($e.Name -join ',') -eq 'B1,C1,B2' -and ($e | Where-Object Name -eq 'B1').Ref -eq 'op://v/i/from-c' }
        chk 'entries -Set: works on an inactive set' { [System.IO.File]::WriteAllText((Join-Path $opSetsDir '.active'), "a`n"); (@(Get-PreflightEnvEntry -Set 'b')).Count -eq 2 }
        Remove-Item -LiteralPath (Join-Path $opSetsDir '.active') -Force
        Remove-Item -LiteralPath (Join-Path $opSetsDir 'c.tsv') -Force

        # Set-name checks, and the "note" name (a legal set name, so it must be validated like any other).
        chk 'check: good names pass'                    { $null -eq (Test-PreflightEnvSet -Set 'a', 'b') }
        chk 'check: an unknown set is named in the message'  { (Test-PreflightEnvSet -Set 'nope') -like "No env set 'nope'*Nothing was changed*" }
        chk 'check: an invalid name is refused'         { (Test-PreflightEnvSet -Set 'Bad') -like "Invalid set name 'Bad'*" -and (Test-PreflightEnvSet -Set '../x') -like 'Invalid set name*' }
        chk 'check: a set called note is validated like any other' { (Test-PreflightEnvSet -Set 'note') -like "No env set 'note'*" }
        chk 'check: one bad name among good ones fails'  { $null -ne (Test-PreflightEnvSet -Set 'a', 'nope', 'b') }

        # A plain load, then a subset: additive, the other set untouched, the memory keeps everything.
        Reset-TestSets; New-TestSet 'a' @("A1`top://v/i/a1"); New-TestSet 'b' @("B1`top://v/i/b1", "B2`top://v/i/b2")
        Invoke-Op { Import-OpEnv }
        chk 'plain load: all three set, no account label (single account)' { $env:A1 -eq 'val-of-a1@main.1password.com' -and $env:B2 -eq 'val-of-b2@main.1password.com' -and $opOut -notmatch 'via ' }
        chk 'plain load: the memory lists every variable and its set' { (Get-Mem) -eq 'A1,B1,B2' -and (Get-Src) -eq 'A1=a,B1=b,B2=b' }
        Remove-Item Env:B1, Env:B2
        Invoke-Op { Import-OpEnv -Set b }
        chk 'subset load: the named set comes back'        { $env:B1 -eq 'val-of-b1@main.1password.com' -and $env:B2 -eq 'val-of-b2@main.1password.com' }
        chk 'subset load: the other set is untouched, and the memory still has it' { $env:A1 -eq 'val-of-a1@main.1password.com' -and (Get-Mem) -eq 'A1,B1,B2' }
        Invoke-Op { Invoke-OpEnv clear b }
        chk 'subset clear: only that set goes, the rest stays loaded and remembered' { -not $env:B1 -and -not $env:B2 -and $env:A1 -and (Get-Mem) -eq 'A1' -and (Get-Src) -eq 'A1=a' }
        chk 'subset clear: says which sets' { $opOut -match 'Cleared the variables of: b' }
        Invoke-Op { Invoke-OpEnv clear }
        chk 'a later plain clear clears what is left and forgets it' { -not $env:A1 -and (Get-Mem) -eq '' -and (Get-Src) -eq '' }

        # A named load unsets nothing; only a plain load is authoritative.
        Invoke-Op { Import-OpEnv }
        Remove-Item -LiteralPath (Join-Path $opSetsDir 'a.tsv') -Force
        Invoke-Op { Import-OpEnv -Set b }
        chk 'subset load: a variable whose set is gone is not unset' { [bool]$env:A1 }
        Invoke-Op { Import-OpEnv }
        chk 'plain load is authoritative: the same variable is unset now' { -not $env:A1 -and $env:B1 -and (Get-Mem) -eq 'B1,B2' }
        Invoke-Op { Invoke-OpEnv clear }; New-TestSet 'a' @("A1`top://v/i/a1")

        # An inactive set loads when named, says so, and a plain load unsets it again.
        [System.IO.File]::WriteAllText((Join-Path $opSetsDir '.active'), "a`n")
        Invoke-Op { Import-OpEnv -Set b }
        chk 'inactive set: loads when named, with the note and the way to keep it' { $env:B1 -and $opOut -match 'not active' -and $opOut -match 'op-env use b' }
        Invoke-Op { Import-OpEnv -Set a }
        chk 'inactive set: an active set gives no such note' { $opOut -notmatch 'not active' }
        Invoke-Op { Import-OpEnv }
        chk 'inactive set: the next plain load unsets it (documented)' { -not $env:B1 -and -not $env:B2 -and $env:A1 }
        Invoke-Op { Invoke-OpEnv clear }; Remove-Item -LiteralPath (Join-Path $opSetsDir '.active') -Force

        # Bad names stop before anything is touched or signed in.
        Invoke-Op { Import-OpEnv }; $before = Get-Mem; Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        foreach ($bad in 'nope', 'Bad', '../x', 'note') {
            Invoke-Op { Import-OpEnv -Set $bad }
            chk "load -Set '$bad': an error, nothing changed" { $opErr.Count -gt 0 -and "$($opErr[0])" -match 'Nothing was changed' -and (Get-Mem) -eq $before }
        }
        Invoke-Op { Invoke-OpEnv load a nope }
        chk 'load: one bad name among good ones loads none, and makes no op call' { $opErr.Count -gt 0 -and (@(Get-OpCalls)).Count -eq 0 }
        Invoke-Op { Invoke-OpEnv clear nope }
        chk 'clear: an unknown set is an error and unsets nothing' { $opErr.Count -gt 0 -and $env:A1 -and (Get-Mem) -eq $before }
        Invoke-Op { Invoke-OpEnv clear }

        # A failed sign-in during a subset load leaves the memory and the environment as they were.
        Invoke-Op { Import-OpEnv -Set a }; $before = Get-Mem; $beforeSrc = Get-Src
        New-TestSet 'dn' @("D1`top://v/i/d1`tdown")
        Invoke-Op { Import-OpEnv -Set dn }
        chk 'subset load: a failed sign-in sets nothing from the set' { -not $env:D1 }
        chk 'subset load: ...and leaves the memory and provenance unchanged' { (Get-Mem) -eq $before -and (Get-Src) -eq $beforeSrc -and $env:A1 }
        Remove-Item -LiteralPath (Join-Path $opSetsDir 'dn.tsv') -Force; Invoke-Op { Invoke-OpEnv clear }

        # Provenance: a variable two sets define belongs to the first one named.
        New-TestSet 's1' @("SHARED`top://v/i/from-s1", "ONLY1`top://v/i/only1")
        New-TestSet 's2' @("SHARED`top://v/i/from-s2", "ONLY2`top://v/i/only2")
        Invoke-Op { Import-OpEnv -Set s1, s2 }
        chk 'shared variable: the first set named supplies it' { $env:SHARED -eq 'val-of-from-s1@main.1password.com' -and (Get-Src) -match 'SHARED=s1' }
        Invoke-Op { Invoke-OpEnv clear s2 }
        chk 'clear the set that lost: its own variable goes, the shared one stays' { -not $env:ONLY2 -and $env:SHARED -and $env:ONLY1 -and (Get-Mem) -match 'SHARED' }
        Invoke-Op { Invoke-OpEnv clear s1 }
        chk 'clear the set that won: the shared variable goes now' { -not $env:SHARED -and -not $env:ONLY1 -and (Get-Mem) -eq '' }
        Invoke-Op { Import-OpEnv -Set s1, s2 }; Invoke-Op { Import-OpEnv -Set s2 }
        chk 'a later named load re-points the variable at the set that just loaded it' { $env:SHARED -eq 'val-of-from-s2@main.1password.com' -and (Get-Src) -match 'SHARED=s2' }
        Invoke-Op { Invoke-OpEnv clear s1 }
        chk '...so clearing s1 leaves it' { [bool]$env:SHARED }
        Invoke-Op { Invoke-OpEnv clear s2 }
        chk '...and clearing s2 removes it' { -not $env:SHARED }
        Invoke-Op { Import-OpEnv }; Invoke-Op { Invoke-OpEnv clear s2 }
        chk 'after a plain load, clearing the losing active set keeps the shared variable' { $env:SHARED -eq 'val-of-from-s1@main.1password.com' -and -not $env:ONLY2 }
        Invoke-Op { Invoke-OpEnv clear }
        $env:ONLY1 = 'mine'
        Invoke-Op { Invoke-OpEnv clear s1 }
        chk 'clear <set> does not unset a same-named variable it never loaded' { $env:ONLY1 -eq 'mine' }
        Remove-Item Env:ONLY1

        # The memory is global: it survives the libs being loaded again (Import-Module -Force, which
        # Update-Preflight does), so a clear after that still knows what is loaded.
        Reset-TestSets; New-TestSet 'a' @("A1`top://v/i/a1"); New-TestSet 'b' @("B1`top://v/i/b1")
        Invoke-Op { Import-OpEnv }
        . (Join-Path $Repo 'pwsh/lib/1password.ps1')
        chk 'reload: the memory survives the libs being loaded again' { (Get-Mem) -eq 'A1,B1' -and (Get-Src) -eq 'A1=a,B1=b' }
        Remove-Item -LiteralPath (Join-Path $opSetsDir 'a.tsv') -Force
        Invoke-Op { Invoke-OpEnv clear }
        chk 'reload: a plain clear still clears a variable whose definition is gone' { -not $env:A1 -and -not $env:B1 }

        # The real thing, not a re-dot-source: Import-Module -Force builds a fresh module scope (Update-Preflight
        # does this), so a $script: memory would be forgotten. Only a $global: one survives it.
        Reset-TestSets; New-TestSet 'a' @("A1`top://v/i/a1")
        $psd1 = Join-Path $Repo 'pwsh/Preflight.psd1'
        $modOut = & (Get-Process -Id $PID).Path -NoProfile -Command ("Import-Module '$psd1' -Force 3>`$null; op-env load *>`$null; " +
            "Import-Module '$psd1' -Force 3>`$null; `$before = [bool]`$env:A1; Remove-Item '$(Join-Path $opSetsDir 'a.tsv')'; op-env clear *>`$null; " +
            "'LOADED=' + `$before + ' CLEARED=' + (-not `$env:A1)") 2>&1 | Out-String
        chk 'Import-Module -Force: clear still clears what a load set before the reload (memory is global)' { $modOut -match 'LOADED=True CLEARED=True' }
        Reset-TestSets

        # A plain load unsets what a previous load set and the sets no longer define.
        Reset-TestSets; New-TestSet 'a' @("A1`top://v/i/a1", "X1`top://v/i/x1")
        Invoke-Op { Import-OpEnv }
        New-TestSet 'a' @("A1`top://v/i/a1")
        Invoke-Op { Import-OpEnv }
        chk 'plain load: a variable removed from its set is unset by the next load' { -not $env:X1 -and $env:A1 }

        # An empty set loads nothing and signs in to nothing.
        Reset-TestSets; New-TestSet 'empty' @(); [System.IO.File]::WriteAllText((Join-Path $opSetsDir 'empty.tsv'), '')
        Invoke-Op { Import-OpEnv -Set empty }
        chk 'an empty set: says so and makes no op call' { $opOut -match 'No secrets in: empty' -and (@(Get-OpCalls)).Count -eq 0 }
        Reset-TestSets
    } else {
        Write-Host 'skipped: Import-OpEnv stub tests (Windows)'
    }

    # ---- op-env: add / list / rm / use (write side) --------------------------------------------
    . (Join-Path $Repo 'pwsh/lib/00-helpers.ps1')
    . (Join-Path $Repo 'pwsh/lib/03-op-env.ps1')
    function Invoke-OpQuiet([scriptblock]$Block) {
        $wrapper = { [CmdletBinding()] param([scriptblock]$B) & $B }
        $script:wErr = $null
        $script:wOut = (& $wrapper $Block -ErrorVariable script:wErr -ErrorAction SilentlyContinue 6>&1 | Out-String)
    }
    function Get-Bytes([string]$p) { [System.IO.File]::ReadAllBytes($p) }
    function Get-Mode([string]$p) { (& stat -c %a $p 2>$null) }
    function Get-Temps { ,@(Get-ChildItem -LiteralPath $wDir -Force -Filter '.tmp.*' -ErrorAction SilentlyContinue) }
    Reset-Env
    $wDir = Join-Path $env:PREFLIGHT_CONFIG_DIR 'envsets'
    Remove-Item -LiteralPath $wDir -Recurse -Force -ErrorAction SilentlyContinue
    $env:OP_ACCOUNT = 'main.1password.com'

    Invoke-OpQuiet { op-env add guild NPM_TOKEN 'op://Private/npm/credential' }
    $b = Get-Bytes (Join-Path $wDir 'guild.tsv')
    chk 'add: writes VAR<TAB>ref and a newline, LF only, no BOM' { [System.Text.Encoding]::UTF8.GetString($b) -ceq "NPM_TOKEN`top://Private/npm/credential`n" -and $b[0] -ne 0xEF -and ($b -notcontains 13) }
    chk 'add: prints the confirmation and how to load it' { $wOut -match '\[guild\] NPM_TOKEN -> op://Private/npm/credential' -and $wOut -match 'Load it now: op-env load' }
    if (-not $IsWindows) {
        chk 'add: the sets directory is mode 700 and the file 600' { (Get-Mode $wDir) -eq '700' -and (Get-Mode (Join-Path $wDir 'guild.tsv')) -eq '600' }
    }
    chk 'add: leaves no temp files' { (Get-Temps).Count -eq 0 }

    Invoke-OpQuiet { op-env add personal GITEA_TOKEN 'op://v/i/pat' acct.example.com }
    Invoke-OpQuiet { op-env add guild OTHER 'op://v/i/other' }
    Invoke-OpQuiet { op-env add guild NPM_TOKEN 'op://Private/npm/rotated' }
    chk 'add: updating a key replaces its line and moves it last, other lines kept as written' { [System.IO.File]::ReadAllText((Join-Path $wDir 'guild.tsv')) -ceq "OTHER`top://v/i/other`nNPM_TOKEN`top://Private/npm/rotated`n" }
    Invoke-OpQuiet { op-env add personal GITEA_TOKEN 'op://v/i/pat2' }
    chk 'add: leaving the account out keeps the one already on the line' { [System.IO.File]::ReadAllText((Join-Path $wDir 'personal.tsv')) -ceq "GITEA_TOKEN`top://v/i/pat2`tacct.example.com`n" }
    Invoke-OpQuiet { op-env add personal GITEA_TOKEN 'op://v/i/pat3' other.example.com }
    chk 'add: an explicit account replaces it' { [System.IO.File]::ReadAllText((Join-Path $wDir 'personal.tsv')) -ceq "GITEA_TOKEN`top://v/i/pat3`tother.example.com`n" }
    chk 'add: after several writes there are still no temp files' { (Get-Temps).Count -eq 0 }

    # Anything unrecognised in the file is kept byte for byte (comments, CRLF lines).
    [System.IO.File]::WriteAllText((Join-Path $wDir 'raw.tsv'), "# a comment`nKEEP`top://v/i/k`r`nGONE`top://v/i/g`n")
    Invoke-OpQuiet { op-env add raw GONE 'op://v/i/g2' }
    chk 'add: unrelated lines (a comment, a CRLF line) are kept exactly as written' { [System.IO.File]::ReadAllText((Join-Path $wDir 'raw.tsv')) -ceq "# a comment`nKEEP`top://v/i/k`r`nGONE`top://v/i/g2`n" }
    Remove-Item -LiteralPath (Join-Path $wDir 'raw.tsv') -Force

    # Validation: nothing is written for a bad name, reference, account or set name.
    $snap = (Get-ChildItem $wDir -Force | ForEach-Object { "$($_.Name):$($_.Length)" }) -join ','
    Invoke-OpQuiet { op-env add guild 'bad name' 'op://v/i/f' }
    chk 'add: an invalid variable name is an error' { $wErr.Count -gt 0 }
    Invoke-OpQuiet { op-env add guild OKNAME 'op://broken' }
    chk 'add: a malformed reference is an error' { $wErr.Count -gt 0 }
    Invoke-OpQuiet { op-env add guild OKNAME 'op://v/i/f' 'not valid!' }
    chk 'add: an invalid account is an error' { $wErr.Count -gt 0 }
    Invoke-OpQuiet { op-env add Guild OKNAME 'op://v/i/f' }
    chk 'add: an invalid set name (uppercase) is an error' { $wErr.Count -gt 0 }
    chk 'add: ...and none of those wrote anything' { ((Get-ChildItem $wDir -Force | ForEach-Object { "$($_.Name):$($_.Length)" }) -join ',') -eq $snap }

    # GITHUB_TOKEN / GH_TOKEN need a yes; no answer counts as no.
    $script:answers = [System.Collections.Generic.Queue[object]]::new()
    function Read-OpEnvAnswer { param([string]$Prompt) if ($script:answers.Count -gt 0) { return $script:answers.Dequeue() } return $null }
    $script:answers.Enqueue('n'); Invoke-OpQuiet { op-env add guild GITHUB_TOKEN 'op://v/i/gh' }
    chk 'add GITHUB_TOKEN: a no is not written'            { -not (Select-String -LiteralPath (Join-Path $wDir 'guild.tsv') -Pattern 'GITHUB_TOKEN' -Quiet) }
    $script:answers.Enqueue($null); Invoke-OpQuiet { op-env add guild GH_TOKEN 'op://v/i/gh' }
    chk 'add GH_TOKEN: no answer (no terminal) counts as no' { -not (Select-String -LiteralPath (Join-Path $wDir 'guild.tsv') -Pattern 'GH_TOKEN' -Quiet) }
    $script:answers.Enqueue('y'); Invoke-OpQuiet { op-env add guild GITHUB_TOKEN 'op://v/i/gh' }
    chk 'add GITHUB_TOKEN: a yes is written, after a warning' { (Select-String -LiteralPath (Join-Path $wDir 'guild.tsv') -Pattern 'GITHUB_TOKEN' -Quiet) -and $wOut -match 'overrides gh CLI' }
    Invoke-OpQuiet { op-env rm guild GITHUB_TOKEN }

    # Prompts for omitted arguments (answers fed through Read-OpEnvAnswer and Select-FromList).
    $script:picks = [System.Collections.Generic.Queue[object]]::new()
    function Select-FromList { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)][string[]]$Items, [string]$Prompt, [switch]$Multiple)
        begin { $all = @() } process { $all += $Items } end { $script:lastChoices = $all; if ($script:picks.Count -gt 0) { return $script:picks.Dequeue() } return $null } }
    $script:picks.Enqueue('+ new set...'); 'fresh', 'ASKED_VAR', 'op://v/i/asked' | ForEach-Object { $script:answers.Enqueue($_) }
    Invoke-OpQuiet { op-env add }
    chk 'add with no arguments: asks for set, variable and reference' { [System.IO.File]::ReadAllText((Join-Path $wDir 'fresh.tsv')) -ceq "ASKED_VAR`top://v/i/asked`n" }
    chk 'add with no arguments: the set picker offers existing sets, the usual names and "new set"' { ($script:lastChoices -contains 'guild') -and ($script:lastChoices -contains 'personal') -and ($script:lastChoices -contains '+ new set...') }
    Remove-Item -LiteralPath (Join-Path $wDir 'fresh.tsv') -Force

    # A new set joins .active only when .active exists; a deactivated set is never reactivated.
    chk 'no .active file: adding sets never creates one' { -not (Test-Path (Join-Path $wDir '.active')) }
    Invoke-OpQuiet { op-env use guild }
    chk 'use: writes the chosen sets, LF only' { [System.IO.File]::ReadAllText((Join-Path $wDir '.active')) -ceq "guild`n" }
    Invoke-OpQuiet { op-env add brandnew X1 'op://v/i/x' }
    chk 'a new set is added to an explicit .active' { [System.IO.File]::ReadAllText((Join-Path $wDir '.active')) -ceq "guild`nbrandnew`n" }
    Invoke-OpQuiet { op-env add personal ANOTHER 'op://v/i/an' }
    chk 'editing a set the user deactivated does not reactivate it' { [System.IO.File]::ReadAllText((Join-Path $wDir '.active')) -ceq "guild`nbrandnew`n" }
    if (-not $IsWindows) {
        # .active gets the default mode, like bash's (it lists set names, not secrets); tests/op-env.sh checks the match.
        if ((& id -u) -ne '0') {
            [System.IO.File]::WriteAllText((Join-Path $wDir '.active'), "guild`n"); & chmod 444 (Join-Path $wDir '.active')
            Invoke-OpQuiet { op-env add another Y1 'op://v/i/y' }
                    chk 'an unwritable .active: add fails up front and writes nothing' { @($wErr | Where-Object { "$_" -match 'Nothing was changed' }).Count -gt 0 -and -not (Test-Path (Join-Path $wDir 'another.tsv')) -and (Get-Temps).Count -eq 0 }
            & chmod 644 (Join-Path $wDir '.active')
        }
    }
    Remove-Item -LiteralPath (Join-Path $wDir '.active') -Force; Remove-Item -LiteralPath (Join-Path $wDir 'brandnew.tsv') -Force; Remove-Item -LiteralPath (Join-Path $wDir 'personal.tsv') -Force

    # use: validates every name before writing anything; picks several with -Multiple.
    Invoke-OpQuiet { op-env use guild }
    Invoke-OpQuiet { op-env use guild nosuch }
    chk 'use: an unknown set is an error and .active is unchanged' { $wErr.Count -gt 0 -and [System.IO.File]::ReadAllText((Join-Path $wDir '.active')) -ceq "guild`n" }
    $script:picks.Enqueue(@('guild')); Invoke-OpQuiet { op-env use }
    chk 'use with no names: asks with a multi-select picker' { [System.IO.File]::ReadAllText((Join-Path $wDir '.active')) -ceq "guild`n" }
    $script:picks.Enqueue(@()); Invoke-OpQuiet { op-env use }
    chk 'use with nothing chosen: no change' { $wOut -match 'No change' -and [System.IO.File]::ReadAllText((Join-Path $wDir '.active')) -ceq "guild`n" }
    Remove-Item -LiteralPath (Join-Path $wDir '.active') -Force

    # list: layout matches bash.
    Invoke-OpQuiet { op-env add acct SECRET1 'op://v/i/s1' main.1password.com }
    Invoke-OpQuiet { op-env add acct SECRET2 'op://v/i/s2' other.1password.com }
    Invoke-OpQuiet { op-env use guild }
    Invoke-OpQuiet { op-env list }
    chk 'list: marks sets active or inactive' { $wOut -match '● guild \(active\)' -and $wOut -match '○ acct \(inactive\)' }
    chk 'list: name column is 28 wide, the account only when it is not the default' { $wOut -match ('    ' + 'SECRET1'.PadRight(28) + ' op://v/i/s1\r?\n') -and $wOut -match ('    ' + 'SECRET2'.PadRight(28) + ' op://v/i/s2  \[account: other.1password.com\]') }
    Invoke-OpQuiet { op-env list guild }
    chk 'list <set>: only that set' { $wOut -match '● guild' -and $wOut -notmatch 'acct' }
    Invoke-OpQuiet { op-env list nosuch }
    chk 'list <unknown set>: an error' { $wErr.Count -gt 0 }

    # rm
    Remove-Item -LiteralPath (Join-Path $wDir '.active') -Force
    Invoke-OpQuiet { op-env rm acct SECRET1 }
    chk 'rm: removes the key, keeps the rest as written, and says how to unset it' { [System.IO.File]::ReadAllText((Join-Path $wDir 'acct.tsv')) -ceq "SECRET2`top://v/i/s2`tother.1password.com`n" -and $wOut -match 'Removed SECRET1 from acct' }
    chk 'rm: leaves no temp files and keeps mode 600' { (Get-Temps).Count -eq 0 -and ($IsWindows -or (Get-Mode (Join-Path $wDir 'acct.tsv')) -eq '600') }
    Invoke-OpQuiet { op-env rm acct NOSUCH }
    chk 'rm: an unknown variable is an error' { $wErr.Count -gt 0 }
    Invoke-OpQuiet { op-env rm nosuch X }
    chk 'rm: an unknown set is an error' { $wErr.Count -gt 0 }
    Invoke-OpQuiet { op-env rm acct SECRET2 }
    chk 'rm: removing the last key leaves an empty set file' { (Get-Item (Join-Path $wDir 'acct.tsv')).Length -eq 0 }
    Invoke-OpQuiet { op-env add acct SECRET2 'op://v/i/s2' }
    $script:picks.Clear(); $script:picks.Enqueue('acct'); $script:picks.Enqueue('SECRET2'); Invoke-OpQuiet { op-env rm }
    chk 'rm with no arguments: asks exactly twice (set, then variable)' { $script:picks.Count -eq 0 }
    chk 'rm with no arguments: picks the set, then the variable' { (Get-Item (Join-Path $wDir 'acct.tsv')).Length -eq 0 }

    # help, unknown commands, and no import noise
    Invoke-OpQuiet { op-env help }
    chk 'help: documents load, clear, add, list, rm and use' { $wOut -match 'op-env load \[set\.\.\.\]' -and $wOut -match 'op-env clear \[set\.\.\.\]' -and $wOut -match 'op-env use \[set\.\.\.\]' }
    Invoke-OpQuiet { op-env bogus }
    chk 'an unknown command is an error' { $wErr.Count -gt 0 }
    Remove-Item -LiteralPath $wDir -Recurse -Force -ErrorAction SilentlyContinue

    # Importing the module: no warnings (a function literally named op-env would warn about an
    # unapproved verb on every shell start), op-env is an alias, and the old names are gone.
    $pwshExe0 = (Get-Process -Id $PID).Path
    $imp = & $pwshExe0 -NoProfile -Command ("`$env:PREFLIGHT_CONFIG_DIR = '$(Join-Path $T 'impcfg')'; `$env:PREFLIGHT_STATE_DIR = '$(Join-Path $T 'impst')'; " +
        "`$w = Import-Module '$(Join-Path $Repo 'pwsh/Preflight.psd1')' -Force 3>&1 2>&1 | Out-String; " +
        "'WARN=[' + `$w.Trim() + ']'; 'TYPE=' + (Get-Command op-env).CommandType; " +
        "'OLD=' + [bool](Get-Command op-load-env -ErrorAction SilentlyContinue) + [bool](Get-Command op-clear-env -ErrorAction SilentlyContinue); " +
        "'EXPORTED=' + ((Get-Module Preflight).ExportedFunctions.Keys -contains 'Invoke-OpEnv')") 2>&1 | Out-String
    chk 'import: no warnings at all (no unapproved-verb warning)' { $imp -match 'WARN=\[\]' }
    chk 'import: op-env is an alias of Invoke-OpEnv'             { $imp -match 'TYPE=Alias' -and $imp -match 'EXPORTED=True' }
    chk 'import: op-load-env and op-clear-env no longer exist'    { $imp -match 'OLD=FalseFalse' }

    # ---- plugins -------------------------------------------------------------------
    $pdir = Join-Path $T 'plug'; New-Item -ItemType Directory -Path (Join-Path $pdir 'cfg') -Force | Out-Null
    $pimp = { param([string]$json)
        [System.IO.File]::WriteAllText((Join-Path $pdir 'cfg/config.json'), $json)
        Remove-Item -LiteralPath (Join-Path $pdir 'state') -Recurse -Force -ErrorAction SilentlyContinue
        & $pwshExe -NoProfile -Command ("`$env:PREFLIGHT_CONFIG_DIR = '$(Join-Path $pdir 'cfg')'; `$env:PREFLIGHT_STATE_DIR = '$(Join-Path $pdir 'state')'; " +
            "Import-Module '$(Join-Path $Repo 'pwsh/Preflight.psd1')' -Force; [bool](Get-Command Set-OwlTheme -ErrorAction SilentlyContinue)") 2>&1 | Out-String }
    $pwshExe = (Get-Process -Id $PID).Path
    $o = & $pimp '{"version":1}'
    chk 'plugins: nothing loads by default (no Set-OwlTheme, no warnings, no owl state)' { $o.Trim() -ceq 'False' -and -not (Test-Path (Join-Path $pdir 'state/owl')) }
    $o = & $pimp '{"version":1,"plugins":["owl"]}'
    chk 'plugins: one named in config.json loads (Set-OwlTheme exported)' { $o.Trim() -ceq 'True' }
    chk 'plugins: ...and seeds its base theme into the state dir' { Test-Path (Join-Path $pdir 'state/owl/theme-catppuccin.omp.json') }
    $o = & $pimp '{"version":1,"plugins":["nope","Bad Name"]}'
    chk 'plugins: an unknown or badly named plugin warns and the import still works' { $o -match "plugin 'nope' not found" -and $o -match "ignoring plugin" -and $o.Trim().EndsWith('False') }

    # ---- installer ---------------------------------------------------------------
    $ih = Join-Path $T 'ihome'; New-Item -ItemType Directory -Path $ih | Out-Null
    $prof = Join-Path $T 'profile.ps1'
    [System.IO.File]::WriteAllText($prof, "# mine`r`n# preflight:begin Import-Module guard`r`nif (-not (Test-Path -LiteralPath 'Env:OWL_OMP_CONFIG')) {`r`n    `$env:OWL_OMP_CONFIG = '/old/theme.json'`r`n}`r`nImport-Module x`r`n# preflight:end Import-Module guard`r`n")
    $pwshExe = (Get-Process -Id $PID).Path
    $inst = { & $pwshExe -NoProfile -File (Join-Path $Repo 'pwsh/install.ps1') -Force -InstallRoot (Join-Path $ih '.preflight') -ProfilePath $prof 2>&1 | Out-String }
    Reset-Env; $env:PREFLIGHT_CONFIG_DIR = Join-Path $ih 'cfg'; $env:PREFLIGHT_STATE_DIR = Join-Path $ih 'state'
    $o = & $inst
    chk 'install: seeds config.json from the general profile' { (Get-Content (Join-Path $ih 'cfg/config.json') -Raw) -ceq (Get-Content (Join-Path $Repo 'defaults/config.general.json') -Raw) }
    chk 'install: seeds no owl state (the owl plugin does that when enabled)' { -not (Test-Path (Join-Path $ih 'state/owl')) }
    $pc = Get-Content -LiteralPath $prof -Raw
    chk 'install: the profile guard sets no OWL_ variable, and an existing guard is replaced in place' { $pc -notmatch 'OWL_' -and $pc -match 'Import-Module' -and $pc -notmatch 'Import-Module x' }
    $before = $pc; $o = & $inst
    chk 'install: a second run changes nothing and keeps config.json' { (Get-Content -LiteralPath $prof -Raw) -ceq $before -and $o -match 'Config exists, kept' }
    Set-Content (Join-Path $ih 'cfg/config.json') '{"version":1,"op":{"account":"mine"}}' -NoNewline
    $o = & $inst
    chk 'install: an edited config.json is never overwritten' { (Get-Content (Join-Path $ih 'cfg/config.json') -Raw) -match 'mine' }
    $env:PREFLIGHT_CONFIG_DIR = Join-Path $ih '.preflight/inside'
    $o = & $inst
    chk 'install: refuses a config dir inside the install root, before touching anything' { $o -match 'Refusing' -and -not (Test-Path (Join-Path $ih '.preflight/inside')) }

    # ---- Update-Preflight must ship install.ps1 and defaults\, or re-running the installer from the
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
        # Make it look like a stale install: a stub installer and no defaults.
        Set-Content (Join-Path $uh 'pwsh/install.ps1') '# STALE INSTALLER'
        $ucfg = Join-Path $T 'ucfg'; $ust = Join-Path $T 'ust'

        $run = {
            param([string]$Command)
            & $pwshExe -NoProfile -Command ("`$env:PREFLIGHT_CONFIG_DIR = '$ucfg'; `$env:PREFLIGHT_STATE_DIR = '$ust'; " +
                "Import-Module '$(Join-Path $uh 'pwsh/Preflight.psd1')' -Force; $Command") 2>&1 | Out-String
        }
        $o = & $run "Update-Preflight -RepoUrl '$up' -DryRun"
        chk 'update: a dry run lists install.ps1 and the defaults' { $o -match 'would update: install.ps1' -and $o -match 'defaults.config.general.json' }
        chk 'update: a dry run changes nothing' { (Get-Content (Join-Path $uh 'pwsh/install.ps1') -Raw) -match 'STALE' -and -not (Test-Path (Join-Path $uh 'defaults')) }

        $o = & $run "Update-Preflight -RepoUrl '$up'"
        chk 'update: install.ps1 is replaced by the current installer' { (Get-Content (Join-Path $uh 'pwsh/install.ps1') -Raw) -ceq (Get-Content (Join-Path $Repo 'pwsh/install.ps1') -Raw) }
        chk 'update: the bundled defaults are delivered beside pwsh\' { (Test-Path (Join-Path $uh 'defaults/config.general.json')) -and (Test-Path (Join-Path $uh 'defaults/theme-catppuccin.omp.json')) }
        chk 'update: plugins\ are delivered too' { Test-Path (Join-Path $uh 'pwsh/plugins/owl.ps1') }
        chk 'update: user config is never written by an update' { -not (Test-Path (Join-Path $ucfg 'config.json')) }

        # The installer then runs from the installed tree, with no checkout.
        $uprof = Join-Path $T 'uprofile.ps1'
        [System.IO.File]::WriteAllText($uprof, "# mine`r`n")
        $o = & $pwshExe -NoProfile -Command ("`$env:PREFLIGHT_CONFIG_DIR = '$ucfg'; `$env:PREFLIGHT_STATE_DIR = '$ust'; " +
            "& '$(Join-Path $uh 'pwsh/install.ps1')' -Force -InstallRoot '$uh' -ProfilePath '$uprof'") 2>&1 | Out-String
        chk 'update then install: config.json is seeded from the delivered defaults' { Test-Path (Join-Path $ucfg 'config.json') }
        chk 'update then install: no owl state is seeded' { -not (Test-Path (Join-Path $ust 'owl')) }
        chk 'update then install: the profile guard is added and the rest of the profile kept' { $pc = Get-Content $uprof -Raw; $pc -match 'Import-Module' -and $pc -match '# mine' }
    } else {
        Write-Host 'skipped: Update-Preflight tests (git not installed)'
    }
} finally {
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$script:passes passed, $script:fails failed"
exit ([int]($script:fails -gt 0))
