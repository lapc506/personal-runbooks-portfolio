# Ubuntu Snap Alacritty — User-Font Persistence & Live Reload

Persist a **user-installed font** (here: Inconsolata, Medium weight) in a
**snap-confined Alacritty**, applied **live with no terminal restart**, while
preserving the existing config (a `Shift+Return` keybinding) byte-for-byte.

This runbook captures the real journey of trying five fonts back to back
(PT Mono → Fira Code → Bitstream Vera Mono → Ubuntu Mono "Bront" → Inconsolata).
Each one exposed a different, non-obvious trap. The fixes generalize to **any**
user font in **any** strictly-confined snap GUI app on a modern Ubuntu.

- **Machine:** Ubuntu, Wayland session, Alacritty **0.17.0 from snap**
  (`/snap/alacritty/155/`), `snapd 2.75.2`, fontconfig host + snap-bundled.
- **Symptom space:** "my font doesn't show up", "bold/italic look wrong",
  "the config edit broke the terminal", "letters feel too far apart".

---

## TL;DR (the working end state)

1. Drop the TTF in `~/.local/share/fonts/<Name>/` and `fc-cache -f`.
2. **Verify the font is visible _inside the snap's confinement_**, not just on
   the host: `snap run --shell alacritty -c 'fc-match "<Family>"'`.
3. Edit `~/.config/alacritty/alacritty.toml`'s `[font]` tables. Alacritty
   **live-reloads on save** (default `true` since 0.13) — no restart.
4. **Never re-type control-character keybindings** when rewriting the file;
   preserve them verbatim or you'll inject a raw `0x1B` and produce invalid TOML.

Final config (Inconsolata, bumped to Medium for a touch more body):

```toml
[font]
size = 12.0

[font.normal]
family = "Inconsolata"
style  = "Medium"      # variable wght=500 — a real instance, not synthetic bold

[font.bold]
family = "Inconsolata"
style  = "Bold"

[font.italic]
family = "Inconsolata"  # Inconsolata has no italic; point at the family so
style  = "Regular"      # fontconfig doesn't substitute a *different* font
```

---

## The journey (and every trap it surfaced)

### Trap 0 — The snap can't necessarily see `~/.local/share/fonts`

Alacritty here is a **strictly-confined snap**, confirmed via the running
process, not assumption:

```bash
pgrep -x alacritty | head -1 | xargs -I{} readlink -f /proc/{}/exe
#  -> /snap/alacritty/155/bin/alacritty
```

The classic `home` snap interface only grants read access to **non-hidden**
files in `$HOME`. `~/.local/share/fonts` lives under `.local` (hidden), so on
older snapd it is **invisible to the app** even though `fc-list` on the host
shows the font. snapd added an explicit AppArmor allowance for
`@{HOME}/.local/share/fonts/` and `@{HOME}/.fonts/` — but only relatively
recently. So the **only trustworthy test** is to query fontconfig from *inside*
the confinement:

```bash
# Host view (necessary but NOT sufficient):
fc-list | grep -i "Inconsolata"

# Confined view (the one that actually matters):
snap run --shell alacritty -c 'fc-match "Inconsolata:weight=bold"'
#  -> Inconsolata-VF.ttf: "Inconsolata" "Bold"   ✓ the snap sees it
```

On `snapd 2.75.2` the user-font dir is whitelisted and this passes. On an older
snapd where it fails, the fallback is to install into a dir the `desktop`
interface already bind-mounts, or to connect a fonts-providing interface — but
verify first, don't guess.

### Trap 1 — Rewriting the config injected a raw ESC and broke TOML

The existing config carried a deliberate keybinding:

```toml
[[keyboard.bindings]]
key = "Return"
mods = "Shift"
chars = "\r"   # ESC + CR, as TOML escape sequences (literal backslashes)
```

Rewriting the file through tool/JSON/heredoc layers **re-interpreted**
`` and wrote an **actual ESC byte (0x1B)** into the file. A raw control
char is illegal inside a TOML basic string, so the parser rejected the whole
file and Alacritty's live reload silently kept the old config:

```
tomllib.TOMLDecodeError: Illegal character '\x1b' (at line 25, column 10)
```

**Failed approach:** re-typing the `chars` line. Every escape layer is a chance
to turn the 6 characters `` into one ESC byte.

**Fix that stuck:** never reconstruct control-character lines. Either copy the
binding **verbatim from the backup**, or — generically — strip only the
`[font*]` tables out of the existing file and prepend the new block, leaving
every other byte untouched. `set-alacritty-font.sh` does the latter and
**validates with `tomllib` before writing**, so a bad edit can never reach disk.

### Trap 2 — fontconfig style **strings** are literal: "Oblique" ≠ "Italic"

With Bitstream Vera Sans Mono (which *does* ship real italics), the obvious
`style = "Italic"` rendered upright text:

```bash
fc-match "Bitstream Vera Sans Mono:style=Italic"   # -> "...Roman"  (WRONG)
fc-match "Bitstream Vera Sans Mono:style=Oblique"  # -> "...Oblique" (right)
fc-match "Bitstream Vera Sans Mono:slant=italic"   # -> "...Oblique" (also right)
```

Alacritty passes the `style` string **literally** to fontconfig's `FC_STYLE`.
Vera's italic is *named* "Oblique", so `"Italic"` finds no such style and falls
back to the regular. Lesson: with older fonts, read the **exact** style name
from `fc-list` — don't assume "Italic". The semantic property (`:slant=italic`)
is robust, but Alacritty only takes the style *name*.

### Trap 3 — A hyphen in the family name breaks the `fc-match` CLI (but not Alacritty)

Ubuntu Mono "Bront" (`chrismwendt/bront`) installs under family
**`Ubuntu Mono - Bront`**. The CLI lied about reachability:

```bash
fc-match "Ubuntu Mono - Bront:style=Regular"    # -> "Ubuntu Mono" (WRONG: fell back)
fc-match "Ubuntu Mono \- Bront:style=Regular"   # -> "Ubuntu Mono - Bront" (correct)
```

In fontconfig **pattern syntax**, `-` separates family from size
(`"Arial-12"`), so the unescaped hyphen mis-parsed the family. But **Alacritty
does not use pattern syntax** — it sets `FC_FAMILY` to the literal config
string, so `family = "Ubuntu Mono - Bront"` matches correctly. Don't discard a
font because the `fc-match` CLI choked on punctuation; verify with the hyphen
escaped, or with `fc-query` directly on the file.

### Trap 4 — Variable-font weights are real instances, not synthetic bold

Inconsolata ships as a **2-axis variable font** (`Inconsolata[wdth,wght].ttf`,
`wght` 200–900 × `wdth` 50–200). fontconfig 2.13+ expands its named instances
(~70 of them: `UltraCondensed Black` … `UltraExpanded Light`). Selecting
`style = "Medium"` picks the **interpolated 500 instance designed by the
typeface**, not a rasterizer-faked bold — so it stays crisp:

```bash
fc-match "Inconsolata:style=Medium"  # -> Inconsolata-VF.ttf: "Inconsolata" "Medium"
```

Two spacing levers fall out of this for free (see next trap's neighbor):
- weight: `Regular` → `Medium` → `SemiBold` (no new files);
- width:  `style = "Condensed Regular"` to tighten without touching `offset.x`.

### Trap 5 — Mixing families across styles is safe **only** when metrics match

Bront ships **Regular only**. To get real bold/italic, the config points
`[font.bold]`/`[font.italic]` at the system **Ubuntu Mono** family:

```toml
[font.normal]      { family = "Ubuntu Mono - Bront", style = "Regular" }
[font.bold]        { family = "Ubuntu Mono",          style = "Bold" }
[font.italic]      { family = "Ubuntu Mono",          style = "Italic" }
[font.bold_italic] { family = "Ubuntu Mono",          style = "Bold Italic" }
```

This is only safe because **Bront is derived from Ubuntu Mono and shares its
advance width** — the cell grid stays aligned. Mixing two monospaces of
different widths (narrow normal + wide bold) makes the cursor and column
alignment jump on any line containing bold. Match metrics or don't mix.

### Why it "felt too spaced" (the user's actual complaint)

Bitstream Vera Sans Mono is **intrinsically wide** (advance ~602/1000 em). That
whitespace is the font's design, not something Alacritty adds. Two cures:

```toml
# (A) pick a narrower font / a Condensed instance of a variable font
[font.normal] { style = "Condensed Regular" }

# (B) Alacritty's own lever — pixels added between cells; negative tightens
[font.offset] { x = -1, y = 0 }
```

---

## Files in this runbook

- **`install-user-font.sh`** — download a TTF/OTF into
  `~/.local/share/fonts/<subdir>/`, `fc-cache`, and **verify visibility on the
  host AND inside the snap's confinement** (the step everyone skips). Idempotent.
- **`set-alacritty-font.sh`** — safely set the `[font]` tables in
  `alacritty.toml`: timestamped backup → strip old `[font*]` tables → prepend
  the new block → **`tomllib`-validate before writing** → rely on live reload.
  Never touches non-font lines (so control-char keybindings survive). Defaults
  to the Inconsolata-Medium config; override via env vars at the top.

## Reproduce (Inconsolata, the end state)

```bash
# 1. install + verify (host and snap)
./install-user-font.sh Inconsolata \
  'https://raw.githubusercontent.com/google/fonts/main/ofl/inconsolata/Inconsolata%5Bwdth,wght%5D.ttf' \
  alacritty

# 2. apply to alacritty.toml (backup + validate + live reload)
./set-alacritty-font.sh
```

## Verification

```bash
# config parses (Alacritty won't reload an invalid file):
python3 -c "import tomllib; tomllib.load(open('$HOME/.config/alacritty/alacritty.toml','rb')); print('TOML OK')"

# the snap resolves each style to the right instance:
for s in Medium Bold; do snap run --shell alacritty -c "fc-match \"Inconsolata:style=$s\""; done
```

## Revert

```bash
cp ~/.config/alacritty/alacritty.toml.bak ~/.config/alacritty/alacritty.toml   # live-reloads back
# fonts are inert files; remove if desired:
rm -rf ~/.local/share/fonts/Inconsolata && fc-cache -f
```

## References

- Alacritty config (`font`, `live_config_reload`, `font.offset`): <https://alacritty.org/config-alacritty.html>
- fontconfig user spec / pattern syntax (`FcNameParse`, the `-` size separator): `man 5 fonts-conf`, `man fc-match`
- snapd `home`/`desktop` interfaces & font access: <https://snapcraft.io/docs/home-interface>
- Inconsolata (variable, OFL): <https://fonts.google.com/specimen/Inconsolata>
- "Bront" patched Ubuntu Mono: <https://github.com/chrismwendt/bront>
