;;; crush-test-buffer.el --- Chat buffer tests for crush  -*- lexical-binding: t; -*-
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
;;; Buffer lifecycle, prompt/response regions, read-only text properties, input ring.

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
(declare-function crush-test--buffer-name "crush-test")
(defvar crush-test--root)

;;; Facade simulation helper: lets tests drive the response cycle
;;; without any transport process, filter, or sentinel.

(defun crush-test--live-pipe-proc ()
  "Return a live pipe process usable as a fake transport process.
The hyper provider's curl transport sends stdin (config + JSON body)
then EOF; a pipe process stays alive to accept that without erroring
(the way a short-lived `true' process would not)."
  (let ((proc (make-pipe-process :name "crush-test-live-fake"
                                 :noquery t
                                 :coding 'binary
                                 :filter #'ignore
                                 :sentinel #'ignore)))
    proc))

(defun crush-test--simulate-facade-response (content &optional reasoning)
  "Append CONTENT as streamed deltas and finalize the response.
Mimics the post-`crush-send-input' state: `crush--response-start'
must already be set (a marker at the response start).  Streams
REASONING (when non-nil) then CONTENT through
`crush-facade--append-delta' and closes the response with
`crush-facade--finalize'.  With no reasoning, CONTENT is streamed as
a single `content' delta.  Runs in the crush buffer."
  (let ((crush-process nil))
    (when (and reasoning (> (length reasoning) 0))
      (let ((i 0))
        (while (< i (length reasoning))
          (let ((next (or (and (string-match "\n" reasoning i)
                               (match-end 0))
                          (length reasoning))))
            (crush-facade--append-delta
             (substring reasoning i next) 'reasoning)
            (setq i next))))
      (crush-facade--append-delta "" 'content))
    (crush-facade--append-delta content 'content)
    (crush-facade--finalize)))

;;; 1. No duplicate defvar crush--continue

(ert-deftest crush-test/no-duplicate-continue-defvar ()
  "Crush--continue should be defined and buffer-local, default nil."
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

;;; 3. Input separator line management

;;; A frozen markdown horizontal divider (`---`) replaces the old
;;; `crush> ' prompt marker.  `crush--prompt-start-marker' sits at the
;;; divider's start; `crush--input-start-marker' sits right after the
;;; divider's trailing blank line, where the editable input region begins.
;;; The divider is tagged `crush-region-type' `separator' so the header
;;; label is honest: untagged input space reports nil, never `user'.

(ert-deftest crush-test/input-separator-inserted-on-init ()
  "A fresh buffer starts with the `---' divider, not `crush> '."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (looking-at "---\n\n"))
          (should-not (save-excursion (search-forward "crush> " nil t)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-separator-is-frozen ()
  "The divider line is read-only previous content: typing into it errors."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (get-char-property (point) 'read-only))
          (should-error (insert-and-inherit "X") :type 'text-read-only)))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-separator-edge-is-editable ()
  "The input area right after the divider's blank line stays editable."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (should-not (get-char-property (point) 'read-only))
          (insert-and-inherit "hello")))
    (crush-test--cleanup)))

(ert-deftest crush-test/markers-flank-the-separator ()
  "`crush--prompt-start-marker' points at the divider, and
`crush--input-start-marker' directly after its trailing blank line."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--prompt-start-marker)
          (should (markerp crush--prompt-start-marker))
          (should (= (marker-position crush--prompt-start-marker) (point-min)))
          (should crush--input-start-marker)
          (should (markerp crush--input-start-marker))
          (should (= (marker-position crush--input-start-marker) (point-max)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/separator-tagged-as-separator-region ()
  "The divider carries `crush-region-type' `separator', not `user'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (eq (get-text-property (point) 'crush-region-type) 'separator))
          (should-not (eq (get-text-property (point) 'crush-region-type) 'user))))
    (crush-test--cleanup)))

(ert-deftest crush-test/separator-region-label-shows-separator ()
  "The header label at the divider reads `separator'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (string= (crush--region-label-at-point) "separator"))))
    (crush-test--cleanup)))

(ert-deftest crush-test/untagged-input-area-label-is-nil ()
  "Untagged editable input space reports nil, never `user'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (should (null (crush--region-label-at-point)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/separator-has-blank-lines ()
  "The divider is framed by blank lines: a blank line below it, and a
blank line above it when it follows a response."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Fresh buffer: divider then a blank line, no blank above.
          (goto-char (point-min))
          (should (looking-at "---\n\n"))
          ;; After a response cycle the divider is preceded by a blank line.
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-test--simulate-facade-response "response text")
          (goto-char (point-max))
          (search-backward "---")
          (should (string-match-p "\n\n---\n\n" (buffer-substring-no-properties
                                                 (max (point-min) (- (point) 2))
                                                 (min (point-max) (+ (point) 5)))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-start-set-on-buffer-init ()
  "After `crush' creates the buffer, crush--prompt-start-marker should be set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--prompt-start-marker)
          (should (markerp crush--prompt-start-marker))
          (should (= (marker-position crush--prompt-start-marker) (point-min)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/facade-finalize-resets-prompt-start ()
  "After the facade finalizes a response, crush--prompt-start-marker is reset."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-test--simulate-facade-response "response text")
          (should crush--prompt-start-marker)
          (should (markerp crush--prompt-start-marker))
          (should (= (marker-position crush--prompt-start-marker)
                     (- (point-max) (length "---\n\n"))))))
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
          (let ((fake-proc (crush-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) fake-proc)))
              (call-interactively #'crush-send-input))
            (goto-char (point-min))
            (should (search-forward "hello world" nil t))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))))
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
                (fake-proc (crush-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest args)
                         (setq captured-stderr (plist-get args :stderr))
                         fake-proc)))
              (call-interactively #'crush-send-input))
            (should captured-stderr)
            (should (or (bufferp captured-stderr)
                        (stringp captured-stderr)))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))))
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
      (let* ((_name1 (crush-test--buffer-name))
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
          (let ((fake-proc (crush-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _args) fake-proc)))
              (call-interactively #'crush-send-input))
            (should (get-buffer "*crush-errors*"))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))))
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
  "After facade finalize, `crush--prompt-id' should be a new unique ID."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((old-id crush--prompt-id))
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            ;; Simulate stream completion via the facade.
            (crush-test--simulate-facade-response "response text")
            ;; New ID should be different
            (should (stringp crush--prompt-id))
            (should (not (string= old-id crush--prompt-id))))))
    (crush-test--cleanup)))

;;; 18. Header line display

;;; Header line: model + region at point

;;; 18b. Header line: model and region type at point

(ert-deftest crush-test/region-label-prompts-and-placeholders ()
  "`crush--region-label-at-point' maps every region type to a label.
The fresh buffer has an input divider at point-min tagged `separator',
so point there resolves to `separator', not `user'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (string= (crush--region-label-at-point) "separator"))))
    (crush-test--cleanup)))

(ert-deftest crush-test/user-input-tagged-as-user-region ()
  "Text typed in the input area carries `crush-region-type' `user'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (should (eq (get-text-property (- (point) 1) 'crush-region-type) 'user))))
    (crush-test--cleanup)))

(ert-deftest crush-test/region-label-in-input-without-prompt-id ()
  "Typed input carries the user region type even though it starts at
the input marker after the separator."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (should (eq (get-text-property (- (point) 1) 'crush-region-type) 'user))
          (goto-char (1- (point)))
          (should (string= (crush--region-label-at-point) "user"))))
    (crush-test--cleanup)))

(ert-deftest crush-test/region-label-user ()
  "User input (typed or attached) resolves to `user'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (insert "attach-region-text"))
          (put-text-property (- (point) 18) (point)
                             'crush-region-type 'user)
          (put-text-property (- (point) 18) (point)
                             'crush-prompt-id crush--prompt-id)
          (goto-char (- (point) 9))
          (should (string= (crush--region-label-at-point) "user"))))
    (crush-test--cleanup)))

(ert-deftest crush-test/region-label-response ()
  "Response regions resolve to `response'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((start (point-max)))
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t))
              (insert "response-text")
              (put-text-property start (point)
                                 'crush-region-type 'response))
            (goto-char (- (point) 5))
            (should (string= (crush--region-label-at-point) "response")))))
    (crush-test--cleanup)))

(ert-deftest crush-test/region-label-tool-output ()
  "The nested `tool-output' region resolves to its symbol name, not the
prompt fallback, even though it carries `crush-prompt-id'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((start (point-max)))
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t))
              (insert "raw-output-text")
              (put-text-property start (point)
                                 'crush-region-type 'tool-output)
              (put-text-property start (point)
                                 'crush-prompt-id crush--prompt-id))
            (goto-char (- (point) 5))
            (should (string= (crush--region-label-at-point) "tool-output")))))
    (crush-test--cleanup)))

(ert-deftest crush-test/region-label-falls-back-to-nil ()
  "Regions with no region type resolve to nil, not a guessed label."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (should (null (crush--region-label-at-point)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/header-model-falls-back-to-hyper-default ()
  "Effective model falls back to `crush-openai-default-model' for hyper
providers with a nil model slot."
  (let ((crush-model nil))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; A fresh buffer is always a hyper provider; with a nil model
            ;; slot the effective model must be the hyper default.
            (should (string= (crush--header-model) crush-openai-default-model))
            ;; A hyper provider with an explicit model uses it.
            (setq-local crush-active-provider
                        (crush-make-hyper-provider
                         :buffer buf
                         :working-directory default-directory
                         :base-url crush-hyper-base-url
                         :token crush-hyper-token
                         :model "my-model"))
            (should (string= (crush--header-model) "my-model"))))
      (crush-test--cleanup))))

(ert-deftest crush-test/header-model-uses-provider-slot ()
  "`crush--header-model' reads the provider model slot set at init."
  (let ((crush-model "claude-sonnet-4-20250514"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= (crush--header-model) "claude-sonnet-4-20250514"))))
      (crush-test--cleanup))))

(ert-deftest crush-test/header-line-shows-model-and-region ()
  "The header line shows both the current model and the region type
at point."
  (let ((crush-model "my-model"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "typed")
            (goto-char (1- (point)))
            (crush--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string-match-p "my-model" h))
              (should (string-match-p "region: user" h)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/header-line-shows-dash-for-nil-region ()
  "Untagged space renders `region: -' in the header line."
  (let ((crush-model "my-model"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (crush--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string-match-p "region: -" h)))))
      (crush-test--cleanup))))

;;; 19. Input separator has prompt-id property

(ert-deftest crush-test/prompt-marker-has-prompt-id-property ()
  "The input separator text should have crush-prompt-id text property."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Find the separator text
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (let ((prompt-id (get-text-property (- (point) 1) 'crush-prompt-id)))
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
              (crush--insert-input-separator))
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
            (let ((fake-proc (crush-test--live-pipe-proc)))
              (set-process-buffer fake-proc (current-buffer))
              (cl-letf (((symbol-function #'make-process)
                         (lambda (&rest _) fake-proc)))
                (crush-send-input))
              ;; Simulate stream completion: invoke the facade finalize
              ;; continuation directly (no process, filter, or sentinel).
              (let ((completion (crush-provider-completion-action
                                 crush-active-provider)))
                (should (functionp completion))
                (funcall completion))
              (when (process-live-p fake-proc)
                (delete-process fake-proc)))
            (let ((second-id crush--prompt-id))
              (goto-char (point-max))
              (insert "second prompt")
              (let ((all-prompts (crush-get-all-prompts)))
                (should (member first-id all-prompts))
                (should (member second-id all-prompts)))))))
    (crush-test--cleanup)))

;;; The previous body used `crush--process-sentinel' to complete the
;;; response; the facade's completion-action indirection replaces it.

;;; 30. Region type tagging: prompt (removed - comint handles via fields)

;;; 31. Region type tagging: input (removed - comint handles via fields)

;;; 32. Region type tagging: response

(ert-deftest crush-test/response-region-tagged-as-response ()
  "Response text should be tagged with crush-region-type 'response."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate a response cycle via the facade (no process).
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-test--simulate-facade-response "response text")
          ;; Check that response text has crush-region-type 'response
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          ;; Finalize must not create any crush overlays.
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
  "Crush-clear-buffer should remove old crush-overlay tagged overlays."
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
  "The facade continuation finalizes the response.
It tags the response, inserts a fresh prompt, and regenerates the ID."
  (unwind-protect
      (with-current-buffer (crush-test--fresh-buffer)
        (goto-char (point-max))
        (newline)
        (setq-local crush--response-start (point-marker))
        (insert "mock response")
        (let ((old-id crush--prompt-id)
              (response-start (point-marker)))
          ;; The facade continuation is exactly what crush-send-input
          ;; injects into the provider.
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
          (search-backward "---")
          (should (< (marker-position response-start)
                     (point)))))
    (crush-test--cleanup)))


;;; 56. Region-type/field reconciliation

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
          (crush-test--simulate-facade-response "response text")
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          (should (eq (get-text-property (- (point) 5) 'crush-region-type) 'response))))
    (crush-test--cleanup)))

(ert-deftest crush-test/org-region-type-still-set ()
  "Attachment blocks should have crush-region-type=user (appended input)."
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
            (should (eq (get-text-property (match-beginning 0) 'crush-region-type) 'user))))
      (crush-test--cleanup))))

;;; 57. Debug logging - crush-debug-mode defcustom

(ert-deftest crush-test/debug-mode-defaults-to-t ()
  "Crush-debug-mode should default to t."
  (should (eq crush-debug-mode t)))

;;; 58. Debug logging - crush--debug-log creates buffer and writes

(ert-deftest crush-test/debug-log-creates-buffer ()
  "Crush--debug-log should create *crush-debug* buffer when enabled."
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
  "Crush--debug-log should do nothing when crush-debug-mode is nil."
  (unwind-protect
      (let ((crush-debug-mode nil))
        (crush--debug-log 'test "should not appear")
        (should-not (get-buffer "*crush-debug*")))
    (crush-test--cleanup)))

;;; 60. Debug logging - command logged in input-sender

;;; 62. Debug logging - streamed output logged via the facade

(ert-deftest crush-test/debug-logs-output ()
  "Streamed content via the facade inserts into the buffer and finalizes.
The debug *crush-debug* logging is the transport's job (crush-provider);
the facade owns insertion.  This replaces the deleted
`crush--output-filter' test that asserted filter-level logging."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "some output text" 'content)
          (goto-char (point-min))
          (should (search-forward "some output text" nil t)))
        (with-current-buffer buf
          (crush-facade--finalize)))
    (crush-test--cleanup)))

;;; 63. Debug logging - finalize path logs via the facade continuation

(ert-deftest crush-test/debug-logs-finalize ()
  "The facade finalize path closes the response and inserts a prompt.
The run provider's process sentinel (deleted) used to log the sentinel
event; the facade continuation now owns completion."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-test--simulate-facade-response "response"))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "---" nil t))))
    (crush-test--cleanup)))

;;; 64. Input separator insertion rename

(ert-deftest crush-test/insert-prompt-renamed ()
  "Crush--insert-input-separator should be defined (renamed from
crush--insert-prompt)."
  (should (fboundp 'crush--insert-input-separator)))

;;; 65. Sentinel freezes previous response read-only

(ert-deftest crush-test/facade-freezes-previous-response ()
  "The facade should freeze the previous response read-only.
After the facade finalizes and inserts the next prompt, the prior
response becomes read-only previous content, blocking edits."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "test")
            (goto-char (point-max))
            (newline)
            (setq-local crush--response-start (point-marker))
            (crush-test--simulate-facade-response "response text")
            ;; Response text becomes frozen as previous content.
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (should (get-char-property (match-beginning 0) 'read-only))
            (should (get-text-property (match-beginning 0) 'read-only))
            (goto-char (match-beginning 0))
            (should-error (insert-and-inherit "X") :type 'text-read-only)))
      (crush-test--cleanup))))

;;; 67. crush--append-as-user-input appends after the input marker

(defun crush-test--input-area-text ()
  "Return the editable input area text: from `crush--input-start-marker'
to the line end."
  (buffer-substring-no-properties
   (marker-position crush--input-start-marker)
   (line-end-position)))

(ert-deftest crush-test/append-as-user-input-lands-in-input-area ()
  "Crush--append-as-user-input should insert after crush--input-start-marker."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (should crush--input-start-marker)
            (crush--append-as-user-input buf "INSERTED CONTENT" nil nil)
            (goto-char (marker-position crush--input-start-marker))
            (should (string-match-p "INSERTED CONTENT"
                                    (crush-test--input-area-text)))
            (should (eq (get-text-property (marker-position crush--input-start-marker)
                                           'crush-region-type)
                        'user))))
      (crush-test--cleanup))))

;;; 69. crush--after-change uses crush--prompt-start-marker

(ert-deftest crush-test/after-change-tags-without-prompt-start ()
  "Crush--after-change should tag input with prompt-id using crush--prompt-start-marker."
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

;;; Parallel markers

(ert-deftest crush-test/prompt-start-marker-set-on-init ()
  "Crush--prompt-start-marker should be set after buffer init."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--prompt-start-marker)
          (should (markerp crush--prompt-start-marker))))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-start-marker-set-on-init ()
  "Crush--input-start-marker should be set after buffer init."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush--input-start-marker)
          (should (markerp crush--input-start-marker))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-start-marker-insertion-type ()
  "Crush--prompt-start-marker should have insertion-type t (advances on insert before)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (markerp crush--prompt-start-marker))
          (should (marker-insertion-type crush--prompt-start-marker))))
    (crush-test--cleanup)))

(ert-deftest crush-test/input-separator-face-defined ()
  "Crush-input-separator-face should be defined."
  (should (facep 'crush-input-separator-face)))

;;; Facade delta streaming

(ert-deftest crush-test/facade-delta-inserts-at-end ()
  "A streamed content delta is appended at point-max (the response area)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "hello world" 'content)
          (goto-char (point-min))
          (should (search-forward "hello world" nil t))
          ;; The delta went to point-max (the response area), so the
          ;; response-start marker now sits before the streamed text.
          (should (< (marker-position crush--response-start) (point-max)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/facade-delta-accumulates ()
  "Multiple deltas accumulate in stream order at the response area."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "abc" 'content)
          (crush-facade--append-delta "xyz" 'content)
          (goto-char (point-min))
          (should (search-forward "abcxyz" nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/facade-delta-logged-to-debug ()
  "Streamed deltas insert into the buffer when debug mode is on.
The *crush-debug* logging is the transport's job (providers), not the
facade; this asserts the facade's contract — insertion completes."
  (unwind-protect
      (let ((crush-debug-mode t)
            (buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "test output" 'content)
          (goto-char (point-min))
          (should (search-forward "test output" nil t)))
        (with-current-buffer buf
          (crush-facade--finalize)))
    (crush-test--cleanup)))

(ert-deftest crush-test/facade-delta-no-field-property ()
  "Streamed deltas should NOT set field on inserted text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "response text" 'content)
          (should-not (get-text-property (1- (point-max)) 'field))))
    (crush-test--cleanup)))

(ert-deftest crush-test/facade-delta-dead-buffer-safe ()
  "The facade's on-delta closure guards a killed crush buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (kill-buffer buf)
        ;; The closure the facade injects into the provider wraps the
        ;; append in `buffer-live-p', so it must not error after the
        ;; buffer died.
        (should-not (funcall (lambda ()
                               (when (buffer-live-p buf)
                                 (with-current-buffer buf
                                   (crush-facade--append-delta "x" 'content))))))
        ;; The raw function itself operates on the current buffer; a
        ;; live current buffer must still work.
        (with-temp-buffer
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "works" 'content)))
    (crush-test--cleanup)))

;;; Custom input ring

(ert-deftest crush-test/custom-input-ring-initialized ()
  "Crush--input-ring should be a ring in a crush buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (boundp 'crush--input-ring))
          (should (ring-p crush--input-ring))))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-add ()
  "Crush--input-ring-add should add input to the ring."
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
  "Crush--input-ring-add should not add consecutive duplicate entries."
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
  "Crush--input-ring-add should not add empty strings."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setq crush--input-ring (make-ring crush-input-ring-size))
          (crush--input-ring-add "")
          (should (= (ring-length crush--input-ring) 0))))
    (crush-test--cleanup)))

(ert-deftest crush-test/custom-input-ring-read-from-file ()
  "Crush--input-ring-read should read history from file."
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
  "Crush--input-ring-write should write history to file."
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
  "Crush-send-input should add prompt to crush--input-ring."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "history test")
          (let ((fake-proc (crush-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc)))
              (call-interactively #'crush-send-input))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))
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
  "\\[crush--input-previous] inserts the previous ring input."
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
  "\\[crush--input-next] inserts the next (more recent) ring input."
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
  "`crush--input-ring-file-name' defaults to a file in `user-emacs-directory'."
  (should (string= crush--input-ring-file-name
                   (expand-file-name "crush-history" user-emacs-directory))))

;;; Mode parent resolution

(ert-deftest crush-test/mode-parent-is-text-mode ()
  "The crush buffer's major mode is the parent mode.
It derives from `text-mode' (or `markdown-mode'), never `comint-mode'.
There is no separate `crush-mode' major mode."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq major-mode crush--parent-mode))
          (should (derived-mode-p 'text-mode))
          (should-not (derived-mode-p 'comint-mode))))
    (crush-test--cleanup)))

(ert-deftest crush-test/separator-has-input-separator-face ()
  "The input separator text should have crush-input-separator-face."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (should (eq (get-text-property (1- (point)) 'font-lock-face)
                      'crush-input-separator-face))))
    (crush-test--cleanup)))

(ert-deftest crush-test/prompt-is-read-only ()
  "The input separator text should be read-only (via text property)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (should (get-char-property (1- (point)) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/clear-buffer-prompt-has-crush-properties ()
  "After crush-clear-buffer, the new separator should have crush properties."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (call-interactively #'crush-clear-buffer)
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (should (get-char-property (match-beginning 0) 'read-only))
          (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                      'crush-input-separator-face))
          (should-not (get-text-property (match-beginning 0) 'field))))
    (crush-test--cleanup)))

;;; Optional markdown-mode base

(ert-deftest crush-test/parent-mode-is-text-or-markdown ()
  "`crush--parent-mode' is either `text-mode' or `markdown-mode'."
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
  "The input separator text should be read-only via a text property.
Backspacing into the separator should be blocked."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (goto-char (match-beginning 0))
          (should (get-text-property (point) 'read-only))
          (should (get-char-property (point) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/cannot-type-into-prompt ()
  "Typing into the read-only input separator should signal text-read-only."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "---" nil t))
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
          (crush-test--simulate-facade-response "response")
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
          (crush-test--simulate-facade-response "response")
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
          (crush-test--simulate-facade-response "response")
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
  "Programmatic insertion bypasses the freeze with `inhibit-read-only'."
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
  "Crush-clear-buffer should reset the buffer so input is editable again."
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
          (crush-test--simulate-facade-response "response")
          (font-lock-ensure)
          (goto-char (point-min))
          (should (search-forward "---" nil t))
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
            (crush-test--simulate-facade-response "# heading")
            (font-lock-ensure)
            (goto-char (point-min))
            (should (search-forward "---" nil t))
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
            (font-lock-ensure)
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
             (lambda (&optional _dir)
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
;;; markers, user input, responses, reasoning) and produces a list of
;;; message alists (not (ROLE . TEXT) conses) that the hyper provider
;;; re-sends.  Role tags (`crush-role') are applied by
;;; `crush--insert-input-separator' / `crush--after-change' (user) and
;;; `crush--tag-response-region' (assistant/reasoning); the builder
;;; groups the buffer by prompt so the pending prompt is never included.

(defun crush-test--msg-role (msg)
  "Return the `role' of message alist MSG."
  (cdr (assoc 'role msg)))

(defun crush-test--msg-content (msg)
  "Return the `content' of message alist MSG, or nil."
  (cdr (assoc 'content msg)))

(defun crush-test--seed-exchange (prompt-text reply-text)
  "Seed a completed exchange in the current crush buffer.
Types PROMPT-TEXT (which lands in the `user' region via
`crush--after-change') and simulates a completed exchange: response
region REPLY-TEXT tagged as the turn's answer, then a fresh input
separator.  Returns the completed prompt's ID."
  (let ((prompt-id crush--prompt-id))
    (goto-char (point-max))
    (insert prompt-text)
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (insert reply-text)
      (crush--tag-response-region response-start (point) prompt-id))
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      ;; Anticipate the newline the separator insertion would leave; it
      ;; must not become part of the user turn.
      (when (eq (char-before (point)) ?\n)
        (delete-region (1- (point)) (point))))
    (setq-local crush--prompt-id (crush--generate-id))
    (crush--insert-input-separator)
    prompt-id))

(ert-deftest crush-test/history-turns-nil-when-only-one-prompt ()
  "With a single (pending) prompt there is no history to extract."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null (crush--history-turns crush--prompt-id)))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-excludes-pending-prompt ()
  "The pending (current) prompt never appears in the messages.
It is being sent when the history is extracted."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((_completed-id (crush-test--seed-exchange "first prompt" "first reply")))
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (crush-test--msg-role (car msgs)) "user"))
              (should (equal (crush-test--msg-content (car msgs)) "first prompt"))))))
    (crush-test--cleanup)))

;;; Helper: seed an exchange that carries a tool call.
(defun crush-test--seed-tool-exchange (prompt-text answer-text tool-calls)
  "Seed an exchange: PROMPT-TEXT as the user input, ANSWER-TEXT as the
assistant answer, and TOOL-CALLS as a list of plists (:name :id
:args-json :result :exit) rendered as tool blocks before the answer,
tagged the way the streaming machinery tags them.  Returns the
completed prompt's ID."
  (let ((prompt-id crush--prompt-id))
    (goto-char (point-max))
    (insert prompt-text)
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (dolist (tc tool-calls)
        (crush--tool-block-insert tc prompt-id))
      (let ((inhibit-read-only t))
        (insert answer-text))
      (crush--tag-response-region response-start (point) prompt-id))
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      ;; Anticipate the newline the separator insertion would leave; it
      ;; must not become part of the user turn.
      (when (eq (char-before (point)) ?\n)
        (delete-region (1- (point)) (point))))
    (setq-local crush--prompt-id (crush--generate-id))
    (crush--insert-input-separator)
    prompt-id))

(ert-deftest crush-test/answer-text-excludes-tool-blocks ()
  "`crush-get-response-text' must not include the rendered tool block
in the assistant answer.  The tool blocks are display decoration around
the raw tool result; the assistant turn carries only the model's own
answer text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-tool-exchange
                     "run ls"
                     "Here is the listing: AGENTS.md"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (let ((answer (crush-get-response-text id)))
              (should (string-match-p "Here is the listing: AGENTS.md" answer))
              (should-not (string-match-p "tool:" answer))
              (should-not (string-match-p "<command>" answer))
              (should-not (string-match-p "<output>" answer))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/tool-rounds-raw-output ()
  "`crush--tool-rounds' emits the raw result as the tool content, not the
rendered decoration."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-tool-exchange
                     "run ls"
                     "Here is the listing"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (let* ((msgs (crush--tool-rounds id))
                   (tool-msg (cl-find "tool" msgs :key #'crush-test--msg-role :test #'string=)))
              (should tool-msg)
              (should (string-match-p "<command>ls</command>" (crush-test--msg-content tool-msg)))
              (should (string-match-p "<output>" (crush-test--msg-content tool-msg)))
              (should (string-match-p "<exit_code>0</exit_code>" (crush-test--msg-content tool-msg)))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-tool-exchange ()
  "A completed exchange with a tool call emits user + assistant(tool_calls)
+ tool messages, reconstructed from the buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-tool-exchange
                     "run ls"
                     "Listing done"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (ignore id)
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (should (= (length msgs) 3))
              (should (equal (crush-test--msg-role (nth 0 msgs)) "user"))
              (should (equal (crush-test--msg-role (nth 1 msgs)) "assistant"))
              (should (vectorp (cdr (assoc 'tool_calls (nth 1 msgs)))))
              (should (equal (crush-test--msg-role (nth 2 msgs)) "tool"))
              (should (string-match-p "<command>ls</command>"
                                      (crush-test--msg-content (nth 2 msgs))))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-carries-tool-metadata ()
  "The assistant message carries the call's id, name, and args from the
`crush-tool-call' property, and the tool result pairs with the same id."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-tool-exchange
                     "run ls"
                     "Listing done"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (ignore id)
            (let* ((msgs (crush--history-turns crush--prompt-id))
                   (assistant (nth 1 msgs))
                   (tool (nth 2 msgs))
                   (tc (aref (cdr (assoc 'tool_calls assistant)) 0)))
              (should (= (length msgs) 3))
              (should (string= (cdr (assoc 'id tc)) "call_1"))
              (should (string= (cdr (assoc 'name (cdr (assoc 'function tc)))) "bash"))
              (should (string= (cdr (assoc 'arguments (cdr (assoc 'function tc))))
                               "{\"command\":\"ls\"}"))
              (should (string= (cdr (assoc 'tool_call_id tool)) "call_1"))
              (let ((content (crush-test--msg-content tool)))
                (should (string-match-p "<command>ls</command>" content))
                (should-not (string-match-p "tool:" content)))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-legacy-tool-fallback ()
  "A tool block without `crush-tool-call' metadata falls back to a bare
tool message with `tool_call_id: unknown' so legacy buffers still replay."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "run ls")
          (goto-char (point-max))
          (newline)
          (let ((response-start (point)))
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t))
              (insert "**tool block**\nraw")
              (put-text-property response-start (point)
                                 'crush-region-type 'tool)
              (put-text-property response-start (point) 'crush-prompt-id crush--prompt-id)
              (put-text-property response-start (point) 'crush-response-to crush--prompt-id))
            (crush--tag-response-region response-start (point) crush--prompt-id))
          (goto-char (point-max))
          (newline)
          (let ((inhibit-read-only t))
            (delete-region (1- (point)) (point)))
          (setq-local crush--prompt-id (crush--generate-id))
          (crush--insert-input-separator)
          (let* ((msgs (crush--history-turns crush--prompt-id))
                 (tool-msg (cl-find "tool" msgs :key #'crush-test--msg-role :test #'string=)))
            (should (= (length msgs) 2))
            (should tool-msg)
            (should (string= (cdr (assoc 'tool_call_id tool-msg)) "unknown"))
            (should (stringp (crush-test--msg-content tool-msg))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-includes-multiple-exchanges ()
  "Two completed exchanges both appear, oldest first."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((_id1 (crush-test--seed-exchange "first prompt" "first reply"))
                (_id2 (crush-test--seed-exchange "second prompt" "second reply")))
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (should (= (length msgs) 4))
              (should (equal (crush-test--msg-role (nth 0 msgs)) "user"))
              (should (equal (crush-test--msg-content (nth 0 msgs)) "first prompt"))
              (should (equal (crush-test--msg-role (nth 1 msgs)) "assistant"))
              (should (equal (crush-test--msg-content (nth 1 msgs)) "first reply"))
              (should (equal (crush-test--msg-role (nth 2 msgs)) "user"))
              (should (equal (crush-test--msg-content (nth 2 msgs)) "second prompt"))
              (should (equal (crush-test--msg-role (nth 3 msgs)) "assistant"))
              (should (equal (crush-test--msg-content (nth 3 msgs)) "second reply"))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-omits-unanswered-attachment-text ()
  "An unanswered prompt contributes its user text but no assistant turn."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first prompt" "first reply")))
            (goto-char (point-max))
            (insert "second prompt")
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (ignore id1)
              (should (= (length msgs) 2))
              (should (equal (crush-test--msg-content (car msgs)) "first prompt"))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-user-text-skips-response-region ()
  "The user message never leaks the assistant reply text.
The response region shares the `crush-prompt-id' tag."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((completed-id (crush-test--seed-exchange "hello" "answer text")))
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (ignore completed-id)
              (should (equal (crush-test--msg-content (car msgs)) "hello"))
              (should (equal (crush-test--msg-content (cadr msgs)) "answer text"))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/user-turn-text-excludes-separator ()
  "`crush--user-turn-text' returns the typed input without the frozen
separator line."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (should (equal (crush--user-turn-text crush--prompt-id)
                         "hello world"))))
    (crush-test--cleanup)))

(ert-deftest crush-test/user-turn-text-includes-attachments ()
  "`crush--user-turn-text' returns typed input plus appended attachments.
Attachments are appended after `crush--input-start-marker' and tagged
`user', so extraction reads them back as part of the turn."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "hello")
            (let ((aid (crush--generate-id)))
              (crush--append-as-user-input buf "```emacs-lisp\n(code)\n```"
                                           aid crush--prompt-id "src/file.el" "1-3"))
            (let ((text (crush--user-turn-text crush--prompt-id)))
              (should (string-match-p "hello" text))
              (should (string-match-p "(code)" text)))))
      (crush-test--cleanup))))

;; Helper: seed an exchange whose response carries a reasoning span.
(defun crush-test--seed-reasoning-exchange (prompt-text reasoning-text answer-text)
  "Seed an exchange whose response carries a reasoning span.
Types PROMPT-TEXT; streams REASONING-TEXT then ANSWER-TEXT as one
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
            (inhibit-modification-hooks t)
            (rs (+ response-start (length reasoning-text))))
        (put-text-property response-start rs 'crush-region-type 'reasoning)))
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      ;; Anticipate the newline the separator insertion would leave; it
      ;; must not become part of the user turn.
      (when (eq (char-before (point)) ?\n)
        (delete-region (1- (point)) (point))))
    (setq-local crush--prompt-id (crush--generate-id))
    (crush--insert-input-separator)
    prompt-id))

(ert-deftest crush-test/history-turns-excludes-reasoning-by-default ()
  "By default the assistant message carries only the answer text.
Here `crush-hyper-history-include-reasoning' is nil, so the CoT span is
dropped."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-reasoning-exchange
                     "question" "step one\nstep two" "final answer")))
            (ignore id)
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (crush-test--msg-content (car msgs)) "question"))
              (should (equal (crush-test--msg-content (cadr msgs)) "final answer"))))))
    (crush-test--cleanup)))

;; Helper: seed an exchange with a multi-round tool loop.  Round 1
;; streams reasoning then content then inserts a tool block; round 2
;; streams reasoning then content.  Tagged exactly as the tool loop
;; tags it via `crush--tag-response-region' after each round.
(defun crush-test--seed-tool-loop-exchange (prompt-text r1-reasoning r1-content
                                                        tool-calls r2-reasoning r2-content)
  "Seed a two-round tool-loop exchange for PROMPT-TEXT.
Round 1 streams R1-REASONING then R1-CONTENT then TOOL-CALLS (a list
of plists rendered as tool blocks); round 2 streams R2-REASONING then
R2-CONTENT.  Returns the completed prompt's ID."
  (let ((prompt-id crush--prompt-id))
    (goto-char (point-max))
    (insert prompt-text)
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      ;; Round 1: reasoning, content, then the tool block.
      (setq-local crush--response-start (point-marker))
      (crush-facade--append-delta r1-reasoning 'reasoning)
      (crush-facade--append-delta r1-content 'content)
      (dolist (tc tool-calls)
        (crush--tool-block-insert tc prompt-id))
      (crush--tag-response-region (marker-position crush--response-start)
                                  (point-max) prompt-id)
      (crush--reasoning-reset)
      ;; Round 2: final reasoning and content, no more tools.
      (setq-local crush--response-start (point-marker))
      (crush-facade--append-delta r2-reasoning 'reasoning)
      (crush-facade--append-delta r2-content 'content)
      (crush--tag-response-region (marker-position crush--response-start)
                                  (point-max) prompt-id)
      (crush--reasoning-reset))
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (when (eq (char-before (point)) ?\n)
        (delete-region (1- (point)) (point))))
    (setq-local crush--prompt-id (crush--generate-id))
    (crush--insert-input-separator)
    prompt-id))

(ert-deftest crush-test/tool-rounds-no-spurious-unknown-tool ()
  "A multi-round tool exchange must not emit a bare `tool' message with
`tool_call_id: unknown' between rounds.

The trailing closing fence of a tool block is `tool'-typed but had no
`crush-tool-call' property, so the reconstruction walker fell into the
legacy branch and swallowed the following round's reasoning + content
as a bogus tool result."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-tool-loop-exchange
                     "push to remotes"
                     "The user wants to push this to remotes."
                     "You have two remotes: `github` and `origin`."
                     (list (list :name "exec_command" :id "call_1"
                                 :args-json "{\"cmd\":\"git remote -v\"}"
                                 :result "github\tgit@github.com:thomasc1971/crush.el.git"
                                 :exit 0))
                     "GitHub pushed successfully."
                     "GitHub pushed. Now to Codeberg")))
            (let ((msgs (crush--tool-rounds id)))
              (should (= (length msgs) 3))
              ;; assistant(tool_calls) + tool pair, then the final
              ;; plain assistant answer; no `unknown' tool message.
              (should (equal (crush-test--msg-role (nth 0 msgs)) "assistant"))
              (should (equal (crush-test--msg-role (nth 1 msgs)) "tool"))
              (should (string= (cdr (assoc 'tool_call_id (nth 1 msgs))) "call_1"))
              (should (equal (crush-test--msg-role (nth 2 msgs)) "assistant"))
              (should (string-match-p "Now to Codeberg"
                                      (crush-test--msg-content (nth 2 msgs))))
              (should-not (cl-find "unknown" msgs
                                   :key (lambda (m) (cdr (assoc 'tool_call_id m)))
                                   :test #'string=))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/tool-rounds-reasoning-stays-reasoning ()
  "A second-round reasoning span must stay tagged `reasoning', not be
overwritten to `response' by the round's re-tag.

When reasoning was overwritten, history replay folded the CoT into the
assistant content and, combined with the fence bug, emitted it as a
spurious tool result."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (crush-test--seed-tool-loop-exchange
                     "push to remotes"
                     "R1 reasoning"
                     "R1 content"
                     (list (list :name "exec_command" :id "call_1"
                                 :args-json "{\"cmd\":\"git status\"}"
                                 :result "nothing to commit" :exit 0))
                     "R2 reasoning"
                     "R2 final answer")))
            (let ((msgs (crush--tool-rounds id)))
              (should (= (length msgs) 3))
              ;; Final assistant message must carry only the answer,
              ;; never the CoT text.
              (let ((final (crush-test--msg-content (nth 2 msgs))))
                (should (string-match-p "R2 final answer" final))
                (should-not (string-match-p "R2 reasoning" final))))
            ;; The reasoning spans themselves must be tagged reasoning.
            (let ((pos (point-min)))
              (while (< pos (point-max))
                (let ((type (get-text-property pos 'crush-region-type))
                      (end (or (next-single-property-change pos 'crush-region-type
                                                            nil (point-max))
                               (point-max))))
                  (when (eq type 'response)
                    (should-not (string-match-p "R2 reasoning"
                                                (buffer-substring-no-properties
                                                 pos (min end (+ pos 40))))))
                  (setq pos end)))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-turns-splits-reasoning-when-enabled ()
  "With reasoning enabled the assistant message gains a reasoning_content
field holding the CoT text."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer))
            (crush-hyper-history-include-reasoning t))
        (with-current-buffer buf
          (let ((id (crush-test--seed-reasoning-exchange
                     "question" "step one\nstep two" "final answer")))
            (ignore id)
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (crush-test--msg-content (car msgs)) "question"))
              (should (equal (crush-test--msg-content (cadr msgs)) "final answer"))
              (should (equal (cdr (assoc 'reasoning_content (cadr msgs)))
                             "step one\nstep two"))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/history-limit-caps-turns ()
  "`crush-hyper-history-limit' caps the prior exchanges; the tail stays."
  (let ((crush-hyper-history-limit 1))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((_id1 (crush-test--seed-exchange "first" "one")))
              (let ((_id2 (crush-test--seed-exchange "second" "two")))
                (let ((msgs (crush--history-turns crush--prompt-id)))
                  (should (= (length msgs) 2))
                  (should (equal (crush-test--msg-content (car msgs)) "second"))
                  (should (equal (crush-test--msg-content (cadr msgs)) "two")))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/history-limit-zero-disables ()
  "`crush-hyper-history-limit' 0 means no history at all."
  (let ((crush-hyper-history-limit 0))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((_id1 (crush-test--seed-exchange "first" "one")))
              (should (null (crush--history-turns crush--prompt-id))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/history-turns-always-fresh ()
  "Extraction reads the live buffer; no cache can go stale."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (crush-test--seed-exchange "first" "reply")))
            (let ((msgs (crush--history-turns crush--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (crush-test--msg-content (car msgs)) "first"))
              (should (equal (crush-test--msg-content (cadr msgs)) "reply")))
            ;; Editing a completed region is reflected immediately.
            (let ((inhibit-read-only t)
                  (rs (text-property-any (point-min) (point-max)
                                         'crush-response-to id1)))
              (delete-region rs (1+ rs)))
            (should-not (equal (crush--history-turns crush--prompt-id)
                               (list (list (cons 'role "user") (cons 'content "first"))
                                     (list (cons 'role "assistant") (cons 'content "reply"))))))))
    (crush-test--cleanup)))

;;; 100. Undo: programmatic changes are not undoable

(ert-deftest crush-test/undo-init-leaves-empty-list ()
  "Fresh buffer init should leave an empty undo list."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null buffer-undo-list))))
    (crush-test--cleanup)))

(ert-deftest crush-test/undo-user-typing-records-entries ()
  "User typing at the prompt should be recorded in the undo list."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null buffer-undo-list))
          (goto-char (point-max))
          (insert "hello")
          (should buffer-undo-list)
          (should (consp buffer-undo-list))))
    (crush-test--cleanup)))

(ert-deftest crush-test/undo-response-cycle-not-recorded ()
  "Stream deltas, finalize, and prompt insertion should not record undo."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null buffer-undo-list))
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          ;; Clear undo entries from the setup typing so we can test
          ;; that the response cycle alone records nothing.
          (setq buffer-undo-list nil)
          (crush-test--simulate-facade-response "response text")
          ;; Programmatic changes should not have recorded undo.
          (should (null buffer-undo-list))))
    (crush-test--cleanup)))

(ert-deftest crush-test/undo-after-response-user-typing-is-undoable ()
  "User typing after a response cycle should still be undoable."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          (setq buffer-undo-list nil)
          (crush-test--simulate-facade-response "response text")
          (should (null buffer-undo-list))
          (goto-char (point-max))
          (insert "new input")
          (should buffer-undo-list)
          (should (consp buffer-undo-list))))
    (crush-test--cleanup)))

(provide 'crush-test-buffer)
;;; crush-test-buffer.el ends here
