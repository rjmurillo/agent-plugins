# measure-twice

Measure twice, cut once. A configurable end-of-turn review gate for Copilot CLI.

Instructions can ask the agent to review its own work, but the agent can forget.

## Installation

```
/plugin marketplace add MattKotsenas/agent-plugins
/plugin install measure-twice@agent-plugins
```

Hooks load when the CLI starts, so restart your session after installing.

## Modes

On or off is per session. Enabling or disabling flips only the current session; setting the default changes what
new sessions start from. Both go through `/measure-twice`:

- **This session**: enable or disable.
- **Default for new sessions**: set the default, or manage it in `config.json` (below). It ships as `on`, so an
  installed gate works immediately.

Turn the current session off for a quiet interactive stretch.

## Configuring the review prompt

The prompt injected on each block is yours to set. The default names no specific reviewers; name your own so the
agent knows exactly what to run. Set it through `/measure-twice`, or manage `config.json` from your dotfiles to keep
it under version control:

```json
{
  "defaultMode": "on",
  "prompt": "Run rubber-duck and iron-shrike, then address any Critical or High findings."
}
```

The home config holds the prompt and the new-session default. It lives in `<COPILOT_HOME>/measure-twice/config.json`
(by default `~/.copilot/measure-twice/config.json`), outside the plugin directory, so it survives plugin updates and
is safe to symlink from dotfiles. Each session's own on/off and gate state live in that session's folder.

## How it works

`scripts/gate.ps1` is registered on the Copilot CLI `sessionStart`, `agentStop`, and `userPromptSubmitted` events.
When the gate is active and the agent tries to finish:

1. `agentStop` blocks with your review prompt and a Measure Twice sentinel when no request is already outstanding
   and no other stop-hook continuation is active.
2. Copilot chooses one blocking hook response and submits it as the continuation prompt.
3. `userPromptSubmitted` marks the gate delivered when the submitted prompt contains the Measure Twice sentinel.
4. The next stop consumes that delivery. Stops while a request remains pending do not enqueue another one.
5. Starting a session or explicitly enabling the gate clears stale pending state.

Measure Twice gates only the main agent. Reviewer and other subagent stops do not create additional review
continuations.

## Requirements

- PowerShell (the gate is a PowerShell script; Windows PowerShell 5.1 or PowerShell 7+)
- Copilot CLI 1.0.72 or later

## Limits

The gate defends against forgetting, not deliberate evasion. A later blocking hook can prevent the review prompt
from being delivered. Measure Twice leaves that request pending instead of retrying and filling the prompt queue;
restart the session or explicitly enable the gate to rearm it.
