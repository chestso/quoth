;;; crush-test.el --- Tests for crush  -*- lexical-binding: t; -*-
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

(require 'ert)
(require 'cl-lib)

(require 'crush)

;;; Helper

(defconst crush-test--root
  (expand-file-name "crush-test" temporary-file-directory)
  "Root directory used by tests to derive a deterministic crush buffer name.")

(defun crush-test--buffer-name ()
  "Return the deterministic crush buffer name for `crush-test--root'."
  (let ((crush--root-buffer-alist nil))
    (crush--buffer-name-for-root crush-test--root)))

(defun crush-test--fresh-buffer ()
  "Create a fresh crush test buffer and return it.
The buffer is bound to `crush-test--root' and deterministically named.
Initializes with the `run' backend (pinned for the run/buffer/mock
tests; the global default is `hyper')."
  (let ((name (crush-test--buffer-name)))
    (when (get-buffer name)
      (kill-buffer name))
    (cl-letf (((symbol-function 'project-current) (lambda (&optional dir) nil)))
      (let ((default-directory crush-test--root)
            (crush-backend-type 'run))
        (crush)))
    (get-buffer (crush-test--buffer-name))))

(defun crush-test--kill-crush-buffer ()
  "Kill any test crush buffer bound to `crush-test--root'."
  (let ((name (crush-test--buffer-name)))
    (when (get-buffer name)
      (kill-buffer name))))

(defun crush-test--cleanup ()
  "Kill test buffers."
  (crush-test--kill-crush-buffer)
  (dolist (name '("*crush-errors*" "*crush-debug*"))
    (when (get-buffer name)
      (kill-buffer name))))

(require 'crush-test-buffer)
(require 'crush-test-commands)
(require 'crush-test-backend)
(require 'crush-test-hyper)
(require 'crush-test-reasoning)
(require 'crush-test-stream)
(require 'crush-test-xxh3)

(provide 'crush-test)
;;; crush-test.el ends here
