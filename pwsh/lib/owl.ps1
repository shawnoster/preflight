# lib/owl.ps1 — Obtusely Optimistic Owl: theme engine + MOTD splash.
#
# PowerShell sibling of bash lib/owl.sh. Provides:
#
#   Set-OwlTheme [-Name <theme>] [-List] [-Current]   (alias: owl-theme)
#   Show-OwlSplash                                    — opt-in MOTD; no auto-fire
#
# Design choices that diverge from bash:
#
# 1. Splash is opt-in. Bash unconditionally splashes on every top-level shell
#    via init.sh. The PowerShell port doesn't auto-fire — users add
#    `Show-OwlSplash` to their $PROFILE after `Import-Module Preflight` if
#    they want it. A PowerShell user already has an OMP banner, possibly
#    posh-git, Terminal-Icons, etc.; adding a 4-line owl on top of that
#    every new tab/window crosses into "noisy" territory.
#
# 2. OMP config patching uses a USER-OWNED copy. The bash version writes
#    back to whatever path OWL_OMP_CONFIG points at. On Windows, $PROFILE
#    typically references `$env:POSH_THEMES_PATH/<theme>.omp.json` which is
#    Microsoft's shared theme directory. We refuse to mutate that. Default
#    path is $HOME\.preflight\state\owl\amro.omp.json; user copies their
#    chosen base theme there once via:
#       Copy-Item "$env:POSH_THEMES_PATH\amro.omp.json" `
#                 "$HOME\.preflight\state\owl\amro.omp.json"
#    Set-OwlTheme refuses to mutate any path under $env:POSH_THEMES_PATH.
#
# Theme state persists at $HOME\.preflight\state\owl\current (path
# separators shown Windows-style; resolved cross-platform via Join-Path).
# Configuration overrides:
#   $env:OWL_THEME_DIR   — state directory (default: $HOME\.preflight\state\owl)
#   $env:OWL_OMP_CONFIG  — path to user-owned OMP JSON (optional)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Show-OwlSplash and Set-OwlTheme are intentionally colorized status panels with ANSI-truecolor escapes; Write-Host preserves the host UI.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Set-OwlTheme persists a single text file (the theme name) and optionally rewrites a user-owned OMP JSON. -WhatIf semantics on a theme switch would be theatrical, not useful.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingInvokeExpression', '',
    Justification = '`oh-my-posh init pwsh` emits PowerShell code that must be eval-d to install the prompt — this is the documented invocation pattern (mirrors what most PowerShell users have in $PROFILE).'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'ArgumentCompleter scriptblocks must accept the standard 5-arg signature. -List is also a parameter-set discriminator (no body usage required).'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns', '',
    Justification = 'Set-OwlEnvColors sets four related env vars (Body/Eyes/Text/Sub) atomically — plural noun reflects the unit of work.'
)]
param()

# ---- Theme catalog ---------------------------------------------------------
# Each theme entry has:
#   Label    — human-readable display name
#   Icon     — emoji glyph patched into the OMP first text segment
#   Body / Eyes / Text / Sub — RGB triplets for the splash and panels
#   Omp.{cat,err,git,node,ok,path,python,yarn} — hex colors for the OMP palette

$script:OwlThemes = [ordered]@{
    catppuccin = @{
        Label = 'Catppuccin Warm'
        Icon  = "$([char]0xD83D)$([char]0xDC31)"  # 🐱
        Body = '196;112;63'    ; Eyes = '250;179;135'
        Text = '205;214;244'   ; Sub  = '108;112;134'
        Omp = @{
            cat = '#CDD6F4'; path   = '#89DCEB'; git  = '#A6E3A1'
            node= '#89B4FA'; python = '#F9E2AF'; yarn = '#F5C2E7'
            ok  = '#A6E3A1'; err    = '#F38BA8'
        }
    }
    honeypot = @{
        Label = 'Honeypot Gold'
        Icon  = "$([char]0xD83C)$([char]0xDF6F)"  # 🍯
        Body = '180;130;50'    ; Eyes = '245;210;110'
        Text = '222;198;158'   ; Sub  = '160;145;115'
        Omp = @{
            cat = '#DEC69E'; path   = '#E8C872'; git  = '#C8B86A'
            node= '#D4A44C'; python = '#F0C878'; yarn = '#E0B868'
            ok  = '#C8B86A'; err    = '#D08040'
        }
    }
    twilight = @{
        Label = 'Twilight Feathers'
        Icon  = "$([char]0xD83E)$([char]0xDD89)"  # 🦉
        Body = '120;95;145'    ; Eyes = '240;195;120'
        Text = '180;170;205'   ; Sub  = '130;120;155'
        Omp = @{
            cat = '#B4A0D0'; path   = '#9E8EC0'; git  = '#A8C090'
            node= '#8EA0D0'; python = '#F0C378'; yarn = '#C8A0C8'
            ok  = '#A8C090'; err    = '#D07878'
        }
    }
    moonlit = @{
        Label = 'Moonlit Branch'
        Icon  = "$([char]0xD83C)$([char]0xDF19)"  # 🌙
        Body = '108;112;164'   ; Eyes = '180;190;254'
        Text = '170;175;220'   ; Sub  = '120;125;160'
        Omp = @{
            cat = '#B4BEFE'; path   = '#94A0E8'; git  = '#8CC0A8'
            node= '#7EA0E0'; python = '#C8B8E0'; yarn = '#A8A0D8'
            ok  = '#8CC0A8'; err    = '#C87888'
        }
    }
    autumn = @{
        Label = 'Autumn Roost'
        Icon  = "$([char]0xD83C)$([char]0xDF42)"  # 🍂
        Body = '160;90;70'     ; Eyes = '230;160;90'
        Text = '210;175;140'   ; Sub  = '150;120;95'
        Omp = @{
            cat = '#D2AF8C'; path   = '#C89868'; git  = '#A8B070'
            node= '#C0885A'; python = '#E0B870'; yarn = '#D09870'
            ok  = '#A8B070'; err    = '#C86050'
        }
    }
    rose = @{
        Label = 'Dusty Rose'
        Icon  = "$([char]0xD83C)$([char]0xDF38)"  # 🌸
        Body = '160;110;130'   ; Eyes = '235;175;185'
        Text = '215;185;195'   ; Sub  = '150;125;138'
        Omp = @{
            cat = '#EBAFB9'; path   = '#D8A0B0'; git  = '#B0C0A0'
            node= '#C098B8'; python = '#E0C0A8'; yarn = '#D0A0C0'
            ok  = '#B0C0A0'; err    = '#D07080'
        }
    }
    moss = @{
        Label = 'Lichen & Moss'
        Icon  = "$([char]0xD83C)$([char]0xDF3F)"  # 🌿
        Body = '90;130;95'     ; Eyes = '170;220;150'
        Text = '160;195;155'   ; Sub  = '110;140;108'
        Omp = @{
            cat = '#AADC96'; path   = '#88C890'; git  = '#90C880'
            node= '#78B890'; python = '#C8D890'; yarn = '#A0C8A0'
            ok  = '#90C880'; err    = '#C88868'
        }
    }
    parchment = @{
        Label = 'Parchment & Ink'
        Icon  = "$([char]0xD83D)$([char]0xDCDC)"  # 📜
        Body = '139;119;101'   ; Eyes = '222;198;158'
        Text = '190;180;165'   ; Sub  = '140;132;120'
        Omp = @{
            cat = '#BEB4A5'; path   = '#C8B898'; git  = '#A8B098'
            node= '#B0A898'; python = '#D0C0A0'; yarn = '#C0B0A0'
            ok  = '#A8B098'; err    = '#C89070'
        }
    }
}

# ---- Quote pools (verbatim from bash _owl_splash) --------------------------
# Mood face pairs: two ASCII glyphs forming the eye row "(L,R)".
# Faces: alert=(o,o), sleepy=(-,-), happy=(^,^), suspicious=(o,O), winking=(o,-).

$script:OwlQuotes = [ordered]@{
    alert = @{
        Face = 'oo'
        Pool = @(
            'The branch holds you because you forgot to fall.'
            'The mouse is busy. The owl is ready.'
            'You can see very far from a place of stillness.'
            'I happen to know a thing or two about things or two.'
            'The customary procedure is to begin. I believe I have mentioned this before.'
            'It is precisely the sort of morning where something could be accomplished, and I intend to witness it.'
            'One does not simply arrive at wisdom. One was already here.'
            'I have consulted my references and they agree with me, as they usually do.'
            'Start where you are. Use what you have. Fly when ready.'
            'Athena chose the owl not for its wisdom but for its willingness to stay up and do the work.'
        )
    }
    sleepy = @{
        Face = '--'
        Pool = @(
            'The hollow is warm enough. It was always warm enough.'
            'People say nothing is impossible, but I do nothing every day.'
            'I was not napping. I was considering the matter with my eyes closed.'
            'The best time to plant a tree was twenty years ago. The second best time is after this cup of tea.'
            'Resting is merely thinking in a more horizontal direction.'
            'I have been awake for some time, I should think. The evidence is inconclusive.'
            'A wise owl once said nothing at all and went back to sleep. It was me. Just now.'
            'One cannot rush the dawn. I have tried, and it does not listen.'
            'Feathers keep you warm whether you notice them or not.'
            'The sun came back. It does that. I shall do the same presently.'
        )
    }
    happy = @{
        Face = '^^'
        Pool = @(
            'As I was saying — and I do say it rather well — things are looking up.'
            'The Japanese call the owl fukurō — luck bird. It has been sitting here this whole time.'
            'A little consideration, a little thought for others, makes all the difference.'
            'Everything is going according to the plan I have just now devised.'
            'I should think this is what they call a capital day. I have spelled it correctly.'
            'One does occasionally get things right. I find it happens to me more than most.'
            'The forest is in order. I have inspected it from this branch.'
            'Trees grow slowly. Nobody complains about trees.'
            "Owl hadn't exactly been given his spelling, but it had come to him."
            "I believe the word is 'splendid.' Or possibly 'speldnid.' In any case, this."
        )
    }
    suspicious = @{
        Face = 'oO'
        Pool = @(
            'Something is afoot. Or possibly a-wing. I am investigating.'
            'The owl does not boast of its night vision to the rooster. It simply sees.'
            'According to the Talmud, the owl sees what others overlook. Mostly because everyone else is asleep.'
            "I don't wish to alarm anyone but that is not where I left that branch."
            'One cannot be too careful. Unless one is me, in which case one is precisely careful enough.'
            'I have noticed a thing. I shall continue to notice it until it explains itself.'
            "If you wait until you're ready, you'll be waiting for the rest of your life. — Lemony Snicket, who was definitely an owl"
            'There is a draft. I suspect Piglet has left something open again.'
            'My uncle Robert once saw something very like this. It turned out to be nothing, but impressively so.'
            'One cannot fly into flying. — Lakota proverb, probably'
        )
    }
    winking = @{
        Face = 'o-'
        Pool = @(
            'Between you and me — and I trust you to keep this between us — today is going to be fine.'
            "I probably shouldn't tell you this, but the secret to wisdom is showing up."
            "This is strictly confidential, but I believe in you. Don't let it get around."
            'Shall I let you in on something? The mice never see me coming. Nor do the deadlines.'
            'I have it on good authority — mine — that everything will sort itself out.'
            'Not everyone can do what we do. Mostly because they are asleep. But still.'
            "I have a system. I shan't describe it, but rest assured it is working."
            'Begin at the beginning, and go on till you come to the end: then stop.'
            "I used to be indecisive. Now I'm not so sure."
            'Keep this between us, but the moon is just the sun being dramatic.'
        )
    }
}

# ---- Internal helpers ------------------------------------------------------

function Get-OwlStateDir {
    if ($env:OWL_THEME_DIR) { return $env:OWL_THEME_DIR }
    # Build the default path with chained Join-Path calls so PowerShell
    # uses the platform-correct separator. Embedding `\` in a literal
    # would create a single directory named ".preflight\state\owl" on
    # POSIX rather than a nested tree.
    return (Join-Path (Join-Path (Join-Path $HOME '.preflight') 'state') 'owl')
}

function Get-OwlOmpConfigPath {
    # User-owned OMP config. If $env:OWL_OMP_CONFIG points anywhere under
    # $env:POSH_THEMES_PATH, we treat the OMP integration as disabled —
    # we don't mutate Microsoft's shared themes.
    if (-not $env:OWL_OMP_CONFIG) { return $null }

    $themesRoot = $env:POSH_THEMES_PATH
    if ($themesRoot) {
        try {
            $configFull = (Resolve-Path -LiteralPath $env:OWL_OMP_CONFIG -ErrorAction SilentlyContinue).Path
            $themesFull = (Resolve-Path -LiteralPath $themesRoot -ErrorAction SilentlyContinue).Path
            if ($configFull -and $themesFull -and $configFull.StartsWith($themesFull, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Verbose "OWL_OMP_CONFIG points inside POSH_THEMES_PATH — skipping OMP patching to avoid mutating shared themes."
                return $null
            }
        } catch {
            # Path resolution failed (one or both paths invalid). Fall
            # through and treat $env:OWL_OMP_CONFIG as given — if it's
            # bad, Update-OmpPaletteForTheme's downstream Test-Path /
            # Get-Content will surface the real error.
            Write-Verbose "Get-OwlOmpConfigPath: path resolution failed: $_"
        }
    }
    return $env:OWL_OMP_CONFIG
}

function Set-OwlEnvColors {
    <#
    .SYNOPSIS
        Export $env:OWL_BODY/EYES/TEXT/SUB so other lib code can read them.
    #>
    param([hashtable]$Theme)
    $env:OWL_BODY = $Theme.Body
    $env:OWL_EYES = $Theme.Eyes
    $env:OWL_TEXT = $Theme.Text
    $env:OWL_SUB  = $Theme.Sub
}

function Update-OmpPaletteForTheme {
    <#
    .SYNOPSIS
        Patch the user's OMP JSON config with the theme's palette + icon.
    .DESCRIPTION
        PowerShell sibling of bash _owl_patch_omp. Reads the JSON, replaces
        the palette object, replaces the first text segment's template
        with the theme icon, atomically writes back. Refuses to touch
        Microsoft's shared theme directory (see Get-OwlOmpConfigPath).
    #>
    param([hashtable]$Theme)

    $configPath = Get-OwlOmpConfigPath
    if (-not $configPath) { return }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Verbose "OWL_OMP_CONFIG file not found: $configPath"
        return
    }

    try {
        $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "Owl theme: failed to parse OMP config as JSON: $_"
        return
    }

    # Replace the palette object outright. Bash version uses the same
    # eight keys; we mirror them exactly so the OMP segments resolve.
    $json['palette'] = @{
        cat    = $Theme.Omp.cat;    path   = $Theme.Omp.path
        git    = $Theme.Omp.git;    node   = $Theme.Omp.node
        ok     = $Theme.Omp.ok;     err    = $Theme.Omp.err
        python = $Theme.Omp.python; yarn   = $Theme.Omp.yarn
    }

    # Update icon in the first text segment of the first block. Defensive
    # traversal — OMP JSON structures vary; if anything's missing we just
    # skip the icon update silently.
    if ($json.ContainsKey('blocks') -and $json.blocks.Count -gt 0) {
        $firstBlock = $json.blocks[0]
        if ($firstBlock -is [hashtable] -and $firstBlock.ContainsKey('segments')) {
            foreach ($seg in $firstBlock.segments) {
                if ($seg -is [hashtable] -and $seg['type'] -eq 'text') {
                    $seg['template'] = "$($Theme.Icon) "
                    break
                }
            }
        }
    }

    # Atomic write: write to a temp file in the same directory, then rename.
    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $configPath).Path
    $tmp = Join-Path $dir ".owl-omp-$([guid]::NewGuid()).tmp"
    try {
        $json | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $configPath -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-OwlSavedThemeName {
    <#
    .SYNOPSIS
        Read the persisted theme name from disk; default to catppuccin.
    #>
    $stateFile = Join-Path (Get-OwlStateDir) 'current'
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        $name = (Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue) -replace '\s+', ''
        if ($name -and $script:OwlThemes.Contains($name)) { return $name }
    }
    return 'catppuccin'
}

function Initialize-OwlTheme {
    <#
    .SYNOPSIS
        Module-load hook: read the saved theme and export $env:OWL_* colors.
        Called by Preflight.psm1; not exported.
    #>
    $name = Get-OwlSavedThemeName
    $theme = $script:OwlThemes[$name]
    if ($theme) { Set-OwlEnvColors -Theme $theme }
}

# ---- Public: Set-OwlTheme --------------------------------------------------

function Set-OwlTheme {
    <#
    .SYNOPSIS
        List, query, or switch OOO themes.
    .DESCRIPTION
        PowerShell sibling of bash `owl-theme`. Without args, lists all
        themes with a colored sample. With -Current, prints the active
        theme name. With a positional theme name (or -Name), persists
        the selection, exports $env:OWL_* colors, optionally patches a
        user-owned OMP config, and prints a preview.

        Themes: catppuccin, honeypot, twilight, moonlit, autumn, rose,
        moss, parchment.

        Run `Set-OwlTheme -List` (or just `owl-theme`) to see them all.
    .PARAMETER Name
        Theme to activate. Accepts Tab-completion via ArgumentCompleter.
    .PARAMETER List
        Show all themes with a colored sample row each. Default behavior
        when no args are given.
    .PARAMETER Current
        Print the active theme name and exit (matches bash `owl-theme --current`).
    .EXAMPLE
        owl-theme
    .EXAMPLE
        owl-theme moonlit
    .EXAMPLE
        Set-OwlTheme -Current
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Name')]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $script:OwlThemes.Keys | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string]$Name,

        [Parameter(ParameterSetName = 'List')]
        [switch]$List,

        [Parameter(ParameterSetName = 'Current')]
        [switch]$Current
    )

    $reset = "`e[0m"

    # --- mode: -Current ---
    if ($Current) {
        Write-Output (Get-OwlSavedThemeName)
        return
    }

    # --- mode: -List or no args ---
    if (-not $Name) {
        $active = Get-OwlSavedThemeName
        Write-Host ''
        Write-Host '  ' -NoNewline
        Write-Host 'OOO Themes' -ForegroundColor White
        Write-Host ''
        foreach ($key in $script:OwlThemes.Keys) {
            $t = $script:OwlThemes[$key]
            $body = "`e[38;2;$($t.Body)m"
            $eyes = "`e[38;2;$($t.Eyes)m"
            $marker = if ($key -eq $active) { "`e[1m▸ `e[0m" } else { '  ' }
            $line = "  $marker$body($eyes`o$body,$eyes`o$body)$reset  {0,-12} {1}  $($t.Icon)" -f $key, $t.Label
            Write-Host $line
        }
        Write-Host ''
        Write-Host '  Usage: ' -NoNewline
        Write-Host 'Set-OwlTheme <name>' -ForegroundColor White -NoNewline
        Write-Host ' (or: owl-theme <name>)'
        Write-Host ''
        return
    }

    # --- mode: switch ---
    $theme = $script:OwlThemes[$Name]
    if (-not $theme) {
        Write-Host "  Unknown theme: $Name"
        Write-Host ('  Available: ' + ($script:OwlThemes.Keys -join ', '))
        return
    }

    # Persist selection.
    $stateDir = Get-OwlStateDir
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $stateDir 'current') -Value $Name -Encoding UTF8 -NoNewline

    # Patch OMP (no-op if OWL_OMP_CONFIG isn't set, doesn't exist, or
    # points inside POSH_THEMES_PATH).
    Update-OmpPaletteForTheme -Theme $theme

    # Export colors for splash + future Invoke-Preflight integration.
    Set-OwlEnvColors -Theme $theme

    # Reload OMP into the current shell so the prompt flips immediately.
    $configPath = Get-OwlOmpConfigPath
    if ($configPath -and (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
        & oh-my-posh init pwsh --config $configPath | Invoke-Expression
    }

    # Preview.
    $body = "`e[38;2;$($theme.Body)m"
    $eyes = "`e[38;2;$($theme.Eyes)m"
    $text = "`e[38;2;$($theme.Text)m"
    $sub  = "`e[38;2;$($theme.Sub)m"

    Write-Host ''
    Write-Host "  $body ___ $reset"
    Write-Host "  $body($eyes`o$body,$eyes`o$body)$reset     $sub`Switched to $($theme.Label).$reset"
    Write-Host "  $body{`"'`}$reset"
    Write-Host "  $body-`"-`"-$reset     $text`The owl approves.$reset"
    Write-Host ''
}

# ---- Public: Show-OwlSplash ------------------------------------------------

function Show-OwlSplash {
    <#
    .SYNOPSIS
        Print the OOO MOTD splash (owl + quote + date/uptime).
    .DESCRIPTION
        Opt-in MOTD. Add this to your $PROFILE after Import-Module Preflight
        if you want the owl on every new shell:

            Import-Module Preflight
            Show-OwlSplash

        Quotes are drawn from one of five mood pools (alert, sleepy, happy,
        suspicious, winking) chosen at random; each mood has its own eye-pair
        face and 10 quotes. Colors come from the active theme — uses
        $env:OWL_* (set by Initialize-OwlTheme on module load) when available.
    .EXAMPLE
        Show-OwlSplash
    #>
    [CmdletBinding()]
    param()

    $reset = "`e[0m"
    $rust  = "`e[38;2;$($env:OWL_BODY ?? '196;112;63')m"
    $peach = "`e[38;2;$($env:OWL_EYES ?? '250;179;135')m"
    $text  = "`e[38;2;$($env:OWL_TEXT ?? '205;214;244')m"
    $sub   = "`e[38;2;$($env:OWL_SUB  ?? '108;112;134')m"

    # Pick a mood at random, then a quote at random from that mood's pool.
    $moods = @($script:OwlQuotes.Keys)
    $moodKey = $moods[(Get-Random -Maximum $moods.Count)]
    $mood = $script:OwlQuotes[$moodKey]
    $eyeL = $mood.Face[0]
    $eyeR = $mood.Face[1]
    $quote = $mood.Pool[(Get-Random -Maximum $mood.Pool.Count)]

    $wrapped = Format-WrappedText -Text $quote -IndentColumn 12

    $dateStr   = (Get-Date).ToString('dddd, MMMM d')
    $uptimeStr = ''
    try {
        # LastBootUpTime via CIM — works on PS 7+ Windows. On non-Windows,
        # this fails silently and we just don't show uptime.
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $up = (Get-Date) - $boot
        $uptimeStr = if ($up.TotalDays -ge 1) {
            '{0}d {1}h {2}m' -f [int]$up.TotalDays, $up.Hours, $up.Minutes
        } elseif ($up.TotalHours -ge 1) {
            '{0}h {1}m' -f [int]$up.TotalHours, $up.Minutes
        } else {
            '{0}m' -f [int]$up.TotalMinutes
        }
    } catch {
        Write-Verbose "Show-OwlSplash: uptime unavailable on this platform: $_"
    }

    Write-Host ''
    Write-Host "  $rust ___ $reset"
    Write-Host "  $rust($peach$eyeL$rust,$peach$eyeR$rust)$reset     $sub$wrapped$reset"
    Write-Host "  $rust{`"'`}$reset"
    if ($uptimeStr) {
        Write-Host "  $rust-`"-`"-$reset     $text$dateStr$reset $sub`· ↑ $uptimeStr$reset"
    } else {
        Write-Host "  $rust-`"-`"-$reset     $text$dateStr$reset"
    }
    Write-Host ''
}

# ---- Aliases ---------------------------------------------------------------
Set-Alias -Name 'owl-theme' -Value Set-OwlTheme -Force -Scope Script

# ---- Module-load hook ------------------------------------------------------
# Read the saved theme name and export $env:OWL_* colors so the splash
# inherits them. No splash auto-fire — opt-in only (see docstring above).
Initialize-OwlTheme
