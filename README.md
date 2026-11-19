# opencode-sound-notify

Non-blocking sound notifications for [OpenCode](https://opencode.ai) on WSL2.

An OpenCode plugin hooks the session event bus and a thin Python dispatcher hands
each WAV to Windows `SoundPlayer`. Every spawn is fire-and-forget, so a broken or
missing audio player can never block, slow down, or crash the agent.

## Sounds

You supply the audio. This repository ships **no** sound files: name your own
clips after the event they should play.

| File | Fires when |
|---|---|
| `complete.wav` | `session.idle` on the main session (a turn finished) |
| `question.wav` | the agent invokes the `question` tool |
| `permission.wav` | any `permission.asked` prompt appears |
| `error.wav` | `session.error`, excluding user cancellation |

Drop them in `~/.config/opencode/plugins/sounds/` or import a folder:

```bash
./install.sh --sounds ~/Downloads/my-sounds
```

The importer expects `<event>.<ext>` and accepts `wav`, `mp3`, `m4a`, `ogg` and
`flac`. Non-WAV inputs are converted with `ffmpeg` when it is available;
`SoundPlayer` only plays WAV, so without `ffmpeg` you must convert them
yourself. Conversion happens at install time, never per notification, so
playback latency stays untouched.

Check what is installed at any time:

```bash
./install.sh --check-sounds
```

Missing files are reported as `MISSING` and produce exit code 1. The plugin
stays silent for a missing sound instead of failing, so this check is the way
to tell "not configured" apart from "broken".

Sub-agent sessions also emit `session.idle`; the plugin tracks them so only the
main agent going idle plays `complete.wav`. Duplicate deliveries within a short
window are suppressed so audio never stacks.

## Requirements

- WSL2 with Windows interop enabled (`powershell.exe` reachable from Linux)
- OpenCode 1.19.x
- `python3` in `PATH`
- `ffmpeg` (optional: converts non-WAV sources to WAV)
- `gh` or `curl` (only for `--from-release` / `--check`)

Native Linux and macOS are not supported: there is no `powershell.exe` and no
`/mnt/c`.

## Install from a clone

```bash
git clone https://github.com/GitJDGT/opencode-sound-notify.git
cd opencode-sound-notify
./install.sh --sounds ~/Downloads/my-sounds
```

Without `--sounds` the plugin installs silently with no audio; run
`--check-sounds` afterwards to confirm the four files are in place.

Optional: also install the `opencode` launcher wrapper, which plays `error.wav`
when the CLI itself exits with a failure (the plugin cannot cover a crash at
startup):

```bash
./install.sh --with-wrapper
```

The wrapper goes to `~/.local/bin/opencode` and must resolve before the real
binary in `PATH`. It locates the real binary by absolute path
(`~/.opencode/bin/opencode`) and never recurses; override with
`OPENCODE_REAL_BIN=/path/to/opencode`.

## Install or update from a release

```bash
./install.sh --from-release              # latest tag
./install.sh --from-release v1.0.0       # pinned
./install.sh --from-release v1.0.0 --checksum <sha256>
./install.sh --from-release --via gh      # force gh, fail if not authenticated
```

Transport defaults to `auto`: `gh` when installed and authenticated, then a
public `curl` fallback with `--via curl`. Public repositories need no
authentication; a private fork needs `gh auth login`.

Check what you have:

```bash
./install.sh --check
```

Reinstalling or updating always backs up the files it replaces, so a downgrade
is just another `--from-release`. Restart OpenCode afterwards so the new plugin
is loaded.

## Verify

```bash
python3 ~/.config/opencode/plugins/sounds/notify.py complete
```

If nothing plays, check interop first:

```bash
command -v powershell.exe
wslpath -w ~/.config/opencode/plugins/sounds/complete.wav
powershell.exe -NoProfile -Command "(New-Object System.Media.SoundPlayer '$(wslpath -w ~/.config/opencode/plugins/sounds/complete.wav)').PlaySync()"
```

Restart OpenCode after installing so the plugin is loaded.

## Uninstall

```bash
./install.sh --uninstall
```

Removal is manifest-driven: the installer records every path it created in
`~/.config/opencode/.sound-notify-installed` and only ever removes those, each
after a timestamped backup. A `sounds/` directory that still holds files you
dropped in yourself is kept, with a warning. Uninstalling can never delete your
own audio.

## Layout

```
plugin/sound-notify.ts       OpenCode plugin (event bus + question hook)
plugin/sounds/notify.py      WSL2 dispatcher (wslpath + PowerShell SoundPlayer)
plugin/sounds/*              Your audio (gitignored; not distributed)
bin/opencode                 Optional PATH wrapper with error sound
install.sh                   Installer (local, release, sounds, checks, uninstall)
VERSION                      Version written into the install manifest
```

`install.sh` writes `~/.config/opencode/.sound-notify-installed`, a plain-text
manifest with the version, the source and one `file=` line per managed path.
Every file it replaces is backed up as `<name>.bak-<timestamp>`. For a preview
without touching anything, add `--dry-run` to any install or uninstall command.

## Publishing (maintainer)

```bash
git init
git add -A
git commit -m "feat: opencode sound notifications with bring-your-own sounds"
gh repo create opencode-sound-notify --public --source . --remote origin --push
git tag v1.0.0
git push origin v1.0.0
```

Audio is excluded by `.gitignore`, so a public push ships code only. The
maintainer's own sounds stay on disk and are simply never committed. If you want
them versioned as a personal backup, keep a separate private repository or
archive — do not force-add them here.

`--from-release` works from the tag tarball alone; no release workflow is
required. Keep the tag scheme `vX.Y.Z` so `--check` and `--from-release` keep
resolving.

## Notes

- On some setups `~/.config/opencode` is a symlink to `~/.opencode`. The
  installer writes through the symlink, so the real files land in the target.
- The plugin assumes Bun (bundled with OpenCode) for `Bun.spawn`.
- Sounds are intentionally short and non-blocking; `notify.py` always exits 0.
- The maintainer's own sounds come from [SoundShelfStudio](https://pixabay.com/es/users/soundshelfstudio-46480698/)
  via Pixabay. They are not distributed here: the Pixabay Content License
  forbids redistributing the audio on a standalone basis. Pick sounds you have
  the rights to use.

## License

MIT — see [LICENSE](LICENSE). Applies to the code in this repository only.

