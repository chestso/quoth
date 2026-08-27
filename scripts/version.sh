#!/bin/sh
# Print the package version from the quoth.el header.
set -e
cd "$(dirname "$0")/.."

sed -n 's/^;;; Version: *\([0-9][0-9.]*\).*/\1/p' quoth.el | head -1
