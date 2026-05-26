#!/usr/bin/env bash
# gemini-code-review.sh — one-shot code review on Gemini 3.5 Flash via liteLLM.
#
# Design B of /gemini-code-review: NO nested Claude Code agent. We resolve a diff,
# feed it + a condensed review rubric to gemini-3.5-flash in a SINGLE completion
# request through the liteLLM proxy, and print the review markdown to stdout.
# An Opus orchestrator (the /gemini-code-review command) then curates the output
# against the repo's real CLAUDE.md rules. This sidesteps the tool-call-translation
# fragility of running the full agent loop on a translated Gemini backend.
#
# Usage:
#   gemini-code-review.sh                 # diff develop...HEAD (default)
#   gemini-code-review.sh 245             # gh pr diff 245
#   gemini-code-review.sh --uncommitted   # git diff HEAD (staged + unstaged)
#   gemini-code-review.sh my-branch       # git diff develop...my-branch
#   gemini-code-review.sh a..b            # git diff a..b
#   [--base <branch>] [--rubric <file>]   # override base branch / rubric file
#
# Requires: GEMINI_API_KEY in ~/.config/litellm-claude/.env, litellm, jq, curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOCAL_DIR="$HOME/.config/litellm-claude"
CONFIG="${SCRIPT_DIR}/config.yaml"
ENV_FILE="${LOCAL_DIR}/.env"
LITELLM_LOG="${LOCAL_DIR}/gcr-proxy.log"
PORT=4000
MODEL="gemini-flash"
BASE="develop"
RUBRIC_FILE=""
TARGET=""

# --- arg parse ---
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --rubric) RUBRIC_FILE="$2"; shift 2 ;;
    --uncommitted) TARGET="--uncommitted"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

# --- secrets (never echoed) ---
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a
if [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "ERROR: GEMINI_API_KEY no está en $ENV_FILE (obtenela en https://aistudio.google.com/apikey)" >&2
  exit 1
fi
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-dojo-agent}"

# --- resolve diff ---
LABEL=""
if [ -z "$TARGET" ]; then
  LABEL="${BASE}...HEAD"; DIFF="$(git diff "${BASE}...HEAD")"
elif [ "$TARGET" = "--uncommitted" ]; then
  LABEL="uncommitted (git diff HEAD)"; DIFF="$(git diff HEAD)"
elif [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  LABEL="PR #${TARGET}"; DIFF="$(gh pr diff "$TARGET")"
elif [[ "$TARGET" == *..* ]]; then
  LABEL="$TARGET"; DIFF="$(git diff "$TARGET")"
else
  LABEL="${BASE}...${TARGET}"; DIFF="$(git diff "${BASE}...${TARGET}")"
fi

if [ -z "${DIFF// }" ]; then
  echo "ERROR: diff vacío para '${LABEL}'. ¿Branch/base correcto?" >&2
  exit 2
fi
DIFF_CHARS=${#DIFF}
[ "$DIFF_CHARS" -gt 600000 ] && echo "WARN: diff grande (${DIFF_CHARS} chars) — Flash tiene ventana amplia pero el review puede perder profundidad." >&2

# --- rubric (condensed; instruction-clean for a single-shot reviewer) ---
if [ -n "$RUBRIC_FILE" ] && [ -f "$RUBRIC_FILE" ]; then
  RUBRIC="$(cat "$RUBRIC_FILE")"
else
  RUBRIC=$(cat <<'RUBRIC_EOF'
You are a battle-tested senior engineer reviewing a diff from the DojoOS codebase
(React 19, TypeScript 5.9, Vite, Supabase, TanStack Query, Tailwind). Review as if
you will debug this at 3 AM during an incident. Read EVERY changed line. You are
given ONLY the diff — do not ask to run commands or open other files; review what
is shown and flag where you'd want to see more.

Hunt for:
- Logic: race conditions, null/undefined access without guards, missing `await`,
  off-by-one, wrong boolean logic (De Morgan), `==` vs `===`, bad type coercion.
- React/state: stale closures, missing useEffect/useMemo/useCallback deps, direct
  prop/state mutation, array-index keys on dynamic lists, missing loading/error/
  empty states.
- Edge cases: empty/zero/negative, empty-string vs null vs undefined, timezones,
  large-dataset perf.
- Architecture: SRP violations, god components (>300 lines), `any` types, missing
  return types, magic numbers/strings, leftover console.logs / commented code.
- Tests: new logic without unit tests; missing error/empty/edge coverage.
- Security: secrets/API keys in frontend, service-role key outside Edge Functions,
  unvalidated user input (no Zod), missing RLS on new tables, SQL injection, XSS
  via raw/unsafe HTML injection, missing CORS / rate limiting on public endpoints.

Output EXACTLY this markdown:

## Gemini Code Review — {LABEL}

### Files Reviewed
| File | +/- | Risk | Notes |
|------|-----|------|-------|

### Findings
#### Critical (blocks merge)
- **[Category]** `file:line` — issue -> fix
#### Major (fix before merge)
- ...
#### Minor (recommended)
- ...

### Missing Tests / Changes
- ...

### Verdict: Approve | Request Changes | Block
| Critical | Major | Minor |
|----------|-------|-------|
| N | N | N |

If a section is empty, write "None.". Be specific with file:line; no vague advice.
RUBRIC_EOF
  )
fi
RUBRIC="${RUBRIC/\{LABEL\}/$LABEL}"

# --- ensure liteLLM proxy on :PORT (start only if free; tear down only ours) ---
STARTED_PROXY=false
proxy_ready() { curl -fsS "http://0.0.0.0:${PORT}/health/readiness" >/dev/null 2>&1; }
cleanup() { $STARTED_PROXY && [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if ! proxy_ready; then
  if lsof -ti ":${PORT}" >/dev/null 2>&1; then
    echo "ERROR: :${PORT} ocupado pero no responde /health/readiness. Liberá el puerto y reintentá." >&2
    exit 3
  fi
  echo "Levantando liteLLM proxy (gemini-flash)..." >&2
  litellm --config "$CONFIG" --port "$PORT" >"$LITELLM_LOG" 2>&1 &
  PROXY_PID=$!; STARTED_PROXY=true
  for _ in $(seq 1 30); do proxy_ready && break; sleep 1; done
  if ! proxy_ready; then echo "ERROR: el proxy no arrancó. Log: $LITELLM_LOG" >&2; tail -5 "$LITELLM_LOG" >&2; exit 4; fi
fi

# --- one completion request ---
BODY="$(jq -n --arg m "$MODEL" --arg sys "$RUBRIC" \
  --arg usr "Review this diff (${LABEL}):"$'\n\n'"\`\`\`diff"$'\n'"${DIFF}"$'\n'"\`\`\`" \
  '{model:$m, messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')"

RESP="$(curl -fsS "http://0.0.0.0:${PORT}/v1/chat/completions" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "$BODY")" || { echo "ERROR: request a Gemini falló." >&2; exit 5; }

CONTENT="$(printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty')"
if [ -z "$CONTENT" ]; then
  echo "ERROR: respuesta sin contenido. Raw:" >&2
  printf '%s\n' "$RESP" | jq -r '.error // .' >&2 2>/dev/null || printf '%s\n' "$RESP" >&2
  exit 6
fi

# --- emit (stdout for the orchestrator + saved copy) ---
OUT="${LOCAL_DIR}/gemini-code-review-$(date +%Y%m%d-%H%M%S).md"
printf '%s\n' "$CONTENT" | tee "$OUT"
echo "" >&2
echo "[saved: $OUT · model: gemini-3.5-flash · diff: $LABEL · ${DIFF_CHARS} chars]" >&2
