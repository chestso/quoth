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
  "After `crush' creates the buffer, comint-last-prompt should be set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should comint-last-prompt)
          (should (markerp (car comint-last-prompt)))
          ;; Prompt should be at the start of the buffer
          (should (= (marker-position (car comint-last-prompt)) (point-min)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/sentinel-resets-prompt-start ()
  "After process sentinel runs, comint-last-prompt should be reset."
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
            (should comint-last-prompt)
            (should (markerp (car comint-last-prompt)))
            ;; New prompt should be at the end of the buffer
            (should (= (marker-position (car comint-last-prompt)) (- (point-max) (length "crush> ")))))))
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
          (let ((fake-proc (make-process
                            :name "crush-test-fake"
                            :buffer buf
                            :command '("true")
                            :connection-type 'pipe
                            :noquery t)))
            (set-marker (process-mark fake-proc) (marker-position (car comint-last-prompt)))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) fake-proc))
                      ((symbol-function 'start-process)
                       (lambda (&rest _args) fake-proc)))
              (call-interactively #'crush-send-input))
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
            (set-marker (process-mark fake-proc) (marker-position (car comint-last-prompt)))
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
                       (let ((start (point)))
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
            (set-marker (process-mark fake-proc) (marker-position (car comint-last-prompt)))
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
            (set-marker (process-mark fake-proc) (marker-position (car comint-last-prompt)))
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
            (insert "---------- Crush Response ----------\n")
            (let ((response-start (point)))
              (insert "response text\n")
              ;; Tag it manually like sentinel does
              (put-text-property response-start (point) 'crush-response-to prompt-id)
              (insert "------------------------------------\n")
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
              (set-marker (process-mark fake-proc) (marker-position (car comint-last-prompt)))
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
            (insert "---------- Crush Response ----------\n")
            (let ((response-start (point)))
              (insert "response text\n")
              ;; Tag and apply face like sentinel does
              (put-text-property response-start (point) 'crush-response-to prompt-id)
              (let ((ov (make-overlay response-start (point) nil t)))
                (overlay-put ov 'face 'crush-response-face)
                (overlay-put ov 'crush-overlay t))
              (insert "------------------------------------\n")
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
              (let ((inhibit-read-only t))
                (insert "---------- Crush Response ----------\n"))
              ;; Mark where response will start
              (setq-local crush--response-start (point-marker))
              ;; Use mock process with actual filter to output response
              (let* ((mock-proc (make-process
                                 :name "crush-mock"
                                 :buffer buf
                                 :command '("sh" "-c" "echo 'response text'")
                                 :connection-type 'pipe
                                 :filter #'comint-output-filter
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
            (let ((inhibit-read-only t))
              (insert "---------- Crush Response ----------\n"))
            (setq-local crush--response-start (point-marker))
            ;; Create process with no output
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "true")
                               :connection-type 'pipe
                               :filter #'comint-output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 2)
              ;; Should not error on empty response
              (crush--process-sentinel mock-proc "finished\n"))
            ;; Check buffer still has separator
            (goto-char (point-min))
            (should (search-forward "------------------------------------" nil t))))
      (crush-test--cleanup))))

;;; 28. Integration: interrupted response still inserts new prompt

(ert-deftest crush-test/integration-interrupted-response ()
  "Interrupted response should still insert separator and new prompt."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Setup buffer
            (goto-char (point-max))
            (newline)
            (let ((inhibit-read-only t))
              (insert "---------- Crush Response ----------\n"))
            (setq-local crush--response-start (point-marker))
            ;; Create process that gets interrupted
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'partial'; sleep 10")
                               :connection-type 'pipe
                               :filter #'comint-output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 0.5)
              ;; Simulate interrupt
              (crush--process-sentinel mock-proc "interrupt\n"))
            ;; Check buffer has interrupted message
            (goto-char (point-min))
            (should (search-forward "Interrupted" nil t))
            ;; Check buffer has new prompt
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
            (let ((inhibit-read-only t))
              (insert "---------- Crush Response ----------\n"))
            (setq-local crush--response-start (point-marker))
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'response text'")
                               :connection-type 'pipe
                               :filter #'comint-output-filter
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
          (let ((inhibit-read-only t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
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

;;; 34. Region type tagging: separator (response header)

(ert-deftest crush-test/separator-region-tagged-as-separator ()
  "The response header separator should be tagged with crush-region-type 'separator."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate sending a prompt
          (goto-char (point-max))
          (insert "test prompt")
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          ;; Check that the footer separator has crush-region-type 'separator
          (goto-char (point-min))
          (should (search-forward "------------------------------------" nil t))
          (let ((region-type (get-text-property (match-beginning 0) 'crush-region-type)))
            (should (eq region-type 'separator)))))
    (crush-test--cleanup)))

;;; 35. Region type tagging: separator (interrupted)

(ert-deftest crush-test/interrupted-separator-tagged-as-separator ()
  "The interrupted separator should be tagged with crush-region-type 'separator."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Setup buffer
            (goto-char (point-max))
            (insert "test")
            (goto-char (point-max))
            (newline)
            (let ((inhibit-read-only t)
                  (sep-start (point)))
              (insert "---------- Crush Response ----------\n")
              (put-text-property sep-start (point) 'crush-region-type 'separator))
            (setq-local crush--response-start (point-marker))
            ;; Create process that gets interrupted
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'partial'; sleep 10")
                               :connection-type 'pipe
                               :filter #'comint-output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 0.5)
              ;; Simulate interrupt
              (crush--process-sentinel mock-proc "interrupt\n"))
            ;; Check that the interrupted separator has crush-region-type 'separator
            (goto-char (point-min))
            (should (search-forward "Interrupted" nil t))
            (let ((region-type (get-text-property (match-beginning 0) 'crush-region-type)))
              (should (eq region-type 'separator)))))
      (crush-test--cleanup))))

;;; 36. Region type tagging: input header separator

(ert-deftest crush-test/input-header-separator-tagged-as-separator ()
  "The '---------- Crush Response ----------' header should be tagged with crush-region-type 'separator."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate sending a prompt
          (goto-char (point-max))
          (insert "test prompt")
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          ;; Check that the header separator has crush-region-type 'separator
          (goto-char (point-min))
          (should (search-forward "---------- Crush Response ----------" nil t))
          (let ((region-type (get-text-property (match-beginning 0) 'crush-region-type)))
            (should (eq region-type 'separator)))))
    (crush-test--cleanup)))

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
  "Fontifying markdown text should create overlays for syntax elements."
  (skip-unless (require 'markdown-mode nil t))
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "**bold text** and `inline code`")
          (crush--fontify-as-markdown (point-min) (point-max))
          ;; Should have overlays with crush-overlay property
          (let ((overlays (overlays-in (point-min) (point-max))))
            (should (cl-some (lambda (ov) (overlay-get ov 'crush-overlay)) overlays)))))
    (crush-test--cleanup)))

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
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo '**bold** text'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
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
  "crush-clear-buffer should remove all crush-overlay tagged overlays."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Create some overlays manually
          (let ((ov (make-overlay (point-min) (point-max))))
            (overlay-put ov 'crush-overlay t))
          ;; Call clear-buffer
          (call-interactively #'crush-clear-buffer)
          ;; Should have no crush-overlay overlays that are still live
          (should-not (cl-some (lambda (ov)
                                 (and (overlay-buffer ov)
                                      (overlay-get ov 'crush-overlay)))
                               (overlays-in (point-min) (point-max))))))
    (crush-test--cleanup)))

;;; 43. Phase 1: comint-output-filter produces field=output

(ert-deftest crush-test/comint-filter-sets-field-output ()
  "Process output should have field=output property when using comint-output-filter."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((proc (make-process
                       :name "crush-test"
                       :buffer buf
                       :command '("true")
                       :connection-type 'pipe
                       :noquery t))
                (inhibit-read-only t))
            (set-process-filter proc #'comint-output-filter)
            (set-marker (process-mark proc) (point-max))
            (comint-output-filter proc "response text\n")
            (should (eq (get-text-property (- (point-max) 5) 'field) 'output))
            (delete-process proc))))
    (crush-test--cleanup)))

;;; 44. Phase 1: comint-output-filter-functions hook runs

(ert-deftest crush-test/comint-filter-functions-hook-runs ()
  "comint-output-filter-functions should run when output is filtered."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (hook-called nil))
        (with-current-buffer buf
          (let ((proc (make-process
                       :name "crush-test"
                       :buffer buf
                       :command '("true")
                       :connection-type 'pipe
                       :noquery t))
                (hook-fn (lambda (_str) (setq hook-called t)))
                (inhibit-read-only t))
            (set-process-filter proc #'comint-output-filter)
            (set-marker (process-mark proc) (point-max))
            (add-hook 'comint-output-filter-functions hook-fn nil t)
            (comint-output-filter proc "test output\n")
            (should hook-called)
            (remove-hook 'comint-output-filter-functions hook-fn t)
            (delete-process proc))))
    (crush-test--cleanup)))

;;; 45. Phase 1: comint-output-filter inserts at process mark

(ert-deftest crush-test/comint-filter-inserts-at-process-mark ()
  "comint-output-filter should insert output at the process mark position."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert "---------- Crush Response ----------\n"))
          (let* ((mark-pos (point))
                 (proc (make-process
                        :name "crush-test"
                        :buffer buf
                        :command '("true")
                        :connection-type 'pipe
                        :noquery t))
                 (inhibit-read-only t))
            (set-process-filter proc #'comint-output-filter)
            (set-marker (process-mark proc) mark-pos)
            (comint-output-filter proc "hello world\n")
            (goto-char mark-pos)
            (should (search-forward "hello world" nil t))
            (should (> (process-mark proc) mark-pos))
            (delete-process proc))))
    (crush-test--cleanup)))

;;; 46. Phase 2: comint prompt fields - prompt is read-only

(ert-deftest crush-test/comint-prompt-is-read-only ()
  "The prompt text should be read-only when using comint field-based prompts."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          ;; Text before point (the prompt) should be read-only
          (should (get-text-property (1- (point)) 'read-only))))
    (crush-test--cleanup)))

;;; 47. Phase 2: comint prompt fields - field-at-pos

(ert-deftest crush-test/comint-field-at-pos-prompt ()
  "field-at-pos should return the correct field for prompt text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          ;; The prompt text should have a field property
          (should (get-text-property 1 'field))))
    (crush-test--cleanup)))

;;; 48. Phase 2: comint prompt fields - comint-highlight-prompt face

(ert-deftest crush-test/comint-prompt-has-highlight-face ()
  "The prompt should have comint-highlight-prompt face."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          ;; Check for comint-highlight-prompt face on prompt text
          (let ((face (get-text-property 1 'font-lock-face)))
            (should (eq face 'comint-highlight-prompt)))))
    (crush-test--cleanup)))

;;; 49. Phase 3: comint-send-input calls crush--input-sender

(ert-deftest crush-test/send-input-calls-input-sender ()
  "comint-send-input should call crush--input-sender with the input text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (sender-called nil)
            (sent-input nil))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test prompt")
          (cl-letf (((symbol-function #'crush--input-sender)
                     (lambda (_proc input)
                       (setq sender-called t
                             sent-input input)))
                    ((symbol-function #'crush--ensure-process)
                     (lambda ()
                       (let ((proc (make-process
                                    :name "crush-fake"
                                    :buffer (current-buffer)
                                    :command '("sleep" "30")
                                    :connection-type 'pipe
                                    :noquery t)))
                         (set-marker (process-mark proc)
                                     (marker-position (car comint-last-prompt)))
                         proc))))
            (call-interactively #'crush-send-input))
          (should sender-called)
          (should (string-match-p "test prompt" sent-input))))
    (crush-test--cleanup)))

;;; 50. Phase 3: comint-send-input adds to input ring

(ert-deftest crush-test/send-input-adds-to-ring ()
  "comint-send-input should add input to comint-input-ring."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "history test")
          (cl-letf (((symbol-function #'crush--input-sender)
                     (lambda (_proc _input) nil))
                    ((symbol-function #'crush--ensure-process)
                     (lambda ()
                       (let ((proc (make-process
                                    :name "crush-fake"
                                    :buffer (current-buffer)
                                    :command '("sleep" "30")
                                    :connection-type 'pipe
                                    :noquery t)))
                         (set-marker (process-mark proc)
                                     (marker-position (car comint-last-prompt)))
                         proc))))
            (call-interactively #'crush-send-input))
          (should (ring-p comint-input-ring))
          (should (> (ring-length comint-input-ring) 0))
          (should (string-match-p "history test"
                                  (ring-ref comint-input-ring 0)))))
    (crush-test--cleanup)))

;;; 51. Phase 3: crush--ensure-process creates placeholder

(ert-deftest crush-test/ensure-process-creates-placeholder ()
  "crush--ensure-process should create a placeholder process if none exists."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Kill any existing process
          (when-let ((proc (get-buffer-process buf)))
            (delete-process proc))
          ;; Call ensure-process
          (crush--ensure-process)
          ;; Should have a process now
          (should (get-buffer-process buf))
          ;; Clean up
          (delete-process (get-buffer-process buf))))
    (crush-test--cleanup)))

;;; 52. Phase 4: Input history - M-p retrieves previous input

(ert-deftest crush-test/input-ring-initialized ()
  "comint-input-ring should be initialized in crush-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (ring-p comint-input-ring))))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-ring-has-file-name ()
  "comint-input-ring-file-name should be set in crush-mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should comint-input-ring-file-name)))
    (crush-test--cleanup)))

;;; 53. Phase 5: Sentinel inserts prompt with comint field properties

(ert-deftest crush-test/sentinel-prompt-has-field-property ()
  "Sentinel-inserted prompt should have field property for comint navigation."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          ;; New prompt should have field property
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          (should (get-text-property (match-beginning 0) 'field))))
    (crush-test--cleanup)))

;;; 54. Phase 5: Sentinel sets comint-last-prompt

(ert-deftest crush-test/sentinel-sets-comint-last-prompt ()
  "Sentinel should set comint-last-prompt after inserting new prompt."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          ;; comint-last-prompt should be set
          (should comint-last-prompt)
          (should (markerp (car comint-last-prompt)))
          (should (markerp (cdr comint-last-prompt)))))
    (crush-test--cleanup)))

;;; 55. Phase 6: Vestigial code removed

(ert-deftest crush-test/comint-use-prompt-regexp-is-nil ()
  "comint-use-prompt-regexp should be nil (field-based prompts)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null comint-use-prompt-regexp))))
    (crush-test--cleanup)))

(ert-deftest crush-test/crush-process-filter-removed ()
  "crush--process-filter should not be defined (replaced by comint-output-filter)."
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
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
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

(ert-deftest crush-test/separator-region-type-still-set ()
  "Separator lines should still have crush-region-type=separator."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-min))
          (should (search-forward "------------------------------------" nil t))
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type) 'separator))))
    (crush-test--cleanup)))

(ert-deftest crush-test/field-output-on-response ()
  "Response text should have field=output (set by comint-output-filter)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo 'response text'")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
                             :sentinel #'ignore
                             :noquery t)))
            (set-marker (process-mark mock-proc) (point-max))
            (accept-process-output mock-proc 2)
            (crush--process-sentinel mock-proc "finished\n"))
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          (should (eq (get-text-property (- (point) 5) 'field) 'output))))
    (crush-test--cleanup)))

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

(ert-deftest crush-test/debug-logs-command-invocation ()
  "crush--input-sender should log the command to *crush-debug*."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--pending-context nil)
          (let ((crush-program "my-crush")
                (crush--continue t))
            (cl-letf (((symbol-function #'make-process)
                       (let ((real-make-process (symbol-function #'make-process)))
                         (lambda (&rest _args)
                           (let ((proc (funcall real-make-process
                                                :name "fake"
                                                :buffer (current-buffer)
                                                :command '("sleep" "30")
                                                :connection-type 'pipe
                                                :noquery t)))
                             (set-process-query-on-exit-flag proc nil)
                             proc)))))
              (crush--input-sender nil "test prompt"))))
        (should (get-buffer "*crush-debug*"))
        (with-current-buffer "*crush-debug*"
          (goto-char (point-min))
          (should (search-forward "command" nil t))
          (should (search-forward "my-crush" nil t))
          (should (search-forward "test prompt" nil t))))
    (crush-test--cleanup)))

;;; 61. Debug logging - input logged in input-sender

(ert-deftest crush-test/debug-logs-input ()
  "crush--input-sender should log the input text to *crush-debug*."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local crush--pending-context nil)
          (cl-letf (((symbol-function #'make-process)
                     (let ((real-make-process (symbol-function #'make-process)))
                       (lambda (&rest _args)
                         (let ((proc (funcall real-make-process
                                              :name "fake"
                                              :buffer (current-buffer)
                                              :command '("sleep" "30")
                                              :connection-type 'pipe
                                              :noquery t)))
                           (set-process-query-on-exit-flag proc nil)
                           proc)))))
            (crush--input-sender nil "hello from test")))
        (with-current-buffer "*crush-debug*"
          (goto-char (point-min))
          (should (search-forward "input" nil t))
          (should (search-forward "hello from test" nil t))))
    (crush-test--cleanup)))

;;; 62. Debug logging - output logged in suppress-false-prompt

(ert-deftest crush-test/debug-logs-output ()
  "crush--suppress-false-prompt should log output to *crush-debug*."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local comint-last-prompt nil)
          (crush--suppress-false-prompt "some output text"))
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
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (sep-start (point)))
            (insert "---------- Crush Response ----------\n")
            (put-text-property sep-start (point) 'crush-region-type 'separator))
          (setq-local crush--response-start (point-marker))
          (let* ((mock-proc (make-process
                             :name "crush-mock"
                             :buffer buf
                             :command '("sh" "-c" "echo response")
                             :connection-type 'pipe
                             :filter #'comint-output-filter
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

;;; 65. Phase 6: Sentinel does not set manual read-only

(ert-deftest crush-test/sentinel-no-manual-read-only ()
  "Sentinel should not set 'read-only text property manually.
comint-prompt-read-only handles read-only via field properties."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "test")
            (goto-char (point-max))
            (newline)
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t)
                  (sep-start (point)))
              (insert "---------- Crush Response ----------\n")
              (put-text-property sep-start (point) 'crush-region-type 'separator))
            (setq-local crush--response-start (point-marker))
            (let* ((mock-proc (make-process
                               :name "crush-mock"
                               :buffer buf
                               :command '("sh" "-c" "echo 'response text'")
                               :connection-type 'pipe
                               :filter #'comint-output-filter
                               :sentinel #'ignore
                               :noquery t)))
              (set-marker (process-mark mock-proc) (point-max))
              (accept-process-output mock-proc 2)
              (crush--process-sentinel mock-proc "finished\n"))
            ;; Response text should NOT have manual read-only property.
            ;; comint handles read-only via field properties on prompts.
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let ((ro (get-text-property (- (point) 5) 'read-only)))
              (should-not ro)))))
    (crush-test--cleanup)))

;;; 66. Phase 6: crush--ensure-process uses comint-last-prompt

(ert-deftest crush-test/ensure-process-syncs-to-comint-last-prompt ()
  "crush--ensure-process should sync process mark to comint-last-prompt start.
Works even when crush-prompt-start is nil, using comint-last-prompt instead."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Kill any existing process
          (when-let ((proc (get-buffer-process buf)))
            (delete-process proc))
          ;; comint-last-prompt should be set from the initial prompt
          (should comint-last-prompt)
          (should (markerp (car comint-last-prompt)))
          (let ((prompt-start (marker-position (car comint-last-prompt))))
            ;; Call ensure-process
            (crush--ensure-process)
            ;; Process mark should be at the prompt start position
            (let ((proc (get-buffer-process buf)))
              (should proc)
              (should (= (process-mark proc) prompt-start))
              (delete-process proc)))))
    (crush-test--cleanup)))

;;; 67. Phase 6: crush--insert-before-prompt uses comint-last-prompt

(ert-deftest crush-test/insert-before-prompt-works-without-prompt-start ()
  "crush--insert-before-prompt should insert before comint-last-prompt.
Works even when crush-prompt-start is nil, using comint-last-prompt instead."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Get prompt start position from comint-last-prompt
            (should comint-last-prompt)
            (let ((prompt-start (marker-position (car comint-last-prompt))))
              ;; Insert content before prompt
              (crush--insert-before-prompt buf "INSERTED CONTENT" nil nil)
              ;; Content should be before the prompt
              (goto-char (point-min))
              (should (search-forward "INSERTED CONTENT" nil t))
              ;; The prompt should still be after the inserted content
              (should (search-forward "crush> " nil t))
              ;; Prompt start should not have moved (comint-last-prompt marker)
              (should (= (marker-position (car comint-last-prompt)) prompt-start)))))
      (crush-test--cleanup))))

;;; 68. Phase 6: crush-send-input uses comint-last-prompt

(ert-deftest crush-test/send-input-works-without-prompt-start ()
  "crush-send-input should extract input using comint-last-prompt.
When crush-prompt-start is nil and there is text before the prompt,
the extracted prompt in stdin should not include the preceding text
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

;;; 69. Phase 6: crush--after-change uses comint-last-prompt

(ert-deftest crush-test/after-change-tags-without-prompt-start ()
  "crush--after-change should tag input with prompt-id using comint-last-prompt.
Works even when crush-prompt-start is nil."
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

;;; 71. Phase 6: crush-clear-buffer uses comint prompt insertion

(ert-deftest crush-test/clear-buffer-prompt-has-field-properties ()
  "After crush-clear-buffer, the new prompt should have comint field properties."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (call-interactively #'crush-clear-buffer)
          (goto-char (point-min))
          (should (search-forward "crush> " nil t))
          ;; Prompt should have field property (comint field-based)
          (should (get-text-property (match-beginning 0) 'field))
          ;; Prompt should have comint-highlight-prompt face
          (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                      'comint-highlight-prompt))))
    (crush-test--cleanup)))

;;; 72. Phase 6: crush-interrupt uses comint prompt insertion

(ert-deftest crush-test/interrupt-prompt-has-field-properties ()
  "After crush-interrupt, the new prompt should have comint field properties."
  (let ((crush-buffer-name "*crush-test*"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Set up a running crush process
            (setq-local crush-process (make-process
                                       :name "crush-test-fake"
                                       :buffer buf
                                       :command '("sleep" "30")
                                       :connection-type 'pipe
                                       :noquery t))
            (call-interactively #'crush-interrupt)
            ;; Find the LAST crush> prompt (the one inserted by interrupt)
            (goto-char (point-max))
            (should (search-backward "crush> " nil t))
            ;; Prompt should have field property (comint field-based)
            (should (get-text-property (match-beginning 0) 'field))
            ;; Prompt should have comint-highlight-prompt face
            (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                        'comint-highlight-prompt))
            (should (null crush-process))))
      (crush-test--cleanup))))

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
          ;; Should have MORE than just the base overlay — org syntax
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
                           (eq (get-text-property
                                (overlay-start ov) 'crush-region-type) 'org)))
                    (overlays-in (point-min) (point-max)))))
              ;; Simulate a response cycle
              (goto-char (point-max))
              (newline)
              (let ((inhibit-read-only t)
                    (inhibit-modification-hooks t)
                    (sep-start (point)))
                (insert "---------- Crush Response ----------\n")
                (put-text-property sep-start (point) 'crush-region-type 'separator))
              (setq-local crush--response-start (point-marker))
              (let* ((mock-proc (make-process
                                 :name "crush-mock"
                                 :buffer buf
                                 :command '("sh" "-c" "echo 'response'")
                                 :connection-type 'pipe
                                 :filter #'comint-output-filter
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
                             (eq (get-text-property
                                  (overlay-start ov) 'crush-region-type) 'org)))
                      (overlays-in (point-min) (point-max)))))
                (should (= (length overlays-after) (length overlays-before)))))))
      (crush-test--cleanup))))

(provide 'crush-test)
;;; crush-test.el ends here
