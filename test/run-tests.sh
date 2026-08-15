#!/bin/sh
# Run crush tests: byte-compile + ERT suite
set -e
cd "$(dirname "$0")/.."

# Add markdown-mode to the load path when installed, so fontification
# tests run under the markdown-mode parent as well.
MD_DIR=$(ls -d "$HOME"/.emacs.d/elpa/markdown-mode-* 2>/dev/null | head -n1)
MD_L=""
if [ -n "$MD_DIR" ]; then
	MD_L="-L $MD_DIR"
fi

echo "=== Byte-compile ==="
for f in crush.el crush-provider.el crush-openai.el crush-stream.el crush-hyper-provider.el crush-xxh3.el crush-tool.el; do
	emacs --batch -L . -f batch-byte-compile "$f" 2>&1 | grep -v "site-start" || true
done

echo "=== ERT tests ==="
emacs --batch -L . -L test $MD_L \
	--eval "(progn (setq load-prefer-newer t) (require 'crush) (require 'crush-test) \
              (ert-run-tests-batch-and-exit))" 2>&1 | grep -v "site-start" || true
