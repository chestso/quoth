#!/bin/sh
# Regenerate quoth-hyper-models.json from the live hyper gateway.
#
# The file is the bundled model-catalog seed: a verbatim
# GET /v1/provider payload (pretty-printed for stable diffs) that
# `quoth-provider--models-seed' primes the catalog cache with, so a
# first-ever `C-c " m' lists every model before the first network
# refresh lands.  Run before releases and commit the result.
set -e
cd "$(dirname "$0")/.."

url="${HYPER_MODELS_URL:-https://hyper.charm.land/v1/provider}"
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

models = payload.get("models")
if not isinstance(models, list) or not models:
    sys.exit("models: payload has no models array; refusing to write")

with open(sys.argv[2], "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
print(f"models: wrote {len(models)} models to {sys.argv[2]}")
PYEOF
