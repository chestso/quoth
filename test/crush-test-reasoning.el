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
  "Point should follow the reasoning stream to the insertion point."
  (crush-test--with-reasoning-process
   (lambda (_proc)
     (goto-char (point-min))
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

;;; Fold: preview overlay + ellipsis for >10 lines, no fold for <=10

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

(defun crush-test--reasoning-ellipsis (&optional buffer)
  "Return the position of the `…' ellipsis in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (when (search-forward "…" nil t)
        (match-beginning 0)))))

(defun crush-test--reasoning-lines (n)
  "Return a string of N numbered lines separated by newlines."
  (mapconcat #'identity
             (cl-loop for i from 1 to n
                      collect (format "line %d" i))
             "\n"))

(ert-deftest crush-test/finalize-auto-collapses-reasoning ()
  "Finalize should auto-collapse reasoning > 10 lines with a preview."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 12)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay))
            (preview-ov (crush-test--reasoning-preview-overlay)))
        (should (overlayp body-ov))
        (should (eq (overlay-get body-ov 'invisible) t))
        (should (overlayp preview-ov))
        (should (eq (overlay-get preview-ov 'face) 'crush-reasoning-face))
        (should (= (count-lines (overlay-start preview-ov)
                                (overlay-end preview-ov))
                   10))
        (goto-char (point-min))
        (should (search-forward "…" nil t))
        (should (get-text-property (1- (point)) 'crush-fold-mark))))
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
      (should-not (crush-test--reasoning-ellipsis))
      (goto-char (point-min))
      (should (search-forward "line 1" nil t))
      (should (search-forward "line 10" nil t)))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-fold-marker-has-toggle-keymap ()
  "The … ellipsis should carry the toggle keymap."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (should (search-forward "…" nil t))
      (let ((keymap (get-text-property (1- (point)) 'keymap)))
        (should (keymapp keymap))
        (should (eq (lookup-key keymap (kbd "TAB"))
                    #'crush-reasoning-toggle))
        (should (eq (lookup-key keymap (kbd "RET"))
                    #'crush-reasoning-toggle))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-marker-is-dim-real-text ()
  "The … ellipsis is real buffer text carrying crush-fold-mark."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (should (search-forward "…" nil t))
      (should (get-text-property (1- (point)) 'crush-fold-mark))
      (should-not (get-text-property (1- (point)) 'face))
      (let ((preview-ov (crush-test--reasoning-preview-overlay)))
        (should (overlayp preview-ov))
        (should (eq (overlay-get preview-ov 'face) 'crush-reasoning-face))))
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
        (goto-char (overlay-end preview-ov))
        (should (looking-at "\n"))
        (goto-char (1+ (overlay-start body-ov)))
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
  "Crush-reasoning-toggle should expand a collapsed reasoning region."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (should (eq (overlay-get body-ov 'crush-fold-state) 'collapsed))
        (goto-char (point-min))
        (search-forward "…")
        (goto-char (1- (point)))
        (crush-reasoning-toggle)
        (should (eq (overlay-get body-ov 'crush-fold-state) 'expanded))
        (should-not (overlay-get body-ov 'invisible))
        (should-not (crush-test--reasoning-ellipsis))
        (should-not (crush-test--reasoning-preview-overlay))
        (goto-char (point-min))
        (should (search-forward "line 11" nil t))))
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
        (goto-char (point-min))
        (search-forward "…")
        (goto-char (1- (point)))
        (crush-reasoning-toggle)       ; expand
        (goto-char (point-min))
        (search-forward "line 11")
        (goto-char (match-beginning 0))
        (crush-reasoning-toggle)       ; collapse
        (should (eq (overlay-get body-ov 'crush-fold-state) 'collapsed))
        (should (eq (overlay-get body-ov 'invisible) t))
        (should (crush-test--reasoning-ellipsis))
        (should (overlayp (crush-test--reasoning-preview-overlay)))
        (goto-char (crush-test--reasoning-ellipsis))
        (should (get-text-property (point) 'read-only))
        (should-error (delete-char 1) :type 'text-read-only)))
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

(ert-deftest crush-test/toggle-via-tab-on-marker ()
  "Pressing TAB on the … ellipsis should toggle the fold."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta (crush-test--reasoning-lines 11)
                                            'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((body-ov (crush-test--reasoning-fold-overlay)))
        (goto-char (point-min))
        (search-forward "…")
        (goto-char (1- (point)))
        (let ((keymap (get-text-property (point) 'keymap)))
          (should (keymapp keymap))
          (should (eq (lookup-key keymap (kbd "TAB"))
                      #'crush-reasoning-toggle)))
        (should (eq (lookup-key (symbol-value 'crush-chat-mode-map) (kbd "TAB"))
                    #'crush--reasoning-tab))
        (let ((binding (key-binding (kbd "TAB"))))
          (if (eq binding #'crush-reasoning-toggle)
              (call-interactively binding)
            (call-interactively #'crush-reasoning-toggle)))
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
                  (setq-local crush-active-backend
                              (crush-make-hyper-backend
                               :buffer (current-buffer)
                               :working-directory default-directory))
                  (cl-letf (((symbol-function 'crush-backend-interrupt)
                             (lambda (_b) nil))
                            ((symbol-function 'crush-backend-active-p)
                             (lambda (_b) t)))
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
                  (setq-local crush-active-backend
                              (crush-make-hyper-backend
                               :buffer (current-buffer)
                               :working-directory default-directory))
                  (cl-letf (((symbol-function 'crush-backend-interrupt)
                             (lambda (_b) nil))
                            ((symbol-function 'crush-backend-active-p)
                             (lambda (_b) t)))
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
              (should (eq (overlay-get ov 'invisible) t)))
            (goto-char (point-min))
            (should (search-forward "…" nil t))
            (should (search-forward "…" nil t))))
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
          (goto-char (point-min))
          (search-forward "…")
          (goto-char (1- (point)))
          (crush-reasoning-toggle)
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
              (should (eq (overlay-get collapsed 'invisible) t)))))
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
              (should (eq (overlay-get ov 'invisible) t)))
            (goto-char (point-min))
            (should (search-forward "…" nil t))
            (should (search-forward "…" nil t))))
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
          (search-forward "tool: bash")
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
          (search-forward "tool: bash")
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type)
                      'tool))
          (should (string= (crush--region-label-at-point) "tool")))
      (crush-test--cleanup))))

(provide 'crush-test-reasoning)
;;; crush-test-reasoning.el ends here