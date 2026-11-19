/**
 * sound-notify — non-blocking sound notifications for OpenCode on WSL2.
 *
 * Fires sounds via a detached python3 dispatcher (sounds/notify.py) that
 * hands playback to Windows SoundPlayer. Spawns are fire-and-forget: never
 * awaited, stdio ignored, every handler wrapped in try/catch so a broken
 * player can never crash or block OpenCode.
 *
 * Mapping (all verified against live traces on 1.19.4):
 *   - question.wav    tool.execute.before, input.tool === "question".
 *                     Fires whenever the agent asks the user to pick options.
 *   - permission.wav  bus event "permission.asked". Fires whenever the TUI
 *                     shows any permission prompt (allow once / allow always /
 *                     reject), for ANY rule in permission.bash — not just git.
 *                     Choosing "allow always" stops future prompts, so the
 *                     sound correctly stops with them.
 *   - complete.wav    bus event "session.idle" (top-level sessions only).
 *   - error.wav       bus event "session.error", excluding MessageAbortedError
 *                     (user cancellation stays silent).
 *
 * Duplicate guard: OpenCode 1.19.4 delivers hook calls and bus events more
 * than once per occurrence, which produced stacked overlapping audio. Sounds
 * are therefore deduplicated by event/permission id within a short window.
 */

import type { Plugin } from "@opencode-ai/plugin"
import type { Event } from "@opencode-ai/sdk"

type SoundEvent = "complete" | "question" | "permission" | "error"

const PYTHON = "python3"
const NOTIFY_PY = `${import.meta.dir}/sounds/notify.py`
const DEDUPE_WINDOW_MS = 3000

/** Fire-and-forget spawn of the dispatcher. Never awaits the child. */
function play(event: SoundEvent): void {
  try {
    Bun.spawn([PYTHON, NOTIFY_PY, event], {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
    })
  } catch {
    // Never let a broken player affect the agent.
  }
}

export default (async () => {
  // Sub-agent sessions (Task tool) also emit session.idle; track them so
  // complete.wav only fires when the MAIN agent goes idle awaiting the user.
  const subAgentSessions = new Set<string>()

  // Duplicate suppression: key -> first-seen timestamp.
  const seen = new Map<string, number>()
  function firstTime(key: string): boolean {
    try {
      const now = Date.now()
      for (const [k, at] of seen) {
        if (now - at > DEDUPE_WINDOW_MS) seen.delete(k)
      }
      if (seen.has(key)) return false
      seen.set(key, now)
      return true
    } catch {
      return true
    }
  }

  return {
    event: async ({ event }: { event: Event }) => {
      try {
        switch (event.type) {
          case "session.created": {
            const { id, parentID } = event.properties.info
            if (parentID) subAgentSessions.add(id)
            return
          }
          case "session.deleted": {
            subAgentSessions.delete(event.properties.info.id)
            return
          }
          case "session.idle": {
            if (subAgentSessions.has(event.properties.sessionID)) return
            if (!firstTime(`idle:${event.properties.sessionID}`)) return
            play("complete")
            return
          }
          case "session.error": {
            // User cancellation (ESC / Ctrl+C abort) surfaces as
            // MessageAbortedError — must stay silent per requirement.
            if (event.properties.error?.name === "MessageAbortedError") return
            play("error")
            return
          }
          case "permission.asked": {
            // Any permission prompt: bash rules, external directory, trust
            // dialogs — whatever requires the user to answer.
            const id = String(event.properties.id ?? "")
            if (!firstTime(`perm:${id}`)) return
            play("permission")
            return
          }
        }
      } catch {
        // Never let a handler failure break the event bus.
      }
    },

    "tool.execute.before": async (input: { tool: string; callID?: string }) => {
      try {
        if (input.tool !== "question") return
        if (!firstTime(`question:${input.callID ?? ""}`)) return
        play("question")
      } catch {
        // Never let a handler failure break the tool pipeline.
      }
    },
  }
}) satisfies Plugin
