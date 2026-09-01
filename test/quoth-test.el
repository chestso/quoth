;;; quoth-test.el --- Tests for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
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

;; Entry point for the quoth test suite: loads the topic test files.

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

;;; Helper

(defconst quoth-test--root
  (expand-file-name "quoth-test" temporary-file-directory)
  "Root directory used by tests to derive a deterministic quoth buffer name.")

(defvar quoth-test--root-created-by-us nil
  "Non-nil when this run created `quoth-test--root'.
Set so the `kill-emacs-hook' cleanup only removes a directory this
run provisioned, never one that pre-existed (parallel runs, leftover
state from an earlier run).")

;; The suite binds `default-directory' to `quoth-test--root' and spawns
;; subprocesses (fake providers, `sleep', hyper-server.py) there.  An
;; arbitrary system cannot be expected to already have this directory,
;; so provision it at load time, before any test body runs; register
;; cleanup so batch runs leave nothing behind.
(unless (file-directory-p quoth-test--root)
  (make-directory quoth-test--root t)
  (when (file-directory-p quoth-test--root)
    (setq quoth-test--root-created-by-us t)
    (add-hook 'kill-emacs-hook
              (lambda ()
                (when (and quoth-test--root-created-by-us
                           (file-directory-p quoth-test--root))
                  (delete-directory quoth-test--root t))))))

(ert-deftest quoth-test/test-root-exists ()
  "The deterministic test root directory exists (suite self-provisions).
Cannot expect an arbitrary system to already have /tmp/quoth-test;
tests bind `default-directory' to `quoth-test--root' and spawn
processes there, so the entry file must create it."
  (should (file-directory-p quoth-test--root)))

(defun quoth-test--buffer-name ()
  "Return the deterministic quoth buffer name for `quoth-test--root'."
  (let ((quoth--root-buffer-alist nil))
    (quoth--buffer-name-for-root quoth-test--root)))

(defun quoth-test--fresh-buffer ()
  "Create a fresh quoth test buffer and return it.
The buffer is bound to `quoth-test--root' and deterministically named.
Initializes with the default hyper provider."
  (let ((name (quoth-test--buffer-name)))
    (when (get-buffer name)
      (kill-buffer name))
    (cl-letf (((symbol-function 'project-current) (lambda (&optional _dir) nil)))
      (let ((default-directory quoth-test--root))
        (quoth)))
    (get-buffer (quoth-test--buffer-name))))

(defun quoth-test--kill-quoth-buffer ()
  "Kill any test quoth buffer bound to `quoth-test--root'."
  (let ((name (quoth-test--buffer-name)))
    (when (get-buffer name)
      (kill-buffer name))))

(defun quoth-test--cleanup ()
  "Kill test buffers."
  (quoth-test--kill-quoth-buffer)
  (dolist (name '("*quoth-errors*" "*quoth-debug*"))
    (when (get-buffer name)
      (kill-buffer name))))

;;; Load the topic test files the same way: `require' first, then
;;; fall back to this directory so flycheck and direct loads work.
(eval-and-compile
  (dolist (dep '("quoth-test-buffer" "quoth-test-commands"
                 "quoth-test-json" "quoth-test-openai" "quoth-test-hyper"
                 "quoth-test-reasoning" "quoth-test-stream"
                 "quoth-test-xxh3" "quoth-test-tools"
                 "quoth-test-process" "quoth-test-searxng" "quoth-test-select"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(provide 'quoth-test)
;;; quoth-test.el ends here
