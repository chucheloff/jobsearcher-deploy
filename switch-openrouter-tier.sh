#!/usr/bin/env bash
# switch-openrouter-tier.sh free|paid
# Flips OpenRouter models in .env (company-mcp) and openclaw.json
# (primary, fallback, cheap/mid/heavy aliases). Backs up both files
# and recreates the affected containers.
set -euo pipefail

TIER="${1:-}"
if [[ "$TIER" != "free" && "$TIER" != "paid" ]]; then
  echo "usage: $0 free|paid" >&2
  exit 2
fi

ENV_FILE="$HOME/jobsearcher-deploy/.env"
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
COMPOSE_DIR="$HOME/jobsearcher-deploy"

if [[ "$TIER" == "free" ]]; then
  EXTRACTION="openai/gpt-oss-120b:free"
  QUALITY="nvidia/nemotron-3-super-120b-a12b:free"
  # Agent driver — needs >100K context for full skills+MCP+convo prompt.
  # Free OpenRouter pool is rate-limited per upstream provider, so we
  # configure a multi-model fallback chain across different providers
  # to ride out transient 429s.
  PRIMARY="openrouter/openai/gpt-oss-120b:free"
  FALLBACKS_JSON='["openrouter/nvidia/nemotron-3-super-120b-a12b:free","openrouter/z-ai/glm-4.5-air:free","openrouter/inclusionai/ling-2.6-flash:free","openrouter/tencent/hy3-preview:free"]'
  CHEAP="openrouter/z-ai/glm-4.5-air:free"
  MID="openrouter/inclusionai/ling-2.6-flash:free"
  HEAVY="openrouter/nvidia/nemotron-3-super-120b-a12b:free"
else
  EXTRACTION="anthropic/claude-3.5-haiku"
  QUALITY="anthropic/claude-3-opus"
  PRIMARY="google/gemini-2.5-flash-lite"
  FALLBACKS_JSON='["openrouter/anthropic/claude-haiku-4.5"]'
  CHEAP="openrouter/anthropic/claude-haiku-4.5"
  MID="openrouter/anthropic/claude-sonnet-4.6"
  HEAVY="openrouter/anthropic/claude-opus-4.7"
fi

echo "==> switching to tier: $TIER"
echo "    extraction = $EXTRACTION"
echo "    quality    = $QUALITY"
echo "    primary    = $PRIMARY"
echo "    fallbacks  = $FALLBACKS_JSON"
echo "    cheap      = $CHEAP"
echo "    mid        = $MID"
echo "    heavy      = $HEAVY"

STAMP=$(date +%Y%m%d-%H%M%S)
cp "$ENV_FILE" "$ENV_FILE.bak-$STAMP"
cp "$OPENCLAW_JSON" "$OPENCLAW_JSON.bak-$STAMP"

sed -i "s|^OPENROUTER_EXTRACTION_MODEL=.*|OPENROUTER_EXTRACTION_MODEL=$EXTRACTION|" "$ENV_FILE"
sed -i "s|^OPENROUTER_QUALITY_MODEL=.*|OPENROUTER_QUALITY_MODEL=$QUALITY|"     "$ENV_FILE"
if grep -q "^OPENROUTER_TIER=" "$ENV_FILE"; then
  sed -i "s|^OPENROUTER_TIER=.*|OPENROUTER_TIER=$TIER|" "$ENV_FILE"
else
  printf "\nOPENROUTER_TIER=%s\n" "$TIER" >> "$ENV_FILE"
fi

python3 - "$OPENCLAW_JSON" "$PRIMARY" "$FALLBACKS_JSON" "$CHEAP" "$MID" "$HEAVY" <<'PY'
import json, sys
path, primary, fallbacks_json, cheap, mid, heavy = sys.argv[1:]
fallbacks = json.loads(fallbacks_json)
with open(path) as f:
    cfg = json.load(f)
defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
defaults["model"] = {"primary": primary, "fallbacks": fallbacks}
models = {primary: {}}
for fb in fallbacks:
    models.setdefault(fb, {})
for m, alias in ((cheap, "cheap"), (mid, "mid"), (heavy, "heavy")):
    if m in models:
        models[m] = {**models[m], "alias": alias}
    else:
        models[m] = {"alias": alias}
defaults["models"] = models
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

cd "$COMPOSE_DIR"
docker compose up -d company-mcp openclaw-gateway openclaw-cli
docker compose restart openclaw-gateway openclaw-cli
echo "==> done. tier=$TIER"
