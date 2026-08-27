#!/bin/sh
# Verify the ;;; Version: header matches the current git tag.
# Lenient on untagged commits (dev state), strict at release time.
set -e
cd "$(dirname "$0")/.."

header=$(./scripts/version.sh)
tag=$(git describe --tags --exact-match 2>/dev/null || true)

if [ -z "$tag" ]; then
	echo "version: untagged commit (dev state, header $header)"
	exit 0
fi

tag_ver=${tag#v}
if [ "$header" != "$tag_ver" ]; then
	echo "VERSION MISMATCH: header $header != tag $tag" >&2
	exit 1
fi

echo "version ok: $header == $tag"
