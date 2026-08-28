;;; quoth-test-reasoning.el --- Chain-of-thought overlay lifecycle tests  -*- lexical-binding: t; -*-

;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/quoth
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience

;;; This file is not part of GNU Emacs.

;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the rights
;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;;; copies of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:

;;; The above copyright notice and this permission notice shall be included in all
;;; copies or substantial portions of the Software.

;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:
;;; Chain-of-thought overlay lifecycle, region tagging on finalize and interrupt, separation.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth"))
    (unless (require (intern dep) nil t)
      (let* ((base (file-name-directory
                    (or buffer-file-name load-file-name default-directory)))
             (dirs (list base (expand-file-name ".." base)))
             (loaded nil))
        (dolist (dir dirs)
          (unless loaded
            (let ((file (expand-file-name (concat dep ".el") dir)))
              (when (file-exists-p file)
                (load file nil t)
                (setq loaded t)))))))))

(declare-function quoth-test--fresh-buffer "quoth-test")
(declare-function quoth-test--cleanup "quoth-test")
(declare-function quoth-test--kill-quoth-buffer "quoth-test")
(defvar quoth-test--root)

;;; 92a2. Hyper transport: reasoning overlay lifecycle

(defun quoth-test--with-reasoning-process (thunk)
  "Run THUNK with a fake hyper pipe process targeting a fresh quoth buffer."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "quoth-hyper-test-reason"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :quoth-target (current-buffer))
            (unwind-protect
                (funcall thunk proc)
              (delete-process proc))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/hyper-reasoning-overlay-created-on-first-delta ()
  "A reasoning delta creates a yellow overlay tagged quoth-overlay."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (quoth-facade--append-delta "think" 'reasoning)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (eq (overlay-get ov 'face) 'quoth-reasoning-face))
       (should (overlay-get ov 'quoth-overlay))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think"))))))

(ert-deftest quoth-test/reasoning-stream-moves-cursor ()
  "Point should follow the reasoning stream when cursor is at point-max."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (goto-char (point-max))
     (quoth-facade--append-delta "think" 'reasoning)
     (should (= (point) (point-max)))
     (quoth-facade--append-delta " harder" 'reasoning)
     (should (= (point) (point-max)))
     (should (string= (buffer-substring-no-properties
                       (- (point) (length " harder")) (point))
                      " harder")))))

(ert-deftest quoth-test/hyper-reasoning-overlay-grows-with-deltas ()
  "Subsequent reasoning deltas extend the overlay."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (quoth-facade--append-delta "think" 'reasoning)
     (quoth-facade--append-delta " harder" 'reasoning)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think harder"))))))

(ert-deftest quoth-test/hyper-content-delta-stops-reasoning-overlay ()
  "First content delta stops the reasoning overlay."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (quoth-facade--append-delta "think" 'reasoning)
     (quoth-facade--append-delta " hard" 'reasoning)
     (quoth-facade--append-delta "answer" 'content)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think hard\n"))))))

(ert-deftest quoth-test/content-delta-inserts-blank-separator ()
  "The first content delta after reasoning adds two newlines before it."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (quoth-facade--append-delta "think" 'reasoning)
     (quoth-facade--append-delta "answer" 'content)
     (goto-char (point-min))
     (search-forward "answer")
     (let ((answer-start (match-beginning 0)))
       (should (string= (buffer-substring (- answer-start 2) answer-start)
                        "\n\n"))))))

(ert-deftest quoth-test/hyper-content-only-no-reasoning-state ()
  "Content-only stream leaves reasoning state nil."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (quoth-facade--append-delta "answer" 'content)
     (should-not (overlays-in (point-min) (point-max)))
     (should-not quoth--reasoning-start)
     (should-not quoth--reasoning-overlay))))

;;; 92a3. Finalize: reasoning region tagging

(defun quoth-test--finalize-with-reasoning (insert-fn)
  "Run INSERT-FN in a fresh quoth buffer, finalize, then return it.
INSERT-FN receives the process; the buffer has a response region
open (`quoth--response-start' at point-max after a newline)."
  (let ((default-directory quoth-test--root)
        result)
    (unwind-protect
        (setq result (with-current-buffer (quoth-test--fresh-buffer)
                       (save-excursion (goto-char (point-max)) (newline))
                       (setq-local quoth--response-start (point-marker))
                       (let ((proc (make-pipe-process :name "quoth-hyper-test-fin"
                                                      :noquery t
                                                      :coding 'binary)))
                         (process-put proc :quoth-target (current-buffer))
                         (unwind-protect
                             (progn
                               (funcall insert-fn proc)
                               (quoth-facade--finalize))
                           (delete-process proc)))
                       (current-buffer)))
      (unless result (quoth-test--cleanup)))
    result))

(ert-deftest quoth-test/finalize-tags-reasoning-region ()
  "Reasoning text should be tagged `quoth-region-type' reasoning."
  (let ((expected-id nil))
    (let ((buf (quoth-test--finalize-with-reasoning
                (lambda (_proc)
                  (setq expected-id quoth--prompt-id)
                  (quoth-facade--append-delta "think hard" 'reasoning)
                  (quoth-facade--append-delta "answer" 'content)))))
      (with-current-buffer buf
        (let ((start (save-excursion
                       (goto-char (point-min))
                       (search-forward "think")
                       (match-beginning 0)))
              (end (save-excursion
                     (goto-char (point-min))
                     (search-forward "hard")
                     (point))))
          (should (eq (get-text-property start 'quoth-region-type) 'reasoning))
          (should (eq (get-text-property (1- end) 'quoth-region-type) 'reasoning))
          (should (string= (get-text-property start 'quoth-prompt-id)
                           expected-id))))
      (quoth-test--kill-quoth-buffer))))

(ert-deftest quoth-test/finalize-tags-response-around-reasoning ()
  "The response region should cover the whole answer including reasoning."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta "think" 'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (search-forward "answer")
        (let ((end (point)))
          (should (eq (get-text-property (1- end) 'quoth-region-type) 'response)))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/finalize-resets-reasoning-state ()
  "Finalize should reset reasoning markers even with no content."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta "think" 'reasoning)))))
    (with-current-buffer buf
      (should-not quoth--reasoning-start)
      (should-not quoth--reasoning-end)
      (should-not quoth--reasoning-overlay))
    (quoth-test--kill-quoth-buffer)))

;;; Fold: preview overlay + body overlay for >10 lines, no fold for <=10
;;;
;;; Overlay-only model: the fold marker lives in the body overlay's
;;; `before-string' (display-only, not buffer text).  No `…' character
;;; is inserted into the buffer.  Toggle is via the overlay keymap.

(defun quoth-test--reasoning-fold-overlay (&optional buffer)
  "Return the body overlay (invisible, folded) in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (car (cl-remove-if-not
          (lambda (o) (overlay-get o 'quoth-fold-state))
          (overlays-in (point-min) (point-max))))))

(defun quoth-test--reasoning-preview-overlay (&optional buffer)
  "Return the preview overlay (first N lines) in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (car (cl-remove-if-not
          (lambda (o) (overlay-get o 'quoth-reasoning-preview))
          (overlays-in (point-min) (point-max))))))

(defun quoth-test--reasoning-marker-overlay (&optional buffer)
  "Return the marker overlay (after-string fold marker) in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (car (cl-remove-if-not
          (lambda (o) (overlay-get o 'quoth-reasoning-marker))
          (overlays-in (point-min) (point-max))))))

(defun quoth-test--reasoning-lines (n)
  "Return a string of N numbered lines separated by newlines."
  (mapconcat #'identity
             (cl-loop for i from 1 to n
                      collect (format "line %d" i))
             "\n"))

(ert-deftest quoth-test/finalize-auto-collapses-reasoning ()
  "Finalize should auto-collapse reasoning > 10 lines with a preview.
The body overlay is invisible with a marker overlay's `after-string'."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 12)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay))
            (preview-ov (quoth-test--reasoning-preview-overlay))
            (marker-ov (quoth-test--reasoning-marker-overlay)))
        (should (overlayp body-ov))
        (should (eq (overlay-get body-ov 'invisible) 'quoth-reasoning-fold))
        (should (overlayp marker-ov))
        (should (stringp (overlay-get marker-ov 'after-string)))
        (should (overlayp preview-ov))
        (should (eq (overlay-get preview-ov 'face) 'quoth-reasoning-face))
        (should (= (count-lines (overlay-start preview-ov)
                                (overlay-end preview-ov))
                   10))))

    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/finalize-no-fold-for-10-or-fewer-lines ()
  "Reasoning of 10 lines or fewer should stay visible with no fold."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 10)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (should-not (quoth-test--reasoning-fold-overlay))
      (should-not (quoth-test--reasoning-preview-overlay))
      (goto-char (point-min))
      (should (search-forward "line 1" nil t))
      (should (search-forward "line 10" nil t)))

    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/finalize-fold-marker-is-before-string ()
  "The fold marker is a display-only `after-string' on a marker overlay.
No `quoth-fold-mark' text property."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((marker-ov (quoth-test--reasoning-marker-overlay)))
        (should (overlayp marker-ov))
        (let ((as (overlay-get marker-ov 'after-string)))
          (should (stringp as))
          ;; The after-string carries the toggle keymap.
          (should (keymapp (get-text-property 0 'keymap as)))
          (should (eq (lookup-key (get-text-property 0 'keymap as) (kbd "TAB"))
                      #'quoth-reasoning-toggle))))
      ;; No quoth-fold-mark text property anywhere.
      (let ((pos (point-min))
            (found nil))
        (while (and (not found) (< pos (point-max)))
          (when (get-text-property pos 'quoth-fold-mark)
            (setq found t))
          (setq pos (1+ pos)))
        (should-not found)))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/finalize-snaps-fold-to-lines ()
  "The preview overlay ends at the N-th line boundary."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((preview-ov (quoth-test--reasoning-preview-overlay))
            (body-ov (quoth-test--reasoning-fold-overlay)))
        (should (overlayp preview-ov))
        (should (overlayp body-ov))
        ;; Preview ends where body starts.
        (should (= (overlay-end preview-ov) (overlay-start body-ov)))
        ;; Body starts at line 11.  The body overlay now begins at the
        ;; start of the line (past the preview's trailing newline), so
        ;; point is already looking at "line 11" — no forward-line needed.
        (goto-char (overlay-start body-ov))
        (should (looking-at "line 11"))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/finalize-content-only-no-fold ()
  "Content-only responses should get no fold control."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (should-not (quoth-test--reasoning-fold-overlay))
      (goto-char (point-min))
      (should-not (search-forward "…" nil t)))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/toggle-expands-collapsed-reasoning ()
  "Quoth-reasoning-toggle should expand a collapsed reasoning region.
No buffer text is inserted or deleted — only overlay properties change."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay)))
        (should (eq (overlay-get body-ov 'quoth-fold-state) 'collapsed))
        ;; Point on the body overlay.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (eq (overlay-get body-ov 'quoth-fold-state) 'expanded))
        (should-not (overlay-get body-ov 'invisible))
        ;; Marker overlay's after-string is hidden when expanded.
        (should-not (overlay-get (quoth-test--reasoning-marker-overlay)
                                 'after-string))
        ;; Hidden content is now visible.  Body starts at line 11
        ;; (past the preview's trailing newline), so no forward-line.
        (goto-char (overlay-start body-ov))
        (should (looking-at "line 11"))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/toggle-collapses-expanded-reasoning ()
  "Quoth-reasoning-toggle should collapse an expanded reasoning region."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay)))
        ;; Expand first.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (eq (overlay-get body-ov 'quoth-fold-state) 'expanded))
        ;; Collapse.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (eq (overlay-get body-ov 'quoth-fold-state) 'collapsed))
        (should (eq (overlay-get body-ov 'invisible) 'quoth-reasoning-fold))
        (should (eq (overlay-get body-ov 'intangible) t))
        (should (stringp (overlay-get (quoth-test--reasoning-marker-overlay)
                                      'after-string)))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/toggle-no-fold-at-point ()
  "Quoth-reasoning-toggle should message when no fold is at point."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (quoth-reasoning-toggle)
          (should (equal messages '("No reasoning fold at point"))))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-arrow-up-past-collapsed ()
  "Collapsed fold body overlay must be intangible so navigation skips it.
`intangible t' alongside `invisible t' ensures cursor motion commands
`line-move', `previous-line', etc. jump over the hidden region instead of
getting stuck at its boundary (which caused 'Beginning of buffer')."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        ;; The body overlay must be both invisible and intangible.
        (should (eq (overlay-get body-ov 'invisible) 'quoth-reasoning-fold))
        (should (eq (overlay-get body-ov 'intangible) t))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-before-string-is-intangible ()
  "The fold marker overlay must NOT carry `intangible'.
The marker overlay is at a visible position (before the invisible body),
so its `after-string' text must be tangible for `line-move-visual' to
navigate through it.  Making the marker intangible was the cause of the
arrow-up navigation bug."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((marker-ov (quoth-test--reasoning-marker-overlay)))
        (should (overlayp marker-ov))
        ;; The marker overlay must NOT be intangible.
        (should-not (overlay-get marker-ov 'intangible))
        ;; The after-string text must NOT carry intangible either.
        (let ((as (overlay-get marker-ov 'after-string)))
          (should (stringp as))
          (should-not (get-text-property 0 'intangible as)))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-named-invisibility-spec ()
  "Test that collapsed reasoning uses a named invisibility spec.
This ensures buffer-reading tools (markdown-preview, export) see the full text."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        ;; Named spec, not bare t.
        (should (eq (overlay-get body-ov 'invisible) 'quoth-reasoning-fold))
        ;; buffer-invisibility-spec includes our spec.
        (should (member 'quoth-reasoning-fold buffer-invisibility-spec))
        ;; The hidden text is still in the buffer.
        (goto-char (overlay-start body-ov))
        (should (search-forward "line 11" (overlay-end body-ov) t))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-tab-from-preview ()
  "TAB from inside the preview overlay should toggle the fold.
The preview overlay carries the toggle keymap so TAB works from
the visible preview lines."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay))
            (preview-ov (quoth-test--reasoning-preview-overlay)))
        (should (overlayp body-ov))
        (should (overlayp preview-ov))
        ;; Place point inside the preview overlay.
        (goto-char (+ (overlay-start preview-ov) 2))
        (should (<= (overlay-start preview-ov) (point)))
        (should (< (point) (overlay-end preview-ov)))
        ;; Toggle should expand the body via the preview overlay.
        (quoth-reasoning-toggle)
        (should (eq (overlay-get body-ov 'quoth-fold-state) 'expanded))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/toggle-via-tab-on-overlay ()
  "Pressing TAB inside the body overlay should toggle the fold."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay)))
        ;; Point inside the body overlay.
        (goto-char (overlay-start body-ov))
        (funcall #'quoth--reasoning-tab)
        (should (eq (overlay-get body-ov 'quoth-fold-state) 'expanded))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/chat-map-binds-reasoning-toggle ()
  "The reasoning-toggle binding resolves to `quoth-reasoning-toggle'."
  (should (eq (lookup-key (symbol-value 'quoth-chat-command-map) (kbd "r"))
              #'quoth-reasoning-toggle)))

(ert-deftest quoth-test/no-toggle-for-10-or-fewer-lines ()
  "Toggling should be a no-op when reasoning is 10 lines or fewer."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 10)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (quoth-reasoning-toggle)
          (should (equal messages '("No reasoning fold at point"))))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-no-character-eating ()
  "Expand/collapse cycles must not insert or delete buffer text.
The buffer size stays constant across multiple toggle cycles."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay))
            (size-before (buffer-size)))
        ;; Expand.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (= (buffer-size) size-before))
        ;; Collapse.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (= (buffer-size) size-before))
        ;; Expand again.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (= (buffer-size) size-before))
        ;; Collapse again.
        (goto-char (overlay-start body-ov))
        (quoth-reasoning-toggle)
        (should (= (buffer-size) size-before))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-reasoning-region-contiguous ()
  "The reasoning region stays contiguous — no gap from a fold marker.
All text from the first reasoning char to the last has
`quoth-region-type' `reasoning'."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "line 1")
      (let ((start (match-beginning 0)))
        (search-forward "line 11")
        (let ((end (point)))
          ;; Every char between line 1 and line 11 must be reasoning.
          (let ((pos start)
                (bad nil))
            (while (and (not bad) (< pos end))
              (unless (eq (get-text-property pos 'quoth-region-type) 'reasoning)
                (setq bad t))
              (setq pos (1+ pos)))
            (should-not bad))
          ;; No nil-typed gap in the reasoning span.
          (should-not (text-property-any start end 'quoth-region-type nil)))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/interrupt-auto-collapses-reasoning ()
  "Quoth-interrupt should auto-collapse partial reasoning."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local quoth--response-start (point-marker))
          (let ((proc (make-pipe-process :name "quoth-hyper-test-int2"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :quoth-target (current-buffer))
            (unwind-protect
                (progn
                  (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                              'reasoning)
                  ;; The provider transport is the interrupt target; the
                  ;; pipe process cannot be interrupted, so mock the abort.
                  (setq-local quoth-active-provider
                              (quoth-make-hyper-provider
                               :buffer (current-buffer)
                               :working-directory default-directory))
                  (setf (quoth-provider-transport-process
                         quoth-active-provider)
                        proc)
                  (cl-letf (((symbol-function 'quoth-openai-abort)
                             (lambda (_p) nil)))
                    (quoth-interrupt)))
              (delete-process proc)))
          (let ((ov (quoth-test--reasoning-fold-overlay)))
            (should (overlayp ov))
            (should (eq (overlay-get ov 'quoth-fold-state) 'collapsed))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/clear-buffer-removes-fold-overlay ()
  "Quoth-clear-buffer should delete the reasoning fold overlay."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "quoth-hyper-test-clr2"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :quoth-target (current-buffer))
            (unwind-protect
                (progn
                  (quoth-facade--append-delta "think" 'reasoning)
                  (quoth-clear-buffer)
                  (should-not (quoth-test--reasoning-fold-overlay))
                  (should-not (overlays-in (point-min) (point-max))))
              (delete-process proc))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/interrupt-tags-reasoning-region ()
  "Quoth-interrupt should tag streamed reasoning up to the interrupt."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local quoth--response-start (point-marker))
          (let ((proc (make-pipe-process :name "quoth-hyper-test-int"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :quoth-target (current-buffer))
            (unwind-protect
                (progn
                  (quoth-facade--append-delta "think hard" 'reasoning)
                  ;; The provider transport is the interrupt target; the
                  ;; pipe process cannot be interrupted, so mock the abort.
                  (setq-local quoth-active-provider
                              (quoth-make-hyper-provider
                               :buffer (current-buffer)
                               :working-directory default-directory))
                  (setf (quoth-provider-transport-process
                         quoth-active-provider)
                        proc)
                  (cl-letf (((symbol-function 'quoth-openai-abort)
                             (lambda (_p) nil)))
                    (quoth-interrupt)))
              (delete-process proc)))
          (let ((start (save-excursion
                         (goto-char (point-min))
                         (search-forward "think")
                         (match-beginning 0))))
            (should (eq (get-text-property start 'quoth-region-type) 'reasoning))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/clear-buffer-removes-reasoning-overlay ()
  "Quoth-clear-buffer should delete the reasoning overlay."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "quoth-hyper-test-clr"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :quoth-target (current-buffer))
            (unwind-protect
                (progn
                  (quoth-facade--append-delta "think" 'reasoning)
                  (should (overlays-in (point-min) (point-max)))
                  (quoth-clear-buffer)
                  (should-not (overlays-in (point-min) (point-max)))
                  (should-not quoth--reasoning-overlay))
              (delete-process proc))))
      (quoth-test--cleanup))))

;;; Multi-round tool calls: reasoning is interleaved with tool blocks.
;;; Each round's reasoning must be independently foldable.

(ert-deftest quoth-test/multi-round-reasoning-folds-independently ()
  "Each tool round's reasoning should get its own fold."
  (let ((default-directory quoth-test--root)
        (expected-id nil))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (setq expected-id quoth--prompt-id)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local quoth--response-start (point-marker))
          ;; Round 1: 11 lines of reasoning then tool block.
          (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                      'reasoning)
          (quoth--reasoning-stop)
          (quoth--reasoning-reset)
          ;; Round 2: 11 lines of reasoning then content.
          (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                      'reasoning)
          (quoth-facade--append-delta "answer" 'content)
          (quoth-facade--close-response
           (marker-position quoth--response-start) expected-id)
          ;; Two fold overlays.
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'quoth-fold-state)
                (push ov folds)))
            (should (= (length folds) 2))
            (dolist (ov folds)
              (should (eq (overlay-get ov 'invisible) 'quoth-reasoning-fold)))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/multi-round-reasoning-fold-toggles-independently ()
  "Toggling a fold should only affect that reasoning round."
  (let ((default-directory quoth-test--root)
        (expected-id nil))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (setq expected-id quoth--prompt-id)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local quoth--response-start (point-marker))
          (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                      'reasoning)
          (quoth--reasoning-stop)
          (quoth--reasoning-reset)
          (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                      'reasoning)
          (quoth-facade--append-delta "answer" 'content)
          (quoth-facade--close-response
           (marker-position quoth--response-start) expected-id)
          ;; Expand the first fold.
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'quoth-fold-state)
                (push ov folds)))
            (goto-char (overlay-start (car folds)))
            (quoth-reasoning-toggle))
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'quoth-fold-state)
                (push ov folds)))
            (should (= (length folds) 2))
            (let ((expanded (cl-find-if (lambda (o) (eq (overlay-get o 'quoth-fold-state) 'expanded)) folds))
                  (collapsed (cl-find-if (lambda (o) (eq (overlay-get o 'quoth-fold-state) 'collapsed)) folds)))
              (should (overlayp expanded))
              (should (overlayp collapsed))
              (should-not (overlay-get expanded 'invisible))
              (should (eq (overlay-get collapsed 'invisible) 'quoth-reasoning-fold)))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/multi-round-reasoning-with-tool-blocks ()
  "Reasoning overlays before tool blocks should be foldable."
  (let ((default-directory quoth-test--root)
        (expected-id nil))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (setq expected-id quoth--prompt-id)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local quoth--response-start (point-marker))
          ;; Round 1: 11 lines of reasoning then tool block insertion.
          (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                      'reasoning)
          (quoth--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>"
                 :exit 0)
           expected-id)
          (let ((rs (marker-position quoth--response-start)))
            (quoth--tag-response-region rs (point) expected-id))
          (quoth--reasoning-reset)
          (setq-local quoth--response-start (point-marker))
          ;; Round 2: 11 lines of reasoning then content.
          (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                      'reasoning)
          (quoth-facade--append-delta "answer" 'content)
          (quoth-facade--close-response
           (marker-position quoth--response-start) expected-id)
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'quoth-fold-state)
                (push ov folds)))
            (should (= (length folds) 2))
            (dolist (ov folds)
              (should (eq (overlay-get ov 'invisible) 'quoth-reasoning-fold)))))
      (quoth-test--cleanup))))

;;; 97. Region tagging: reasoning + tool blocks in one response
;;;
;;; `quoth--tag-response-region' must tag the content-before-toolblock
;;; span, the tool blocks, and the content-after-toolblock span so the
;;; header line shows the right region type at any point.  Regression
;;; for the header-line region label showing "plain"/"prompt" instead
;;; of "tool" when point sat on a tool block (the old code derived the
;;; reasoning sub-span only from the reasoning overlay, which ends
;;; before the first tool block, and never re-tagged the response).

(ert-deftest quoth-test/tools-reasoning-tags-content-and-tools ()
  "Test that a response with reasoning, tool blocks, and content tags every span.
The reasoning is tagged on the CoT text, tool on the tool blocks, and
response on the final content."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-facade--append-delta "think hard" 'reasoning)
          (quoth--tool-block-insert
           (list :name "bash" :id "call_1" :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>" :exit 0)
           quoth--prompt-id)
          (quoth-facade--append-delta "final answer" 'content)
          ;; The finalize flow tags the full response through point-max.
          (goto-char (point-max))
          (newline)
          (quoth--tag-response-region (marker-position quoth--response-start)
                                      (point) quoth--prompt-id)
          (goto-char (point-min))
          (search-forward "think")
          (should (eq (get-text-property (match-beginning 0) 'quoth-region-type)
                      'reasoning))
          (search-forward "🛠️ bash")
          (should (eq (get-text-property (match-beginning 0) 'quoth-region-type)
                      'tool))
          (search-forward "final answer")
          (should (eq (get-text-property (match-beginning 0) 'quoth-region-type)
                      'response)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tools-reasoning-tags-tool-blocks-tagged ()
  "Test that the tool block itself carries the tool region type.
The `quoth-region-type' tool tag appears even when the response has
reasoning, so the header line shows region: tool."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-facade--append-delta "think" 'reasoning)
          (quoth--tool-block-insert
           (list :name "bash" :id "call_1" :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>" :exit 0)
           quoth--prompt-id)
          (goto-char (point-max))
          (newline)
          (quoth--tag-response-region (marker-position quoth--response-start)
                                      (point) quoth--prompt-id)
          (goto-char (point-min))
          (search-forward "🛠️ bash")
          (should (eq (get-text-property (match-beginning 0) 'quoth-region-type)
                      'tool))
          (should (string= (quoth--region-label-at-point) "tool")))
      (quoth-test--cleanup))))

;;; 98. Overlay newline invariants: ensure reasoning overlay always ends
;;; with a newline so `:extend t' paints the last line's background to
;;; EOL, the fold `before-string' marker starts on its own line, and
;;; the marker carries the reasoning face for a consistent background.

(ert-deftest quoth-test/reasoning-overlay-ends-with-newline ()
  "The reasoning overlay must end with a newline after `quoth--reasoning-stop'.
This ensures `:extend t' on `quoth-reasoning-face' paints the last
line's background to the end of the screen line."
  (quoth-test--with-reasoning-process
   (lambda (_proc)
     (quoth-facade--append-delta "think hard" 'reasoning)
     (quoth--reasoning-stop)
     (let ((ov quoth--reasoning-overlay))
       (should (overlayp ov))
       (should (eq (char-before (overlay-end ov)) ?\n))))))

(ert-deftest quoth-test/fold-before-string-on-own-line ()
  "The fold before-string marker must start on its own line.
`preview-end' must be past the newline after the last preview line
so the body overlay (and its before-string) starts at the beginning
of the next line."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay))
            (preview-ov (quoth-test--reasoning-preview-overlay)))
        (should (overlayp body-ov))
        (should (overlayp preview-ov))
        ;; preview-end is the body start; the char before it is a newline.
        (should (eq (char-before (overlay-start body-ov)) ?\n))
        ;; preview-end is at the beginning of a line.
        (save-excursion
          (goto-char (overlay-start body-ov))
          (should (bolp)))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-before-string-has-reasoning-face ()
  "The fold marker must carry `quoth-reasoning-face'.
This gives the marker line the same background color as the reasoning
text for visual consistency."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((marker-ov (quoth-test--reasoning-marker-overlay)))
        (should (overlayp marker-ov))
        (let ((as (overlay-get marker-ov 'after-string)))
          (should (stringp as))
          (should (eq (get-text-property 0 'face as) 'quoth-reasoning-face)))))
    (quoth-test--kill-quoth-buffer)))

(ert-deftest quoth-test/fold-preview-includes-trailing-newline ()
  "The preview overlay must include the trailing newline of its last line.
This ensures the last preview line's background extends to EOL via
`:extend t', matching the reasoning overlay's own trailing newline."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((preview-ov (quoth-test--reasoning-preview-overlay)))
        (should (overlayp preview-ov))
        ;; The char before preview-end is a newline.
        (should (eq (char-before (overlay-end preview-ov)) ?\n))))
    (quoth-test--kill-quoth-buffer)))

;;; 99. Arrow-up past collapsed fold: the fold marker must not block
;;; vertical navigation.  `line-move-visual' / `previous-line' from
;;; below the collapsed fold must skip the marker and land in the
;;; preview, not signal `beginning-of-buffer'.

(ert-deftest quoth-test/fold-arrow-up-past-marker ()
  "The fold marker must not block vertical navigation.
The marker must NOT be a `before-string' on the invisible body overlay,
because `before-string' text at an invisible+intangible position creates
a navigation trap: `line-move-visual' targets the marker's visual line
but cannot land point there (the position is invisible), so it signals
`beginning-of-buffer'.

Instead, the marker must be an `after-string' on a separate visible
overlay at the boundary between preview and body.  This overlay is at a
visible position, so the marker text is tangible and navigable."
  (let ((buf (quoth-test--finalize-with-reasoning
              (lambda (_proc)
                (quoth-facade--append-delta (quoth-test--reasoning-lines 11)
                                            'reasoning)
                (quoth-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (quoth-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        ;; The body overlay must NOT carry a before-string.
        (should-not (overlay-get body-ov 'before-string)))
      ;; There must be a separate marker overlay with after-string.
      (let* ((marker-ov nil)
             (marker-text "... reasoning"))
        (dolist (ov (overlays-in (point-min) (point-max)))
          (when (and (overlay-get ov 'quoth-overlay)
                     (overlay-get ov 'after-string)
                     (string-match-p marker-text
                                     (overlay-get ov 'after-string)))
            (setq marker-ov ov)))
        (should (overlayp marker-ov))
        ;; The marker overlay must be at a position NOT inside the body overlay.
        (let ((body-ov (quoth-test--reasoning-fold-overlay)))
          (should (or (< (overlay-start marker-ov) (overlay-start body-ov))
                      (> (overlay-start marker-ov) (overlay-end body-ov)))))))
    (quoth-test--kill-quoth-buffer)))

(provide 'quoth-test-reasoning)
;;; quoth-test-reasoning.el ends here
