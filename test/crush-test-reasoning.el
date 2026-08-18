;;; crush-test-reasoning.el --- Chain-of-thought overlay lifecycle tests  -*- lexical-binding: t; -*-

;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/crush.el
;;; Version: 0.1.0
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
  (dolist (dep '("crush"))
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

(declare-function crush-test--fresh-buffer "crush-test")
(declare-function crush-test--cleanup "crush-test")
(declare-function crush-test--kill-crush-buffer "crush-test")
(defvar crush-test--root)

;;; 92a2. Hyper transport: reasoning overlay lifecycle

(defun crush-test--with-reasoning-process (thunk)
  "Run THUNK with a fake hyper pipe process targeting a fresh crush buffer."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "crush-hyper-test-reason"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-target (current-buffer))
            (unwind-protect
                (funcall thunk proc)
              (delete-process proc))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-reasoning-overlay-created-on-first-delta ()
  "A reasoning delta creates a yellow overlay tagged crush-overlay."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (crush-facade--append-delta "think" 'reasoning)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (eq (overlay-get ov 'face) 'crush-reasoning-face))
       (should (overlay-get ov 'crush-overlay))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think"))))))

(ert-deftest crush-test/reasoning-stream-moves-cursor ()
  "Point should follow the reasoning stream when cursor is at point-max."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (goto-char (point-max))
     (crush-facade--append-delta "think" 'reasoning)
     (should (= (point) (point-max)))
     (crush-facade--append-delta " harder" 'reasoning)
     (should (= (point) (point-max)))
     (should (string= (buffer-substring-no-properties
                       (- (point) (length " harder")) (point))
                      " harder")))))

(ert-deftest crush-test/hyper-reasoning-overlay-grows-with-deltas ()
  "Subsequent reasoning deltas extend the overlay."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (crush-facade--append-delta "think" 'reasoning)
     (crush-facade--append-delta " harder" 'reasoning)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think harder"))))))

(ert-deftest crush-test/hyper-content-delta-freezes-reasoning-overlay ()
  "First content delta freezes the reasoning overlay."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (crush-facade--append-delta "think" 'reasoning)
     (crush-facade--append-delta " hard" 'reasoning)
     (crush-facade--append-delta "answer" 'content)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think hard"))))))

(ert-deftest crush-test/content-delta-inserts-blank-separator ()
  "The first content delta after reasoning adds two newlines before it."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (crush-facade--append-delta "think" 'reasoning)
     (crush-facade--append-delta "answer" 'content)
     (goto-char (point-min))
     (search-forward "answer")
     (let ((answer-start (match-beginning 0)))
       (should (string= (buffer-substring (- answer-start 2) answer-start)
                        "\n\n"))))))

(ert-deftest crush-test/hyper-content-only-no-reasoning-state ()
  "Content-only stream leaves reasoning state nil."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (crush-facade--append-delta "answer" 'content)
     (should-not (overlays-in (point-min) (point-max)))
     (should-not crush--reasoning-start)
     (should-not crush--reasoning-overlay))))

;;; 92a3. Finalize: reasoning region tagging

(defun crush-test--finalize-with-reasoning (insert-fn)
  "Run INSERT-FN in a fresh crush buffer, finalize, then return it.
INSERT-FN receives the process; the buffer has a response region
open (`crush--response-start' at point-max after a newline)."
  (let ((default-directory crush-test--root)
        result)
    (unwind-protect
        (setq result (with-current-buffer (crush-test--fresh-buffer)
                       (save-excursion (goto-char (point-max)) (newline))
                       (setq-local crush--response-start (point-marker))
                       (let ((proc (make-pipe-process :name "crush-hyper-test-fin"
                                                      :noquery t
                                                      :coding 'binary)))
                         (process-put proc :crush-target (current-buffer))
                         (unwind-protect
                             (progn
                               (funcall insert-fn proc)
                               (crush-facade--finalize))
                           (delete-process proc)))
                       (current-buffer)))
      (unless result (crush-test--cleanup)))
    result))

(ert-deftest crush-test/finalize-tags-reasoning-region ()
  "Reasoning text should be tagged `crush-region-type' reasoning."
  (let ((expected-id nil))
    (let ((buf (crush-test--finalize-with-reasoning
                (lambda (_proc)
                  (setq expected-id crush--prompt-id)
                  (crush-facade--append-delta "think hard" 'reasoning)
                  (crush-facade--append-delta "answer" 'content)))))
      (with-current-buffer buf
        (let ((start (save-excursion
                       (goto-char (point-min))
                       (search-forward "think")
                       (match-beginning 0)))
              (end (save-excursion
                     (goto-char (point-min))
                     (search-forward "hard")
                     (point))))
          (should (eq (get-text-property start 'crush-region-type) 'reasoning))
          (should (eq (get-text-property (1- end) 'crush-region-type) 'reasoning))
          (should (string= (get-text-property start 'crush-prompt-id)
                           expected-id))))
      (crush-test--kill-crush-buffer))))

(ert-deftest crush-test/finalize-tags-response-around-reasoning ()
  "The response region should cover the whole answer including reasoning."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "think" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (search-forward "answer")
        (let ((end (point)))
          (should (eq (get-text-property (1- end) 'crush-region-type) 'response)))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-resets-reasoning-state ()
  "Finalize should reset reasoning markers even with no content."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "think" 'reasoning)))))
    (with-current-buffer buf
      (should-not crush--reasoning-start)
      (should-not crush--reasoning-end)
      (should-not crush--reasoning-overlay))
    (crush-test--kill-crush-buffer)))

;;; Fold: preview overlay + body overlay for >10 lines, no fold for <=10
;;;
;;; Overlay-only model: the fold marker lives in the body overlay's
;;; `before-string' (display-only, not buffer text).  No `…' character
;;; is inserted into the buffer.  Toggle is via the overlay keymap.

(defun crush-test--reasoning-fold-overlay (&optional buffer)
  "Return the body overlay (invisible, folded) in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (car (cl-remove-if-not
          (lambda (o) (overlay-get o 'crush-fold-state))
          (overlays-in (point-min) (point-max))))))

(defun crush-test--reasoning-preview-overlay (&optional buffer)
  "Return the preview overlay (first N lines) in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (car (cl-remove-if-not
          (lambda (o) (overlay-get o 'crush-reasoning-preview))
          (overlays-in (point-min) (point-max))))))

(defun crush-test--reasoning-lines (n)
  "Return a string of N numbered lines separated by newlines."
  (mapconcat #'identity
             (cl-loop for i from 1 to n
                      collect (format "line %d" i))
             "\n"))

(ert-deftest crush-test/finalize-auto-collapses-reasoning ()
  "Finalize should auto-collapse reasoning > 10 lines with a preview.
The body overlay is invisible with a `before-string' marker.  No `…'
character is inserted into the buffer."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 12)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay))
            (preview-ov (crush-test--reasoning-preview-overlay)))
        (should (overlayp body-ov))
        (should (eq (overlay-get body-ov 'invisible) 'crush-reasoning-fold))
        (should (stringp (overlay-get body-ov 'before-string)))
        (should (overlayp preview-ov))
        (should (eq (overlay-get preview-ov 'face) 'crush-reasoning-face))
        (should (= (count-lines (overlay-start preview-ov)
                                (overlay-end preview-ov))
                   10))
        ;; No ellipsis character in the buffer.
        (goto-char (point-min))
        (should-not (search-forward "…" nil t))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-no-fold-for-10-or-fewer-lines ()
  "Reasoning of 10 lines or fewer should stay visible with no fold."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 10)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (should-not (crush-test--reasoning-fold-overlay))
      (should-not (crush-test--reasoning-preview-overlay))
      (goto-char (point-min))
      (should (search-forward "line 1" nil t))
      (should (search-forward "line 10" nil t))
      ;; No ellipsis in the buffer.
      (should-not (search-forward "…" nil t)))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-fold-marker-is-before-string ()
  "The fold marker is a display-only `before-string' on the body overlay.
No `crush-fold-mark' text property, no `…' in the buffer."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        (let ((bs (overlay-get body-ov 'before-string)))
          (should (stringp bs))
          ;; The before-string carries the toggle keymap.
          (should (keymapp (get-text-property 0 'keymap bs)))
          (should (eq (lookup-key (get-text-property 0 'keymap bs) (kbd "TAB"))
                      #'crush-reasoning-toggle))))
      ;; No ellipsis character in the buffer.
      (goto-char (point-min))
      (should-not (search-forward "…" nil t))
      ;; No crush-fold-mark text property anywhere.
      (let ((pos (point-min))
            (found nil))
        (while (and (not found) (< pos (point-max)))
          (when (get-text-property pos 'crush-fold-mark)
            (setq found t))
          (setq pos (1+ pos)))
        (should-not found)))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-snaps-fold-to-lines ()
  "The preview overlay ends at the N-th line boundary."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((preview-ov (crush-test--reasoning-preview-overlay))
            (body-ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp preview-ov))
        (should (overlayp body-ov))
        ;; Preview ends where body starts.
        (should (= (overlay-end preview-ov) (overlay-start body-ov)))
        ;; Body starts at line 11.
        (goto-char (overlay-start body-ov))
        (forward-line)
        (should (looking-at "line 11"))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-content-only-no-fold ()
  "Content-only responses should get no fold control."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (should-not (crush-test--reasoning-fold-overlay))
      (goto-char (point-min))
      (should-not (search-forward "…" nil t)))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/toggle-expands-collapsed-reasoning ()
  "Crush-reasoning-toggle should expand a collapsed reasoning region.
No buffer text is inserted or deleted — only overlay properties change."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (should (eq (overlay-get body-ov 'crush-fold-state) 'collapsed))
        ;; Point on the body overlay.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (eq (overlay-get body-ov 'crush-fold-state) 'expanded))
        (should-not (overlay-get body-ov 'invisible))
        (should-not (overlay-get body-ov 'before-string))
        ;; Hidden content is now visible.
        (goto-char (overlay-start body-ov))
        (forward-line)
        (should (looking-at "line 11"))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/toggle-collapses-expanded-reasoning ()
  "Crush-reasoning-toggle should collapse an expanded reasoning region."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        ;; Expand first.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (eq (overlay-get body-ov 'crush-fold-state) 'expanded))
        ;; Collapse.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (eq (overlay-get body-ov 'crush-fold-state) 'collapsed))
        (should (eq (overlay-get body-ov 'invisible) 'crush-reasoning-fold))
        (should (eq (overlay-get body-ov 'intangible) t))
        (should (stringp (overlay-get body-ov 'before-string)))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/toggle-no-fold-at-point ()
  "Crush-reasoning-toggle should message when no fold is at point."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (crush-reasoning-toggle)
          (should (equal messages '("No reasoning fold at point"))))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/fold-arrow-up-past-collapsed ()
  "Collapsed fold body overlay must be intangible so navigation skips it.
`intangible t' alongside `invisible t' ensures cursor motion commands
line-move, previous-line, etc. jump over the hidden region instead of
getting stuck at its boundary (which caused 'Beginning of buffer')."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        ;; The body overlay must be both invisible and intangible.
        (should (eq (overlay-get body-ov 'invisible) 'crush-reasoning-fold))
        (should (eq (overlay-get body-ov 'intangible) t))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/fold-before-string-is-intangible ()
  "The before-string marker must carry `intangible t' so arrow-up
skips it entirely instead of getting stuck on the marker line."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        (let ((bs (overlay-get body-ov 'before-string)))
          (should (stringp bs))
          (should (eq (get-text-property 0 'intangible bs) t)))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/fold-named-invisibility-spec ()
  "Collapsed reasoning uses a named invisibility spec so buffer-reading
tools (markdown-preview, export) see the full text."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp body-ov))
        ;; Named spec, not bare t.
        (should (eq (overlay-get body-ov 'invisible) 'crush-reasoning-fold))
        ;; buffer-invisibility-spec includes our spec.
        (should (member 'crush-reasoning-fold buffer-invisibility-spec))
        ;; The hidden text is still in the buffer.
        (goto-char (overlay-start body-ov))
        (should (search-forward "line 11" (overlay-end body-ov) t))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/fold-tab-from-preview ()
  "TAB from inside the preview overlay should toggle the fold.
The preview overlay carries the toggle keymap so TAB works from
the visible preview lines."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay))
            (preview-ov (crush-test--reasoning-preview-overlay)))
        (should (overlayp body-ov))
        (should (overlayp preview-ov))
        ;; Place point inside the preview overlay.
        (goto-char (+ (overlay-start preview-ov) 2))
        (should (<= (overlay-start preview-ov) (point)))
        (should (< (point) (overlay-end preview-ov)))
        ;; Toggle should expand the body via the preview overlay.
        (crush-reasoning-toggle)
        (should (eq (overlay-get body-ov 'crush-fold-state) 'expanded))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/toggle-via-tab-on-overlay ()
  "Pressing TAB inside the body overlay should toggle the fold."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        ;; Point inside the body overlay.
        (goto-char (overlay-start body-ov))
        (funcall #'crush--reasoning-tab)
        (should (eq (overlay-get body-ov 'crush-fold-state) 'expanded))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/chat-map-binds-reasoning-toggle ()
  "The reasoning-toggle binding resolves to `crush-reasoning-toggle'."
  (should (eq (lookup-key (symbol-value 'crush-chat-command-map) (kbd "r"))
              #'crush-reasoning-toggle)))

(ert-deftest crush-test/no-toggle-for-10-or-fewer-lines ()
  "Toggling should be a no-op when reasoning is 10 lines or fewer."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 10)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (crush-reasoning-toggle)
          (should (equal messages '("No reasoning fold at point"))))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/fold-no-character-eating ()
  "Expand/collapse cycles must not insert or delete buffer text.
The buffer size stays constant across multiple toggle cycles."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay))
            (size-before (buffer-size)))
        ;; Expand.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (= (buffer-size) size-before))
        ;; Collapse.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (= (buffer-size) size-before))
        ;; Expand again.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (= (buffer-size) size-before))
        ;; Collapse again.
        (goto-char (overlay-start body-ov))
        (crush-reasoning-toggle)
        (should (= (buffer-size) size-before))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/fold-reasoning-region-contiguous ()
  "The reasoning region stays contiguous — no gap from a fold marker.
All text from the first reasoning char to the last has
`crush-region-type' `reasoning'."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
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
              (unless (eq (get-text-property pos 'crush-region-type) 'reasoning)
                (setq bad t))
              (setq pos (1+ pos)))
            (should-not bad))
          ;; No nil-typed gap in the reasoning span.
          (should-not (text-property-any start end 'crush-region-type nil)))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/interrupt-auto-collapses-reasoning ()
  "Crush-interrupt should auto-collapse partial reasoning."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local crush--response-start (point-marker))
          (let ((proc (make-pipe-process :name "crush-hyper-test-int2"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-target (current-buffer))
            (unwind-protect
                (progn
                  (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                              'reasoning)
                  ;; The transport process is the interrupt target; the
                  ;; pipe process cannot be interrupted, so mock the kill.
                  (setq-local crush-process proc)
                  (setq-local crush-active-provider
                              (crush-make-hyper-provider
                               :buffer (current-buffer)
                               :working-directory default-directory))
                  (cl-letf (((symbol-function 'interrupt-process)
                             (lambda (_p &optional _fg) nil)))
                    (crush-interrupt)))
              (delete-process proc)))
          (let ((ov (crush-test--reasoning-fold-overlay)))
            (should (overlayp ov))
            (should (eq (overlay-get ov 'crush-fold-state) 'collapsed))))
      (crush-test--cleanup))))

(ert-deftest crush-test/clear-buffer-removes-fold-overlay ()
  "Crush-clear-buffer should delete the reasoning fold overlay."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "crush-hyper-test-clr2"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-target (current-buffer))
            (unwind-protect
                (progn
                  (crush-facade--append-delta "think" 'reasoning)
                  (crush-clear-buffer)
                  (should-not (crush-test--reasoning-fold-overlay))
                  (should-not (overlays-in (point-min) (point-max))))
              (delete-process proc))))
      (crush-test--cleanup))))

(ert-deftest crush-test/interrupt-tags-reasoning-region ()
  "Crush-interrupt should tag streamed reasoning up to the interrupt."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local crush--response-start (point-marker))
          (let ((proc (make-pipe-process :name "crush-hyper-test-int"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-target (current-buffer))
            (unwind-protect
                (progn
                  (crush-facade--append-delta "think hard" 'reasoning)
                  ;; The transport process is the interrupt target; the
                  ;; pipe process cannot be interrupted, so mock the kill.
                  (setq-local crush-process proc)
                  (setq-local crush-active-provider
                              (crush-make-hyper-provider
                               :buffer (current-buffer)
                               :working-directory default-directory))
                  (cl-letf (((symbol-function 'interrupt-process)
                             (lambda (_p &optional _fg) nil)))
                    (crush-interrupt)))
              (delete-process proc)))
          (let ((start (save-excursion
                         (goto-char (point-min))
                         (search-forward "think")
                         (match-beginning 0))))
            (should (eq (get-text-property start 'crush-region-type) 'reasoning))))
      (crush-test--cleanup))))

(ert-deftest crush-test/clear-buffer-removes-reasoning-overlay ()
  "Crush-clear-buffer should delete the reasoning overlay."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "crush-hyper-test-clr"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-target (current-buffer))
            (unwind-protect
                (progn
                  (crush-facade--append-delta "think" 'reasoning)
                  (should (overlays-in (point-min) (point-max)))
                  (crush-clear-buffer)
                  (should-not (overlays-in (point-min) (point-max)))
                  (should-not crush--reasoning-overlay))
              (delete-process proc))))
      (crush-test--cleanup))))

;;; Multi-round tool calls: reasoning is interleaved with tool blocks.
;;; Each round's reasoning must be independently foldable.

(ert-deftest crush-test/multi-round-reasoning-folds-independently ()
  "Each tool round's reasoning should get its own fold."
  (let ((default-directory crush-test--root)
        (expected-id nil))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq expected-id crush--prompt-id)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local crush--response-start (point-marker))
          ;; Round 1: 11 lines of reasoning then tool block.
          (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                      'reasoning)
          (crush--reasoning-stop)
          (crush--reasoning-reset)
          ;; Round 2: 11 lines of reasoning then content.
          (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                      'reasoning)
          (crush-facade--append-delta "answer" 'content)
          (crush-facade--close-response
           (marker-position crush--response-start) expected-id)
          ;; Two fold overlays.
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'crush-fold-state)
                (push ov folds)))
            (should (= (length folds) 2))
            (dolist (ov folds)
              (should (eq (overlay-get ov 'invisible) 'crush-reasoning-fold)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/multi-round-reasoning-fold-toggles-independently ()
  "Toggling a fold should only affect that reasoning round."
  (let ((default-directory crush-test--root)
        (expected-id nil))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq expected-id crush--prompt-id)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                      'reasoning)
          (crush--reasoning-stop)
          (crush--reasoning-reset)
          (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                      'reasoning)
          (crush-facade--append-delta "answer" 'content)
          (crush-facade--close-response
           (marker-position crush--response-start) expected-id)
          ;; Expand the first fold.
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'crush-fold-state)
                (push ov folds)))
            (goto-char (overlay-start (car folds)))
            (crush-reasoning-toggle))
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'crush-fold-state)
                (push ov folds)))
            (should (= (length folds) 2))
            (let ((expanded (cl-find-if (lambda (o) (eq (overlay-get o 'crush-fold-state) 'expanded)) folds))
                  (collapsed (cl-find-if (lambda (o) (eq (overlay-get o 'crush-fold-state) 'collapsed)) folds)))
              (should (overlayp expanded))
              (should (overlayp collapsed))
              (should-not (overlay-get expanded 'invisible))
              (should (eq (overlay-get collapsed 'invisible) 'crush-reasoning-fold)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/multi-round-reasoning-with-tool-blocks ()
  "Reasoning overlays before tool blocks should be foldable."
  (let ((default-directory crush-test--root)
        (expected-id nil))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq expected-id crush--prompt-id)
          (save-excursion (goto-char (point-max)) (newline))
          (setq-local crush--response-start (point-marker))
          ;; Round 1: 11 lines of reasoning then tool block insertion.
          (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                      'reasoning)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>"
                 :exit 0)
           expected-id)
          (let ((rs (marker-position crush--response-start)))
            (crush--tag-response-region rs (point) expected-id))
          (crush--reasoning-reset)
          (setq-local crush--response-start (point-marker))
          ;; Round 2: 11 lines of reasoning then content.
          (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                      'reasoning)
          (crush-facade--append-delta "answer" 'content)
          (crush-facade--close-response
           (marker-position crush--response-start) expected-id)
          (let ((folds nil))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'crush-fold-state)
                (push ov folds)))
            (should (= (length folds) 2))
            (dolist (ov folds)
              (should (eq (overlay-get ov 'invisible) 'crush-reasoning-fold)))))
      (crush-test--cleanup))))

;;; 97. Region tagging: reasoning + tool blocks in one response
;;;
;;; `crush--tag-response-region' must tag the content-before-toolblock
;;; span, the tool blocks, and the content-after-toolblock span so the
;;; header line shows the right region type at any point.  Regression
;;; for the header-line region label showing "plain"/"prompt" instead
;;; of "tool" when point sat on a tool block (the old code derived the
;;; reasoning sub-span only from the reasoning overlay, which ends
;;; before the first tool block, and never re-tagged the response).

(ert-deftest crush-test/tools-reasoning-tags-content-and-tools ()
  "A response with reasoning, tool blocks, and final content tags every
span: reasoning on the CoT text, tool on the tool blocks, response on
the final content."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "think hard" 'reasoning)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1" :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>" :exit 0)
           crush--prompt-id)
          (crush-facade--append-delta "final answer" 'content)
          ;; The finalize flow tags the full response through point-max.
          (goto-char (point-max))
          (newline)
          (crush--tag-response-region (marker-position crush--response-start)
                                      (point) crush--prompt-id)
          (goto-char (point-min))
          (search-forward "think")
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type)
                      'reasoning))
          (search-forward "🛠️ bash")
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type)
                      'tool))
          (search-forward "final answer")
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type)
                      'response)))
      (crush-test--cleanup))))

(ert-deftest crush-test/tools-reasoning-tags-tool-blocks-tagged ()
  "The tool block itself carries `crush-region-type' tool even when
the response has reasoning, so the header line shows region: tool."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "think" 'reasoning)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1" :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>" :exit 0)
           crush--prompt-id)
          (goto-char (point-max))
          (newline)
          (crush--tag-response-region (marker-position crush--response-start)
                                      (point) crush--prompt-id)
          (goto-char (point-min))
          (search-forward "🛠️ bash")
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type)
                      'tool))
          (should (string= (crush--region-label-at-point) "tool")))
      (crush-test--cleanup))))

(provide 'crush-test-reasoning)
;;; crush-test-reasoning.el ends here