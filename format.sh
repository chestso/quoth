echo "=== Formatting Elisp ==="
# `indent-region' re-indents Emacs Lisp.  It runs with tabs disabled so
# indentation stays spaces (the repo style).  Two files are excluded:
# their deep `define-key'/`overlay-put' nesting (crush-stream.el) and a
# docstring glued to its body opener (test/crush-test-backend.el) are
# valid Lisp but mis-indented by `calculate-lisp-indent'; running
# `indent-region' on them corrupts the layout, so only trailing
# whitespace is cleaned there.
emacs --batch -L . --eval '(progn
        (dolist (file (append (file-expand-wildcards "*.el")
                              (file-expand-wildcards "test/*.el")))
          (let ((excluded (member (file-name-nondirectory file)
                                  (list "crush-stream.el"
                                        "crush-test-backend.el"))))
            (find-file file)
            (unless excluded
              (setq indent-tabs-mode nil)
              (indent-region (point-min) (point-max)))
            (delete-trailing-whitespace)
            (save-buffer)
            (message "  %s%s" file
                     (if excluded " (skipped indent)" "")))))' 2>&1 | grep -E "^  "

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
