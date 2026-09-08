#!/bin/sh
# Regenerate the bundled model-catalog seeds from the live providers.
#
# Each seed primes the catalog cache on a cold `quoth-provider-models-cached'
# read, so a first-ever `C-c " m' lists every model before the first
# network refresh lands.  Run before releases and commit the results.
#
#   quoth-hyper-models.json   verbatim GET /v1/models payload
#                             (pretty-printed for stable diffs).
#   quoth-ollama-models.json  assembled from GET /api/tags (membership)
#                             plus a POST /api/show fan-out per model
#                             (capabilities, context length).
set -e
cd "$(dirname "$0")/.."

# --- hyper -----------------------------------------------------------------
url="${HYPER_MODELS_URL:-https://hyper.charm.land/api/v1/models}"
out="quoth-hyper-models.json"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --max-time 60 "$url" -o "$tmp"

# Pretty-print with python (always available: the wire tests need it)
# and sanity-check the shape before replacing the tracked file.
python3 - "$tmp" "$out" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    payload = json.load(f)

models = payload.get("data")
if not isinstance(models, list) or not models:
    sys.exit("models: payload has no models array; refusing to write")

with open(sys.argv[2], "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
print(f"models: wrote {len(models)} models to {sys.argv[2]}")
PYEOF

# --- ollama ----------------------------------------------------------------
root="${OLLAMA_API_ROOT:-https://ollama.com/api}"
out="quoth-ollama-models.json"
tmp=$(mktemp)

curl -fsSL --max-time 60 "$root/tags" -o "$tmp"

python3 - "$tmp" "$root" "$out" <<'PYEOF'
import json
import sys
import urllib.request
import concurrent.futures

with open(sys.argv[1]) as f:
    tags = json.load(f)

models = tags.get("models")
if not isinstance(models, list) or not models:
    sys.exit("models: tags payload has no models array; refusing to write")

names = [m.get("name") for m in models if isinstance(m, dict) and m.get("name")]
if not names:
    sys.exit("models: tags payload has no model names; refusing to write")


def show(name):
    req = urllib.request.Request(
        sys.argv[2] + "/show",
        data=json.dumps({"model": name}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


entries = []
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    for name, meta in zip(names, pool.map(show, names)):
        caps = meta.get("capabilities") or []
        details = meta.get("details") or {}
        info = meta.get("model_info") or {}
        context = next((v for k, v in info.items()
                        if k.endswith(".context_length")), None)
        entries.append({
            "id": name,
            "capabilities": caps,
            "context_length": context,
            "parameter_size": details.get("parameter_size"),
            "quantization_level": details.get("quantization_level"),
        })

with open(sys.argv[3], "w") as f:
    json.dump(entries, f, indent=2)
    f.write("\n")
print(f"models: wrote {len(entries)} models to {sys.argv[3]}")
PYEOF

rm -f "$tmp"
