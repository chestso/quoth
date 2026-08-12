#!/bin/sh
# Format all source files in the project.
set -e
cd "$(dirname "$0")"

echo "=== Formatting Elisp ==="
emacs --batch -L . \
	--eval '(progn
        (dolist (file (append (file-expand-wildcards "*.el")
                              (file-expand-wildcards "test/*.el")))
          (find-file file)
          (indent-region (point-min) (point-max))
          (delete-trailing-whitespace)
          (save-buffer)
          (message "  %s" file)))' 2>&1 | grep -E "^  "

echo "=== Formatting Markdown ==="
find . -name "*.md" -not -path "./.git/*" -print0 |
	xargs -0 npx prettier --write --prose-wrap preserve 2>&1 | sed 's/^/  /'

echo "=== Formatting Shell ==="
find . -name "*.sh" -not -path "./.git/*" -print0 |
	xargs -0 shfmt -w 2>&1 | sed 's/^/  /' || true

echo "=== Formatting Python ==="
find . -name "*.py" -not -path "./.git/*" -print0 |
	xargs -0 black 2>&1 | sed 's/^/  /' || true

echo "=== Done ==="
