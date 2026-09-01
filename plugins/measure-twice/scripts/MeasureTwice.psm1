#requires -Version 5.1
<#
Gate logic for measure-twice, in small functions each easy to test on its own.
The home config lives under <COPILOT_HOME>/measure-twice; each session's on/off
and gate state live in that session's own folder.
#>

$script:DefaultPrompt = 'A review gate is active. If this turn produced anything you are presenting to the user - code, a document, a PR description, a review comment - run your review agents now and address any Critical or High findings before finishing. If this turn was pure investigation with nothing to hand over, just proceed.'
$script:ReviewPromptSentinel = '<!-- measure-twice:review-request -->'

function Get-MTCopilotHome {
    if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
}

function Get-MTConfigPath {
    Join-Path (Join-Path (Get-MTCopilotHome) 'measure-twice') 'config.json'
}

function Get-MTSessionDir {
    # Control commands use COPILOT_AGENT_SESSION_ID; hooks supply their session ID.
    # Returns $null when neither is available so callers never change global state.
    param([string]$SessionId = $env:COPILOT_AGENT_SESSION_ID)
    if ($SessionId) {
        return Join-Path (Join-Path (Get-MTCopilotHome) 'session-state') $SessionId
    }
    $null
}

function Test-MTMainAgentStop {
    param([string]$SessionId, [string]$TranscriptPath)
    if (-not ($SessionId -and $TranscriptPath)) { return $false }
    $transcriptSessionDir = Split-Path $TranscriptPath -Parent
    if (-not $transcriptSessionDir) { return $false }
    $transcriptSessionId = Split-Path $transcriptSessionDir -Leaf
    $SessionId.Equals($transcriptSessionId, [StringComparison]::OrdinalIgnoreCase)
}

function Get-MTConfig {
    # Home config: the review prompt and the default on/off for new sessions. An
    # unreadable or corrupt file falls back to defaults rather than a null config.
    param([string]$ConfigPath)
    $config = [PSCustomObject]@{ defaultMode = 'on'; prompt = $script:DefaultPrompt }
    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($loaded) { $config = $loaded }
        } catch { }
    }
    if (-not $config.PSObject.Properties['defaultMode']) { $config | Add-Member -NotePropertyName defaultMode -NotePropertyValue 'on' -Force }
    if (-not $config.PSObject.Properties['prompt']) { $config | Add-Member -NotePropertyName prompt -NotePropertyValue $script:DefaultPrompt -Force }
    $config
}

function Save-MTConfig {
    # Write in place so a symlinked config.json (managed from dotfiles) keeps its
    # link; never remove-and-recreate, which would swap the link for a plain file.
    # Throws on failure so a control command never reports a save that did not happen.
    param($Config, [string]$ConfigPath)
    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath -Parent) -ErrorAction Stop | Out-Null
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8 -ErrorAction Stop
}

function Get-MTSessionMode {
    # This session's effective on/off: the session override if set, else the home
    # default. An override file that exists but is unreadable or holds an invalid
    # value fails closed to 'on' - better to over-gate than to silently skip a
    # session someone configured on purpose. $SessionDir may be $null.
    param([string]$SessionDir, [string]$DefaultMode)
    if ($SessionDir) {
        $path = Join-Path $SessionDir 'measure-twice-mode.json'
        if (Test-Path $path) {
            try { $mode = [string](Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).mode } catch { return 'on' }
            if ($mode -eq 'on' -or $mode -eq 'off') { return $mode }
            return 'on'
        }
    }
    $DefaultMode
}

function Set-MTSessionMode {
    # Throws on failure so -enable / -disable never claim a change that did not persist.
    param([string]$SessionDir, [string]$Mode)
    New-Item -ItemType Directory -Force -Path $SessionDir -ErrorAction Stop | Out-Null
    [PSCustomObject]@{ mode = $Mode } | ConvertTo-Json | Set-Content -Path (Join-Path $SessionDir 'measure-twice-mode.json') -Encoding UTF8 -ErrorAction Stop
}

function Get-MTGateStatePath {
    param([string]$SessionDir)
    Join-Path $SessionDir 'measure-twice-gate-state.json'
}

function Set-MTReviewPromptState {
    param(
        [ValidateSet('pending', 'delivered')][string]$State,
        [string]$StatePath
    )
    New-Item -ItemType Directory -Force -Path (Split-Path $StatePath -Parent) -ErrorAction Stop | Out-Null
    [PSCustomObject]@{ state = $State } |
        ConvertTo-Json |
        Set-Content -Path $StatePath -Encoding UTF8 -ErrorAction Stop
}

function Register-MTReviewPromptDelivery {
    param([string]$Prompt, [string]$StatePath)
    if (-not ($Prompt -and $Prompt.Contains($script:ReviewPromptSentinel))) { return }
    Set-MTReviewPromptState -State delivered -StatePath $StatePath
}

function Get-MTReviewPromptState {
    param([string]$StatePath)
    if (-not (Test-Path $StatePath)) { return $null }
    $json = Get-Content $StatePath -Raw -ErrorAction Stop
    if ($json.TrimStart().StartsWith('[')) { throw "Invalid Measure Twice gate state at $StatePath" }
    $state = $json | ConvertFrom-Json -ErrorAction Stop
    if ($state -is [PSCustomObject] -and
        $state.state -is [string] -and
        @('pending', 'delivered') -ccontains $state.state) {
        return [string]$state.state
    }
    throw "Invalid Measure Twice gate state at $StatePath"
}

function Clear-MTGateState {
    param([string]$StatePath)
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force -ErrorAction Stop }
}

function Invoke-WithMTGateLock {
    param(
        [string]$StatePath,
        [scriptblock]$Action,
        [int]$TimeoutMilliseconds = 5000
    )

    New-Item -ItemType Directory -Force -Path (Split-Path $StatePath -Parent) -ErrorAction Stop | Out-Null
    $lockPath = "$StatePath.lock"
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $stream = $null
    while (-not $stream) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 50
        }
    }

    try { & $Action } finally { $stream.Dispose() }
}

function Invoke-MTGate {
    <#
    Emits at most one block while a review prompt is outstanding. A submitted
    sentinel authorizes one stop, regardless of stop_hook_active.
    #>
    param($Config, [bool]$StopHookActive, [string]$StatePath)

    $reason = "$($Config.prompt)`n`n$script:ReviewPromptSentinel"
    switch (Get-MTReviewPromptState -StatePath $StatePath) {
        'delivered' {
            Clear-MTGateState -StatePath $StatePath
            return $null
        }
        'pending' { return $null }
    }

    if ($StopHookActive) { return $null }
    Set-MTReviewPromptState -State pending -StatePath $StatePath
    $reason
}

Export-ModuleMember -Function Get-MTCopilotHome, Get-MTConfigPath, Get-MTSessionDir, Test-MTMainAgentStop, Get-MTConfig, Save-MTConfig, Get-MTSessionMode, Set-MTSessionMode, Get-MTGateStatePath, Register-MTReviewPromptDelivery, Clear-MTGateState, Invoke-WithMTGateLock, Invoke-MTGate
