# Troubleshooting

Operational notes that do not belong in the README: quirks of OpenCode's event
bus, prompts that never reach the plugin, and how to instrument the plugin when
a sound refuses to fire.

## A sound never fires, but playback works

Verify the dispatcher first:

```bash
python3 ~/.config/opencode/plugins/sounds/notify.py complete
```

If that is audible, the plugin or the event is the problem, not audio.

## Permission prompts never sound

Symptom: `git commit` runs with no prompt and `permission.wav` stays silent.

Cause: a `permission.bash` rule set to `"ask"` is silently overridden for any
agent that defines its own `permission` block **without** a `bash` entry.
OpenCode fills missing tool permissions with `allow` after the global rules, and
the last matching rule wins.

Inspect the resolved rules:

```bash
opencode debug agent <your-agent>
```

Fix: declare `bash` explicitly inside the agent, broad rule first and narrow
rules last:

```json
{
  "permission": {
    "bash": {
      "*": "allow",
      "git commit *": "ask",
      "git push": "ask",
      "git push *": "ask",
      "git push --force *": "ask",
      "git rebase *": "ask",
      "git reset --hard *": "ask"
    }
  }
}
```

Note that `git -C /path commit` does **not** match the `git commit *` pattern,
so it never prompts and never plays a sound.

## Instrumenting the plugin

When an event seems missing, stop guessing and trace it. Add this to the plugin,
restart OpenCode, reproduce, then remove it:

```ts
import { appendFileSync } from "node:fs"

const TRACE_LOG = "/tmp/sound-notify-events.log"

function trace(message: string): void {
  try {
    appendFileSync(TRACE_LOG, `${new Date().toISOString()} ${message}\n`)
  } catch {}
}
```

Trace every `event.type` in `event()`, each `tool.execute.before` call
(`input.tool` and the argument keys), and every `play()` invocation.

Inspecting the binary is also useful when an event is suspected to be dead:

```bash
grep -ao 'permission\.[a-zA-Z_]*' ~/.opencode/bin/opencode | sort -u
```

## Known limitations

- **`permission.ask` hook is dead**: present in the 1.19.4 binary, never invoked
  by the TUI. Do not build on it.
- **Duplicate delivery**: hooks and bus events arrive more than once per
  occurrence. Deduplication is mandatory or sounds stack on top of each other.
- **Tool errors that do not abort the turn emit no `session.error`**, so no
  `error.wav` for them. Only a hard abort reaches that event, and user
  cancellation (`MessageAbortedError`) is excluded on purpose.
- **"Allow always" removes the prompt, therefore the sound**, for that rule
  from then on. That is expected behavior, not a bug.
- **New-directory trust dialog** is expected to arrive as `permission.asked` but
  is unverified.
- **Spawn latency**: if PowerShell is slow to start, a cue can lag a few tens of
  milliseconds. It never blocks the agent.

## Sound design (optional)

The player never depends on this; a missing or oddly mastered file is simply
quieter. For cues that sit beside Windows audio without competing:

- 16-bit PCM WAV
- ~20% nominal amplitude
- target RMS around 300-370 with peaks at 5-8% of full scale

## Manual cleanup

The installer removes what it installed, with backups. If you installed by hand
before that existed, the files are:

```
~/.config/opencode/plugins/sounds/
~/.config/opencode/plugins/sound-notify.ts
~/.local/bin/opencode        # only if you installed the wrapper
```

Remove those three paths. Restore `~/.local/bin/opencode` if it held something
else before.
