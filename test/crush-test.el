;;; rush-test.el --- Tests for crush  -*- lexical-binding: t; -*-

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
The buffer is bound to `crush-test--root' and deterministically named."
  (let ((name (crush-test--buffer-name)))
    (when (get-buffer name)
      (kill-buffer name))
    (cl-letf (((symbol-function 'project-current) (lambda (&optional dir) nil)))
      (let ((default-directory crush-test--root))
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

(provide 'crush-test)
;;; crush-test.el ends here
