# Migrate VS Code: snap → official .deb

Replaces the VS Code **snap** with Microsoft's official **`.deb`** so its Electron
links the **host Mesa/GL** and matches the other deb editors (Cursor/Kiro/Antigravity).
This makes the NVIDIA-primary EGL acceleration recipe (see
`../Ubuntu_NVIDIA_Primary_Webview_Disable_GPU/` and the editor exception) apply
cleanly, with no snap layer as a variable.

## Run

```bash
sudo ./migrate-vscode-snap-to-deb.sh
```

Idempotent. **Safeguard:** the snap is removed only after the `.deb` is confirmed
installed — a failed install never leaves you without an editor. User config and
extensions (`~/.config/Code`, `~/.vscode`) are shared and preserved.

## After (user-space, no sudo — the assistant handles it)
- Remove the stale `~/.local/share/applications/code_code.desktop` override (it
  pointed at the gone `/snap/bin/code`).
- Repoint the dock favorite `code_code.desktop` → `code.desktop`.
- Apply the EGL acceleration recipe to the new `code.desktop`.

## Revert
`sudo apt remove code` + `sudo snap install code --classic`, then redo the dock favorite.
