#!/usr/bin/env bash
# alacritty-x11 — launch the snap Alacritty forced onto XWayland.
#
# Why: under native Wayland with the snap's bundled (stale) Mesa on the Intel
# iGPU, Alacritty's partial-damage rendering leaves ghost text / unscrubbed
# lines on scroll. XWayland uses a full-surface present path and the artifact
# disappears. See README.md.
#
# Install:
#   install -Dm755 alacritty-x11.sh ~/.local/bin/alacritty-x11
# then point your .desktop / keybinding at `alacritty-x11` instead of `alacritty`.
set -euo pipefail

# Pin winit's backend to X11 so it routes through XWayland instead of the
# native Wayland partial-damage path.
export WINIT_UNIX_BACKEND=x11

# XWayland needs DISPLAY; GNOME/mutter sets :0 by default. Don't override if
# the session already exported one.
export DISPLAY="${DISPLAY:-:0}"

exec alacritty "$@"
