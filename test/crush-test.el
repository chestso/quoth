;;; crush-test.el --- Tests for crush  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(require 'crush)

;;; Helper

(defun crush-test--fresh-buffer ()
  "Create a fresh crush test buffer and return it."
  (let ((crush-buffer-name "*crush-test*"))
    (when (get-buffer crush-buffer-name)
      (kill-buffer crush-buffer-name))
    (crush)
    (get-buffer crush-buffer-name)))

(defun crush-test--cleanup ()
  "Kill test buffers."
  (dolist (name '("*crush-test*" "*crush-errors*"))
    (when (get-buffer name)
      (kill-buffer name))))

;;; 1. No duplicate defvar crush--continue

(ert-deftest crush-test/no-duplicate-continue-defvar ()
  "crush--continue should be defined and buffer-local, default nil."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (local-variable-p 'crush--continue))
          (should (null crush--continue))))
    (crush-test--cleanup)))

;;; 2. Working directory resolution

(ert-deftest crush-test/default-directory-uses-custom-when-set ()
  "When `crush-working-directory' is set, the crush buffer should use it."
  (let ((crush-working-directory "/tmp"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= (file-truename default-directory)
                             (file-truename "/tmp/")))))
      (crush-test--cleanup))))

(ert-deftest crush-test/default-directory-uses-default-when-no-project ()
  "When no project and no custom dir, uses `default-directory'."
  (let ((crush-working-directory nil)
        (expected-dir (file-truename default-directory)))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= (file-truename default-directory)
                             expected-dir))))
      (crush-test--cleanup))))

;;; 3. Prompt region management

(ert-deftest crush-test/prompt-start-set-on-buffer-init ()
  "After `crush' creates the buffer, `crush-prompt-start' should be a marker at point-max."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (markerp crush-prompt-start))
          (should (= (marker-position crush-prompt-start) (point-max)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/sentinel-resets-prompt-start ()
  "After process sentinel runs, `crush-prompt-start' should be reset to point-max."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush-prompt-start nil)
          (let* ((proc (make-process
                        :name "crush-test-fake"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t)))
            (setq-local crush-process proc)
            (set-marker (process-mark proc) (point-max))
            (accept-process-output proc 1)
            (funcall #'crush--process-sentinel proc 'finished)
            (should (markerp crush-prompt-start))
            (should (= (marker-position crush-prompt-start) (point-max))))))
    (crush-test--cleanup)))

;;; 4. Input locking

(ert-deftest crush-test/send-input-errors-when-process-running ()
  "`crush-send-input' should signal an error when a process is running."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test prompt")
          (setq-local crush-process (make-process
                                     :name "crush-test-fake"
                                     :buffer buf
                                     :command '("sleep" "30")
                                     :connection-type 'pipe
                                     :noquery t))
          (should-error (call-interactively #'crush-send-input))
          (interrupt-process crush-process)
          (setq-local crush-process nil)))
    (crush-test--cleanup)))

;;; 5. Prompt echoing

(ert-deftest crush-test/send-input-inserts-response-header ()
  "`crush-send-input' should insert a response header in the buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          ;; Stub make-process to return a fake process
          (let ((fake-proc (make-process
                            :name "crush-test-fake"
                            :buffer buf
                            :command '("true")
                            :connection-type 'pipe
                            :noquery t)))
            (set-marker (process-mark fake-proc) (point-max))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) fake-proc)))
              (call-interactively #'crush-send-input))
            ;; Check that the response header appears in the buffer
            (goto-char (point-min))
            (should (search-forward "---------- Crush Response ----------" nil t))
            (when (process-live-p fake-proc)
              (interrupt-process fake-proc)))))
    (crush-test--cleanup)))

;;; 6. Stderr handling

(ert-deftest crush-test/stderr-goes-to-separate-buffer ()
  "Stderr output should go to a separate `*crush-errors*' buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test stderr")
          (let ((captured-stderr nil)
                (fake-proc (make-process
                            :name "crush-test-fake"
                            :buffer buf
                            :command '("true")
                            :connection-type 'pipe
                            :noquery t)))
            (set-marker (process-mark fake-proc) (point-max))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest args)
                         (setq captured-stderr (plist-get args :stderr))
                         fake-proc)))
              (call-interactively #'crush-send-input))
            (should captured-stderr)
            (should (or (bufferp captured-stderr)
                        (stringp captured-stderr)))
            (when (process-live-p fake-proc)
              (interrupt-process fake-proc)))))
    (crush-test--cleanup)))

;;; 7. crush-clear-buffer resets session

(ert-deftest crush-test/clear-buffer-resets-continue ()
  "`crush-clear-buffer' should reset `crush--continue' to nil."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--continue t)
          (call-interactively #'crush-clear-buffer)
          (should (null crush--continue))))
    (crush-test--cleanup)))

;;; 8. Selection insertion during running process

(ert-deftest crush-test/insert-selection-works-while-process-running ()
  "`crush-insert-selection' should work even when `crush-process' is non-nil."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local crush-process (make-process
                                       :name "crush-test-fake"
                                       :buffer buf
                                       :command '("sleep" "30")
                                       :connection-type 'pipe
                                       :noquery t)))
          ;; Use a temp buffer as the source
          (with-temp-buffer
            (insert "some selected code\n")
            (crush-insert-selection (point-min) (point-max)))
          ;; The selection should have been inserted into the crush buffer
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "some selected code" nil t))
            (when (process-live-p crush-process)
              (interrupt-process crush-process))
            (setq-local crush-process nil)))
      (crush-test--cleanup))))

;;; 9. crush-new-session resets continue

(ert-deftest crush-test/new-session-resets-continue ()
  "`crush-new-session' should reset `crush--continue' to nil."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--continue t)
          (call-interactively #'crush-new-session)
          (should (null crush--continue))))
    (crush-test--cleanup)))

;;; 10. build-command includes --continue when set

(ert-deftest crush-test/build-command-with-continue ()
  "`crush--build-command' should include --continue when `crush--continue' is non-nil."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--continue t)
          (let ((cmd (crush--build-command)))
            (should (member "--continue" cmd)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/build-command-without-continue ()
  "`crush--build-command' should omit --continue when `crush--continue' is nil."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--continue nil)
          (let ((cmd (crush--build-command)))
            (should-not (member "--continue" cmd)))))
    (crush-test--cleanup)))

;;; Minor mode

(ert-deftest crush-test/minor-mode-defined ()
  "crush-minor-mode should be defined as a minor mode."
  (should (boundp 'crush-minor-mode))
  (should (fboundp 'crush-minor-mode)))

(ert-deftest crush-test/minor-mode-keymap-has-bindings ()
  "crush-minor-mode-map should have the expected keybindings."
  (let ((map (symbol-value 'crush-minor-mode-map)))
    (should (keymapp map))
    (should (eq (lookup-key map (kbd "C-c C-s")) #'crush-insert-selection))
    (should (eq (lookup-key map (kbd "C-c C-b")) #'crush-insert-buffer))
    (should (eq (lookup-key map (kbd "C-c C-p")) #'crush-insert-filepath))
    (should (eq (lookup-key map (kbd "C-c C-c")) #'crush))))

(ert-deftest crush-test/minor-mode-toggle ()
  "crush-minor-mode should toggle on and off in a source buffer."
  (with-temp-buffer
    (insert "hello")
    (should-not crush-minor-mode)
    (crush-minor-mode 1)
    (should crush-minor-mode)
    (crush-minor-mode -1)
    (should-not crush-minor-mode)))

;;; crush-insert-buffer

(ert-deftest crush-test/insert-buffer-inserts-entire-buffer ()
  "crush-insert-buffer should insert the entire buffer as an org source block."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (with-temp-buffer
          (insert "line one\nline two\nline three\n")
          (setq-local buffer-file-name "/fake/path/src/foo.el")
          (crush-insert-buffer)
          (with-current-buffer crush-buffer-name
            (goto-char (point-min))
            ;; File path appears before content in the org block
            (should (search-forward "src/foo.el" nil t))
            (should (search-forward "line one" nil t))
            (should (search-forward "line three" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-buffer-no-file-shows-no-file ()
  "crush-insert-buffer should show (no file) when buffer has no file."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (with-temp-buffer
          (insert "content\n")
          (setq-local buffer-file-name nil)
          (crush-insert-buffer)
          (with-current-buffer crush-buffer-name
            (goto-char (point-min))
            (should (search-forward "(no file)" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-buffer-works-while-process-running ()
  "crush-insert-buffer should work even when a crush process is running."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (progn
          (crush-test--fresh-buffer)
          (with-current-buffer "*crush-test*"
            (setq-local crush-process (make-process
                                       :name "crush-test-fake"
                                       :buffer (current-buffer)
                                       :command '("sleep" "30")
                                       :connection-type 'pipe
                                       :noquery t)))
          (with-temp-buffer
            (insert "buffer content\n")
            (crush-insert-buffer))
          (with-current-buffer "*crush-test*"
            (goto-char (point-min))
            (should (search-forward "buffer content" nil t))
            (when (process-live-p crush-process)
              (interrupt-process crush-process))
            (setq-local crush-process nil)))
      (crush-test--cleanup))))

;;; crush-insert-filepath

(ert-deftest crush-test/insert-filepath-inserts-path ()
  "crush-insert-filepath should insert the file path as context."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (with-temp-buffer
          (insert "some code\n")
          (setq-local buffer-file-name "/fake/path/src/bar.el")
          (crush-insert-filepath)
          (with-current-buffer crush-buffer-name
            (goto-char (point-min))
            (should (search-forward "/fake/path/src/bar.el" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-filepath-no-file-errors ()
  "crush-insert-filepath should error when buffer has no file."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (with-temp-buffer
          (insert "some code\n")
          (setq-local buffer-file-name nil)
          (should-error (crush-insert-filepath)))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-filepath-uses-relative-path ()
  "crush-insert-filepath should use a path relative to project root."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (with-temp-buffer
          (insert "code\n")
          ;; Set buffer-file-name to something under the cwd
          (setq-local buffer-file-name
                      (expand-file-name "test/crush-mode-test.el"
                                        default-directory))
          (crush-insert-filepath)
          (with-current-buffer crush-buffer-name
            (goto-char (point-min))
            ;; Should contain a relative path, not absolute
            (should (search-forward "test/crush-mode-test.el" nil t))))
      (crush-test--cleanup))))

;;; crush-insert-selection via minor mode keymap

(ert-deftest crush-test/insert-selection-via-minor-mode-key ()
  "crush-insert-selection should be callable via the minor mode keybinding."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (with-temp-buffer
          (insert "selected text\n")
          (goto-char (point-min))
          (set-mark (point))
          (forward-word)
          (crush-minor-mode 1)
          ;; Verify the keybinding resolves to the right command
          (let ((binding (key-binding (kbd "C-c C-s"))))
            (should (eq binding #'crush-insert-selection)))
          ;; Call the command directly
          (call-interactively #'crush-insert-selection)
          (with-current-buffer crush-buffer-name
            (goto-char (point-min))
            (should (search-forward "selected" nil t)))
          (crush-minor-mode -1))
      (crush-test--cleanup))))

;;; Mock CLI integration tests

(defun crush-test--mock-program ()
  "Return path to the mock crush CLI script."
  (expand-file-name "mock-crush.sh"
                    (file-name-directory (locate-library "crush-test"))))

(defun crush-test--with-mock (body)
  "Execute BODY with `crush-program' set to the mock CLI.
Returns the contents of the capture file after BODY completes."
  (let* ((cap (make-temp-file "crush-test-capture"))
         (crush-program (crush-test--mock-program))
         (crush-buffer-name "*crush-test*")
         (process-environment (cons (format "CRUSH_CAPTURE_FILE=%s" cap)
                                    process-environment)))
    (unwind-protect
        (progn
          (funcall body)
          (with-temp-buffer
            (insert-file-contents cap)
            (buffer-string)))
      (crush-test--cleanup)
      (when (file-exists-p cap)
        (delete-file cap)))))

(ert-deftest crush-test/mock-sends-prompt-as-arg ()
  "Without context, the prompt should be sent as a CLI argument."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       (goto-char (point-max))
                       (insert "what is 2+2?")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    (should (string-match-p "ARGS:" result))
    (should (string-match-p "what is 2+2?" result))
    (should-not (string-match-p "STDIN:" result))))

(ert-deftest crush-test/mock-sends-context-via-stdin ()
  "With context blocks, the context and prompt should be sent via stdin."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       ;; Simulate an inserted org block before the prompt
                       (goto-char (point-min))
                       (insert "#+begin_src text :file foo.el :lines 1-3\n(foo)\n#+end_src\n\n")
                       ;; Update prompt-start to after "crush> "
                       (setq-local crush-prompt-start
                                   (let ((m (make-marker)))
                                     (set-marker m (- (point-max) (length "crush> ")))
                                     m))
                       (goto-char (point-max))
                       (insert "explain this code")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    (should (string-match-p "STDIN:" result))
    (should (string-match-p "explain this code" result))
    (should (string-match-p "#\\+begin_src text :file foo.el" result))
    (should (string-match-p "org-mode source blocks" result))))

(ert-deftest crush-test/mock-sends-continue-flag ()
  "After first prompt, --continue should be passed on subsequent prompts."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       (setq-local crush--continue t)
                       (goto-char (point-max))
                       (insert "follow up question")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    (should (string-match-p "ARGS:" result))
    (should (string-match-p "\\-\\-continue" result))
    (should (string-match-p "follow up question" result))))

;;; 11. --quiet flag suppresses spinner

(ert-deftest crush-test/build-command-includes-quiet ()
  "`crush--build-command' should always include --quiet to suppress spinner."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((cmd (crush--build-command)))
            (should (member "--quiet" cmd)))))
    (crush-test--cleanup)))

;;; 12. Exit code handling

(ert-deftest crush-test/sentinel-shows-interrupted-on-sigint ()
  "When process exits with code 130, sentinel should show 'Interrupted'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate a process that was interrupted
          (let* ((fake-proc (make-process
                             :name "crush-test-fake"
                             :buffer buf
                             :command '("sh" "-c" "kill -INT $$")
                             :connection-type 'pipe
                             :noquery t)))
            (setq-local crush-process fake-proc)
            (set-marker (process-mark fake-proc) (point-max))
            (accept-process-output fake-proc 1)
            ;; Manually call sentinel with "interrupt" signal
            (crush--process-sentinel fake-proc "interrupt\n")
            ;; Check for interrupted message
            (goto-char (point-min))
            (should (search-forward "Interrupted" nil t)))))
    (crush-test--cleanup)))

;;; 13. --session flag support

(ert-deftest crush-test/build-command-includes-session-when-set ()
  "`crush--build-command' should include --session when set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--session "abc123")
          (let ((cmd (crush--build-command)))
            (should (member "--session" cmd))
            (should (member "abc123" cmd)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/build-command-omits-session-when-nil ()
  "`crush--build-command' should omit --session when nil."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--session nil)
          (let ((cmd (crush--build-command)))
            (should-not (member "--session" cmd)))))
    (crush-test--cleanup)))

;;; 14. --model flag support

(ert-deftest crush-test/build-command-includes-model-when-set ()
  "`crush--build-command' should include --model when `crush-model' is set."
  (let ((crush-model "claude-sonnet-4-20250514"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((cmd (crush--build-command)))
              (should (member "--model" cmd))
              (should (member "claude-sonnet-4-20250514" cmd)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/build-command-omits-model-when-nil ()
  "`crush--build-command' should omit --model when `crush-model' is nil."
  (let ((crush-model nil))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((cmd (crush--build-command)))
              (should-not (member "--model" cmd)))))
      (crush-test--cleanup))))

;;; 15. Stderr buffer creation

(ert-deftest crush-test/stderr-buffer-is-created ()
  "The `*crush-errors*' buffer should be created when sending input."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (let ((fake-proc (make-process
                            :name "crush-test-fake"
                            :buffer buf
                            :command '("true")
                            :connection-type 'pipe
                            :noquery t)))
            (set-marker (process-mark fake-proc) (point-max))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest args)
                         ;; Return the fake process
                         fake-proc)))
              (call-interactively #'crush-send-input))
            ;; The errors buffer should exist
            (should (get-buffer "*crush-errors*"))
            (when (process-live-p fake-proc)
              (interrupt-process fake-proc)))))
    (crush-test--cleanup)))

(provide 'crush-test)
;;; crush-test.el ends here
