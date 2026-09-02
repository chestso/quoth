#!/bin/sh
# Run quoth tests: byte-compile + ERT suite.
#
# "unit" (the default) skips the wire-integration tests (tagged :integration)
# so the everyday suite stays fast and needs no external server processes.
# "wire" (make test-wire) runs byte-compile plus ONLY the :integration tests.
set -e
cd "$(dirname "$0")/.."

MODE="${1:-unit}"
case "$MODE" in
unit) selector="(not (tag :integration))" ;;
wire) selector="(tag :integration)" ;;
*)
	echo "usage: $0 [unit|wire]" >&2
	exit 2
	;;
esac

# Add markdown-mode to the load path when installed, so fontification
# tests run under the markdown-mode parent as well.
MD_DIR=$(ls -d "$HOME"/.emacs.d/elpa/markdown-mode-* 2>/dev/null | head -n1)
MD_L=""
if [ -n "$MD_DIR" ]; then
	MD_L="-L $MD_DIR"
fi

echo "=== Byte-compile ==="
for f in quoth.el quoth-provider.el quoth-openai.el quoth-hyper-provider.el quoth-tools.el quoth-xxh3.el quoth-process.el quoth-searxng.el quoth-select.el; do
	emacs --batch -L . -f batch-byte-compile "$f" 2>&1 | grep -v "site-start" || true
done

echo "=== ERT tests (${MODE}) ==="
emacs --batch -L . -L test $MD_L \
	--eval "(progn (setq load-prefer-newer t) (require 'quoth) (require 'quoth-test) \
              (ert-run-tests-batch-and-exit '$selector))" 2>&1 | grep -v "site-start" || true
