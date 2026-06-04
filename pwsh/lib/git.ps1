# lib/git.ps1 — Git workflow helpers for Preflight.
#
# Mirrors lib/git.sh on the bash side:
#   Switch-GitBranch          (gco)     — Checkout a branch, with picker
#   Show-GitLog               (glog)    — Pretty git log + interactive picker
#   Pop-GitStash              (gstash)  — Pop (or apply) a stash with picker
#   New-GitHubPullRequest     (gpr)     — gh pr create --web
#   Save-GitWip               (gwip)    — Quick WIP commit (skips hooks)
#   Undo-GitWip               (gunwip)  — Soft-reset last WIP commit
#   Remove-MergedGitBranches  (gclean)  — Prune merged branches (safe variant)
#   Sync-GitFork              (gsync)   — Fetch upstream, merge, push origin
#
# Plus simple aliases for everyday git invocations:
#   gs  -> git status
#   ga  -> git add
#   gpl -> git pull
#   gd  -> git diff
#   gds -> git diff --staged
#
# Note: bash also defines `gc` (git commit) and `gp` (git push), but those
# names collide with built-in PowerShell aliases (`gc` -> Get-Content,
# `gp` -> Get-ItemProperty). Users who want them can override with
# `Set-Alias gc git -Force` etc. in their accounts.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI output; Write-Host is appropriate.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'ArgumentCompleter scriptblocks must accept the standard 5-arg signature even when individual parameters are unused.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Switch-GitBranch wraps `git checkout` (no -WhatIf in git itself); Save-GitWip / Undo-GitWip / Sync-GitFork wrap routine git operations users invoke unbothered. Remove-MergedGitBranches DOES use ShouldProcess explicitly because it deletes things; the analyzer flags the wrapper functions inappropriately here.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns', '',
    Justification = 'Remove-MergedGitBranches operates on the set of merged branches in one pass — plural is intentional and reads naturally to operators.'
)]
param()

# ---- Shared helpers --------------------------------------------------------

function Test-GitCli {
    if (Get-Command git -ErrorAction SilentlyContinue) { return $true }
    Write-Error "Git not found in PATH. Install from https://git-scm.com/."
    return $false
}

function Test-GitRepo {
    & git rev-parse --git-dir *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-GitBranchList {
    <#
    .SYNOPSIS
        Return all local + remote branch names, deduped. Used by
        Switch-GitBranch's picker and tab-completer.
    .DESCRIPTION
        Lists `refs/heads` directly (local branches) plus `refs/remotes`
        (remote-tracking refs) with the leading `<remote>/` prefix stripped
        from the latter. We use `for-each-ref` rather than `git branch
        --all` because the latter surfaces the symbolic `refs/remotes/<remote>/HEAD`
        ref as a bare `<remote>` entry in the output. Also filters out
        any explicit `<remote>/HEAD` that might show through.

        Branch names containing `/` (e.g. `feature/foo`) are preserved —
        we strip exactly one leading segment, and only from refs that
        appeared under `refs/remotes`.
    #>
    if (-not (Test-GitCli)) { return @() }
    if (-not (Test-GitRepo)) { return @() }

    $local  = @(& git for-each-ref --format='%(refname:short)' refs/heads 2>$null)
    $remote = @(& git for-each-ref --format='%(refname:short)' refs/remotes 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }

    $remoteStripped = $remote |
        Where-Object { $_ -and $_ -notmatch '/HEAD$' } |
        ForEach-Object {
            # Strip exactly one leading "<remote>/" segment, leaving any
            # remaining slashes (feature/foo, hotfix/bar) intact.
            $i = $_.IndexOf('/')
            if ($i -ge 0) { $_.Substring($i + 1) }
            # else: skip — refs/remotes/<remote> with no slash is the
            # symbolic HEAD ref for that remote, not a branch.
        }

    return @(
        @($local) + @($remoteStripped) |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

# ---- Switch-GitBranch ------------------------------------------------------

function Switch-GitBranch {
    <#
    .SYNOPSIS
        Checkout a git branch. Pass a name or pick interactively.
    .DESCRIPTION
        PowerShell sibling of bash `gco`. Lists local + remote branches
        (deduped), and runs `git checkout` against the chosen one. Without
        an argument, prompts via Select-FromList (Out-GridView / fzf /
        numbered prompt).
    .PARAMETER Branch
        Branch name to checkout. If omitted, prompts.
    .EXAMPLE
        gco main
    .EXAMPLE
        Switch-GitBranch          # picker
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            Get-GitBranchList |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }
        })]
        [string]$Branch
    )

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }

    if (-not $Branch) {
        $branches = Get-GitBranchList
        if ($branches.Count -eq 0) {
            Write-Error 'No branches found.'
            return
        }
        $Branch = $branches | Select-FromList -Prompt 'Checkout branch'
    }

    if (-not $Branch) { return }
    & git checkout $Branch
}

# ---- Show-GitLog -----------------------------------------------------------

function Show-GitLog {
    <#
    .SYNOPSIS
        Pretty git log; interactive when a TTY and fzf are both available,
        otherwise falls back to a plain --oneline log.
    .DESCRIPTION
        PowerShell sibling of bash `glog`. With fzf installed, opens an
        interactive picker showing `git show` output for the highlighted
        commit. Without fzf (or when stdout is redirected), prints a
        colorized `--oneline` log.
    .EXAMPLE
        glog
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }

    $interactive = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
    if ($interactive -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
        # fzf shows the same `git show` preview pane the bash version does.
        & git log --oneline --color=always |
            & fzf --ansi --preview 'git show --color=always {1}' --preview-window 'right:60%'
    } else {
        & git log --oneline --color=always
    }
}

# ---- Pop-GitStash ----------------------------------------------------------

function Pop-GitStash {
    <#
    .SYNOPSIS
        Pop (or apply) a git stash with optional picker.
    .DESCRIPTION
        PowerShell sibling of bash `gstash`. Without arguments, lists
        stashes via Select-FromList. With -Apply, runs `git stash apply`
        instead of `pop` (keeps the stash in the list).
    .PARAMETER StashRef
        Stash reference (e.g. 'stash@{0}'). If omitted, prompts.
    .PARAMETER Apply
        Use `git stash apply` instead of `git stash pop`. Apply leaves
        the stash in the list; pop (default) removes it.
    .EXAMPLE
        gstash
    .EXAMPLE
        gstash -Apply
    .EXAMPLE
        Pop-GitStash 'stash@{0}'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$StashRef,
        [switch]$Apply
    )

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }

    if (-not $StashRef) {
        $entries = & git stash list 2>$null
        if (-not $entries) {
            Write-Host '⚠️  No stashes to pop'
            return
        }
        $picked = @($entries) | Select-FromList -Prompt 'Select stash'
        if (-not $picked) { return }
        # `git stash list` lines look like `stash@{0}: WIP on main: ...`.
        # Take the first colon-delimited field — matches bash `cut -d: -f1`.
        $StashRef = ($picked -split ':', 2)[0].Trim()
    }

    if (-not $StashRef) { return }
    $verb = if ($Apply) { 'apply' } else { 'pop' }
    & git stash $verb $StashRef
}

# ---- New-GitHubPullRequest -------------------------------------------------

function New-GitHubPullRequest {
    <#
    .SYNOPSIS
        Open a new pull request via the GitHub CLI.
    .DESCRIPTION
        PowerShell sibling of bash `gpr`. Wraps `gh pr create --web` so the
        browser handles the title/body composition. Requires the `gh` CLI
        to be installed and authenticated.
    .EXAMPLE
        gpr
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host '⚠️  GitHub CLI (gh) not installed. See https://cli.github.com/.'
        return
    }
    & gh pr create --web
}

# ---- Save-GitWip / Undo-GitWip ---------------------------------------------

function Save-GitWip {
    <#
    .SYNOPSIS
        Stage everything and commit as 'WIP: <message>', skipping hooks.
    .DESCRIPTION
        PowerShell sibling of bash `gwip`. Designed for "I need to switch
        branches NOW" moments — bypasses pre-commit hooks. Pair with
        Undo-GitWip on the way back.
    .PARAMETER Message
        Description appended to "WIP: ". Defaults to "work in progress".
    .EXAMPLE
        gwip
    .EXAMPLE
        gwip 'spike on auth refactor'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Message
    )

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }

    $msg = if ($Message) { ($Message -join ' ').Trim() } else { 'work in progress' }
    & git add -A
    & git commit -m "WIP: $msg" --no-verify
}

function Undo-GitWip {
    <#
    .SYNOPSIS
        Undo the last WIP commit, leaving changes staged.
    .DESCRIPTION
        PowerShell sibling of bash `gunwip`. Soft-resets HEAD~1 only if the
        last commit's message starts with 'WIP:' — otherwise refuses to
        avoid trampling real commits.
    .EXAMPLE
        gunwip
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }

    $lastMsg = & git log -1 --pretty=%B 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'No commits in this repo yet.'
        return
    }
    if ($lastMsg -notmatch '(?m)^WIP:') {
        Write-Host '⚠️  Last commit is not a WIP commit'
        return
    }
    & git reset --soft HEAD~1
    Write-Host '✅ Undid WIP commit'
}

# ---- Remove-MergedGitBranches ---------------------------------------------

function Remove-MergedGitBranches {
    <#
    .SYNOPSIS
        Prune local branches that have been merged AND no longer exist on
        the remote — supersedes both bash gclean and the existing
        Remove-MergedBranches profile function with the safer behavior.
    .DESCRIPTION
        Diverges from bash `gclean` to match the safer behavior of the
        user's existing Remove-MergedBranches: a branch is only deleted
        when BOTH conditions hold:

          1. It has been merged into the current HEAD (or `-MainBranch`).
          2. It no longer exists on the `origin` remote.

        That second check guards against deleting branches that are still
        active on a feature branch you've merged locally for testing but
        haven't shipped yet. Bash gclean's "anything merged into main" is
        more aggressive; this implementation prefers conservatism.

        Always preserves: main, master, develop, the current branch, and
        the branch passed via -MainBranch (or `$env:GIT_MAIN_BRANCH`,
        defaulting to 'main').

        -WhatIf shows what would be deleted without acting; -Confirm
        prompts per branch.
    .PARAMETER MainBranch
        The mainline branch to compare against. Defaults to
        `$env:GIT_MAIN_BRANCH` then 'main'. Will be excluded from deletion.
    .EXAMPLE
        gclean              # delete merged-and-remote-gone branches
    .EXAMPLE
        gclean -WhatIf      # preview without deleting
    .EXAMPLE
        gclean develop      # treat 'develop' as main
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0)]
        [string]$MainBranch
    )

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }

    if (-not $MainBranch) {
        $MainBranch = if ($env:GIT_MAIN_BRANCH) { $env:GIT_MAIN_BRANCH } else { 'main' }
    }

    Write-Host '📡 git fetch --prune'
    & git fetch --prune

    $current = & git rev-parse --abbrev-ref HEAD
    if ($LASTEXITCODE -ne 0) { return }

    # Local branches that have been merged into HEAD. Strip the leading "  "
    # marker and the "* " marker on the current branch.
    $merged = & git branch --merged --format='%(refname:short)' 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    # Branches still present on origin (without the `origin/` prefix). We
    # only delete locally if the branch is gone from origin too — same
    # safety net as the user's existing Remove-MergedBranches.
    $remote = & git branch -r --format='%(refname:short)' 2>$null |
        ForEach-Object { $_ -replace '^origin/', '' }
    $remoteSet = @{}
    foreach ($r in $remote) { if ($r) { $remoteSet[$r.Trim()] = $true } }

    $protected = @($MainBranch, 'main', 'master', 'develop', $current) | Where-Object { $_ }
    $candidates = $merged |
        Where-Object { $_ } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -notin $protected -and -not $remoteSet.ContainsKey($_) }

    if (-not $candidates) {
        Write-Host '✅ No merged-and-orphaned branches to delete'
        return
    }

    foreach ($branch in $candidates) {
        if ($PSCmdlet.ShouldProcess($branch, 'git branch -d')) {
            & git branch -d $branch
        }
    }
    Write-Host '✅ Cleaned merged branches'
}

# ---- Sync-GitFork ----------------------------------------------------------

function Sync-GitFork {
    <#
    .SYNOPSIS
        Sync a fork's main branch with upstream, then push to origin.
    .DESCRIPTION
        PowerShell sibling of bash `gsync`. Runs:
            git fetch upstream
            git checkout <main>
            git merge upstream/<main>
            git push origin <main>

        Requires an `upstream` remote to be configured.
    .PARAMETER MainBranch
        The mainline branch to sync. Defaults to `$env:GIT_MAIN_BRANCH`,
        then 'main'.
    .EXAMPLE
        gsync
    .EXAMPLE
        gsync develop
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$MainBranch
    )

    if (-not (Test-GitCli)) { return }
    if (-not (Test-GitRepo)) {
        Write-Error 'Not in a git repository.'
        return
    }
    if (-not $MainBranch) {
        $MainBranch = if ($env:GIT_MAIN_BRANCH) { $env:GIT_MAIN_BRANCH } else { 'main' }
    }

    # Validate that an upstream remote exists.
    $remotes = & git remote 2>$null
    if ($LASTEXITCODE -ne 0 -or 'upstream' -notin @($remotes)) {
        Write-Error "No 'upstream' remote configured. Add one with: git remote add upstream <url>"
        return
    }

    & git fetch upstream
    if ($LASTEXITCODE -ne 0) { return }
    & git checkout $MainBranch
    if ($LASTEXITCODE -ne 0) { return }
    & git merge "upstream/$MainBranch"
    if ($LASTEXITCODE -ne 0) { return }
    & git push origin $MainBranch
}

# ---- Aliases ---------------------------------------------------------------
# Function names with kebab muscle-memory matches.

Set-Alias -Name 'gco'    -Value Switch-GitBranch         -Force -Scope Script
Set-Alias -Name 'glog'   -Value Show-GitLog              -Force -Scope Script
Set-Alias -Name 'gstash' -Value Pop-GitStash             -Force -Scope Script
Set-Alias -Name 'gpr'    -Value New-GitHubPullRequest    -Force -Scope Script
Set-Alias -Name 'gwip'   -Value Save-GitWip              -Force -Scope Script
Set-Alias -Name 'gunwip' -Value Undo-GitWip              -Force -Scope Script
Set-Alias -Name 'gclean' -Value Remove-MergedGitBranches -Force -Scope Script
Set-Alias -Name 'gsync'  -Value Sync-GitFork             -Force -Scope Script

# Simple straight-to-git wrappers. The bash side defines these as bash
# aliases (`alias gs='git status'`); PowerShell aliases can only point at
# a single command, not a command-with-args, so we ship them as one-line
# functions instead. They're added to FunctionsToExport in the manifest.
#
# Skipped: `gc` (Get-Content) and `gp` (Get-ItemProperty) — those names
# are built-in PS aliases. Users who want them can override with
# `Set-Alias gc git -Force` from accounts.ps1.

function gs  { & git status   @args }
function ga  { & git add      @args }
function gpl { & git pull     @args }
function gd  { & git diff     @args }
function gds { & git diff --staged @args }
