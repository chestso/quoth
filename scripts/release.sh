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

ver_lt() {
	[ "$1" != "$2" ] && printf '%s\n%s\n' "$1" "$2" | sort -V -C
}

ver_le() {
	[ "$1" = "$2" ] || printf '%s\n%s\n' "$1" "$2" | sort -V -C
}

if [ -z "$(git tag -l)" ]; then
	# First release: allow equality with the current header.
	if ! ver_le "$cur" "$new"; then
		echo "release: first release must be >= current header: $cur -> $new" >&2
		exit 1
	fi
elif ! ver_lt "$cur" "$new"; then
	echo "release: version must increase: $cur -> $new" >&2
	exit 1
fi

if [ "$cur" = "$new" ]; then
	# Header already at the release version: tag the existing HEAD.
	git tag "v$VERSION" -m "Release v$VERSION"
else
	sed -i "s/^;;; Version: .*/;;; Version: $VERSION/" quoth.el
	git add quoth.el
	git commit -m "Release v$VERSION"
	git tag "v$VERSION" -m "Release v$VERSION"
fi

echo "release: tagged v$VERSION"
echo "push with: git push --tags"
