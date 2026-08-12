;;; crush-test-reasoning.el --- Reasoning streaming tests for crush  -*- lexical-binding: t; -*-

;;; Commentary:
;;; Chain-of-thought overlay lifecycle, region tagging on finalize and interrupt, separation.

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'crush)

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
              (delete-process proc)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/hyper-reasoning-overlay-created-on-first-delta ()
  "A reasoning delta creates a yellow overlay tagged crush-overlay."
  (crush-test--with-reasoning-process
   (lambda (proc)
     (crush--hyper-insert-delta proc "think" 'reasoning)
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
   (lambda (proc)
     ;; Move point away from the insertion area first, as a user might
     ;; when scrolling up to read earlier conversation.
     (goto-char (point-min))
     (crush--hyper-insert-delta proc "think" 'reasoning)
     (should (= (point) (point-max)))
     (crush--hyper-insert-delta proc " harder" 'reasoning)
     (should (= (point) (point-max)))
     (should (string= (buffer-substring-no-properties
                       (- (point) (length " harder")) (point))
                      " harder")))))

(ert-deftest crush-test/hyper-reasoning-overlay-grows-with-deltas ()
  "Subsequent reasoning deltas extend the overlay."
  (crush-test--with-reasoning-process
   (lambda (proc)
     (crush--hyper-insert-delta proc "think" 'reasoning)
     (crush--hyper-insert-delta proc " harder" 'reasoning)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think harder"))))))

(ert-deftest crush-test/hyper-content-delta-freezes-reasoning-overlay ()
  "First content delta freezes the reasoning overlay."
  (crush-test--with-reasoning-process
   (lambda (proc)
     (crush--hyper-insert-delta proc "think" 'reasoning)
     (crush--hyper-insert-delta proc " hard" 'reasoning)
     (crush--hyper-insert-delta proc "answer" 'content)
     (let ((ov (car (overlays-in (point-min) (point-max)))))
       (should (overlayp ov))
       (should (string= (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov))
                        "think hard"))))))

(ert-deftest crush-test/content-delta-inserts-blank-separator ()
  "The first content delta after reasoning adds two newlines before it."
  (crush-test--with-reasoning-process
   (lambda (proc)
     (crush--hyper-insert-delta proc "think" 'reasoning)
     (crush--hyper-insert-delta proc "answer" 'content)
     (goto-char (point-min))
     (search-forward "answer")
     (let ((answer-start (match-beginning 0)))
       (should (string= (buffer-substring (- answer-start 2) answer-start)
                        "\n\n"))))))

(ert-deftest crush-test/hyper-content-only-no-reasoning-state ()
  "Content-only stream leaves reasoning state nil."
  (crush-test--with-reasoning-process
   (lambda (proc)
     (crush--hyper-insert-delta proc "answer" 'content)
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
                               (crush--finalize-response))
                           (delete-process proc)))
                       (current-buffer)))
      (unless result (crush-test--cleanup)))
    result))

(ert-deftest crush-test/finalize-tags-reasoning-region ()
  "Reasoning text should be tagged `crush-region-type' reasoning."
  (let ((expected-id nil))
    (let ((buf (crush-test--finalize-with-reasoning
		(lambda (proc)
                  (setq expected-id crush--prompt-id)
                  (crush--hyper-insert-delta proc "think hard" 'reasoning)
                  (crush--hyper-insert-delta proc "answer" 'content)))))
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
              (lambda (proc)
                (crush--hyper-insert-delta proc "think" 'reasoning)
                (crush--hyper-insert-delta proc "answer" 'content)))))
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
              (lambda (proc)
                (crush--hyper-insert-delta proc "think" 'reasoning)))))
    (with-current-buffer buf
      (should-not crush--reasoning-start)
      (should-not crush--reasoning-end)
      (should-not crush--reasoning-overlay))
    (crush-test--kill-crush-buffer)))

(ert-deftest crush-test/interrupt-tags-reasoning-region ()
  "crush-interrupt should tag streamed reasoning up to the interrupt."
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
                  (crush--hyper-insert-delta proc "think hard" 'reasoning)
                  ;; Simulate an active backend so crush-interrupt
                  ;; calls the backend interrupt path.
                  (setq-local crush--backend
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
  "crush-clear-buffer should delete the reasoning overlay."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((proc (make-pipe-process :name "crush-hyper-test-clr"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-target (current-buffer))
            (unwind-protect
                (progn
                  (crush--hyper-insert-delta proc "think" 'reasoning)
                  (should (overlays-in (point-min) (point-max)))
                  (crush-clear-buffer)
                  (should-not (overlays-in (point-min) (point-max)))
                  (should-not crush--reasoning-overlay))
              (delete-process proc))))
      (crush-test--cleanup))))

(provide 'crush-test-reasoning)
;;; crush-test-reasoning.el ends here
