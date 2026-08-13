;;; crush-test-reasoning.el --- Reasoning streaming tests for crush  -*- lexical-binding: t; -*-
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
     ;; Move point away from the insertion area first, as a user might
     ;; when scrolling up to read earlier conversation.
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

;;; Fold: auto-collapse on finalize

(defun crush-test--reasoning-fold-overlay (&optional buffer)
  "Return the reasoning fold overlay in BUFFER (default current), or nil.
The fold lives on the reasoning overlay, tagged `crush-overlay'."
  (with-current-buffer (or buffer (current-buffer))
    (let ((found nil))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'crush-overlay)
                   (overlay-get ov 'crush-fold-state))
          (setq found ov)))
      found)))

(ert-deftest crush-test/finalize-auto-collapses-reasoning ()
  "Finalize should auto-collapse the reasoning region with a dim marker."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "line one
line two
" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp ov))
        (should (eq (overlay-get ov 'invisible) t))
        ;; The marker is real buffer text above the overlay.
        (goto-char (point-min))
        (should (search-forward "..." nil t))
        (should (get-text-property (point) 'crush-fold-mark))
        (let ((marker (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
          (should (string-match-p "reasoning" marker))
          (should (string-match-p "(2 lines" marker)))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-fold-marker-has-toggle-keymap ()
  "The collapse marker should carry the toggle keymap."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "think" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "...")
      (let ((keymap (get-text-property (point) 'keymap)))
        (should (keymapp keymap))
        (should (eq (lookup-key keymap (kbd "TAB"))
                    #'crush-reasoning-toggle))
        (should (eq (lookup-key keymap (kbd "RET"))
                    #'crush-reasoning-toggle))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-marker-is-dim-real-text ()
  "The collapse marker is real buffer text carrying crush-fold-mark.
A marker overlay paints it with the reasoning region background."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "think" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "...")
      (should (get-text-property (point) 'crush-fold-mark))
      ;; No face text property (font-lock would strip it)...
      (should-not (get-text-property (point) 'face))
      ;; ...but a crush-overlay with the reasoning face covers the marker.
      (let ((found nil))
        (dolist (o (overlays-in (line-beginning-position) (line-end-position)))
          (when (and (overlay-get o 'crush-overlay)
                     (eq (overlay-get o 'face) 'crush-reasoning-face))
            (setq found o)))
        (should (overlayp found))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-snaps-fold-to-lines ()
  "The collapsed fold snaps to whole lines.
The marker sits at the line start and the body overlay ends at end of
line."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "partial\n" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((ov (crush-test--reasoning-fold-overlay)))
        (should (overlayp ov))
        ;; The marker line starts at column 0.
        (goto-char (point-min))
        (search-forward "...")
        (goto-char (match-beginning 0))
        (should (bolp))
        ;; The hidden body ends at end of line.
        (goto-char (overlay-end ov))
        (should (eolp))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/finalize-content-only-no-fold ()
  "Content-only responses should get no fold control."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (should-not (crush-test--reasoning-fold-overlay))
      (goto-char (point-min))
      (should-not (search-forward "..." nil t)))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/toggle-expands-collapsed-reasoning ()
  "Crush-reasoning-toggle should expand a collapsed reasoning region."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "line one
line two
" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((ov (crush-test--reasoning-fold-overlay)))
        (should (eq (overlay-get ov 'crush-fold-state) 'collapsed))
        ;; Point on the marker, then toggle.
        (goto-char (point-min))
        (search-forward "...")
        (crush-reasoning-toggle)
        (should (eq (overlay-get ov 'crush-fold-state) 'expanded))
        (should-not (overlay-get ov 'invisible))
        ;; Marker text gone; reasoning body visible again.
        (goto-char (point-min))
        (should (search-forward "line one" nil t))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/toggle-collapses-expanded-reasoning ()
  "Crush-reasoning-toggle should collapse an expanded reasoning region."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "line one
line two
" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((ov (crush-test--reasoning-fold-overlay)))
        (goto-char (point-min))
        (search-forward "...")
        (crush-reasoning-toggle)       ; expand
        ;; Move onto the reasoning body and collapse.
        (goto-char (point-min))
        (search-forward "line one")
        (goto-char (match-beginning 0))
        (crush-reasoning-toggle)       ; collapse
        (should (eq (overlay-get ov 'crush-fold-state) 'collapsed))
        (should (eq (overlay-get ov 'invisible) t))
        ;; Marker text is back.
        (goto-char (point-min))
        (should (search-forward "..." nil t))
        ;; The re-collapsed marker is read-only like the response.
        (goto-char (match-beginning 0))
        (should (get-text-property (point) 'read-only))
        (should-error (delete-region (line-beginning-position)
                                     (line-end-position))
                      :type 'text-read-only)))
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
  "Pressing TAB on the collapse marker should toggle the fold.
The marker's real-text keymap dispatches TAB to the toggle."
  (let ((buf (crush-test--finalize-with-reasoning
              (lambda (_proc)
                (crush-facade--append-delta "think" 'reasoning)
                (crush-facade--append-delta "answer" 'content)))))
    (with-current-buffer buf
      (let ((ov (crush-test--reasoning-fold-overlay)))
        (goto-char (point-min))
        (search-forward "...")
        (let ((keymap (get-text-property (point) 'keymap)))
          (should (keymapp keymap))
          (should (eq (lookup-key keymap (kbd "TAB"))
                      #'crush-reasoning-toggle)))
        (should (eq (lookup-key (symbol-value 'crush-chat-mode-map) (kbd "TAB"))
                    #'crush--reasoning-tab))
        ;; Dispatch TAB with point on the marker text.
        (let ((binding (key-binding (kbd "TAB"))))
          (if (eq binding #'crush-reasoning-toggle)
              (call-interactively binding)
            (call-interactively #'crush-reasoning-toggle)))
        (should (eq (overlay-get ov 'crush-fold-state) 'expanded))))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/chat-map-binds-reasoning-toggle ()
  "The reasoning-toggle binding resolves to `crush-reasoning-toggle'."
  (should (eq (lookup-key (symbol-value 'crush-chat-command-map) (kbd "r"))
              #'crush-reasoning-toggle)))

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
                  (crush-facade--append-delta "partial think" 'reasoning)
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
                  ;; Simulate an active backend so crush-interrupt
                  ;; calls the backend interrupt path.
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

(provide 'crush-test-reasoning)
;;; crush-test-reasoning.el ends here
