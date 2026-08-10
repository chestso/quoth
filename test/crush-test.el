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
  (dolist (name '("*crush-test*" "*crush-errors*" "*crush-debug*"))
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
  "After `crush' creates the buffer, crush--prompt-start-marker should be set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--prompt-start-marker)
          (should (markerp crush--prompt-start-marker))
          (should (= (marker-position crush--prompt-start-marker) (point-min)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/sentinel-resets-prompt-start ()
  "After process sentinel runs, crush--prompt-start-marker should be reset."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
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
            (should crush--prompt-start-marker)
            (should (markerp crush--prompt-start-marker))
            (should (= (marker-position crush--prompt-start-marker) (- (point-max) (length "crush> ")))))))
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
  "`crush-send-input' should not error and should leave buffer in valid state."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (let ((fake-proc (make-process
                            :name "crush-test-fake"
                            :buffer buf
                            :command '("true")
                            :connection-type 'pipe
                            :noquery t)))
            (set-marker (process-mark fake-proc) (marker-position crush--prompt-start-marker))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) fake-proc))
                      ((symbol-function 'start-process)
                       (lambda (&rest _args) fake-proc)))
              (call-interactively #'crush-send-input))
            (goto-char (point-min))
            (should (search-forward "hello world" nil t))
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
            (set-marker (process-mark fake-proc) (marker-position crush--prompt-start-marker))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest args)
                         (setq captured-stderr (plist-get args :stderr))
                         fake-proc))
                      ((symbol-function 'start-process)
                       (lambda (&rest _args) fake-proc)))
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

;;; 10. Backend command includes --continue when continue-p is true

(ert-deftest crush-test/backend-command-includes-continue ()
  "crush-backend-send-prompt should include --continue when :continue-p is t."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue t)
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--continue" captured-args))))

(ert-deftest crush-test/backend-command-omits-continue ()
  "crush-backend-send-prompt should omit --continue when :continue-p is nil."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue nil)
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not (member "--continue" captured-args))))

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

(ert-deftest crush-test/mock-process-exits-promptly-without-context ()
  "Without context, the crush process should exit promptly after sending EOF.
Regression test: `crush run' reads all of stdin before processing, so stdin
must be closed with EOF even when the prompt is a CLI arg. Otherwise the
process never exits and the buffer hangs after hitting RET."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (crush-test--with-mock
         (lambda ()
           (let ((buf (crush-test--fresh-buffer)))
             (with-current-buffer buf
               (goto-char (point-max))
               (insert "exit test")
               (call-interactively #'crush-send-input)
               ;; Wait for the process to exit on its own, timing how long.
               (let ((start (float-time)))
                 (while (and crush-process
                             (process-live-p crush-process)
                             (< (- (float-time) start) 2.0))
                   (accept-process-output crush-process 0.1))
                 ;; It must finish well under the old 2s hang window.
                 (should (< (- (float-time) start) 1.0))
                 (should-not (process-live-p crush-process)))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/mock-sends-context-via-stdin ()
  "With context blocks, the context and prompt should be sent via stdin."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       ;; Simulate an inserted org block before the prompt
                       (goto-char (point-min))
                       (let ((start (point))
                             (inhibit-read-only t))
                         (insert "#+begin_src text :file foo.el :lines 1-3\n(foo)\n#+end_src\n\n")
                         (add-text-properties
                          start (point)
                          (list 'crush-attachment-id "test-attach-id"
                                'crush-prompt-id crush--prompt-id
                                'crush-region-type 'org)))
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

(ert-deftest crush-test/backend-command-includes-quiet ()
  "crush-backend-send-prompt should always include --quiet."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--quiet" captured-args))))

;;; 12. Exit code handling

(ert-deftest crush-test/sentinel-shows-interrupted-on-sigint ()
  "When process exits with interrupt signal, sentinel should insert a new prompt."
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
            ;; Check that a new prompt was inserted
            (goto-char (point-min))
            (should (search-forward "crush> " nil t)))))
    (crush-test--cleanup)))

;;; 13. --session flag support

(ert-deftest crush-test/backend-command-includes-session-when-set ()
  "crush-backend-send-prompt should include --session when session-id is set."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--session "abc123")
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--session" captured-args))
    (should (member "abc123" captured-args))))

(ert-deftest crush-test/backend-command-omits-session-when-nil ()
  "crush-backend-send-prompt should omit --session when session-id is nil."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--session nil)
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not (member "--session" captured-args))))

;;; 14. --model flag support

(ert-deftest crush-test/backend-command-includes-model-when-set ()
  "crush-backend-send-prompt should include --model when crush-model is set."
  (let ((crush-model "claude-sonnet-4-20250514")
        (captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--model" captured-args))
    (should (member "claude-sonnet-4-20250514" captured-args))))

(ert-deftest crush-test/backend-command-omits-model-when-nil ()
  "crush-backend-send-prompt should omit --model when crush-model is nil."
  (let ((crush-model nil)
        (captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not (member "--model" captured-args))))

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
            (set-marker (process-mark fake-proc) (marker-position crush--prompt-start-marker))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _args) fake-proc))
                      ((symbol-function #'start-process)
                       (lambda (&rest _args) fake-proc)))
              (call-interactively #'crush-send-input))
            (should (get-buffer "*crush-errors*"))
            (when (process-live-p fake-proc)
              (interrupt-process fake-proc)))))
    (crush-test--cleanup)))

;;; 16. Prompt ID generation

(ert-deftest crush-test/prompt-id-is-set-on-buffer-init ()
  "After buffer init, `crush--prompt-id' should be a non-nil string."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (stringp crush--prompt-id))
          (should (> (length crush--prompt-id) 0))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-id-regenerated-after-response ()
  "After sentinel runs, `crush--prompt-id' should be a new unique ID."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((old-id crush--prompt-id))
            ;; Simulate process completion
            (let* ((fake-proc (make-process
                               :name "crush-test-fake"
                               :buffer buf
                               :command '("true")
                               :connection-type 'pipe
                               :noquery t)))
              (setq-local crush-process fake-proc)
              (set-marker (process-mark fake-proc) (point-max))
              (accept-process-output fake-proc 1)
              (crush--process-sentinel fake-proc "finished\n")
              ;; New ID should be different
              (should (stringp crush--prompt-id))
              (should (not (string= old-id crush--prompt-id))))))
	(crush-test--cleanup)))

;;; 17. Attachment tracking

  (ert-deftest crush-test/insert-selection-records-attachment ()
    "Inserting selection should record attachment with prompt ID."
    (let ((crush-buffer-name "*crush-test*"))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (let ((prompt-id crush--prompt-id))
		;; Insert selection from temp buffer
		(with-temp-buffer
                  (insert "selected code\n")
                  (setq-local buffer-file-name "/test/file.el")
                  (crush-insert-selection (point-min) (point-max)))
		;; Check attachment was recorded
		(should (listp crush--attachments))
		(should (= 1 (length crush--attachments)))
		(let ((attach (car crush--attachments)))
                  (should (string= (plist-get attach :prompt-id) prompt-id))
                  (should (stringp (plist-get attach :id)))
                  (should (string-match-p "selected code" (plist-get attach :content))))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/attachments-cleared-after-send ()
  "Attachments should be cleared after sending prompt."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (push (list :id "attach-test" :prompt-id crush--prompt-id :content "test")
                crush--attachments)
          (should (= 1 (length crush--attachments)))
          (goto-char (point-max))
          (insert "test prompt")
          (let ((fake-proc (make-process
                            :name "crush-test-fake"
                            :buffer buf
                            :command '("true")
                            :connection-type 'pipe
                            :noquery t)))
            (set-marker (process-mark fake-proc) (marker-position crush--prompt-start-marker))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc))
                      ((symbol-function #'start-process)
                       (lambda (&rest _args) fake-proc)))
              (call-interactively #'crush-send-input))
            (should (null crush--attachments))
            (when (process-live-p fake-proc)
              (interrupt-process fake-proc)))))
    (crush-test--cleanup)))

;;; 18. Header line display

(ert-deftest crush-test/header-line-shows-prompt-id ()
  "Header line should show prompt ID."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should header-line-format)
          (should (string-match-p crush--prompt-id (format "%s" header-line-format)))))
    (crush-test--cleanup)))

;;; 19. Prompt marker has prompt-id property

(ert-deftest crush-test/prompt-marker-has-prompt-id-property ()
  "The `crush> ' prompt marker should have crush-prompt-id text property."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Find the "crush> " text
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (let ((prompt-id (get-text-property (- (point) 7) 'crush-prompt-id)))
            (should prompt-id)
            (should (string= prompt-id crush--prompt-id)))))
    (crush-test--cleanup)))

;;; 20. User input gets prompt-id property

(ert-deftest crush-test/user-input-gets-prompt-id-property ()
  "Text typed after the prompt should have crush-prompt-id property."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          ;; Check that the inserted text has the property
          (let ((prompt-id (get-text-property (- (point) 5) 'crush-prompt-id)))
            (should prompt-id)
            (should (string= prompt-id crush--prompt-id)))))
    (crush-test--cleanup)))

;;; 21. Attachments have attachment-id and prompt-id properties

(ert-deftest crush-test/attachment-has-properties ()
  "Inserted attachments should have crush-attachment-id and crush-prompt-id properties."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((prompt-id crush--prompt-id))
              ;; Insert selection from temp buffer
              (with-temp-buffer
                (insert "selected code\n")
                (setq-local buffer-file-name "/test/file.el")
                (crush-insert-selection (point-min) (point-max)))
              ;; Find the org block in crush buffer
              (goto-char (point-min))
              (should (search-forward "selected code" nil t))
              (let ((attach-id (get-text-property (- (point) 5) 'crush-attachment-id))
                    (attach-prompt-id (get-text-property (- (point) 5) 'crush-prompt-id)))
                (should attach-id)
                (should (string= attach-prompt-id prompt-id))))))
      (crush-test--cleanup))))

;;; 22. Response text has response-to property

(ert-deftest crush-test/response-has-response-to-property ()
  "Response text should have crush-response-to property linking to prompt."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((prompt-id crush--prompt-id))
            ;; Simulate a response manually
            (goto-char (point-max))
            (let ((response-start (point)))
              (insert "response text\n")
              ;; Tag it manually like sentinel does
              (put-text-property response-start (point) 'crush-response-to prompt-id)
              (crush--insert-prompt))
            ;; Check response text has property
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let ((response-to (get-text-property (- (point) 5) 'crush-response-to)))
              (should response-to)
              (should (string= response-to prompt-id))))))
    (crush-test--cleanup)))

;;; 23. History retrieval functions

(ert-deftest crush-test/get-prompt-at-point ()
  "`crush-get-prompt-at-point' should return prompt ID at cursor."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test input")
          (let ((prompt-id (crush-get-prompt-at-point)))
            (should prompt-id)
            (should (string= prompt-id crush--prompt-id)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/get-all-prompts ()
  "`crush-get-all-prompts' should return all prompt IDs in buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((first-id crush--prompt-id))
            (goto-char (point-max))
            (insert "first prompt")
            (let ((fake-proc (make-process
                              :name "crush-test-fake"
                              :buffer buf
                              :command '("true")
                              :connection-type 'pipe
                              :noquery t)))
              (set-marker (process-mark fake-proc) (marker-position crush--prompt-start-marker))
              (cl-letf (((symbol-function #'make-process)
                         (lambda (&rest _) fake-proc))
                        ((symbol-function #'start-process)
                         (lambda (&rest _args) fake-proc)))
                (call-interactively #'crush-send-input))
              (accept-process-output fake-proc 1)
              (crush--process-sentinel fake-proc "finished\n"))
            (let ((second-id crush--prompt-id))
              (goto-char (point-max))
              (insert "second prompt")
              (let ((all-prompts (crush-get-all-prompts)))
                (should (member first-id all-prompts))
                (should (member second-id all-prompts)))))))
    (crush-test--cleanup)))

;;; 24. Response text has response face

(ert-deftest crush-test/response-has-response-face ()
  "Response text should have crush-response-face applied via overlay."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((prompt-id crush--prompt-id))
            ;; Simulate a response manually
            (goto-char (point-max))
            (let ((response-start (point)))
              (insert "response text\n")
              ;; Tag and apply face like sentinel does
              (put-text-property response-start (point) 'crush-response-to prompt-id)
              (let ((ov (make-overlay response-start (point) nil t)))
                (overlay-put ov 'face 'crush-response-face)
                (overlay-put ov 'crush-overlay t))
              (crush--insert-prompt))
            ;; Check response text has face via overlay
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let ((face (get-char-property (- (point) 5) 'face)))
              (should (eq face 'crush-response-face))))))
    (crush-test--cleanup)))

;;; 25. Sentinel applies response face

(ert-deftest crush-test/sentinel-applies-response-face ()
  "Sentinel should apply crush-response-face to response text via overlay."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((prompt-id crush--prompt-id))
            ;; Simulate sending a prompt
            (goto-char (point-max))
            (insert "test prompt")
            ;; Set response-start marker
            (setq-local crush--response-start (point-marker))
            (insert "response text\n")
            ;; Run sentinel
            (crush--process-sentinel (make-process :name "test" :buffer buf :command '("true") :connection-type 'pipe :noquery t) "finished\n")
            ;; Check response text has face via overlay
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let ((face (get-char-property (- (point) 5) 'face)))
              (should (eq face 'crush-response-face))))))
    (crush-test--cleanup)))

;;; 26. Integration: real process produces response with face

(ert-deftest crush-test/integration-response-has-face ()
  "Full integration: sending prompt and receiving response should apply face."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((prompt-id crush--prompt-id))
              ;; Insert prompt (simulating user typing)
              (goto-char (point-max))
              (insert "hello")
              ;; Simulate what crush-send-input does before starting process
              (goto-char (point-max))
              (newline)
              ;; Mark where response will start
              (setq-local crush--response-start (point-marker))
              ;; Use mock process with actual filter to output response
              (let* ((mock-proc (make-process
                                 :name "crush-mock"
                                 :buffer buf
                                 :command '("sh" "-c" "echo 'response text'")
                                 :connection-type 'pipe
                                 :filter #'crush--output-filter
				 :sentinel #'ignore
                                 :noquery t)))
                (set-marker (process-mark mock-proc) (point-max))
                ;; Let process complete
                (accept-process-output mock-proc 2)
                ;; Run sentinel to apply faces
                (crush--process-sentinel mock-proc "finished\n"))
              ;; Check response text has face via overlay
              (goto-char (point-min))
              (should (search-forward "response text" nil t))
              (let* ((pos (- (point) 5))
                     (face (get-char-property pos 'face)))
                (should face)
                (should (eq face 'crush-response-face))))))
      (crush-test--cleanup))))

;;; 27. Integration: empty response still applies face

(ert-deftest crush-test/integration-empty-response ()
  "Even empty response should not crash when applying face."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Setup buffer
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            ;; Create process with no output
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "true")
                               :connection-type 'pipe
                               :filter #'crush--output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 2)
	      ;; Should not error on empty response
	      (crush--process-sentinel mock-proc "finished\n"))
	    ;; Check buffer still has a new prompt
	    (goto-char (point-min))
	    (should (search-forward "crush> " nil t))))
      (crush-test--cleanup))))

;;; 28. Integration: interrupted response still inserts new prompt

(ert-deftest crush-test/integration-interrupted-response ()
  "Interrupted response should still insert new prompt."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Setup buffer
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            ;; Create process that gets interrupted
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'partial'; sleep 10")
                               :connection-type 'pipe
                               :filter #'crush--output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 0.5)
              ;; Simulate interrupt
              (crush--process-sentinel mock-proc "interrupt\n"))
            ;; Check buffer has new prompt
            (goto-char (point-min))
            (should (search-forward "crush> " nil t))))
      (crush-test--cleanup))))

;;; 29. Overlays survive font-lock fontification

(ert-deftest crush-test/overlays-survive-font-lock ()
  "Response face overlays must survive font-lock fontification.
This is the core bug: text properties get stripped by font-lock,
but overlays persist."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Simulate a complete response cycle
            (goto-char (point-max))
            (insert "test")
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'response text'")
                               :connection-type 'pipe
                               :filter #'crush--output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 2)
              (crush--process-sentinel mock-proc "finished\n"))
            ;; Verify overlay exists before font-lock
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let ((pos (- (point) 5)))
              (should (get-char-property pos 'face))
              (should (eq (get-char-property pos 'face) 'crush-response-face)))
            ;; Now run font-lock fontify (simulates interactive Emacs)
            (font-lock-fontify-buffer)
            ;; Overlay must survive font-lock
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let* ((pos (- (point) 5))
                   (face (get-char-property pos 'face)))
              (should face)
              (should (eq face 'crush-response-face)))))
      (crush-test--cleanup))))

;;; 30. Region type tagging: prompt (removed - comint handles via fields)

;;; 31. Region type tagging: input (removed - comint handles via fields)

;;; 32. Region type tagging: response

(ert-deftest crush-test/response-region-tagged-as-response ()
  "Response text should be tagged with crush-region-type 'response."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate a response cycle
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          ;; Check that response text has crush-region-type 'response
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          (let ((region-type (get-text-property (- (point) 5) 'crush-region-type)))
            (should (eq region-type 'response)))))
    (crush-test--cleanup)))

;;; 33. Region type tagging: org (attachment)

(ert-deftest crush-test/attachment-region-tagged-as-org ()
  "Attachment blocks should be tagged with crush-region-type 'org."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Insert selection from temp buffer
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name "/test/file.el")
              (crush-insert-selection (point-min) (point-max)))
            ;; Check that the org block has crush-region-type 'org
            (goto-char (point-min))
            (should (search-forward "#+begin_src" nil t))
            (let ((region-type (get-text-property (match-beginning 0) 'crush-region-type)))
              (should (eq region-type 'org)))))
      (crush-test--cleanup))))

;;; 34. Region type tagging: separator (removed - separators no longer inserted)

;;; 35. Region type tagging: separator (removed - separators no longer inserted)

;;; 36. Region type tagging: separator (removed - separators no longer inserted)

;;; 37. Fontification dispatcher: crush--fontify-region

(ert-deftest crush-test/fontify-region-dispatches-to-markdown ()
  "crush--fontify-region should call crush--fontify-as-markdown for 'response type."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (called nil))
        (with-current-buffer buf
          (insert "test response")
          (cl-letf (((symbol-function #'crush--fontify-as-markdown)
                     (lambda (_start _end) (setq called t))))
            (crush--fontify-region (point-min) (point-max) 'response)
            (should called))))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-region-dispatches-to-org ()
  "crush--fontify-region should call crush--fontify-as-org for 'org type."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (called nil))
        (with-current-buffer buf
          (insert "#+begin_src\ntest\n#+end_src")
          (cl-letf (((symbol-function #'crush--fontify-as-org)
                     (lambda (_start _end) (setq called t))))
            (crush--fontify-region (point-min) (point-max) 'org)
            (should called))))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-region-noop-for-prompt ()
  "crush--fontify-region should do nothing for 'prompt type.
The prompt region type has been removed in Phase 7; comint handles
prompt fontification via comint-highlight-prompt face. This test
verifies it still doesn't error when called with 'prompt (for
backward compatibility) but the type is never set in the buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "crush> ")
          ;; Should not error or call anything
          (crush--fontify-region (point-min) (point-max) 'prompt)
          (should t)))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-region-noop-for-input ()
  "crush--fontify-region should do nothing for 'input type.
The input region type has been removed in Phase 7; comint handles
input via field properties. This test verifies it still doesn't error
when called with 'input (for backward compatibility) but the type is
never set in the buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "user input")
          ;; Should not error or call anything
          (crush--fontify-region (point-min) (point-max) 'input)
          (should t)))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-region-noop-for-separator ()
  "crush--fontify-region should do nothing for 'separator type."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "---------- separator ----------")
          ;; Should not error or call anything
          (crush--fontify-region (point-min) (point-max) 'separator)
          (should t)))
    (crush-test--cleanup)))

;;; 38. Fontification: crush--fontify-as-markdown

(ert-deftest crush-test/fontify-markdown-creates-overlays ()
  "Fontifying markdown text should NOT create face overlays in markdown parent.
When the buffer is markdown-mode, native font-lock provides highlighting
and no face overlays are created by crush."
  (skip-unless (require 'markdown-mode nil t))
  (let ((crush--parent-mode 'markdown-mode))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (insert "**bold text** and `inline code`")
            (crush--fontify-as-markdown (point-min) (point-max))
            ;; No face overlays should be created in markdown parent
            (let ((overlays (overlays-in (point-min) (point-max))))
              (should-not (cl-some (lambda (ov) (overlay-get ov 'face))
                                   overlays)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/fontify-markdown-applies-base-face ()
  "Fontifying markdown should apply crush-response-face as base overlay."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "plain text")
          (crush--fontify-as-markdown (point-min) (point-max))
          ;; Should have at least one overlay with crush-response-face
          (let ((overlays (overlays-in (point-min) (point-max))))
            (should (cl-some (lambda (ov)
                               (eq (overlay-get ov 'face) 'crush-response-face))
                             overlays)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-markdown-empty-region ()
  "Fontifying empty region should not crash."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Empty region
          (crush--fontify-as-markdown (point-min) (point-min))
          (should t)))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-markdown-overlays-tagged ()
  "Fontification overlays should be tagged with crush-overlay property."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "text")
          (crush--fontify-as-markdown (point-min) (point-max))
          (let ((overlays (overlays-in (point-min) (point-max))))
            (dolist (ov overlays)
              (when (overlay-get ov 'face)
                (should (overlay-get ov 'crush-overlay)))))))
    (crush-test--cleanup)))

;;; 38b. Fontification: markdown parent relies on native font-lock
;;;        (no fallback face, no overlay fontification)

(ert-deftest crush-test/fontify-markdown-no-overlay-in-markdown-parent ()
  "When the buffer is markdown-mode, response fontification should NOT
create any crush overlays. Native markdown font-lock handles highlighting,
and the fallback face overlay must not be applied."
  (let ((crush--parent-mode 'markdown-mode))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (insert "**bold** and `code`")
            (crush--fontify-as-markdown (point-min) (point-max))
            ;; No face overlays should be created in the response region
            (let ((overlays (overlays-in (point-min) (point-max))))
              (should-not (cl-some (lambda (ov) (overlay-get ov 'face))
                                   overlays)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/fontify-markdown-keeps-face-in-text-fallback ()
  "When the buffer is text-mode (no markdown-mode), the fallback
crush-response-face overlay SHOULD be applied so responses stay distinct."
  (let ((crush--parent-mode 'text-mode))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (insert "plain response text")
            (crush--fontify-as-markdown (point-min) (point-max))
            (let ((overlays (overlays-in (point-min) (point-max))))
              (should (cl-some (lambda (ov)
                                 (eq (overlay-get ov 'face) 'crush-response-face))
                               overlays)))))
      (crush-test--cleanup))))

;;; 39. Fontification: crush--fontify-as-org

(ert-deftest crush-test/fontify-org-creates-overlays ()
  "Fontifying org text should create overlays for syntax elements."
  (skip-unless (require 'org nil t))
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "#+begin_src text :file test.el\n(code)\n#+end_src")
          (crush--fontify-as-org (point-min) (point-max))
          ;; Should have overlays with crush-overlay property
          (let ((overlays (overlays-in (point-min) (point-max))))
            (should (cl-some (lambda (ov) (overlay-get ov 'crush-overlay)) overlays)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-org-applies-base-face ()
  "Fontifying org should apply crush-org-face as base overlay."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "#+begin_src\ntext\n#+end_src")
          (crush--fontify-as-org (point-min) (point-max))
          ;; Should have at least one overlay with crush-org-face
          (let ((overlays (overlays-in (point-min) (point-max))))
            (should (cl-some (lambda (ov)
                               (eq (overlay-get ov 'face) 'crush-org-face))
                             overlays)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/fontify-org-empty-region ()
  "Fontifying empty org region should not crash."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Empty region
          (crush--fontify-as-org (point-min) (point-min))
          (should t)))
    (crush-test--cleanup)))

;;; 40. Integration: sentinel calls fontification

(ert-deftest crush-test/sentinel-fontifies-response ()
  "Sentinel should fontify the response text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate sending a prompt
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo '**bold** text'")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          ;; Response should have overlays from fontification
          (goto-char (point-min))
          (should (search-forward "bold" nil t))
          (let ((overlays (overlays-in (- (point) 4) (point))))
            (should (cl-some (lambda (ov) (overlay-get ov 'crush-overlay)) overlays)))))
    (crush-test--cleanup)))

;;; 41. Integration: attachment insertion calls fontification

(ert-deftest crush-test/insert-selection-fontifies-org ()
  "Inserting selection should fontify the org block."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Insert selection from temp buffer
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name "/test/file.el")
              (crush-insert-selection (point-min) (point-max)))
            ;; Org block should have overlays from fontification
            (goto-char (point-min))
            (should (search-forward "#+begin_src" nil t))
            (let ((overlays (overlays-in (match-beginning 0) (match-end 0))))
              (should (cl-some (lambda (ov) (overlay-get ov 'crush-overlay)) overlays)))))
      (crush-test--cleanup))))

;;; 42. Integration: crush-clear-buffer removes overlays

(ert-deftest crush-test/clear-buffer-removes-overlays ()
  "crush-clear-buffer should remove old crush-overlay tagged overlays.
New overlays created by the fresh prompt are expected to remain."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Create an extra overlay manually
          (let ((ov (make-overlay (point-min) (point-max))))
            (overlay-put ov 'crush-overlay t)
            (overlay-put ov 'face 'highlight))
          ;; Call clear-buffer
          (call-interactively #'crush-clear-buffer)
          ;; Should have no overlay with face 'highlight' (the manual one is gone)
          (should-not (cl-some (lambda (ov)
                                 (and (overlay-buffer ov)
                                      (eq (overlay-get ov 'face) 'highlight)))
                               (overlays-in (point-min) (point-max))))))
    (crush-test--cleanup)))

;;; 44. Phase 1: comint-output-filter-functions hook runs (DELETED in Phase 2)

;;; 45. Phase 1: comint-output-filter inserts at process mark (rewritten in Phase 2 as output-filter-inserts-at-mark)

;;; 46. Phase 2: comint prompt fields - prompt is read-only (DELETED in Phase 4: replaced by prompt-is-read-only)

;;; 47. Phase 2: comint prompt fields - field-at-pos (DELETED in Phase 4: no field property)

;;; 48. Phase 2: comint prompt fields - comint-highlight-prompt face (DELETED in Phase 4: replaced by prompt-has-crush-prompt-face)

;;; 49. Phase 3: comint-send-input calls crush--input-sender (DELETED in Phase 3)

;;; 50. Phase 3: comint-send-input adds to input ring (DELETED in Phase 3: replaced by custom-input-ring tests)

;;; 51. Phase 3: crush--ensure-process creates placeholder (DELETED in Phase 3: no placeholder needed)

;;; 52. Phase 4: Input history - M-p retrieves previous input (DELETED: replaced by custom-input-ring tests)

;;; 53. Phase 5: Sentinel inserts prompt with comint field properties (DELETED in Phase 4: no field property)

;;; 54. Phase 5: Sentinel sets comint-last-prompt (DELETED in Phase 4: no comint-last-prompt)

;;; 55. Phase 6: Vestigial code removed

;;; 48. Phase 2: comint-use-prompt-regexp (DELETED in Phase 3: comint settings removed)

(ert-deftest crush-test/crush-process-filter-removed ()
  "crush--process-filter should not be defined (replaced by crush--output-filter)."
  (should-not (fboundp 'crush--process-filter)))

;;; 56. Phase 7: Region-type/field reconciliation

(ert-deftest crush-test/response-region-type-still-set ()
  "Response text should still have crush-region-type=response."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          (should (eq (get-text-property (- (point) 5) 'crush-region-type) 'response))))
    (crush-test--cleanup)))

(ert-deftest crush-test/org-region-type-still-set ()
  "Attachment blocks should still have crush-region-type=org."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name "/test/file.el")
              (crush-insert-selection (point-min) (point-max)))
            (goto-char (point-min))
            (should (search-forward "#+begin_src" nil t))
            (should (eq (get-text-property (match-beginning 0) 'crush-region-type) 'org))))
      (crush-test--cleanup))))

(ert-deftest crush-test/separator-region-type-removed ()
  "No separator lines should be present after response."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response'")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-min))
          (should (search-forward "response" nil t))
          ;; No separator lines should be present
          (goto-char (point-min))
          (should-not (search-forward "------------------------------------" nil t))))
    (crush-test--cleanup)))

;;; 56. field-output-on-response (DELETED in Phase 2: no field=output with custom filter)

;;; 57. Debug logging - crush-debug-mode defcustom

(ert-deftest crush-test/debug-mode-defaults-to-t ()
  "crush-debug-mode should default to t."
  (should (eq crush-debug-mode t)))

;;; 58. Debug logging - crush--debug-log creates buffer and writes

(ert-deftest crush-test/debug-log-creates-buffer ()
  "crush--debug-log should create *crush-debug* buffer when enabled."
  (unwind-protect
      (let ((crush-debug-mode t))
        (should-not (get-buffer "*crush-debug*"))
        (crush--debug-log 'test "hello world")
        (should (get-buffer "*crush-debug*"))
        (with-current-buffer "*crush-debug*"
          (goto-char (point-min))
          (should (search-forward "test: hello world" nil t))))
    (crush-test--cleanup)))

;;; 59. Debug logging - disabled mode is no-op

(ert-deftest crush-test/debug-log-disabled-no-op ()
  "crush--debug-log should do nothing when crush-debug-mode is nil."
  (unwind-protect
      (let ((crush-debug-mode nil))
        (crush--debug-log 'test "should not appear")
        (should-not (get-buffer "*crush-debug*")))
    (crush-test--cleanup)))

;;; 60. Debug logging - command logged in input-sender

;;; 60. Debug logging - command logged (DELETED: crush--input-sender removed in Phase 3)

;;; 61. Debug logging - input logged (DELETED: crush--input-sender removed in Phase 3)

;;; 62. Debug logging - output logged in crush--output-filter

(ert-deftest crush-test/debug-logs-output ()
  "crush--output-filter should log output to *crush-debug*."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let* ((proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-marker (process-mark proc) (point-max))
            (crush--output-filter proc "some output text")
            (delete-process proc)))
        (with-current-buffer "*crush-debug*"
          (goto-char (point-min))
          (should (search-forward "output" nil t))
          (should (search-forward "some output text" nil t))))
    (crush-test--cleanup)))

;;; 63. Debug logging - sentinel logged

(ert-deftest crush-test/debug-logs-sentinel ()
  "crush--process-sentinel should log the event to *crush-debug*."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo response")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n")))
        (with-current-buffer "*crush-debug*"
          (goto-char (point-min))
          (should (search-forward "sentinel" nil t))
          (should (search-forward "finished" nil t))))
    (crush-test--cleanup)))

;;; 64. Phase 6: Vestigial function rename

(ert-deftest crush-test/insert-prompt-renamed ()
  "crush--insert-prompt should be defined (renamed from crush--insert-prompt-marker)."
  (should (fboundp 'crush--insert-prompt)))

(ert-deftest crush-test/insert-prompt-marker-removed ()
  "crush--insert-prompt-marker should not be defined (renamed to crush--insert-prompt)."
  (should-not (fboundp 'crush--insert-prompt-marker)))

;;; 65. Phase 6: Sentinel freezes previous response read-only

(ert-deftest crush-test/sentinel-freezes-previous-response ()
  "Sentinel should freeze the previous response read-only.
After the sentinel inserts the next prompt, the prior response becomes
read-only previous content, blocking edits and insertions."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "test")
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'response text'")
                               :connection-type 'pipe
                               :filter #'crush--output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 2)
              (crush--process-sentinel mock-proc "finished\n"))
            ;; Response text becomes frozen as previous content.
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (should (get-char-property (match-beginning 0) 'read-only))
            (should (get-text-property (match-beginning 0) 'read-only))
            (goto-char (match-beginning 0))
            (should-error (insert-and-inherit "X") :type 'text-read-only))))
    (crush-test--cleanup)))

;;; 66. Phase 6: crush--ensure-process uses crush--prompt-start-marker (DELETED in Phase 3: ensure-process removed)

;;; 67. Phase 6: crush--insert-before-prompt uses crush--prompt-start-marker

(ert-deftest crush-test/insert-before-prompt-works-without-prompt-start ()
  "crush--insert-before-prompt should insert before crush--prompt-start-marker."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (should crush--prompt-start-marker)
            (let ((prompt-start (marker-position crush--prompt-start-marker)))
              (crush--insert-before-prompt buf "INSERTED CONTENT" nil nil)
              (goto-char (point-min))
              (should (search-forward "INSERTED CONTENT" nil t))
              (should (search-forward "crush> " nil t))
              (should (> (marker-position crush--prompt-start-marker) prompt-start)))))
      (crush-test--cleanup))))

;;; 68. Phase 6: crush-send-input uses crush--input-start-marker

(ert-deftest crush-test/send-input-works-without-prompt-start ()
  "crush-send-input should extract input using crush--input-start-marker.
The extracted prompt in stdin should not include preceding text
or the crush> prompt marker."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       ;; Add an attachment via the real function
                       (crush--insert-before-prompt
                        buf
                        "#+begin_src text :file foo.el :lines 1-3\n(foo)\n#+end_src"
                        "test-attach-id" crush--prompt-id)
                       (goto-char (point-max))
                       (insert "hello world")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    ;; The stdin capture should contain the prompt "hello world"
    (should (string-match-p "STDIN:" result))
    (should (string-match-p "hello world" result))
    ;; It should NOT contain the "crush> " prompt marker
    (should-not (string-match-p "crush> " result))))

;;; 69. Phase 6: crush--after-change uses crush--prompt-start-marker

(ert-deftest crush-test/after-change-tags-without-prompt-start ()
  "crush--after-change should tag input with prompt-id using crush--prompt-start-marker."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Type text after the prompt
          (goto-char (point-max))
          (insert "typed text")
          ;; Check that the inserted text has the prompt-id property
          (let ((prompt-id (get-text-property (- (point) 5) 'crush-prompt-id)))
            (should prompt-id)
            (should (string= prompt-id crush--prompt-id)))))
    (crush-test--cleanup)))

;;; 70. Phase 6: Remove crush-prompt-start and crush--make-prompt-marker

(ert-deftest crush-test/prompt-start-var-removed ()
  "crush-prompt-start should not be a defined variable."
  (should-not (boundp 'crush-prompt-start)))

(ert-deftest crush-test/make-prompt-marker-removed ()
  "crush--make-prompt-marker should not be defined."
  (should-not (fboundp 'crush--make-prompt-marker)))

;;; 71. Phase 6: crush-clear-buffer uses comint prompt insertion (DELETED in Phase 4: replaced by clear-buffer-prompt-has-crush-properties)

;;; 72. Phase 6: crush-interrupt uses comint prompt insertion (DELETED in Phase 4: no field property)

;;; 73. Bug fix: org fontification creates syntax overlays in crush buffer

(ert-deftest crush-test/fontify-org-creates-syntax-overlays-in-crush-buffer ()
  "Fontifying org text should create syntax overlays in the crush buffer,
not just the base face overlay. The temp-buffer overlays must be copied
back to the crush buffer."
  (skip-unless (require 'org nil t))
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "#+begin_src text :file test.el\n(code)\n#+end_src")
          (crush--fontify-as-org (point-min) (point-max))
          ;; Should have MORE than just the base overlay -- org syntax
          ;; elements (e.g. org-block, org-meta-line) should have overlays
          (let ((overlays (overlays-in (point-min) (point-max))))
            ;; At least 2 overlays: base face + at least one syntax overlay
            (should (> (length overlays) 1))
            ;; At least one overlay should have a face that is NOT crush-org-face
            (should (cl-some (lambda (ov)
                               (let ((face (overlay-get ov 'face)))
                                 (and face
                                      (not (eq face 'crush-org-face))
                                      (overlay-get ov 'crush-overlay))))
                             overlays)))))
    (crush-test--cleanup)))

;;; 74. Bug fix: org overlays survive sentinel (next prompt)

(ert-deftest crush-test/org-overlays-survive-sentinel ()
  "Org attachment overlays should survive sentinel inserting a new prompt.
The overlays must persist in the crush buffer across prompt cycles."
  (skip-unless (require 'org nil t))
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Insert an attachment via the real function
            (crush--insert-before-prompt
             buf
             "#+begin_src text :file test.el\n(code)\n#+end_src"
             "attach-1" crush--prompt-id)
            ;; Count org-region overlays before sentinel
            (let ((overlays-before
                   (cl-remove-if-not
                    (lambda (ov)
                      (and (overlay-get ov 'crush-overlay)
                           (not (overlay-get ov 'read-only))
                           (eq (get-text-property
                                (overlay-start ov) 'crush-region-type) 'org)))
                    (overlays-in (point-min) (point-max)))))
              ;; Simulate a response cycle
              (goto-char (point-max))
              (newline)
              (setq-local crush--response-start (point-marker))
              (let* ((mock-proc (make-process
                                 :name "crush-mock"
                                 :buffer buf
                                 :command '("sh" "-c" "echo 'response'")
                                 :connection-type 'pipe
                                 :filter #'crush--output-filter
                                 :sentinel #'ignore
                                 :noquery t)))
                (set-marker (process-mark mock-proc) (point-max))
                (accept-process-output mock-proc 2)
                (crush--process-sentinel mock-proc "finished\n"))
              ;; Org overlays should still exist after sentinel
              (let ((overlays-after
                     (cl-remove-if-not
                      (lambda (ov)
                        (and (overlay-buffer ov)
                             (overlay-get ov 'crush-overlay)
                             (not (overlay-get ov 'read-only))
                             (eq (get-text-property
                                  (overlay-start ov) 'crush-region-type) 'org)))
                      (overlays-in (point-min) (point-max)))))
                (should (= (length overlays-after) (length overlays-before)))))))
      (crush-test--cleanup))))

;;; 75. Bug: org overlays disappear on send-input

(ert-deftest crush-test/insert-before-prompt-keeps-prompt-marker ()
  "Inserting an attachment before the prompt should not move
crush--prompt-start-marker backward. The marker must advance
past inserted text so comint-send-input's delete-region only
deletes the prompt+input, not the attachment."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (= (marker-position crush--prompt-start-marker) (point-min)))
          ;; Insert an attachment before the prompt
          (crush--insert-before-prompt
           buf
           "#+begin_src text :file test.el\n(code)\n#+end_src"
           "attach-1" crush--prompt-id)
          ;; crush--prompt-start-marker should now point to the prompt,
          ;; not to the beginning of the attachment
          (goto-char (marker-position crush--prompt-start-marker))
          (should (search-forward "crush> " nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/org-overlays-survive-send-input ()
  "Org attachment overlays should survive comint-send-input.
The overlays must not be destroyed by delete-region in comint-send-input,
which happens when crush--prompt-start-marker is wrong."
  (skip-unless (require 'org nil t))
  (let ((crush-buffer-name "*crush-test*"))
    (crush-test--cleanup)
    (dolist (proc (process-list))
      (when (string-prefix-p "crush" (process-name proc))
        (delete-process proc)))
    (unwind-protect
        (let* ((cap (make-temp-file "crush-cap"))
               (crush-program (crush-test--mock-program))
               (process-environment
                (cons (format "CRUSH_CAPTURE_FILE=%s" cap) process-environment)))
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (crush--insert-before-prompt
               buf
               "#+begin_src text :file test.el\n(code)\n#+end_src"
               "attach-1" crush--prompt-id)
              (let ((count-overlays
                     (lambda ()
                       (cl-remove-if-not
                        (lambda (ov)
                          (and (overlay-buffer ov)
                               (overlay-get ov 'crush-overlay)
                               (eq (get-text-property
                                    (overlay-start ov) 'crush-region-type) 'org)))
                        (overlays-in (point-min) (point-max))))))
                (let ((before (length (funcall count-overlays))))
                  (should (> before 0))
                  ;; Type prompt and send
                  (goto-char (point-max))
                  (insert "test prompt")
                  (call-interactively #'crush-send-input)
                  ;; Overlays should survive comint-send-input
                  (should (= (length (funcall count-overlays)) before))
                  (accept-process-output crush-process 3)
                  (while (and crush-process (process-live-p crush-process))
                    (accept-process-output crush-process 1))))))
          (when (file-exists-p cap) (delete-file cap)))
      (crush-test--cleanup))))

;;; Backend abstraction tests

(ert-deftest crush-test/backend-is-run-by-default ()
  "crush--backend should be a crush-run-backend by default."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--backend)
          (should (crush-backend-p crush--backend))
          (should (crush-run-backend-p crush--backend))
          (should (eq (crush-backend-type crush--backend) 'run))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-has-buffer ()
  "crush--backend should have its buffer set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq (crush-backend-buffer crush--backend) buf))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-has-program ()
  "crush-run-backend should have the program path set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (string= (crush-run-backend-program crush--backend) crush-program))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-active-p-when-no-process ()
  "crush-backend-active-p should return nil when no process is running."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (crush-backend-active-p crush--backend))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-active-p-when-process-running ()
  "crush-backend-active-p should return non-nil when a process is running."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush-process (make-process
                                     :name "crush-test-fake"
                                     :buffer buf
                                     :command '("sleep" "30")
                                     :connection-type 'pipe
                                     :noquery t))
          (should (crush-backend-active-p crush--backend))
          (interrupt-process crush-process)
          (setq-local crush-process nil)))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-send-prompt-spawns-process ()
  "crush-backend-send-prompt should spawn a crush process via the backend."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((result (crush-test--with-mock
                       (lambda ()
                         (let ((buf (crush-test--fresh-buffer)))
                           (with-current-buffer buf
                             (goto-char (point-max))
                             (insert "test via backend")
                             (call-interactively #'crush-send-input)
                             (accept-process-output crush-process 2)))))))
          (should (string-match-p "test via backend" result)))
      (crush-test--cleanup))))

(ert-deftest crush-test/backend-send-prompt-with-context ()
  "crush-backend-send-prompt should send context via stdin when attachments exist."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((result (crush-test--with-mock
                       (lambda ()
                         (let ((buf (crush-test--fresh-buffer)))
                           (with-current-buffer buf
                             (goto-char (point-min))
                             (let ((start (point))
                                   (inhibit-read-only t))
                               (insert "#+begin_src text :file foo.el :lines 1-3\n(foo)\n#+end_src\n\n")
                               (add-text-properties
                                start (point)
                                (list 'crush-attachment-id "test-attach-id"
                                      'crush-prompt-id crush--prompt-id
                                      'crush-region-type 'org)))
                             (goto-char (point-max))
                             (insert "explain this code")
                             (call-interactively #'crush-send-input)
                             (accept-process-output crush-process 2)))))))
          (should (string-match-p "STDIN:" result))
          (should (string-match-p "explain this code" result))
          (should (string-match-p "#\\+begin_src text :file foo.el" result)))
      (crush-test--cleanup))))

(ert-deftest crush-test/backend-interrupt-stops-process ()
  "crush-backend-interrupt should stop the running process."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush-process (make-process
                                     :name "crush-test-fake"
                                     :buffer buf
                                     :command '("sleep" "30")
                                     :connection-type 'pipe
                                     :noquery t))
          (should (crush-backend-active-p crush--backend))
          (crush-backend-interrupt crush--backend)
          (should-not (crush-backend-active-p crush--backend))
          (setq-local crush-process nil)))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-cleanup-kills-process ()
  "crush-backend-cleanup should kill any running process."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush-process (make-process
                                     :name "crush-test-fake"
                                     :buffer buf
                                     :command '("sleep" "30")
                                     :connection-type 'pipe
                                     :noquery t))
          (should (crush-backend-active-p crush--backend))
          (crush-backend-cleanup crush--backend)
          (should-not (crush-backend-active-p crush--backend))))
    (crush-test--cleanup)))

(ert-deftest crush-test/client-backend-struct ()
  "crush-client-backend should be a crush-backend struct."
  (let ((backend (crush-make-client-backend
                  :buffer (current-buffer)
                  :working-directory "/tmp"
                  :host nil)))
    (should (crush-backend-p backend))
    (should (crush-client-backend-p backend))
    (should (eq (crush-backend-type backend) 'client))))

(ert-deftest crush-test/client-backend-active-p-no-sse ()
  "crush-backend-active-p should return nil when no SSE process."
  (let ((backend (crush-make-client-backend
                  :buffer (current-buffer)
                  :working-directory "/tmp"
                  :host nil)))
    (should-not (crush-backend-active-p backend))))

(ert-deftest crush-test/client-backend-send-prompt-errors ()
  "crush-backend-send-prompt should error for client backend (not yet implemented)."
  (let ((backend (crush-make-client-backend
                  :buffer (current-buffer)
                  :working-directory "/tmp"
                  :host nil)))
    (should-error (crush-backend-send-prompt backend "test" :context nil :session-id nil))))

(ert-deftest crush-test/backend-grant-permission-noop-for-run ()
  "crush-backend-grant-permission should be a no-op for run backend."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null (crush-backend-grant-permission crush--backend "perm-id" 'allow)))))
    (crush-test--cleanup)))

;;; Phase 0: Parallel markers

(ert-deftest crush-test/prompt-start-marker-set-on-init ()
  "crush--prompt-start-marker should be set after buffer init."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--prompt-start-marker)
          (should (markerp crush--prompt-start-marker))))
    (crush-test--cleanup)))

;;; Phase 0 tracking tests (DELETED in Phase 4: no comint-last-prompt to track)

(ert-deftest crush-test/input-start-marker-set-on-init ()
  "crush--input-start-marker should be set after buffer init."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--input-start-marker)
          (should (markerp crush--input-start-marker))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-start-marker-insertion-type ()
  "crush--prompt-start-marker should have insertion-type t (advances on insert before)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (markerp crush--prompt-start-marker))
          (should (marker-insertion-type crush--prompt-start-marker))))
    (crush-test--cleanup)))

(ert-deftest crush-test/crush-prompt-face-defined ()
  "crush-prompt-face should be defined."
  (should (facep 'crush-prompt-face)))

;;; Phase 2: Custom output filter

(ert-deftest crush-test/output-filter-inserts-at-mark ()
  "crush--output-filter should insert text at the process mark position."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (let* ((mark-pos (point))
                 (proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-marker (process-mark proc) mark-pos)
            (crush--output-filter proc "hello world\n")
            (goto-char mark-pos)
            (should (search-forward "hello world" nil t))
            (should (> (process-mark proc) mark-pos))
            (delete-process proc))))
    (crush-test--cleanup)))

(ert-deftest crush-test/output-filter-advances-process-mark ()
  "crush--output-filter should advance the process mark past inserted text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (let* ((mark-pos (point))
                 (proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-marker (process-mark proc) mark-pos)
            (crush--output-filter proc "abc")
            (should (= (process-mark proc) (+ mark-pos 3)))
            (crush--output-filter proc "xyz")
            (should (= (process-mark proc) (+ mark-pos 6)))
            (delete-process proc))))
    (crush-test--cleanup)))

(ert-deftest crush-test/output-filter-logs-to-debug ()
  "crush--output-filter should log output to *crush-debug* when debug mode is on."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let* ((proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-marker (process-mark proc) (point-max))
            (crush--output-filter proc "test output\n")
            (delete-process proc)))
        (with-current-buffer "*crush-debug*"
          (goto-char (point-min))
          (should (search-forward "output" nil t))
          (should (search-forward "test output" nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/output-filter-no-field-property ()
  "crush--output-filter should NOT set field=output on inserted text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (let* ((mark-pos (point))
                 (proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-marker (process-mark proc) mark-pos)
            (crush--output-filter proc "response text\n")
            (should-not (get-text-property (+ mark-pos 1) 'field))
            (delete-process proc))))
    (crush-test--cleanup)))

(ert-deftest crush-test/output-filter-handles-dead-buffer ()
  "crush--output-filter should not error when process buffer is dead."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let* ((proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-marker (process-mark proc) (point-max))
            (kill-buffer buf)
            (should-not (crush--output-filter proc "should not error\n"))
            (delete-process proc))))
    (crush-test--cleanup)))

(ert-deftest crush-test/suppress-false-prompt-removed ()
  "crush--suppress-false-prompt should not be defined after Phase 2."
  (should-not (fboundp 'crush--suppress-false-prompt)))

;;; Phase 3: Custom input ring

(ert-deftest crush-test/custom-input-ring-initialized ()
  "crush--input-ring should be a ring in crush-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (boundp 'crush--input-ring))
          (should (ring-p crush--input-ring))))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-add ()
  "crush--input-ring-add should add input to the ring."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (crush--input-ring-add "first prompt")
          (should (= (ring-length crush--input-ring) 1))
          (should (string= "first prompt" (ring-ref crush--input-ring 0)))
          (crush--input-ring-add "second prompt")
          (should (= (ring-length crush--input-ring) 2))
          (should (string= "second prompt" (ring-ref crush--input-ring 0)))
          (should (string= "first prompt" (ring-ref crush--input-ring 1)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-add-skips-duplicate ()
  "crush--input-ring-add should not add consecutive duplicate entries."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (crush--input-ring-add "same prompt")
          (should (= (ring-length crush--input-ring) 1))
          (crush--input-ring-add "same prompt")
          (should (= (ring-length crush--input-ring) 1))))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-add-skips-empty ()
  "crush--input-ring-add should not add empty strings."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (crush--input-ring-add "")
          (should (= (ring-length crush--input-ring) 0))))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-read-from-file ()
  "crush--input-ring-read should read history from file."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (tmpfile (make-temp-file "crush-ring-test")))
        (with-temp-buffer
          (insert "line one\nline two\nline three\n")
          (write-region (point-min) (point-max) tmpfile nil 'quiet))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (let ((crush--input-ring-file-name tmpfile))
            (crush--input-ring-read))
          (should (= (ring-length crush--input-ring) 3))
          (should (string= "line three" (ring-ref crush--input-ring 0)))
          (should (string= "line two" (ring-ref crush--input-ring 1)))
          (should (string= "line one" (ring-ref crush--input-ring 2))))
        (when (file-exists-p tmpfile) (delete-file tmpfile)))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-write-to-file ()
  "crush--input-ring-write should write history to file."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (tmpfile (make-temp-file "crush-ring-test")))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (crush--input-ring-add "alpha")
          (crush--input-ring-add "beta")
          (let ((crush--input-ring-file-name tmpfile))
            (crush--input-ring-write))
          (with-temp-buffer
            (insert-file-contents tmpfile)
            (goto-char (point-min))
            (should (search-forward "beta" nil t))
            (should (search-forward "alpha" nil t))))
        (when (file-exists-p tmpfile) (delete-file tmpfile)))
    (crush-test--cleanup)))

(ert-deftest crush-test/send-input-adds-to-custom-ring ()
  "crush-send-input should add prompt to crush--input-ring."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "history test")
          (let ((real-make-process (symbol-function #'make-process)))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _)
                         (let ((proc (funcall real-make-process
                                              :name "crush-fake"
                                              :buffer (current-buffer)
                                              :command '("true")
                                              :connection-type 'pipe
                                              :noquery t)))
                           (set-process-query-on-exit-flag proc nil)
                           proc))))
              (call-interactively #'crush-send-input)))
          (should (> (ring-length crush--input-ring) 0))
          (should (string-match-p "history test"
                                  (ring-ref crush--input-ring 0)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/no-placeholder-process ()
  "crush-mode should not require a placeholder process for input."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (get-buffer-process (current-buffer)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/ensure-process-removed ()
  "crush--ensure-process should not be defined after Phase 3."
  (should-not (fboundp 'crush--ensure-process)))

(ert-deftest crush-test/input-sender-removed ()
  "crush--input-sender should not be defined after Phase 3."
  (should-not (fboundp 'crush--input-sender)))

(ert-deftest crush-test/input-previous-inserts-from-ring ()
  "M-p should insert previous input from crush--input-ring."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (crush--input-ring-add "old prompt one")
          (crush--input-ring-add "old prompt two")
          (setq-local crush--input-ring-index 0)
          (goto-char (point-max))
          (crush--input-previous)
          (should (string= "old prompt two"
                           (buffer-substring-no-properties
                            (marker-position crush--input-start-marker)
                            (line-end-position))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-next-inserts-from-ring ()
  "M-n should insert next (more recent) input from crush--input-ring."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (crush--input-ring-add "old prompt one")
          (crush--input-ring-add "old prompt two")
          (setq-local crush--input-ring-index 1)
          (goto-char (point-max))
          (crush--input-next)
          (should (string= "old prompt two"
                           (buffer-substring-no-properties
                            (marker-position crush--input-start-marker)
                            (line-end-position))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-ring-file-name-default ()
  "crush--input-ring-file-name should default to a file in user-emacs-directory."
  (should (string= crush--input-ring-file-name
                   (expand-file-name "crush-history" user-emacs-directory))))

;;; Phase 4: Sever comint-mode, switch to text-mode

(ert-deftest crush-test/mode-parent-is-text-mode ()
  "crush-mode should derive from text-mode, not comint-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq major-mode 'crush-mode))
          (should (derived-mode-p 'text-mode))
          (should-not (derived-mode-p 'comint-mode))))
    (crush-test--cleanup)))

(ert-deftest crush-test/no-comint-last-prompt ()
  "comint-last-prompt should not be set in crush-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (bound-and-true-p comint-last-prompt))))
    (crush-test--cleanup)))

(ert-deftest crush-test/no-field-property-on-prompt ()
  "The prompt should NOT have field property (comint removed)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (should-not (get-text-property (1- (point)) 'field))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-has-crush-prompt-face ()
  "The prompt text should have crush-prompt-face."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (should (eq (get-text-property (1- (point)) 'font-lock-face)
                      'crush-prompt-face))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-is-read-only ()
  "The prompt text should be read-only (via overlay)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (should (get-char-property (1- (point)) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/clear-buffer-prompt-has-crush-properties ()
  "After crush-clear-buffer, the new prompt should have crush properties."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (call-interactively #'crush-clear-buffer)
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (should (get-char-property (match-beginning 0) 'read-only))
          (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                      'crush-prompt-face))
          (should-not (get-text-property (match-beginning 0) 'field))))
    (crush-test--cleanup)))

(ert-deftest crush-test/no-comint-in-crush-source ()
  "crush.el source should not contain (require 'comint)."
  (with-temp-buffer
    (insert-file-contents (locate-library "crush.el"))
    (goto-char (point-min))
    (should-not (search-forward "(require 'comint)" nil t))))

;;; Phase 5: crush-chat-mode minor mode

(ert-deftest crush-test/chat-mode-is-defined ()
  "crush-chat-mode should be defined as a minor mode."
  (should (boundp 'crush-chat-mode))
  (should (fboundp 'crush-chat-mode)))

(ert-deftest crush-test/chat-mode-enabled-in-crush-buffer ()
  "crush-chat-mode should be enabled in crush buffers."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush-chat-mode)))
    (crush-test--cleanup)))

(ert-deftest crush-test/chat-mode-has-keymap ()
  "crush-chat-mode-map should have the expected keybindings."
  (let ((map (symbol-value 'crush-chat-mode-map)))
    (should (keymapp map))
    (should (eq (lookup-key map (kbd "RET")) #'crush-send-input))
    (should (eq (lookup-key map (kbd "C-c C-c")) #'crush-interrupt))
    (should (eq (lookup-key map (kbd "C-c C-k")) #'crush-clear-buffer))
    (should (eq (lookup-key map (kbd "C-c C-s")) #'crush-new-session))
    (should (eq (lookup-key map (kbd "C-c C-i")) #'crush-insert-selection))
    (should (eq (lookup-key map (kbd "M-p")) #'crush--input-previous))
    (should (eq (lookup-key map (kbd "M-n")) #'crush--input-next))))

(ert-deftest crush-test/chat-mode-ret-binds-send-input ()
  "RET in a crush buffer should resolve to crush-send-input via minor mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq (key-binding (kbd "RET")) #'crush-send-input))))
    (crush-test--cleanup)))

(ert-deftest crush-test/chat-mode-adds-after-change-hook ()
  "crush-chat-mode should add crush--after-change to after-change-functions."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (memq #'crush--after-change after-change-functions))))
    (crush-test--cleanup)))

(ert-deftest crush-test/chat-mode-adds-post-command-hook ()
  "crush-chat-mode should add crush--update-header-line to post-command-hook."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (memq #'crush--update-header-line post-command-hook))))
    (crush-test--cleanup)))

(ert-deftest crush-test/chat-mode-disable-removes-hooks ()
  "Disabling crush-chat-mode should remove its hooks."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (crush-chat-mode -1)
          (should-not (memq #'crush--after-change after-change-functions))
          (should-not (memq #'crush--update-header-line post-command-hook))))
    (crush-test--cleanup)))

(ert-deftest crush-test/crush-mode-does-not-add-hooks ()
  "crush-mode should not add after-change-functions or post-command-hook directly.
Those hooks are managed by crush-chat-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (crush-chat-mode -1)
          (should-not (memq #'crush--after-change after-change-functions))
          (should-not (memq #'crush--update-header-line post-command-hook))))
    (crush-test--cleanup)))

(ert-deftest crush-test/crush-mode-map-is-empty ()
  "crush-mode-map should have no custom keybindings (moved to crush-chat-mode-map).
Parent keymap bindings (from text-mode) may still be present."
  (let ((map crush-mode-map))
    (should (keymapp map))
    (should-not (lookup-key map [crush-send-input]))
    (should-not (lookup-key map [crush-interrupt]))
    (should-not (lookup-key map [crush-clear-buffer]))
    (should-not (lookup-key map [crush-new-session]))
    (should-not (lookup-key map [crush-insert-selection]))
    (should-not (lookup-key map [crush--input-previous]))
    (should-not (lookup-key map [crush--input-next]))))

;;; Phase 6: Backend abstraction cleanup

(ert-deftest crush-test/build-command-removed ()
  "crush--build-command should not be defined (folded into run backend)."
  (should-not (fboundp 'crush--build-command)))

(ert-deftest crush-test/send-input-always-uses-backend ()
  "crush-send-input should always use crush--backend (never nil)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--backend)))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-send-prompt-receives-continue-p ()
  "crush-backend-send-prompt should receive :continue-p keyword."
  (let ((received-continue-p nil))
    (cl-letf (((symbol-function #'crush-backend-send-prompt)
               (lambda (_backend _prompt &rest _keys)
                 (setq received-continue-p
                       (plist-get _keys :continue-p))
                 (make-process :name "crush-fake"
                               :buffer (current-buffer)
                               :command '("true")
                               :connection-type 'pipe
                               :noquery t))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue t)
              (goto-char (point-max))
              (insert "test continue-p")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should received-continue-p)))

(ert-deftest crush-test/backend-send-prompt-continue-p-nil-when-no-continue ()
  "crush-backend-send-prompt :continue-p should be nil when crush--continue is nil."
  (let ((received-continue-p 'unset))
    (cl-letf (((symbol-function #'crush-backend-send-prompt)
               (lambda (_backend _prompt &rest _keys)
                 (setq received-continue-p
                       (plist-get _keys :continue-p))
                 (make-process :name "crush-fake"
                               :buffer (current-buffer)
                               :command '("true")
                               :connection-type 'pipe
                               :noquery t))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue nil)
              (goto-char (point-max))
              (insert "test no continue")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not received-continue-p)))

(ert-deftest crush-test/send-input-no-dead-else-branch ()
  "crush-send-input should not have a fallback path when backend is nil.
The else branch in crush-send-input is dead code since crush--backend
is always set after crush--init-buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--backend)
          (should (crush-run-backend-p crush--backend))))
    (crush-test--cleanup)))

;;; Phase 8: Optional markdown-mode base

(ert-deftest crush-test/parent-mode-is-text-or-markdown ()
  "crush--parent-mode should be either text-mode or markdown-mode."
  (should (memq crush--parent-mode '(text-mode markdown-mode))))

(ert-deftest crush-test/mode-derives-from-parent-mode ()
  "crush-mode should derive from crush--parent-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (derived-mode-p crush--parent-mode))))
    (crush-test--cleanup)))

;;; Text-property-based read-only prompt

(ert-deftest crush-test/can-type-after-prompt ()
  "User should be able to type after the prompt without text-read-only error."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (should-not (get-char-property (point) 'read-only))
          (insert-and-inherit "hello")
          (goto-char (point-min))
          (should (search-forward "hello" nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-is-read-only-via-text-property ()
  "The prompt text should be read-only via a text property.
Backspacing into the prompt should be blocked."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (goto-char (match-beginning 0))
          (should (get-text-property (point) 'read-only))
          (should (get-char-property (point) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/cannot-type-into-prompt ()
  "Typing into the read-only prompt should signal text-read-only."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (goto-char (match-beginning 0))
          (should-error (insert-and-inherit "X") :type 'text-read-only)))
    (crush-test--cleanup)))

(ert-deftest crush-test/previous-content-is-read-only ()
  "After a response cycle, previous content should be read-only via text property."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo response")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-min))
          (should (search-forward "response" nil t))
          (should (get-text-property (match-beginning 0) 'read-only))
          (should (get-char-property (match-beginning 0) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/cannot-type-into-previous-response ()
  "Typing into a frozen previous response should signal text-read-only."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo response")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-min))
          (should (search-forward "response" nil t))
          (goto-char (match-beginning 0))
          (should-error (insert-and-inherit "X") :type 'text-read-only)))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-area-is-editable ()
  "After a response cycle, the new input area should be editable."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo response")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-max))
          (should-not (get-char-property (point) 'read-only))
          (insert-and-inherit "new input")
          (goto-char (point-min))
          (should (search-forward "new input" nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/read-only-via-text-property-tagged ()
  "Read-only should be enforced via a text property, not an overlay."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; The prompt carries a read-only text property.
          (should (get-text-property 1 'read-only))
          ;; No overlay should be responsible for read-only.
          (should-not (cl-some (lambda (ov) (overlay-get ov 'read-only))
                               (overlays-in (point-min) (point-max))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/inhibit-read-only-allows-programmatic-insert ()
  "Programmatic insertion with inhibit-read-only should bypass the freeze."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-min))
            (insert "PROGRAMMATIC"))
          (goto-char (point-min))
          (should (search-forward "PROGRAMMATIC" nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/clear-buffer-keeps-prompt-readable-input ()
  "crush-clear-buffer should reset the buffer so input is editable again."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (call-interactively #'crush-clear-buffer)
          (goto-char (point-max))
          (should-not (get-char-property (point) 'read-only))
          (insert-and-inherit "hello")
          (goto-char (point-min))
          (should (search-forward "hello" nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/read-only-survives-font-lock ()
  "Prompt read-only and input editability should survive font-lock refontification."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo response")
                             :connection-type 'pipe
                             :filter #'crush--output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (font-lock-fontify-buffer)
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (should (get-char-property (match-beginning 0) 'read-only))
          (goto-char (match-beginning 0))
          (should-error (insert-and-inherit "X") :type 'text-read-only)
          (goto-char (point-max))
          (should-not (get-char-property (point) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/read-only-survives-markdown-font-lock ()
  "Read-only should survive markdown font-lock when markdown-mode is available.
This mirrors the user session where markdown fontification could previously
fail to enforce read-only."
  (skip-unless (require 'markdown-mode nil t))
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "test")
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo '# heading'")
                               :connection-type 'pipe
                               :filter #'crush--output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 2)
              (crush--process-sentinel mock-proc "finished\n"))
            (font-lock-fontify-buffer)
            (goto-char (point-min))
            (should (search-forward "crush> " nil t))
            (goto-char (match-beginning 0))
            (should (get-text-property (point) 'read-only))
            (should-error (insert-and-inherit "X") :type 'text-read-only)
            (goto-char (point-max))
            (should-not (get-char-property (point) 'read-only))))
      (crush-test--cleanup))))

(provide 'crush-test)
;;; crush-test.el ends here
