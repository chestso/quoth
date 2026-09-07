#!/bin/sh
# Build the package tarball from the current git tag.
set -e
cd "$(dirname "$0")/.."

tag=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -z "$tag" ]; then
	echo "dist: HEAD is not tagged; run make release first" >&2
	exit 1
fi

./scripts/check-version.sh >/dev/null

files="quoth.el quoth-json.el quoth-provider.el quoth-openai-client.el quoth-context.el \
quoth-openai-provider.el quoth-hyper-provider.el \
quoth-ollama-provider.el quoth-xxh3.el quoth-process.el quoth-tools.el quoth-searxng.el \
quoth-select.el quoth-debug-tools.el quoth-hyper-models.json quoth-ollama-models.json \
LICENSE README.md SEARXNG.md"

out="quoth-${tag#v}.tar.gz"
# shellcheck disable=SC2086  # allowlist words are deliberate
git archive --format=tar.gz --prefix=quoth/ -o "$out" "$tag" $files
echo "dist: $out"
