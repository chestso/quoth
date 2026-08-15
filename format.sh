echo "=== Formatting Elisp ==="
# `indent-region' re-indents Emacs Lisp.  It runs with tabs disabled so
# indentation stays spaces (the repo style).  One file is excluded: its
# deep `define-key'/`overlay-put' nesting (crush-stream.el) is valid
# Lisp but mis-indented by `calculate-lisp-indent'; running
# `indent-region' on it corrupts the layout, so only trailing
# whitespace is cleaned there.  Every other file gets `emacs-lisp-mode'
# before indenting.
# `timeout --foreground' keeps the batch Emacs killable by Ctrl+C (no
# separate process group) while still guaranteeing the step cannot hang:
# `with-temp-buffer' avoids find-file/save-buffer entirely, so no file-local
# vars, mode hooks, or "create directory?" prompts can ever block it.
timeout --foreground 60 emacs --batch -L . --eval '(progn
        (dolist (file (append (file-expand-wildcards "*.el")
                              (file-expand-wildcards "test/*.el")))
          (let ((excluded (member (file-name-nondirectory file)
                                  (list "crush-stream.el")))
                (abs (expand-file-name file)))
            (with-temp-buffer
              (insert-file-contents abs)
              (emacs-lisp-mode)
              (setq indent-tabs-mode nil)
              (unless excluded
                (indent-region (point-min) (point-max)))
              (delete-trailing-whitespace)
              (write-region (point-min) (point-max) abs))
            (message "  %s%s" file
                     (if excluded " (skipped indent)" "")))))' 2>&1 | grep -E "^  " || true

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
