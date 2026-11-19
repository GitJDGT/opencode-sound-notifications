#!/usr/bin/env python3
"""Non-blocking sound dispatcher for OpenCode on WSL2.

Usage: python3 notify.py <complete|question|permission|error>

Resolves the WAV (located next to this script) to a Windows path and hands
playback off to a detached powershell.exe SoundPlayer process. Returns
immediately after Popen -- never waits for playback.

Every failure path is silent: a broken player must never affect OpenCode.
"""

import os
import subprocess
import sys

EVENTS = ("complete", "question", "permission", "error")
WSLPATH_TIMEOUT_S = 2
DEFAULT_DISTRO = "Ubuntu"


def unc_root() -> str:
    """Windows UNC root for this WSL distro.

    WSL_DISTRO_NAME is set by WSL itself; the literal fallback keeps the
    dispatcher usable from cron-like contexts that inherit an empty env.
    """
    distro = os.environ.get("WSL_DISTRO_NAME") or DEFAULT_DISTRO
    return "\\\\wsl.localhost\\" + distro


def main() -> None:
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in EVENTS:
            sys.exit(0)

        script_dir = os.path.dirname(os.path.abspath(__file__))
        wav_path = os.path.join(script_dir, sys.argv[1] + ".wav")

        if not os.path.isfile(wav_path):
            sys.exit(0)

        unc = None
        try:
            result = subprocess.run(
                ["wslpath", "-w", wav_path],
                capture_output=True,
                text=True,
                timeout=WSLPATH_TIMEOUT_S,
            )
            if result.returncode == 0:
                candidate = result.stdout.strip()
                if candidate:
                    unc = candidate
        except Exception:
            unc = None

        if not unc:
            # wav_path is absolute (/home/...), so simple concat yields
            # \\wsl.localhost\<distro>/home/... which Windows accepts.
            unc = unc_root() + wav_path

        ps_command = (
            "(New-Object System.Media.SoundPlayer '" + unc + "').PlaySync()"
        )
        subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                ps_command,
            ],
            cwd="/mnt/c",
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
