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

### 2. Configurar archivos

```bash
# Crear directorio de config
mkdir -p ~/.config/litellm-claude

# Copiar config
cp config.yaml ~/.config/litellm-claude/

# Copiar y editar .env
cp .env.example ~/.config/litellm-claude/.env
# Editar: poner GEMINI_API_KEY y LITELLM_MASTER_KEY

# Copiar script wrapper
mkdir -p ~/.local/bin
cp claude-code-vertex ~/.local/bin/
chmod +x ~/.local/bin/claude-code-vertex

# (Opcional) Copiar desktop launcher
cp claude-code-vertex.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/
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
