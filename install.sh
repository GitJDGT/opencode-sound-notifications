#!/usr/bin/env bash
# sound-notify installer for OpenCode on WSL2.
#
# Two install sources:
#   1. local   -- copy from this checkout (default)
#   2. release -- download a tagged tarball from GitHub Releases
#
# Nothing is deleted without a timestamped backup next to the original.
set -euo pipefail

REPO="${SOUND_NOTIFY_REPO:-GitJDGT/opencode-sound-notify}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins"
SOUNDS_DIR="$PLUGIN_DIR/sounds"
BIN_DIR="${XDG_BIN:-$HOME/.local/bin}"
MARKER="$CONFIG_DIR/.sound-notify-installed"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="local"
WITH_WRAPPER=0
DRY_RUN=0
RELEASE_TAG=""
CHECKSUM=""
VIA="auto"
SOUNDS_SRC=""
SOUND_EVENTS=(complete question permission error)
INSTALLED_FILES=()
DL_TMP=""
trap 'if [ -n "$DL_TMP" ]; then rm -rf "$DL_TMP"; fi' EXIT

usage() {
  cat <<'USAGE'
sound-notify installer (OpenCode on WSL2)

Usage:
  ./install.sh [options]

Options:
  --with-wrapper          Also install the ~/.local/bin/opencode wrapper
  --sounds <dir>          Import your own sounds named <event>.<ext>
                          (event = complete|question|permission|error;
                           mp3/m4a/ogg/flac need ffmpeg to become WAV)
  --check-sounds          Report which of the four sounds are installed
  --from-release [tag]    Install from a GitHub release tag (e.g. v1.0.0)
                          Omit the tag to use the latest release.
  --checksum <sha256>     Verify the downloaded tarball against this digest
  --via auto|gh|curl      Download transport (default: auto = gh first, then curl)
  --check                 Print installed version and latest release, then exit
  --uninstall             Remove the files this installer manages
  --dry-run               Show what would happen, change nothing
  -h, --help              Show this help

Examples:
  ./install.sh
  ./install.sh --sounds ~/Downloads/pixabay-sounds
  ./install.sh --check-sounds
  ./install.sh --with-wrapper
  ./install.sh --from-release v1.0.0 --checksum <sha256>
  ./install.sh --from-release                       # private repo: uses gh
  ./install.sh --from-release --via curl            # public repo, no gh needed
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

backup_if_exists() {
  local target="$1"
  [ -e "$target" ] || return 0
  local backup="${target}.bak-$(date +%Y%m%dT%H%M%S)"
  run cp -a "$target" "$backup"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] backup: $backup"; else log "backup: $backup"; fi
}

preflight() {
  local ok=0

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found in PATH; the dispatcher needs it"
    ok=1
  fi
  if ! command -v powershell.exe >/dev/null 2>&1; then
    warn "powershell.exe not found; sound playback requires WSL2 with interop enabled"
    ok=1
  fi
  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    warn "WSL_DISTRO_NAME is empty; this plugin targets WSL2, not native Linux"
  fi
  return "$ok"
}

installed_version() {
  [ -f "$MARKER" ] || { printf 'none\n'; return 0; }
  sed -n 's/^version=//p' "$MARKER" | head -1
}

# Ownership manifest: every path this installer created or replaced. Uninstall
# only touches these, so user-supplied sounds are never deleted by accident.
record_file() { INSTALLED_FILES+=("$1"); }

marker_write() {
  local version="unknown"
  [ -f "$SRC/VERSION" ] && version="$(head -1 "$SRC/VERSION" | tr -d '[:space:]')"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write manifest $MARKER (version $version, ${#INSTALLED_FILES[@]} files)"
    return 0
  fi

  {
    printf 'version=%s\n' "$version"
    printf 'source=%s\n' "$MODE"
    printf 'installed_at=%s\n' "$(date -Iseconds)"
    local f
    if [ "${#INSTALLED_FILES[@]}" -gt 0 ]; then
      for f in "${INSTALLED_FILES[@]}"; do
        printf 'file=%s\n' "$f"
      done
    fi
  } > "$MARKER"
}

check_sounds() {
  local missing=0 ev
  for ev in "${SOUND_EVENTS[@]}"; do
    if [ -f "$SOUNDS_DIR/$ev.wav" ]; then
      log "  ok       $ev.wav"
    else
      log "  MISSING  $ev.wav"
      missing=$((missing + 1))
    fi
  done
  return "$missing"
}

convert_one() {
  local src="$1" dest="$2"
  command -v ffmpeg >/dev/null 2>&1 || return 2
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ffmpeg convert $(basename "$src") -> $(basename "$dest")"
    return 0
  fi
  ffmpeg -y -loglevel error -i "$src" "$dest"
}

# Case-insensitive lookup so files coming from Windows (Complete.WAV) still
# match. Echoes the first hit, or nothing.
find_sound() {
  local dir="$1" ev="$2"
  find "$dir" -maxdepth 1 -type f \
    \( -iname "$ev.wav" -o -iname "$ev.mp3" -o -iname "$ev.m4a" \
       -o -iname "$ev.ogg" -o -iname "$ev.flac" \) \
    2>/dev/null | head -1
}

# Import user-supplied sounds named <event>.<ext> from an external directory.
import_sounds() {
  local dir="$1"
  [ -d "$dir" ] || die "sounds directory not found: $dir"

  local ev ext src dest rc
  for ev in "${SOUND_EVENTS[@]}"; do
    src="$(find_sound "$dir" "$ev")"
    if [ -z "$src" ]; then
      warn "no $ev.{wav,mp3,m4a,ogg,flac} in $dir"
      continue
    fi
    ext="$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')"

    dest="$SOUNDS_DIR/$ev.wav"
    if [ "$ext" = "wav" ]; then
      backup_if_exists "$dest"
      run cp "$src" "$dest"
    else
      rc=0
      convert_one "$src" "$dest" || rc=$?
      if [ "$rc" -eq 2 ]; then
        warn "ffmpeg not installed; convert $(basename "$src") to WAV yourself"
        continue
      elif [ "$rc" -ne 0 ]; then
        warn "ffmpeg failed on $(basename "$src")"
        continue
      fi
      log "converted: $(basename "$src") -> $ev.wav"
    fi
    record_file "$dest"
  done
}

# Convert <event>.mp3/m4a/ogg/flac that already sit in the sounds dir and have
# no WAV counterpart. Runtime conversion is deliberately avoided: it would add
# latency to every notification and SoundPlayer only plays WAV.
convert_existing_sounds() {
  local ev src dest rc
  for ev in "${SOUND_EVENTS[@]}"; do
    [ -f "$SOUNDS_DIR/$ev.wav" ] && continue
    src="$(find_sound "$SOUNDS_DIR" "$ev")"
    [ -n "$src" ] || continue
    case "$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')" in
      wav) continue ;;
    esac

    dest="$SOUNDS_DIR/$ev.wav"
    rc=0
    convert_one "$src" "$dest" || rc=$?
    if [ "$rc" -eq 0 ]; then
      log "converted: $(basename "$src") -> $ev.wav"
      record_file "$dest"
    elif [ "$rc" -eq 2 ]; then
      warn "found $(basename "$src") but ffmpeg is missing; install ffmpeg or supply $ev.wav"
    else
      warn "ffmpeg failed on $(basename "$src")"
    fi
  done
}

gh_ready() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

# Latest tag: gh first (works for private repos), then the public API.
latest_release_tag() {
  local tag=""
  if [ "$VIA" != "curl" ] && gh_ready; then
    tag="$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || true)"
    [ -n "$tag" ] || tag="$(gh api "repos/$REPO/tags" --jq '.[0].name' 2>/dev/null || true)"
  fi
  if [ -z "$tag" ] && [ "$VIA" != "gh" ]; then
    command -v curl >/dev/null 2>&1 || return 0
    tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  # gh api echoes the error body on 404; keep only a plausible tag.
  tag="$(printf '%s' "$tag" | head -1 | tr -d '[:space:]')"
  case "$tag" in
    v[0-9]*|[0-9]*) printf '%s\n' "$tag" ;;
    *)              printf '\n' ;;
  esac
}

resolve_release() {
  local tag="$RELEASE_TAG"

  if [ -z "$tag" ]; then
    tag="$(latest_release_tag)"
    [ -n "$tag" ] || die "could not resolve the latest release of $REPO (is it private? authenticate with 'gh auth login')"
  fi
  case "$tag" in v*) ;; *) tag="v$tag" ;; esac

  local tmp
  tmp="$(mktemp -d)"
  DL_TMP="$tmp"

  if [ "$VIA" != "curl" ] && gh_ready; then
    log "downloading via gh: $REPO@$tag"
    gh api "repos/$REPO/tarball/$tag" > "$tmp/src.tar.gz" 2>/dev/null \
      || die "gh download failed for $tag"
  elif [ "$VIA" = "gh" ]; then
    die "--via gh requested but gh is missing or not authenticated"
  else
    local url="https://github.com/$REPO/archive/refs/tags/$tag.tar.gz"
    log "downloading via curl: $url"
    curl -fsSL "$url" -o "$tmp/src.tar.gz" \
      || die "download failed for $tag (private repositories require 'gh auth login')"
  fi

  if [ -n "$CHECKSUM" ]; then
    printf '%s  %s\n' "$CHECKSUM" "$tmp/src.tar.gz" | sha256sum -c - >/dev/null \
      || die "checksum mismatch for $tag"
    log "checksum: verified"
  else
    warn "no --checksum provided; tarball integrity was not verified"
  fi

  tar xzf "$tmp/src.tar.gz" -C "$tmp"
  local root
  root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [ -n "$root" ] || die "unexpected tarball layout"
  SRC="$root"
  log "source: $tag"
}

install_plugin() {
  [ -f "$SRC/plugin/sound-notify.ts" ] || die "missing $SRC/plugin/sound-notify.ts"
  [ -f "$SRC/plugin/sounds/notify.py" ] || die "missing $SRC/plugin/sounds/notify.py"

  run mkdir -p "$SOUNDS_DIR"
  backup_if_exists "$PLUGIN_DIR/sound-notify.ts"
  run cp "$SRC/plugin/sound-notify.ts" "$PLUGIN_DIR/sound-notify.ts"
  record_file "$PLUGIN_DIR/sound-notify.ts"

  local wav
  for wav in "$SRC"/plugin/sounds/*.wav; do
    [ -f "$wav" ] || continue
    run cp "$wav" "$SOUNDS_DIR/"
    record_file "$SOUNDS_DIR/$(basename "$wav")"
  done
  backup_if_exists "$SOUNDS_DIR/notify.py"
  run cp "$SRC/plugin/sounds/notify.py" "$SOUNDS_DIR/notify.py"
  run chmod +x "$SOUNDS_DIR/notify.py"
  record_file "$SOUNDS_DIR/notify.py"

  log "plugin:  $PLUGIN_DIR/sound-notify.ts"
  log "sounds:  $SOUNDS_DIR"
}

install_wrapper() {
  [ -f "$SRC/bin/opencode" ] || die "missing $SRC/bin/opencode"
  run mkdir -p "$BIN_DIR"
  if [ -e "$BIN_DIR/opencode" ] && ! cmp -s "$SRC/bin/opencode" "$BIN_DIR/opencode"; then
    backup_if_exists "$BIN_DIR/opencode"
  fi
  run cp "$SRC/bin/opencode" "$BIN_DIR/opencode"
  run chmod +x "$BIN_DIR/opencode"
  record_file "$BIN_DIR/opencode"
  log "wrapper: $BIN_DIR/opencode"
}

uninstall_all() {
  local removed=0 f ev

  if [ -f "$MARKER" ]; then
    while IFS= read -r f; do
      case "$f" in
        file=*) f="${f#file=}" ;;
        *)      continue ;;
      esac
      [ -e "$f" ] || continue
      backup_if_exists "$f"
      run rm -f "$f"
      removed=1
    done < "$MARKER"
  else
    if [ -e "$PLUGIN_DIR/sound-notify.ts" ] || [ -e "$SOUNDS_DIR/notify.py" ] \
       || [ -e "$BIN_DIR/opencode" ] || [ -e "$SOUNDS_DIR/complete.wav" ]; then
      warn "no install manifest found; removing only canonical paths"
    fi
    for f in "$PLUGIN_DIR/sound-notify.ts" "$SOUNDS_DIR/notify.py" "$BIN_DIR/opencode"; do
      [ -e "$f" ] || continue
      backup_if_exists "$f"
      run rm -f "$f"
      removed=1
    done
    for ev in "${SOUND_EVENTS[@]}"; do
      f="$SOUNDS_DIR/$ev.wav"
      [ -e "$f" ] || continue
      backup_if_exists "$f"
      run rm -f "$f"
      removed=1
    done
  fi

  # Never remove a directory that still holds files we do not manage. Backups
  # created above are ours, so they do not count as leftovers.
  if [ -d "$SOUNDS_DIR" ]; then
    local leftover
    leftover="$(ls -A "$SOUNDS_DIR" 2>/dev/null | grep -Ev '\.bak-[0-9]{8}T[0-9]{6}$' || true)"
    if [ -n "$leftover" ]; then
      warn "left $SOUNDS_DIR in place: it still contains files this installer does not manage"
    fi
  fi

  if [ -f "$MARKER" ]; then
    run rm -f "$MARKER"
    removed=1
  fi

  [ "$removed" -eq 1 ] && log "uninstalled" || log "nothing to uninstall"
}

show_check() {
  log "installed: $(installed_version)"
  local latest
  latest="$(latest_release_tag || true)"
  log "latest:    ${latest:-unavailable}"
}

main() {
  case "$MODE" in
    check)        show_check; exit 0 ;;
    check-sounds) if check_sounds; then exit 0; else exit 1; fi ;;
    uninstall)    uninstall_all; exit 0 ;;
  esac

  if [ "$MODE" = "release" ]; then
    resolve_release
  fi

  preflight || warn "proceeding with unmet prerequisites"

  install_plugin
  [ "$WITH_WRAPPER" -eq 1 ] && install_wrapper
  [ -n "$SOUNDS_SRC" ] && import_sounds "$SOUNDS_SRC"
  convert_existing_sounds
  marker_write

  log ""
  log "Sounds:"
  if ! check_sounds; then
    log ""
    log "Some sounds are missing. Name yours complete.wav question.wav permission.wav"
    log "error.wav, then drop them in:"
    log "  $SOUNDS_DIR"
    log "or run: $0 --sounds <dir>   (mp3/m4a/ogg/flac are converted with ffmpeg)"
  fi

  log ""
  log "Test it now:"
  log "  python3 $SOUNDS_DIR/notify.py complete"
  log "If you hear nothing, run: python3 $SOUNDS_DIR/notify.py error  (and check WSL audio)"
  if [ "$WITH_WRAPPER" -eq 1 ]; then
    log "Wrapper installed: open a new terminal so PATH resolves it first."
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-wrapper) WITH_WRAPPER=1 ;;
    --from-release)
      MODE="release"
      if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
        RELEASE_TAG="$2"; shift
      fi
      ;;
    --checksum)
      [ $# -ge 2 ] || die "--checksum requires a value"
      CHECKSUM="$2"; shift
      ;;
    --via)
      [ $# -ge 2 ] || die "--via requires a value"
      case "$2" in
        auto|gh|curl) VIA="$2" ;;
        *) die "--via accepts auto, gh or curl" ;;
      esac
      shift
      ;;
    --check)        MODE="check" ;;
    --check-sounds) MODE="check-sounds" ;;
    --sounds)
      [ $# -ge 2 ] || die "--sounds requires a directory"
      SOUNDS_SRC="$2"; shift
      ;;
    --uninstall) MODE="uninstall" ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

main
