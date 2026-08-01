#!/bin/sh
# Run crush tests: byte-compile + ERT suite
set -e
cd "$(dirname "$0")/.."

echo "=== Byte-compile ==="
emacs --batch -L . -f batch-byte-compile crush.el 2>&1 | grep -v "site-start" || true

echo "=== ERT tests ==="
emacs --batch -L . -L test \
	--eval "(progn (require 'crush) (require 'crush-test) \
              (ert-run-tests-batch-and-exit))" 2>&1 | grep -v "site-start" || true
