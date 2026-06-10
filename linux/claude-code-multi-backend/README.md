# Claude Code Launcher — multi-backend

Lanzador de Claude Code con soporte para múltiples backends: Anthropic directo,
Gemini API, Vertex AI y OpenCode Go.

## Requisitos

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) instalado
- [Alacritty](https://alacritty.org/) instalado (`sudo snap install alacritty`)
- Python 3.11+ con [`uv`](https://docs.astral.sh/uv/) (solo para Gemini/Vertex via liteLLM)
- `gcloud` CLI (solo para Vertex AI)

## Instalación

### 1. Symlinks de los scripts

Los scripts viven en el repo y se referencian por symlink:

```bash
REPO="$PWD"  # ruta del repo
mkdir -p ~/.local/bin
ln -sf "$REPO/claude-code-vertex" ~/.local/bin/
ln -sf "$REPO/claude-code-vertex-gui" ~/.local/bin/
```

### 2. Launcher del Escritorio

El `.desktop` se copia (NO symlink — GNOME cachea los symlinks):

```bash
cp "$REPO/claude-code-multi-backend.desktop" ~/Escritorio/
chmod +x ~/Escritorio/claude-code-multi-backend.desktop
```

### 3. Configurar API keys

Crear `~/.config/litellm-claude/.env`:

```bash
mkdir -p ~/.config/litellm-claude
cp -n .env.example ~/.config/litellm-claude/.env
```

O simplemente ejecutar el launcher — te pide las keys que falten y las guarda
automáticamente.

## Backends

| # | Backend | Requiere |
|---|---|---|
| 1 | Anthropic directo | `claude login` (login propio de Claude) |
| 2 | Gemini API | `GEMINI_API_KEY` en `.env` |
| 3 | Vertex AI | `gcloud auth application-default login` |
| 4 | OpenCode Go | `OPENCODE_GO_API_KEY` en `.env` |

Cuando elegís un backend cuya key falta, el script te la pide y la guarda en
`.env` automáticamente.

### OpenCode Go

Modelos Anthropic-compatibles disponibles:
- MiniMax M2.7 (`minimax-m2.7`)
- MiniMax M2.5 (`minimax-m2.5`)

API key en https://opencode.ai/auth

## Funcionalidades

- **Selección de backend** al arrancar
- **Resume de sesiones** con respaldo automático (`~/.claude/sessions-backup/`)
- **Recuperación de sesiones huérfanas**: lista también las sesiones reales que
  quedaron sin heartbeat tras un crash (ver abajo)
- **Respaldo al iniciar** vía hook `SessionStart` (no sólo al retomar)
- **Resolución UUID → short ID**: pegar UUID funciona
- **Confirmación de directorio** antes de lanzar
- **Proxy liteLLM** para Gemini/Vertex (se mata solo si hay puerto stale)
- **Sin proxy** para Anthropic directo y OpenCode Go

## Recuperación de sesiones (cómo funciona)

El selector arma la lista desde **tres fuentes**, deduplicadas por UUID:

| Fuente | Origen | Tag |
|---|---|---|
| Activas | `~/.claude/sessions/<pid>.json` (heartbeat de procesos vivos) | — |
| Respaldos | `~/.claude/sessions-backup/<uuid>.json` | `[respaldo]` |
| Huérfanas | `~/.claude/projects/<proj>/<uuid>.jsonl` (transcripts reales) | `[huérfana]` |

El heartbeat `<pid>.json` lo escribe Claude Code y **sólo existe mientras el
proceso vive**; al salir limpio lo borra, y al arrancar tras un reinicio purga
los que quedaron huérfanos. Por eso una sesión que muere en un **freeze de GPU /
corte de energía** desaparecía del menú aunque su transcript siguiera intacto en
disco.

Tres arreglos cierran el hueco:

1. **Fuente "huérfana"** — el selector escanea los transcripts reales en
   `~/.claude/projects` (últimos `ORPHAN_MAX_AGE_DAYS` días, tope `ORPHAN_LIMIT`)
   y muestra cualquiera sin heartbeat vivo ni respaldo. El transcript es la
   fuente de verdad, así que la sesión siempre es recuperable.
2. **Hook `SessionStart`** (`hooks/session-backup.sh`) — respalda la metadata de
   cada sesión **apenas arranca**, no sólo cuando la retomás por el menú. Así el
   respaldo sobrevive a un crash que ocurra antes de retomarla.
3. **Recreación del cwd borrado** — Claude Code resuelve `--resume` por el
   mapeo `cwd → ~/.claude/projects/<dir-codificado>`; retomar desde otro
   directorio falla con "session not found". Si el cwd original ya no existe
   (caso típico: un worktree limpiado post-merge), el selector ofrece
   recrearlo vacío antes del resume en vez de saltarse el `cd` en silencio.
   El resume por **ID manual** también localiza el cwd (heartbeat → respaldo →
   transcript) y aplica la misma lógica.
4. **cwd de creación vs. cwd del heartbeat** — Claude Code archiva el transcript
   bajo el project-dir que corresponde al cwd **de creación** de la sesión, y no
   lo re-archiva nunca. El heartbeat/respaldo, en cambio, guarda el **último**
   cwd. Si una sesión cambia de directorio a mitad de vida (típico al saltar
   entre worktrees), esos dos divergen: el menú podía mandar a retomar desde el
   último cwd, donde `--resume` falla con *"No conversation found with session
   ID"* porque el transcript vive en otro project-dir. El selector ahora deriva
   el cwd autoritativo del **primer `cwd` del transcript** (`_creation_cwd_for_uuid`),
   con fallback al heartbeat, y avisa en pantalla cuando la sesión migró. Esto es
   distinto del caso 3 (cwd **borrado**): acá el cwd existe, pero es el equivocado.

Variables de entorno opcionales: `ORPHAN_MAX_AGE_DAYS` (default 14),
`ORPHAN_LIMIT` (default 25).

### Instalar el hook de respaldo

```bash
./hooks/install-session-backup-hook.sh
```

Idempotente: registra `session-backup.sh` como hook `SessionStart` en
`~/.claude/settings.json` sin duplicar ni tocar el resto de la config (deja un
`.bak` con timestamp por las dudas).

## Arquitectura

```
Antes de arrancar Claude Code:

  GUI wrapper (claude-code-vertex-gui)
    └── alacritty -e claude-code-vertex
          └── pick backend → set env vars
                ├── Anthropic direct → claude (sin proxy)
                ├── OpenCode Go     → claude + ANTHROPIC_BASE_URL
                ├── Gemini API      → litellm + claude --model gemini-pro
                └── Vertex AI       → litellm + claude --model vertex-gemini-pro
```

## PATH propagation (gotcha importante)

Cuando el launcher arranca desde el `.desktop` del Escritorio, la cadena de
procesos es:

```
.desktop → bash (no interactivo) → alacritty -e → claude-code-vertex → claude
```

El PATH lo hereda de la sesión Wayland/X11, **no** de `~/.bashrc`. El bashrc
por defecto de Ubuntu/Debian tiene este guard al inicio:

```bash
case $- in
    *i*) ;;
      *) return;;
esac
```

Para shells no interactivos hace `return` temprano, así que los exports de
abajo (`~/.bun/bin`, `nvm`, etc.) **nunca se cargan**. Resultado: cuando
`claude` levanta sus subprocesos (MCP stdio servers via `npx`/`bun`), fallan
con `ENOENT` porque esas rutas no están en PATH.

Por eso `claude-code-vertex-gui` exporta PATH explícitamente antes de invocar
`alacritty -e`. Incluye `~/.local/bin`, `~/.bun/bin`, el node activo de nvm
(resuelto desde `$NVM_DIR/alias/default`, con fallback a la última versión
instalada) y la system path estándar. Cualquier herramienta lanzada por esta
misma vía hereda el PATH correcto.

Si agregás otra ruta a tus tools de usuario (por ejemplo `~/.cargo/bin`),
sumala al `export PATH=...` del wrapper.

## Archivos

| Archivo | Propósito |
|---|---|
| `claude-code-vertex` | Script principal (selección, proxy, lanzamiento) |
| `claude-code-vertex-gui` | Wrapper que lanza en Alacritty |
| `claude-code-multi-backend.desktop` | Launcher del Escritorio |
| `config.yaml` | Configuración liteLLM |
| `.env.example` | Template de secrets |
| `hooks/session-backup.sh` | Hook `SessionStart`: respalda metadata al iniciar |
| `hooks/install-session-backup-hook.sh` | Registra el hook en `settings.json` (idempotente) |
