# lib/aws.ps1 — AWS CLI helpers for Preflight.
#
# Mirrors lib/aws.sh on the bash side:
#   Set-AwsProfile   (aliases: awsp, switch-aws-profile)
#   Get-AwsIdentity  (alias: aws-whoami)
#   Connect-Aws      (alias: aws-login)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'User-facing CLI output; Write-Host is appropriate.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'ArgumentCompleter scriptblocks must accept the standard 5-arg signature even when individual parameters are unused.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns', '',
    Justification = 'AWS is an acronym, not a plural. Connect-Aws / Get-AwsIdentity / Set-AwsProfile read naturally to operators familiar with the AWS CLI.'
)]
param()

# ---- Shared helpers --------------------------------------------------------

function Test-AwsCli {
    if (Get-Command aws -ErrorAction SilentlyContinue) { return $true }
    Write-Error "AWS CLI ('aws') not found in PATH. Install AWS CLI v2 from https://aws.amazon.com/cli/"
    return $false
}

function Get-AwsProfileList {
    <#
    .SYNOPSIS
        Return the list of profiles defined in ~/.aws/config / ~/.aws/credentials.
        Wraps `aws configure list-profiles` so callers don't need to spawn the
        CLI directly.
    #>
    if (-not (Test-AwsCli)) { return @() }
    $output = & aws configure list-profiles 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($output | Where-Object { $_ })
}

# ---- Set-AwsProfile --------------------------------------------------------

function Set-AwsProfile {
    <#
    .SYNOPSIS
        Switch the active AWS profile by setting $env:AWS_PROFILE.
    .DESCRIPTION
        PowerShell sibling of the bash `awsp` / `switch-aws-profile`. Pass a
        profile name directly or pick interactively via Out-GridView / fzf /
        numbered prompt.

        Does NOT log in — sets the env var only. Use Connect-Aws to also run
        `aws sso login` against the chosen profile.
    .PARAMETER ProfileName
        Profile name to activate. If omitted, prompts interactively.
    .EXAMPLE
        Set-AwsProfile guild-prod-readonly
    .EXAMPLE
        awsp                        # interactive picker
    .EXAMPLE
        awsp guild-dev              # direct
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            Get-AwsProfileList |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    # Quote names with whitespace; AWS profile names rarely
                    # contain spaces but some teams use slashes/dots.
                    if ($_ -match '\s') { "'$_'" } else { $_ }
                }
        })]
        [string]$ProfileName
    )

    if (-not (Test-AwsCli)) { return }

    if (-not $ProfileName) {
        $profiles = Get-AwsProfileList
        if ($profiles.Count -eq 0) {
            Write-Error "No AWS profiles configured. Run 'aws configure sso' or edit ~/.aws/config."
            return
        }
        $ProfileName = $profiles | Select-FromList -Prompt 'Select AWS Profile'
    }

    if (-not $ProfileName) {
        Write-Host '⚠️  No profile selected.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess("`$env:AWS_PROFILE", "Set to '$ProfileName'")) { return }

    $env:AWS_PROFILE = $ProfileName
    Write-Host "✅ Switched to AWS profile: $env:AWS_PROFILE"
}

# ---- Get-AwsIdentity -------------------------------------------------------

function Get-AwsIdentity {
    <#
    .SYNOPSIS
        Show the current AWS profile, region, and caller identity.
    .DESCRIPTION
        Mirrors the bash `aws-whoami`. Prints $env:AWS_PROFILE, the configured
        region for that profile, and the output of `aws sts get-caller-identity`.

        Returns nothing on the pipeline; this is a status command, not a
        data-emitting one.
    .EXAMPLE
        Get-AwsIdentity
    .EXAMPLE
        aws-whoami
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-AwsCli)) { return }

    if ($env:AWS_PROFILE) {
        Write-Host "📍 Profile: $env:AWS_PROFILE"
    } else {
        Write-Host '⚠️  AWS_PROFILE not set'
    }

    # Region: scoped to the active profile if there is one, else the default.
    $region = if ($env:AWS_PROFILE) {
        & aws configure get region --profile $env:AWS_PROFILE 2>$null
    } else {
        & aws configure get region 2>$null
    }
    if ($region) { Write-Host "🌎 Region:  $region" }

    # Caller identity. Use --output table to match the bash version's UX.
    # On failure, distinguish "not signed in" from "auth error".
    $stsOutput = & aws sts get-caller-identity --output table 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ($stsOutput | Out-String).TrimEnd()
    } else {
        Write-Host '❌ Not authenticated or no valid credentials'
    }
}

# ---- Connect-Aws -----------------------------------------------------------

function Connect-Aws {
    <#
    .SYNOPSIS
        Run `aws sso login` against a profile (interactively pickable).
    .DESCRIPTION
        Mirrors the bash `aws-login`. Uses the given profile, falls back to
        $env:AWS_PROFILE, or offers interactive selection if neither is set.
        Sets $env:AWS_PROFILE to the resolved profile so subsequent commands
        in the same shell inherit it.
    .PARAMETER ProfileName
        Profile to log in with. Falls back to $env:AWS_PROFILE, then prompts.
    .EXAMPLE
        Connect-Aws guild-dev
    .EXAMPLE
        aws-login                  # uses $env:AWS_PROFILE or prompts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            Get-AwsProfileList |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }
        })]
        [string]$ProfileName
    )

    if (-not (Test-AwsCli)) { return }

    if (-not $ProfileName) { $ProfileName = $env:AWS_PROFILE }

    if (-not $ProfileName) {
        $profiles = Get-AwsProfileList
        if ($profiles.Count -eq 0) {
            Write-Error "No AWS profiles configured."
            return
        }
        $ProfileName = $profiles | Select-FromList -Prompt 'Select profile for SSO login'
    }

    if (-not $ProfileName) { return }

    $env:AWS_PROFILE = $ProfileName
    Write-Host "📍 Profile: $env:AWS_PROFILE"
    & aws sso login --profile $ProfileName
}

# ---- Aliases ---------------------------------------------------------------
# Match bash muscle memory: awsp, aws-whoami, aws-login.

Set-Alias -Name 'awsp'                -Value Set-AwsProfile  -Force -Scope Script
Set-Alias -Name 'switch-aws-profile'  -Value Set-AwsProfile  -Force -Scope Script
Set-Alias -Name 'aws-whoami'          -Value Get-AwsIdentity -Force -Scope Script
Set-Alias -Name 'aws-login'           -Value Connect-Aws     -Force -Scope Script
