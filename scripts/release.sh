#!/bin/sh
# Bump the Version header and cut the matching git tag in one step.
# Push remains manual.
set -e
cd "$(dirname "$0")/.."

VERSION=${VERSION:-}

if [ -z "$VERSION" ]; then
	echo "usage: make release VERSION=x.y.z" >&2
	exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "release: dirty tree; commit or stash first" >&2
	exit 1
fi

cur=$(./scripts/version.sh)
new=$VERSION

if ! printf '%s\n%s\n' "$cur" "$new" | sort -V -C; then
	echo "release: version must increase: $cur -> $new" >&2
	exit 1
fi

sed -i "s/^;;; Version: .*/;;; Version: $VERSION/" quoth.el
git add quoth.el
git commit -m "Release v$VERSION"
git tag "v$VERSION" -m "Release v$VERSION"

echo "release: tagged v$VERSION"
echo "push with: git push --tags"
