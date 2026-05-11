# Claude Code con Gemini 3.1 Pro via liteLLM

Usar **Claude Code** (el agente CLI de Anthropic) con **Gemini 3.1 Pro Preview**
de Google usando [liteLLM](https://litellm.ai) como proxy de traducción entre
formatos de API.

## Motivación

Claude Code normalmente solo funciona con modelos de Anthropic. Con liteLLM
interceptamos las llamadas y las traducimos al formato de Gemini, permitiendo:

- Usar Gemini desde la interfaz y tooling de Claude Code.
- Consumir **Google for Startups credits** (cubren tanto Gemini API como
  Vertex AI).

## Requisitos

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) instalado.
- Python 3.11+ con [`uv`](https://docs.astral.sh/uv/).
- (Opcional) `gcloud` CLI si usás Vertex AI.

## Instalación

### 1. Instalar liteLLM

```bash
uv tool install 'litellm[proxy,google]'
```

### 2. Symlinkear archivos desde el repo

Todos los archivos viven **en el repo** y se referencian por symlink.
Nada se copia — editar el repo actualiza todo automáticamente.

```bash
REPO="$PWD"  # o la ruta donde clonaste el repo

# Script wrapper (para usar desde terminal)
mkdir -p ~/.local/bin
ln -sf "$REPO/claude-code-vertex" ~/.local/bin/

# Desktop launcher (para menú de aplicaciones)
ln -sf "$REPO/claude-code-vertex.desktop" ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/

# .env local (secrets — NUNCA commitear al repo)
mkdir -p ~/.config/litellm-claude
cp -n .env.example ~/.config/litellm-claude/.env
# Editar: poner GEMINI_API_KEY y LITELLM_MASTER_KEY
```

### 3. Obtener API keys

**Gemini API:** https://aistudio.google.com/apikey

**Vertex AI:** `gcloud auth application-default login` (necesita permisos de
Vertex AI en el proyecto GCP).

Luego editar `~/.config/litellm-claude/.env`:

```bash
GEMINI_API_KEY=AIza...
LITELLM_MASTER_KEY=sk-...
```

## Uso

### Desde terminal

```bash
claude-code-vertex
```

### Desde el menú de aplicaciones

Buscar "Claude Code (Gemini)" en el launcher (GNOME/KDE/etc).

### Selección de backend

El script detecta automáticamente qué credenciales tenés:

| Backend | Detección | Créditos GfS |
|---|---|---|
| Gemini API | `GEMINI_API_KEY` en `.env` | Sí |
| Vertex AI | `gcloud auth application-default-login` | Sí |

Si tenés ambos configurados, te pregunta cuál usar al arrancar.

### Cómo funciona el desktop launcher

El `.desktop` file usa el field code `%k` (ruta del propio archivo `.desktop`)
junto con `readlink -f` para resolver la ubicación real del repo aunque el
`.desktop` esté instalado como symlink. Así no hay rutas absolutas hardcodeadas.

```
Exec=bash -c 'exec "$(dirname "$(readlink -f "$0")")/claude-code-vertex"' %k
```

El script hace lo mismo para encontrar `config.yaml` en el repo.

### Argumentos adicionales

Se pueden pasar flags a Claude Code:

```bash
claude-code-vertex --print "Hola"
```

## Arquitectura

```
Claude Code  ──HTTP──>  liteLLM proxy  ──HTTP──>  Gemini API / Vertex AI
(Anthropic                (:4000)                  (Google)
 Messages API)            traduce formatos
```

liteLLM recibe requests en formato Anthropic Messages API, las traduce al
formato de Gemini, las reenvía, y traduce la respuesta de vuelta.

## Referencias

- [liteLLM — Vertex AI docs](https://docs.litellm.ai/docs/providers/vertex)
- [liteLLM — Claude con modelos no-Anthropic](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)
- [Google AI Studio](https://aistudio.google.com/apikey)
- [Google for Startups — AI program](https://cloud.google.com/startup/ai)
