# Porting to another agent

This project is two layers: a portable dispatcher and an agent-specific adapter.
Porting to a new agent means writing a new adapter; the dispatcher, the sounds
and the install discipline stay as they are.

```
agent hooks ──► adapter (per agent) ──► notify.py ──► powershell.exe ──► speaker
```

## The dispatcher contract

The only interface between an adapter and the transport is one command:

```bash
python3 notify.py <complete|question|permission|error>
```

Guarantees an adapter may rely on:

- exits `0` on every path, including invalid arguments and missing files
- never blocks, prints, or waits for playback
- a missing WAV is silence, not an error
- no knowledge of any agent, session, or hook system

## Event semantics

Name the events by meaning, not by the hook that supplies them.

| Event | Meaning |
|---|---|
| `complete` | the agent finished a turn and waits for the human |
| `question` | the agent asks the human to choose between options |
| `permission` | an approval prompt is on screen and needs an answer |
| `error` | a hard failure; **excludes** user cancellation |

## Adapter invariants

These four are what make a port pleasant instead of annoying:

1. **Cancellation is not an error.** A user abort (Ctrl+C, ESC) must stay
   silent. Map only genuine failures to `error`.
2. **Child sessions are not `complete`.** Delegated or sub-agent sessions often
   emit the same "finished" event. Without filtering, every worker plays a
   chime. Track session ids with a parent and skip them.
3. **Deduplicate.** Several agents deliver the same hook and bus event more than
   once per occurrence, which stacks audio. Key by event or call id inside a
   short window (3 s is what this adapter uses).
4. **Spawn detached and never throw.** Fire-and-forget, stdio ignored, every
   handler wrapped. A broken player must not be able to break the host's event
   loop.

## Platform requirements

- WSL2 with interop enabled: WSL's own audio is a dummy sink, so playback must
  go through Windows
- `powershell.exe` reachable from Linux
- `python3` in `PATH`
- `SoundPlayer` plays WAV only; convert other formats at install time
- the distro name comes from `WSL_DISTRO_NAME`, never hardcoded

## Locating the dispatcher

Resolve `notify.py` **relative to the adapter**, not by absolute path. That is
what lets the same code run from `~/.config/opencode/plugins`, from a git clone,
or from an extracted release tarball. In the OpenCode adapter it is
`import.meta.dir`; a shell-based adapter can use its own script directory.

## Minimal adapter skeleton

```text
on agent_turn_finished(session)  -> if not child(session): play("complete")
on agent_question(call)          -> if first(call):            play("question")
on agent_permission(id)          -> if first(id):              play("permission")
on agent_failure(error)          -> if not cancelled(error):   play("error")
```

Everything else in an adapter is bookkeeping for those four lines: parent
tracking, dedupe windows, and locating the script.

## Acceptance checklist

A port is done when all six hold:

1. `python3 notify.py complete` plays standalone, outside the agent.
2. A question from the agent plays `question` exactly once.
3. A permission prompt plays `permission` exactly once.
4. Finishing a turn plays `complete` exactly once.
5. Cancelling with Ctrl+C stays silent.
6. A delegated sub-agent finishing stays silent.
7. Deleting one WAV keeps the agent working and that one cue silent.

## Known per-agent differences

| Agent | Integration surface |
|---|---|
| OpenCode | TypeScript plugin, `event` bus plus `tool.execute.before`, auto-discovered from `plugins/` |
| Antigravity CLI | `hooks.json` plus `plugin.json` with pre-tool and stop hooks |

The hook names, the delivery guarantees and the registration mechanism differ in
every case; the four invariants above do not.

One warning that is not about this project: OpenCode can silently disable its own
`permission.bash: "ask"` rules when an agent defines a `permission` block without
a `bash` entry. Then no prompt appears and `permission.wav` never fires. See
[troubleshooting.md](troubleshooting.md) for the diagnosis and the fix.
