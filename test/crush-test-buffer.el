;;; crush-test-buffer.el --- Chat buffer tests for crush  -*- lexical-binding: t; -*-

;;; Commentary:
;;; Buffer lifecycle, prompt/response regions, read-only text properties, input ring.

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'crush)

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
        (default-directory crush-test--root)
        (expected-dir (file-name-as-directory (file-truename crush-test--root))))
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

;;; 9. Session UUID state: init, rotation, distinctness

(ert-deftest crush-test/session-uuid-init ()
  "A fresh crush buffer gets a session UUID and its XXH3-64 hash."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (stringp crush--session-uuid))
          (should (> (length crush--session-uuid) 0))
          (should (string= crush--session-id
                           (crush-xxh3-hash64 crush--session-uuid)))
          (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" crush--session-id))))
    (crush-test--cleanup)))

(ert-deftest crush-test/session-uuid-distinct-across-buffers ()
  "Two fresh crush buffers get distinct session UUIDs."
  (unwind-protect
      (let* ((name1 (crush-test--buffer-name))
             (buf1 (crush-test--fresh-buffer))
             (uuid1 (with-current-buffer buf1 crush--session-uuid)))
        ;; Force a second buffer by turning off buffer reuse (fresh-buffer
        ;; kills the existing one, so create a separately named buffer).
        (let ((crush--root-buffer-alist nil)
              (buf2 (get-buffer-create "*crush:sess2*")))
          (crush--init-buffer buf2)
          (let ((uuid2 (with-current-buffer buf2 crush--session-uuid)))
            (should-not (equal uuid1 uuid2)))
          (kill-buffer buf2)))
    (crush-test--cleanup)))

(ert-deftest crush-test/session-uuid-rotates-on-clear ()
  "`crush-clear-buffer' rotates the session UUID (fresh cache affinity)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((old-uuid crush--session-uuid)
                (old-id crush--session-id))
            (crush-clear-buffer)
            (should-not (equal crush--session-uuid old-uuid))
            (should-not (equal crush--session-id old-id))
            (should (string= crush--session-id
                             (crush-xxh3-hash64 crush--session-uuid))))))
    (crush-test--cleanup)))

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
      (crush-test--cleanup))))

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
          ;; Sentinel must not create any crush overlays anymore.
          (let ((overlays (cl-remove-if-not (lambda (ov) (overlay-get ov 'crush-overlay))
                                            (overlays-in (point-min) (point-max)))))
            (should-not overlays))
          (let ((region-type (get-text-property (- (point) 5) 'crush-region-type)))
            (should (eq region-type 'response)))))
    (crush-test--cleanup)))

;;; 34. Region type tagging: separator (removed - separators no longer inserted)

;;; 35. Region type tagging: separator (removed - separators no longer inserted)

;;; 36. Region type tagging: separator (removed - separators no longer inserted)

;;; 40. Integration: crush-clear-buffer removes overlays

(ert-deftest crush-test/clear-buffer-removes-overlays ()
  "crush-clear-buffer should remove old crush-overlay tagged overlays."
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

(ert-deftest crush-test/facade-finalize-tags-and-reprompts ()
  "The facade continuation should finalize the response: tag it, insert a
fresh prompt, and regenerate the prompt ID."
  (unwind-protect
      (with-current-buffer (crush-test--fresh-buffer)
        (goto-char (point-max))
        (newline)
        (setq-local crush--response-start (point-marker))
        (insert "mock response")
        (let ((old-id crush--prompt-id)
              (response-start (point-marker)))
          ;; The facade continuation is exactly what crush-send-input
          ;; injects into the backend.
          (let ((buf (current-buffer)))
            (funcall (lambda ()
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (crush-facade--finalize))))))
          ;; Fresh prompt inserted after the response, with a new ID.
          (goto-char (point-min))
          (search-forward "mock response")
          (should (eq (get-text-property (match-beginning 0)
                                         'crush-region-type)
                      'response))
          (should-not (string= crush--prompt-id old-id))
          (goto-char (point-max))
          (search-backward "crush> ")
          (should (< (marker-position response-start)
                     (point)))))
    (crush-test--cleanup)))

;;; (Phase 2-5 comint-era tests were deleted during the migration; the
;;; surviving invariants are covered by the tests below.)

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
  "Attachment blocks should have crush-region-type=attachment."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name "/test/file.el")
              (crush-insert-selection (point-min) (point-max)))
            (goto-char (point-min))
            (should (search-forward "Attachment:" nil t))
            (should (eq (get-text-property (match-beginning 0) 'crush-region-type) 'attachment))))
      (crush-test--cleanup))))

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

;;; 64. Prompt insertion rename

(ert-deftest crush-test/insert-prompt-renamed ()
  "crush--insert-prompt should be defined (renamed from crush--insert-prompt-marker)."
  (should (fboundp 'crush--insert-prompt)))


;;; 65. Phase 6: Sentinel freezes previous response read-only

(ert-deftest crush-test/sentinel-freezes-previous-response ()
  "Sentinel should freeze the previous response read-only.
After the sentinel inserts the next prompt, the prior response becomes
read-only previous content, blocking edits and insertions."
  (let ((default-directory crush-test--root))
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
  (let ((default-directory crush-test--root))
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

;;; Phase 3: Custom input ring

(ert-deftest crush-test/custom-input-ring-initialized ()
  "crush--input-ring should be a ring in a crush buffer."
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
  "The crush buffer should not require a placeholder process for input."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (get-buffer-process (current-buffer)))))
    (crush-test--cleanup)))


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
  "The crush buffer's major mode should be the parent mode (text-mode or
markdown-mode), deriving from text-mode and never comint-mode.
There is no separate `crush-mode' major mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq major-mode crush--parent-mode))
          (should (derived-mode-p 'text-mode))
          (should-not (derived-mode-p 'comint-mode))))
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

;;; Phase 8: Optional markdown-mode base

(ert-deftest crush-test/parent-mode-is-text-or-markdown ()
  "crush--parent-mode should be either text-mode or markdown-mode."
  (should (memq crush--parent-mode '(text-mode markdown-mode))))

(ert-deftest crush-test/mode-derives-from-parent-mode ()
  "The crush buffer major mode should derive from crush--parent-mode."
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
  (let ((default-directory crush-test--root))
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
            (should-not (get-char-property (point) 'read-only))
            ;; Crash regression: after markdown fontify, typing in the
            ;; input area must still work (font-lock must not leak the
            ;; prompt's read-only into new input). Insert twice.
            (insert-and-inherit "a")
            (insert-and-inherit "b")
            (goto-char (point-min))
            (should (search-forward "ab" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/type-at-fresh-prompt-after-markdown-font-lock ()
  "Typing at a fresh prompt must work after markdown refontification.
Regression: when markdown-mode fontifies the buffer, it strips
`rear-nonsticky' from the read-only prompt text.  Without it, text typed
right after the prompt inherits `read-only' and Emacs signals
\"Text is read-only\" on the very first insertion."
  (skip-unless (require 'markdown-mode nil t))
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Fontify without any prior input, as jit-lock does during
            ;; redisplay.  This strips rear-nonsticky from the prompt.
            (font-lock-fontify-buffer)
            (goto-char (point-max))
            (should-not (get-char-property (point) 'read-only))
            (insert-and-inherit "hello")
            (insert-and-inherit " world")
            (goto-char (point-min))
            (should (search-forward "hello world" nil t))
            ;; The prompt itself must still be read-only and frozen.
            (goto-char (point-min))
            (should (get-char-property (point) 'read-only))
            (should-error (insert-and-inherit "X") :type 'text-read-only)))
      (crush-test--cleanup))))

;;; 90. Per-project buffer naming

(defun crush-test--cleanup-registry ()
  "Purge `crush--root-buffer-alist' and kill the buffers it names."
  (dolist (entry crush--root-buffer-alist)
    (when (get-buffer (cdr entry))
      (kill-buffer (cdr entry))))
  (setq crush--root-buffer-alist nil))

(ert-deftest crush-test/current-buffer-uses-default-directory-root ()
  "`crush--current-crush-buffer' should use `default-directory' as root."
  (unwind-protect
      (let* ((root (expand-file-name "crush-test-x" temporary-file-directory))
             (buf (with-temp-buffer
                    (setq default-directory root)
                    (crush--current-crush-buffer))))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string= (crush--canonical-root crush--project-root)
                           (crush--canonical-root root)))))
    (crush-test--cleanup-registry)))

(ert-deftest crush-test/current-buffer-uses-project-root ()
  "`crush--current-crush-buffer' should prefer the project root."
  (cl-letf (((symbol-function 'project-current)
             (lambda (&optional dir)
               (list 'vc 'Git "/tmp/crush-proj-root/"))))
    (unwind-protect
        (let* ((root (expand-file-name "crush-test-x" temporary-file-directory))
               (buf (with-temp-buffer
                      (setq default-directory root)
                      (crush--current-crush-buffer))))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (string= (crush--canonical-root crush--project-root)
                             (crush--canonical-root
                              "/tmp/crush-proj-root/")))))
      (crush-test--cleanup-registry))))

(ert-deftest crush-test/current-buffer-reuses-existing-buffer ()
  "Resolving the same root twice should return the same buffer."
  (unwind-protect
      (let* ((root (expand-file-name "crush-test-x" temporary-file-directory))
             (buf1 (with-temp-buffer
                     (setq default-directory root)
                     (crush--current-crush-buffer)))
             (buf2 (with-temp-buffer
                     (setq default-directory root)
                     (crush--current-crush-buffer))))
        (should (eq buf1 buf2)))
    (crush-test--cleanup-registry)))

(ert-deftest crush-test/buffer-name-uses-root-basename ()
  "`crush--buffer-name-for-root' should use the root directory's basename."
  (should (string= (crush--buffer-name-for-root "/tmp/foo/") "*crush:foo*"))
  (should (string= (crush--buffer-name-for-root "~/x/y/") "*crush:y*")))

(ert-deftest crush-test/buffer-name-same-basename-distinct-roots-collide ()
  "Two roots with the same basename should get distinct buffer names."
  (let ((crush--root-buffer-alist nil))
    (should (string= (crush--buffer-name-for-root "/tmp/foo/") "*crush:foo*"))
    (should (string= (crush--buffer-name-for-root "/tmp/bar/foo/") "*crush:foo(2)*"))))

(ert-deftest crush-test/buffer-name-stable-per-root ()
  "Re-resolving a root should return the same name (no growing suffix)."
  (let ((crush--root-buffer-alist nil))
    (crush--buffer-name-for-root "/tmp/foo/")
    (should (string= (crush--buffer-name-for-root "/tmp/bar/foo/") "*crush:foo(2)*"))
    ;; Resolving either root again must not change the mapping.
    (should (string= (crush--buffer-name-for-root "/tmp/foo/") "*crush:foo*"))
    (should (string= (crush--buffer-name-for-root "/tmp/bar/foo/") "*crush:foo(2)*"))))

(ert-deftest crush-test/buffer-name-trailing-slash-canonicalized ()
  "Roots differing only in trailing slash should map to the same name."
  (let ((crush--root-buffer-alist nil))
    (should (string= (crush--buffer-name-for-root "/tmp/foo") "*crush:foo*"))
    (should (string= (crush--buffer-name-for-root "/tmp/foo/") "*crush:foo*"))))

(ert-deftest crush-test/buffer-name-root-slash-fallback ()
  "The root \"/\" has no basename and should get a fallback name."
  (should (string= (crush--buffer-name-for-root "/") "*crush:root*")))

(ert-deftest crush-test/buffer-name-three-way-collision ()
  "Three roots with the same basename should be suffixed 2 and 3."
  (let ((crush--root-buffer-alist nil))
    (should (string= (crush--buffer-name-for-root "/a/foo/") "*crush:foo*"))
    (should (string= (crush--buffer-name-for-root "/b/foo/") "*crush:foo(2)*"))
    (should (string= (crush--buffer-name-for-root "/c/foo/") "*crush:foo(3)*"))))

(ert-deftest crush-test/buffer-name-fresh-registry-registers-root ()
  "Resolving a root should register it in `crush--root-buffer-alist'."
  (let ((crush--root-buffer-alist nil))
    (crush--buffer-name-for-root "/tmp/x/foo/")
    (should (assoc "/tmp/x/foo/" crush--root-buffer-alist))
    (should (equal (alist-get "/tmp/x/foo/" crush--root-buffer-alist nil nil #'equal)
                   "*crush:foo*"))))



;;; 33. Conversation history extraction: tagged regions -> turns

;;; These tests pin the contract of the facade's history extraction:
;;; `crush--history-turns' reads the buffer's tagged regions (prompt
;;; markers, user input, responses, reasoning) and produces the (ROLE
;;; . TEXT) conversation that the hyper backend re-sends.  Role tags
;;; (`crush-role') are applied by `crush--insert-prompt' /
;;; `crush--after-change' (user) and `crush--tag-response-region'
;;; (assistant/reasoning); the turns builder groups the buffer by
;;; prompt so the pending prompt is never included.

(defun crush-test--seed-exchange (prompt-text reply-text)
  "In the current crush buffer, type PROMPT-TEXT and simulate a
completed exchange: response region REPLY-TEXT tagged as the turn's
answer, then a fresh pending prompt marker.  Returns the completed
prompt's ID."
  (let ((prompt-id crush--prompt-id))
    (goto-char (point-max))
    (insert prompt-text)
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (insert reply-text)
      (crush--tag-response-region response-start (point) prompt-id))
    (goto-char (point-max))
    (newline)
    (setq-local crush--prompt-id (crush--generate-id))
    (crush--insert-prompt)
    prompt-id))

(ert-deftest crush-test/history-turns-nil-when-only-one-prompt ()
  "With a single (pending) prompt there is no history to extract."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null (crush--history-turns crush--prompt-id)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-excludes-pending-prompt ()
  "The pending (current) prompt is being sent; it must not appear in
the returned turns."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((completed-id (crush-test--seed-exchange "first prompt" "first reply")))
            (should (= (length (crush--history-turns crush--prompt-id)) 2))
            (should (equal (car (crush--history-turns crush--prompt-id))
                           (cons 'user "first prompt"))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-includes-multiple-exchanges ()
  "Two completed exchanges both appear, oldest first."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first prompt" "first reply"))
                (id2 (crush-test--seed-exchange "second prompt" "second reply")))
            (let ((turns (crush--history-turns crush--prompt-id)))
              (should (= (length turns) 4))
              (should (equal (nth 0 turns) (cons 'user "first prompt")))
              (should (equal (nth 1 turns) (cons 'assistant "first reply")))
              (should (equal (nth 2 turns) (cons 'user "second prompt")))
              (should (equal (nth 3 turns) (cons 'assistant "second reply")))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-omits-unanswered-attachment-text ()
  "An unanswered prompt contributes its user text but no assistant turn."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first prompt" "first reply")))
            (goto-char (point-max))
            (insert "second prompt")
            (let ((turns (crush--history-turns crush--prompt-id)))
              (ignore id1)
              (should (= (length turns) 2))
              (should (equal (car turns) (cons 'user "first prompt")))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-user-text-skips-response-region ()
  "The user turn must not leak the assistant reply text itself
(responses share the `crush-prompt-id' tag)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((completed-id (crush-test--seed-exchange "hello" "answer text")))
            (let ((turns (crush--history-turns crush--prompt-id)))
              (ignore completed-id)
              (should (equal (car turns) (cons 'user "hello")))
              (should (equal (cadr turns) (cons 'assistant "answer text")))))))
    (crush-test--cleanup)))

;; Helper: seed an exchange whose response carries a reasoning span.
(defun crush-test--seed-reasoning-exchange (prompt-text reasoning-text answer-text)
  "Type PROMPT-TEXT; stream REASONING-TEXT then ANSWER-TEXT as one
response, tagged as the streaming machinery tags it (reasoning span
over the CoT, response for the answer).  Returns the prompt ID."
  (let ((prompt-id crush--prompt-id))
    (goto-char (point-max))
    (insert prompt-text)
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (insert reasoning-text "\n\n" answer-text)
      ;; Tag the whole response, then re-tag the CoT span as reasoning.
      (crush--tag-response-region response-start (point) prompt-id)
      (let ((inhibit-read-only t)
            (rs (+ response-start (length reasoning-text))))
        (put-text-property response-start rs 'crush-region-type 'reasoning)))
    (goto-char (point-max))
    (newline)
    (setq-local crush--prompt-id (crush--generate-id))
    (crush--insert-prompt)
    prompt-id))

(ert-deftest crush-test/history-turns-excludes-reasoning-by-default ()
  "By default (`crush-hyper-history-include-reasoning' nil) the
assistant turn carries only the answer text; the CoT span is dropped."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-reasoning-exchange
                     "question" "step one\nstep two" "final answer")))
            (ignore id)
            (let ((turns (crush--history-turns crush--prompt-id)))
              (should (= (length turns) 2))
              (should (equal (car turns) (cons 'user "question")))
              (should (equal (cadr turns) (cons 'assistant "final answer")))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-splits-reasoning-when-enabled ()
  "With `crush-hyper-history-include-reasoning' t, the assistant turn
is followed by a `reasoning' record carrying the CoT text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (crush-hyper-history-include-reasoning t))
        (with-current-buffer buf
          (let ((id (crush-test--seed-reasoning-exchange
                     "question" "step one\nstep two" "final answer")))
            (ignore id)
            (let ((turns (crush--history-turns crush--prompt-id)))
              (should (= (length turns) 3))
              (should (equal (car turns) (cons 'user "question")))
              (should (equal (cadr turns) (cons 'assistant "final answer")))
              (should (equal (caddr turns)
                             (cons 'reasoning "step one\nstep two")))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-limit-caps-turns ()
  "`crush-hyper-history-limit' caps the prior exchanges; the tail stays."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (crush-hyper-history-limit 1))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first" "one")))
            (ignore id1)
            (let ((id2 (crush-test--seed-exchange "second" "two")))
              (ignore id2)
              (let ((turns (crush--history-turns crush--prompt-id)))
                (should (= (length turns) 2))
                (should (equal (car turns) (cons 'user "second")))
                (should (equal (cadr turns) (cons 'assistant "two")))))))
    (crush-test--cleanup))))

(ert-deftest crush-test/history-limit-zero-disables ()
  "`crush-hyper-history-limit' 0 means no history at all."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (crush-hyper-history-limit 0))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first" "one")))
            (ignore id1)
            (should (null (crush--history-turns crush--prompt-id)))))
    (crush-test--cleanup))))

(ert-deftest crush-test/history-turns-always-fresh ()
  "Extraction reads the live buffer; no cache can go stale."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first" "reply")))
            (let ((turns (crush--history-turns crush--prompt-id)))
              (should (equal turns
                             '((user . "first") (assistant . "reply")))))
            ;; Editing a completed region is reflected immediately.
            (let ((inhibit-read-only t)
                  (rs (text-property-any (point-min) (point-max)
                                         'crush-response-to id1)))
              (delete-region rs (1+ rs)))
            (should-not (equal (crush--history-turns crush--prompt-id)
                               '((user . "first") (assistant . "reply")))))
    (crush-test--cleanup)))))

(provide 'crush-test-buffer)
;;; crush-test-buffer.el ends here
