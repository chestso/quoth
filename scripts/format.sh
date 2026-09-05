#!/bin/sh
# Format all source files: Elisp via Emacs indent-region, Markdown via
# prettier, Shell via shfmt, Python via black.
set -e
cd "$(dirname "$0")/.."

echo "=== Formatting Elisp ==="
# `indent-region' re-indents Emacs Lisp.  It runs with tabs disabled so
# indentation stays spaces (the repo style).
# `timeout --foreground' keeps the batch Emacs killable by Ctrl+C (no
# separate process group) while still guaranteeing the step cannot hang:
# `with-temp-buffer' avoids find-file/save-buffer entirely, so no file-local
# vars, mode hooks, or "create directory?" prompts can ever block it.
timeout --foreground 60 emacs --batch -L . --eval '(progn
        (dolist (file (append (file-expand-wildcards "*.el")
                              (file-expand-wildcards "test/*.el")))
          (let ((abs (expand-file-name file)))
            (with-temp-buffer
              (insert-file-contents abs)
              (emacs-lisp-mode)
              (setq indent-tabs-mode nil)
              (indent-region (point-min) (point-max))
              (delete-trailing-whitespace)
              (write-region (point-min) (point-max) abs))
            (message "  %s" file))))' 2>&1 | grep -E "^  " || true

echo "=== Formatting Markdown ==="
# `--prose-wrap always' reflows prose and bullets to `--print-width',
# keeping inline code spans unbroken and the output idempotent, so
# wrapping is a gate property rather than a per-edit chore.
find . -name "*.md" -not -path "./.git/*" -not -path "./.crush/*" -print0 |
	xargs -0 npx prettier --write --prose-wrap always --print-width 80 2>&1 | sed 's/^/  /'

echo "=== Formatting Shell ==="
find . -name "*.sh" -not -path "./.git/*" -print0 |
	xargs -0 shfmt -w 2>&1 | sed 's/^/  /' || true

echo "=== Formatting Python ==="
find . -name "*.py" -not -path "./.git/*" -print0 |
	xargs -0 black 2>&1 | sed 's/^/  /' || true

echo "=== Done ==="
