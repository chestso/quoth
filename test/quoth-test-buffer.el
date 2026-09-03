;;; quoth-test-buffer.el --- Chat buffer tests for quoth  -*- lexical-binding: t; -*-
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
;;; Buffer lifecycle, prompt/response regions, text properties, input ring.

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

(declare-function quoth-test--fresh-buffer "quoth-test")
(declare-function quoth-test--cleanup "quoth-test")
(declare-function quoth-test--buffer-name "quoth-test")
(defvar quoth-test--root)

;;; Simulation helper: lets tests drive the response cycle
;;; without any transport process, filter, or sentinel.

(defun quoth-test--live-pipe-proc ()
  "Return a live pipe process usable as a fake transport process.
The hyper provider's curl transport sends stdin (config + JSON body)
then EOF; a pipe process stays alive to accept that without erroring
\(the way a short-lived `true' process would not)."
  (let ((proc (make-pipe-process :name "quoth-test-live-fake"
                                 :noquery t
                                 :coding 'binary
                                 :filter #'ignore
                                 :sentinel #'ignore)))
    proc))

(defun quoth-test--simulate-response (content &optional reasoning)
  "Append CONTENT as streamed deltas and finalize the response.
Mimics the post-`quoth-send-input' state: `quoth--response-start'
must already be set (a marker at the response start).  Streams
REASONING (when non-nil) then CONTENT through
`quoth--append-delta' and closes the response with
`quoth--finalize-response'.  With no reasoning, CONTENT is streamed as
a single `content' delta.  Runs in the quoth buffer."
  (when (and reasoning (> (length reasoning) 0))
    (let ((i 0))
      (while (< i (length reasoning))
        (let ((next (or (and (string-match "\n" reasoning i)
                             (match-end 0))
                        (length reasoning))))
          (quoth--append-delta
           (substring reasoning i next) 'reasoning)
          (setq i next))))
    (quoth--append-delta "" 'content))
  (quoth--append-delta content 'content)
  (quoth--finalize-response))

;;; 1. No duplicate defvar quoth--continue

(ert-deftest quoth-test/no-duplicate-continue-defvar ()
  "Quoth--continue should be defined and buffer-local, default nil."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (local-variable-p 'quoth--continue))
          (should (null quoth--continue))))
    (quoth-test--cleanup)))

;;; 2. Working directory resolution

(ert-deftest quoth-test/default-directory-uses-custom-when-set ()
  "When `quoth-working-directory' is set, the quoth buffer should use it."
  (let ((quoth-working-directory "/tmp"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= (file-truename default-directory)
                             (file-truename "/tmp/")))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/default-directory-uses-default-when-no-project ()
  "When no project and no custom dir, uses `default-directory'."
  (let ((quoth-working-directory nil)
        (default-directory quoth-test--root)
        (expected-dir (file-name-as-directory (file-truename quoth-test--root))))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= (file-truename default-directory)
                             expected-dir))))
      (quoth-test--cleanup))))

;;; 3. Input separator line management

;; The input separator is a markdown horizontal divider (`---`).
;;; `quoth--prompt-start-marker' sits at the divider's start;
;;; `quoth--input-start-marker' sits right after the divider's trailing
;;; blank line, where the editable input region begins.
;;; The divider is tagged `quoth-region-type' `separator' so the header
;;; label is honest: untagged input space reports nil, never `user'.

(ert-deftest quoth-test/input-separator-inserted-on-init ()
  "A fresh buffer starts with the `---' divider, not `quoth> '."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (looking-at "---\n\n"))
          (should-not (save-excursion (search-forward "quoth> " nil t)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/input-separator-edge-is-editable ()
  "The input area right after the divider's blank line stays editable."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert-and-inherit "hello")))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/markers-flank-the-separator ()
  "Test that markers flank the separator.
`quoth--prompt-start-marker' points at the divider, and
`quoth--input-start-marker' directly after its trailing blank line."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should quoth--prompt-start-marker)
          (should (markerp quoth--prompt-start-marker))
          (should (= (marker-position quoth--prompt-start-marker) (point-min)))
          (should quoth--input-start-marker)
          (should (markerp quoth--input-start-marker))
          (should (= (marker-position quoth--input-start-marker) (point-max)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/separator-tagged-as-separator-region ()
  "The divider carries `quoth-region-type' `separator', not `user'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (eq (get-text-property (point) 'quoth-region-type) 'separator))
          (should-not (eq (get-text-property (point) 'quoth-region-type) 'user))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/separator-region-label-shows-separator ()
  "The header label at the divider reads `separator'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (string= (quoth--region-label-at-point) "separator"))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/untagged-input-area-label-is-nil ()
  "Untagged editable input space reports nil, never `user'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (should (null (quoth--region-label-at-point)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/separator-has-blank-lines ()
  "Test that the divider is framed by blank lines.
A blank line below it, and a blank line above it when it follows a response."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Fresh buffer: divider then a blank line, no blank above.
          (goto-char (point-min))
          (should (looking-at "---\n\n"))
          ;; After a response cycle the divider is preceded by a blank line.
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-test--simulate-response "response text")
          (goto-char (point-max))
          (search-backward "---")
          (should (string-match-p "\n\n---\n\n" (buffer-substring-no-properties
                                                 (max (point-min) (- (point) 2))
                                                 (min (point-max) (+ (point) 5)))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/prompt-start-set-on-buffer-init ()
  "After `quoth' creates the buffer, quoth--prompt-start-marker should be set."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should quoth--prompt-start-marker)
          (should (markerp quoth--prompt-start-marker))
          (should (= (marker-position quoth--prompt-start-marker) (point-min)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/finalize-resets-prompt-start ()
  "After the send loop finalizes a response, quoth--prompt-start-marker is reset."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-test--simulate-response "response text")
          (should quoth--prompt-start-marker)
          (should (markerp quoth--prompt-start-marker))
          (should (= (marker-position quoth--prompt-start-marker)
                     (- (point-max) (length "---\n\n"))))))
    (quoth-test--cleanup)))

;;; 4. Input locking

(ert-deftest quoth-test/send-input-errors-when-busy ()
  "`quoth-send-input' signals a user error while the turn is busy.
The guard reads the phase machine: any non-idle phase rejects the send."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test prompt")
          (dolist (phase '(preparing streaming tools))
            (quoth--phase-set phase)
            (should-error (call-interactively #'quoth-send-input)
                          :type 'user-error))
          (quoth--phase-set 'idle)))
    (quoth-test--cleanup)))

;;; 5. Prompt echoing

(ert-deftest quoth-test/send-input-inserts-response-header ()
  "`quoth-send-input' should not error and should leave buffer in valid state."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) fake-proc)))
              (call-interactively #'quoth-send-input))
            (goto-char (point-min))
            (should (search-forward "hello world" nil t))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/send-input-sends-multiline-prompt ()
  "`quoth-send-input' sends the entire input region, not just one line.
A multiline prompt (typed with naked RET) is sent in full."
  (unwind-protect
      (let ((sent-prompt nil))
        (cl-letf (((symbol-function 'quoth-provider-send-prompt)
                   (lambda (_provider prompt &rest _args)
                     (setq sent-prompt prompt)
                     (make-pipe-process :name "quoth-test-fake" :noquery t))))
          (with-current-buffer (quoth-test--fresh-buffer)
            (goto-char (point-max))
            (insert "line one\nline two\nline three")
            (call-interactively #'quoth-send-input)))
        (should (string= sent-prompt "line one\nline two\nline three")))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/send-input-moves-point-to-eof ()
  "`quoth-send-input' moves point to eof before inserting the separator.
Sending with point in the middle of the input must not split the
prompt: the user separator lands at point-max."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "line one\nline two\nline three")
          (goto-char (point-min))
          (search-forward "line two")
          (cl-letf (((symbol-function 'quoth-provider-send-prompt)
                     (lambda (_provider _prompt &rest _args)
                       (make-pipe-process :name "quoth-test-fake" :noquery t))))
            (call-interactively #'quoth-send-input))
          (should (= (point) (point-max)))
          (goto-char (point-min))
          (should (search-forward "line three" nil t))
          ;; The separator follows the last input line at eof.
          (should (search-forward "---" nil t))
          (should (<= (point) (point-max)))))
    (quoth-test--cleanup)))

;;; 6. Stderr handling

(ert-deftest quoth-test/stderr-goes-to-separate-buffer ()
  "Stderr output should go to a separate `*quoth-errors*' buffer."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test stderr")
          (let ((captured-stderr nil)
                (fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest args)
                         (setq captured-stderr (plist-get args :stderr))
                         fake-proc)))
              (call-interactively #'quoth-send-input))
            (should captured-stderr)
            (should (or (bufferp captured-stderr)
                        (stringp captured-stderr)))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))))
    (quoth-test--cleanup)))

;;; 7. quoth-clear-buffer resets session

(ert-deftest quoth-test/clear-buffer-resets-continue ()
  "`quoth-clear-buffer' should reset `quoth--continue' to nil."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (setq-local quoth--continue t)
          (call-interactively #'quoth-clear-buffer)
          (should (null quoth--continue))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/clear-buffer-cleans-provider-transport ()
  "`quoth-clear-buffer' should clean up the active provider's request
handle: the stage is killed, the curl aborted, and the slot cleared."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((stage (make-pipe-process :name "quoth-test-clear-stage"
                                          :noquery t :coding 'binary
                                          :filter #'ignore
                                          :sentinel #'ignore))
                (curl (make-pipe-process :name "quoth-test-clear-transport"
                                         :noquery t :coding 'binary
                                         :filter #'ignore
                                         :sentinel #'ignore)))
            (setf (quoth-provider-request quoth-active-provider)
                  (list :stage-process stage :curl curl :done-p nil))
            (call-interactively #'quoth-clear-buffer)
            (should-not (process-live-p stage))
            (should-not (process-live-p curl))
            (should-not (quoth-provider-request quoth-active-provider))))
        (quoth-test--cleanup))))

;;; 9. Session UUID state: init, rotation, distinctness

(ert-deftest quoth-test/session-uuid-init ()
  "A fresh quoth buffer gets a session UUID and its XXH3-64 hash."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (stringp quoth--session-uuid))
          (should (> (length quoth--session-uuid) 0))
          (should (string= quoth--session-id
                           (quoth-xxh3-hash64 quoth--session-uuid)))
          (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" quoth--session-id))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/session-uuid-distinct-across-buffers ()
  "Two fresh quoth buffers get distinct session UUIDs."
  (unwind-protect
      (let* ((_name1 (quoth-test--buffer-name))
             (buf1 (quoth-test--fresh-buffer))
             (uuid1 (with-current-buffer buf1 quoth--session-uuid)))
        ;; Force a second buffer by turning off buffer reuse (fresh-buffer
        ;; kills the existing one, so create a separately named buffer).
        (let ((quoth--root-buffer-alist nil)
              (buf2 (get-buffer-create "*quoth:sess2*")))
          (quoth--init-buffer buf2)
          (let ((uuid2 (with-current-buffer buf2 quoth--session-uuid)))
            (should-not (equal uuid1 uuid2)))
          (kill-buffer buf2)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/session-uuid-rotates-on-clear ()
  "`quoth-clear-buffer' rotates the session UUID (fresh cache affinity)."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((old-uuid quoth--session-uuid)
                (old-id quoth--session-id))
            (quoth-clear-buffer)
            (should-not (equal quoth--session-uuid old-uuid))
            (should-not (equal quoth--session-id old-id))
            (should (string= quoth--session-id
                             (quoth-xxh3-hash64 quoth--session-uuid))))))
    (quoth-test--cleanup)))

;;; 15. Stderr buffer creation

(ert-deftest quoth-test/stderr-buffer-is-created ()
  "The `*quoth-errors*' buffer should be created when sending input."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _args) fake-proc)))
              (call-interactively #'quoth-send-input))
            (should (get-buffer "*quoth-errors*"))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))))
    (quoth-test--cleanup)))

;;; 16. Prompt ID generation

(ert-deftest quoth-test/prompt-id-is-set-on-buffer-init ()
  "After buffer init, `quoth--prompt-id' should be a non-nil string."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (stringp quoth--prompt-id))
          (should (> (length quoth--prompt-id) 0))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/prompt-id-regenerated-after-response ()
  "After the finalize, `quoth--prompt-id' should be a new unique ID."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((old-id quoth--prompt-id))
            (goto-char (point-max))
            (newline)
            (setq-local quoth--response-start (point-marker))
            ;; Simulate stream completion via.
            (quoth-test--simulate-response "response text")
            ;; New ID should be different
            (should (stringp quoth--prompt-id))
            (should (not (string= old-id quoth--prompt-id))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/interrupt-regenerates-prompt-id ()
  "After `quoth-interrupt', the buffer gets a fresh pending prompt ID."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((old-id quoth--prompt-id))
            (goto-char (point-max))
            (newline)
            (setq-local quoth--response-start (point-marker))
            (setf (quoth-provider-request quoth-active-provider)
                  (make-pipe-process :name "quoth-test-interrupt-id"
                                     :noquery t :coding 'binary
                                     :filter #'ignore :sentinel #'ignore))
            (quoth--phase-set 'streaming)
            (cl-letf (((symbol-function 'quoth-openai-abort) #'ignore))
              (quoth-interrupt))
            (should (stringp quoth--prompt-id))
            (should (not (string= old-id quoth--prompt-id))))))
    (quoth-test--cleanup)))

;;; 18. Header line display

;;; Header line: model + region at point

;;; 18b. Header line: model and region type at point

(ert-deftest quoth-test/region-label-prompts-and-placeholders ()
  "`quoth--region-label-at-point' maps every region type to a label.
The fresh buffer has an input divider at point-min tagged `separator',
so point there resolves to `separator', not `user'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (string= (quoth--region-label-at-point) "separator"))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/user-input-tagged-as-user-region ()
  "Sent user input is tagged `quoth-region-type' `user' at send time."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          ;; Before send: untagged.
          (should-not (eq (get-text-property (- (point) 1) 'quoth-region-type) 'user))
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc)))
              (quoth-send-input))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))
          ;; After send: tagged `user'.
          (goto-char (point-min))
          (should (search-forward "hello world" nil t))
          (should (eq (get-text-property (match-beginning 0) 'quoth-region-type) 'user))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/region-label-user ()
  "User input (typed or attached) resolves to `user'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (insert "attach-region-text")
          (put-text-property (- (point) 18) (point)
                             'quoth-region-type 'user)
          (put-text-property (- (point) 18) (point)
                             'quoth-prompt-id quoth--prompt-id)
          (goto-char (- (point) 9))
          (should (string= (quoth--region-label-at-point) "user"))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/region-label-response ()
  "Response regions resolve to `response'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((start (point-max)))
            (let ((inhibit-modification-hooks t))
              (insert "response-text")
              (put-text-property start (point)
                                 'quoth-region-type 'response))
            (goto-char (- (point) 5))
            (should (string= (quoth--region-label-at-point) "response")))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/region-label-tool-output ()
  "Test that the nested `tool-output' region resolves to its symbol name.
It is not the prompt fallback, even though it carries `quoth-prompt-id'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((start (point-max)))
            (let ((inhibit-modification-hooks t))
              (insert "raw-output-text")
              (put-text-property start (point)
                                 'quoth-region-type 'tool-output)
              (put-text-property start (point)
                                 'quoth-prompt-id quoth--prompt-id))
            (goto-char (- (point) 5))
            (should (string= (quoth--region-label-at-point) "tool-output")))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/region-label-falls-back-to-nil ()
  "Regions with no region type resolve to nil, not a guessed label."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (should (null (quoth--region-label-at-point)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/header-model-falls-back-to-hyper-default ()
  "Test that the effective model falls back to the hyper default.
This is `quoth-openai-default-model' for hyper providers with a nil
model slot."
  (let ((quoth-model nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            ;; A fresh buffer is always a hyper provider; with a nil model
            ;; slot the effective model must be the hyper default.
            (should (string= (quoth--header-model) quoth-openai-default-model))
            ;; A hyper provider with an explicit model uses it.
            (setq-local quoth-active-provider
                        (quoth-make-hyper-provider
                         :buffer buf
                         :working-directory default-directory
                         :base-url quoth-hyper-base-url
                         :token quoth-hyper-token
                         :model "my-model"))
            (should (string= (quoth--header-model) "my-model"))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-model-uses-provider-slot ()
  "`quoth--header-model' reads the provider model slot set at init."
  (let ((quoth-model "claude-sonnet-4-20250514"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= (quoth--header-model) "claude-sonnet-4-20250514"))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-line-shows-model-and-region ()
  "Test that the header line shows both the model and the region type.
Both the current model and the region type at point appear."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (let ((start (point)))
              (insert "typed")
              (put-text-property start (point) 'quoth-region-type 'user))
            (goto-char (1- (point)))
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string= h "(my-model  user)")))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-line-shows-dash-for-nil-region ()
  "Untagged space renders `region: -' in the header line."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string= h "(my-model  -)")))))
      (quoth-test--cleanup))))

;;; 19. Input separator has prompt-id property

(ert-deftest quoth-test/prompt-marker-has-prompt-id-property ()
  "The input separator text should have quoth-prompt-id text property."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Find the separator text
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (let ((prompt-id (get-text-property (- (point) 1) 'quoth-prompt-id)))
            (should prompt-id)
            (should (string= prompt-id quoth--prompt-id)))))
    (quoth-test--cleanup)))

;;; 20. User input gets prompt-id property at send time

(ert-deftest quoth-test/user-input-gets-prompt-id-property ()
  "Sent user input is tagged with quoth-prompt-id at send time."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (sent-id nil))
        (with-current-buffer buf
          (setq sent-id quoth--prompt-id)
          (goto-char (point-max))
          (insert "hello world")
          ;; Before send: untagged.
          (should-not (get-text-property (- (point) 5) 'quoth-prompt-id))
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc)))
              (quoth-send-input))
            (when (process-live-p fake-proc)
              (delete-process fake-proc))))
        ;; After send: the input region (now history) carries the prompt-id.
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "hello world" nil t))
          (let ((prompt-id (get-text-property (match-beginning 0) 'quoth-prompt-id)))
            (should prompt-id)
            (should (string= prompt-id sent-id)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/response-has-response-to-property ()
  "Response text should have quoth-response-to property linking to prompt."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((prompt-id quoth--prompt-id))
            ;; Simulate a response manually
            (goto-char (point-max))
            (let ((response-start (point)))
              (insert "response text\n")
              ;; Tag it manually like sentinel does
              (put-text-property response-start (point) 'quoth-response-to prompt-id)
              (quoth--insert-input-separator))
            ;; Check response text has property
            (goto-char (point-min))
            (should (search-forward "response text" nil t))
            (let ((response-to (get-text-property (- (point) 5) 'quoth-response-to)))
              (should response-to)
              (should (string= response-to prompt-id))))))
    (quoth-test--cleanup)))

;;; 23. History retrieval functions

(ert-deftest quoth-test/get-all-prompts ()
  "`quoth-get-all-prompts' should return all prompt IDs in buffer."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((first-id quoth--prompt-id))
            (goto-char (point-max))
            (insert "first prompt")
            (let ((fake-proc (quoth-test--live-pipe-proc)))
              (set-process-buffer fake-proc (current-buffer))
              (cl-letf (((symbol-function #'make-process)
                         (lambda (&rest _) fake-proc)))
                (quoth-send-input))
              ;; Simulate stream completion: invoke the the finalize
              ;; continuation directly (no process, filter, or sentinel).
              (let ((completion (quoth-provider-completion-action
                                 quoth-active-provider)))
                (should (functionp completion))
                (funcall completion))
              (when (process-live-p fake-proc)
                (delete-process fake-proc)))
            (let ((second-id quoth--prompt-id))
              (goto-char (point-max))
              (insert "second prompt")
              (let ((all-prompts (quoth-get-all-prompts)))
                (should (member first-id all-prompts))
                (should (member second-id all-prompts)))))))
    (quoth-test--cleanup)))

;;; 30. Region type tagging: response

(ert-deftest quoth-test/response-region-tagged-as-response ()
  "Response text should be tagged with quoth-region-type 'response."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate a response cycle via (no process).
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-test--simulate-response "response text")
          ;; Check that response text has quoth-region-type 'response
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          ;; Finalize must not create any quoth overlays.
          (let ((overlays (cl-remove-if-not (lambda (ov) (overlay-get ov 'quoth-overlay))
                                            (overlays-in (point-min) (point-max)))))
            (should-not overlays))
          (let ((region-type (get-text-property (- (point) 5) 'quoth-region-type)))
            (should (eq region-type 'response)))))
    (quoth-test--cleanup)))

;;; 31. Integration: quoth-clear-buffer removes overlays

(ert-deftest quoth-test/clear-buffer-removes-overlays ()
  "Quoth-clear-buffer should remove old quoth-overlay tagged overlays."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Create an extra overlay manually
          (let ((ov (make-overlay (point-min) (point-max))))
            (overlay-put ov 'quoth-overlay t)
            (overlay-put ov 'face 'highlight))
          ;; Call clear-buffer
          (call-interactively #'quoth-clear-buffer)
          ;; Should have no overlay with face 'highlight' (the manual one is gone)
          (should-not (cl-some (lambda (ov)
                                 (and (overlay-buffer ov)
                                      (eq (overlay-get ov 'face) 'highlight)))
                               (overlays-in (point-min) (point-max))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/finalize-tags-and-reprompts ()
  "The the core continuation finalizes the response.
It tags the response, inserts a fresh prompt, and regenerates the ID."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (goto-char (point-max))
        (newline)
        (setq-local quoth--response-start (point-marker))
        (insert "mock response")
        (let ((old-id quoth--prompt-id)
              (response-start (point-marker)))
          ;; The the core continuation is exactly what quoth-send-input
          ;; injects into the provider.
          (let ((buf (current-buffer)))
            (funcall (lambda ()
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (quoth--finalize-response))))))
          ;; Fresh prompt inserted after the response, with a new ID.
          (goto-char (point-min))
          (search-forward "mock response")
          (should (eq (get-text-property (match-beginning 0)
                                         'quoth-region-type)
                      'response))
          (should-not (string= quoth--prompt-id old-id))
          (goto-char (point-max))
          (search-backward "---")
          (should (< (marker-position response-start)
                     (point)))))
    (quoth-test--cleanup)))

;;; 56. Region-type/field reconciliation

(ert-deftest quoth-test/response-region-type-still-set ()
  "Response text should still have quoth-region-type=response."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-test--simulate-response "response text")
          (goto-char (point-min))
          (should (search-forward "response text" nil t))
          (should (eq (get-text-property (- (point) 5) 'quoth-region-type) 'response))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/org-region-type-still-set ()
  "Attachment blocks should have quoth-region-type=user (appended input)."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name "/test/file.el")
              (quoth-insert-selection (point-min) (point-max)))
            (goto-char (point-min))
            (should (search-forward "Attachment:" nil t))
            (should (eq (get-text-property (match-beginning 0) 'quoth-region-type) 'user))))
      (quoth-test--cleanup))))

;;; 57. Debug logging - quoth-debug-mode defcustom

(ert-deftest quoth-test/debug-mode-defaults-to-t ()
  "Quoth-debug-mode should default to t."
  (should (eq quoth-debug-mode t)))

;;; 58. Debug logging - quoth--debug-log creates buffer and writes

(ert-deftest quoth-test/debug-log-creates-buffer ()
  "Quoth--debug-log should create *quoth-debug* buffer when enabled."
  (unwind-protect
      (let ((quoth-debug-mode t))
        (should-not (get-buffer "*quoth-debug*"))
        (quoth--debug-log 'test "hello world")
        (should (get-buffer "*quoth-debug*"))
        (with-current-buffer "*quoth-debug*"
          (goto-char (point-min))
          (should (search-forward "test: hello world" nil t))))
    (quoth-test--cleanup)))

;;; 59. Debug logging - disabled mode is no-op

(ert-deftest quoth-test/debug-log-disabled-no-op ()
  "Quoth--debug-log should do nothing when quoth-debug-mode is nil."
  (unwind-protect
      (let ((quoth-debug-mode nil))
        (quoth--debug-log 'test "should not appear")
        (should-not (get-buffer "*quoth-debug*")))
    (quoth-test--cleanup)))

;;; 60. Debug logging - command logged in input-sender

;;; 62. Debug logging - streamed output logged via

(ert-deftest quoth-test/debug-logs-output ()
  "Streamed content inserts into the buffer and finalizes.
The debug *quoth-debug* logging is the transport's job (quoth-provider);
the send loop owns insertion."
  (unwind-protect
      (let ((quoth-debug-mode t)
            (buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth--append-delta "some output text" 'content)
          (goto-char (point-min))
          (should (search-forward "some output text" nil t)))
        (with-current-buffer buf
          (quoth--finalize-response)))
    (quoth-test--cleanup)))

;;; 63. Debug logging - finalize path logs via continuation

(ert-deftest quoth-test/debug-logs-finalize ()
  "The finalize path closes the response and inserts a prompt.
The send loop continuation owns completion and logs it."
  (unwind-protect
      (let ((quoth-debug-mode t)
            (buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-test--simulate-response "response"))
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "---" nil t))))
    (quoth-test--cleanup)))

(defun quoth-test--input-area-text ()
  "Return the input area text to the line end.
The text starts at `quoth--input-start-marker' and runs to the line end."
  (buffer-substring-no-properties
   (marker-position quoth--input-start-marker)
   (line-end-position)))

(ert-deftest quoth-test/append-as-user-input-lands-in-input-area ()
  "Quoth--append-as-user-input should insert after quoth--input-start-marker."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (should quoth--input-start-marker)
            (quoth--append-as-user-input buf "INSERTED CONTENT")
            (goto-char (marker-position quoth--input-start-marker))
            (should (string-match-p "INSERTED CONTENT"
                                    (quoth-test--input-area-text)))
            (should (eq (get-text-property (marker-position quoth--input-start-marker)
                                           'quoth-region-type)
                        'user))))
      (quoth-test--cleanup))))

;;; 69. Typed input is NOT tagged live (no after-change hook)

(ert-deftest quoth-test/typed-input-not-tagged-live ()
  "Text typed at the prompt carries no region-type until send time.
There is no after-change hook; tagging happens in `quoth-send-input'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "typed text")
          ;; No region-type, no prompt-id until send.
          (should-not (get-text-property (- (point) 5) 'quoth-region-type))
          (should-not (get-text-property (- (point) 5) 'quoth-prompt-id))))
    (quoth-test--cleanup)))

;;; Parallel markers

(ert-deftest quoth-test/prompt-start-marker-set-on-init ()
  "Quoth--prompt-start-marker should be set after buffer init."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should quoth--prompt-start-marker)
          (should (markerp quoth--prompt-start-marker))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/input-start-marker-set-on-init ()
  "Quoth--input-start-marker should be set after buffer init."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should quoth--input-start-marker)
          (should (markerp quoth--input-start-marker))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/prompt-start-marker-insertion-type ()
  "Quoth--prompt-start-marker should have insertion-type t (advances on insert before)."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (markerp quoth--prompt-start-marker))
          (should (marker-insertion-type quoth--prompt-start-marker))))
    (quoth-test--cleanup)))

;;; Delta streaming

(ert-deftest quoth-test/delta-inserts-at-end ()
  "A streamed content delta is appended at point-max (the response area)."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth--append-delta "hello world" 'content)
          (goto-char (point-min))
          (should (search-forward "hello world" nil t))
          ;; The delta went to point-max (the response area), so the
          ;; response-start marker now sits before the streamed text.
          (should (< (marker-position quoth--response-start) (point-max)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/delta-accumulates ()
  "Multiple deltas accumulate in stream order at the response area."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth--append-delta "abc" 'content)
          (quoth--append-delta "xyz" 'content)
          (goto-char (point-min))
          (should (search-forward "abcxyz" nil t))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/delta-logged-to-debug ()
  "Streamed deltas insert into the buffer when debug mode is on.
The *quoth-debug* logging is the transport's job (providers), not the
the core; this asserts the contract — insertion completes."
  (unwind-protect
      (let ((quoth-debug-mode t)
            (buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth--append-delta "test output" 'content)
          (goto-char (point-min))
          (should (search-forward "test output" nil t)))
        (with-current-buffer buf
          (quoth--finalize-response)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/delta-no-field-property ()
  "Streamed deltas should NOT set field on inserted text."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (setq-local quoth--response-start (point-marker))
          (quoth--append-delta "response text" 'content)
          (should-not (get-text-property (1- (point-max)) 'field))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/delta-dead-buffer-safe ()
  "The the core's on-delta closure guards a killed quoth buffer."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (kill-buffer buf)
        ;; The closure the send loop injects into the provider wraps the
        ;; append in `buffer-live-p', so it must not error after the
        ;; buffer died.
        (should-not (funcall (lambda ()
                               (when (buffer-live-p buf)
                                 (with-current-buffer buf
                                   (quoth--append-delta "x" 'content))))))
        ;; The raw function itself operates on the current buffer; a
        ;; live current buffer must still work.
        (with-temp-buffer
          (setq-local quoth--response-start (point-marker))
          (quoth--append-delta "works" 'content)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/delta-cursor-stays-when-scrolled-back ()
  "When cursor is not at point-max, streaming should not move it.
This allows users to scroll back and read earlier content while
the response streams in."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Set up some existing content
          (goto-char (point-max))
          (insert "existing content\n")
          (setq-local quoth--response-start (point-marker))
          ;; Position cursor in the middle of existing content
          (goto-char (point-min))
          (search-forward "existing")
          (let ((saved-point (point)))
            ;; Stream in new content
            (quoth--append-delta "streamed text" 'content)
            ;; Cursor should stay where it was
            (should (= (point) saved-point))
            ;; New content should be at the end
            (goto-char (point-max))
            (should (search-backward "streamed text" nil t)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/delta-cursor-follows-when-at-end ()
  "When cursor is at point-max, streaming should advance it.
This gives a terminal-like reading experience for users watching
the live stream."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (setq-local quoth--response-start (point-marker))
          ;; Cursor is at point-max
          (should (= (point) (point-max)))
          ;; Stream in content
          (quoth--append-delta "streaming text" 'content)
          ;; Cursor should have moved to the new point-max
          (should (= (point) (point-max)))
          ;; Content should be visible at point
          (should (string= (buffer-substring-no-properties
                            (- (point) (length "streaming text"))
                            (point))
                           "streaming text"))))
    (quoth-test--cleanup)))

;;; Window point preservation

;; These tests assert the window-point-aware behavior of
;; `quoth--insert-at-eof': it must read the window's point (not the
;; stale buffer point) so a user who scrolled back keeps their place
;; even when the insertion runs from a process filter/sentinel.

(ert-deftest quoth-test/insert-at-eof-preserves-window-point ()
  "Test that insertion does not move a window whose point is not at point-max.
The buffer's own point may be stale (as in a process filter); the
`window-point' is the authoritative cursor position."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "line one\nline two\n"))
        (let ((win (display-buffer buf t)))
          (select-window win)
          ;; Force the window point to 9 while buffer point stays at max.
          (set-window-point win 9)
          (let* ((saved-win-point (window-point win))
                 (saved-win-start (window-start win)))
            (should (= saved-win-point 9))
            (should (< saved-win-point (with-current-buffer buf (point-max))))
            (with-current-buffer buf
              (quoth--insert-at-eof "appended text"))
            (should (= (window-point win) saved-win-point))
            (should (= (window-start win) saved-win-start)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/insert-at-eof-follows-window-point-at-end ()
  "Insertion must advance a window whose point is at point-max."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "existing\n"))
        (let ((win (display-buffer buf t)))
          (select-window win)
          (set-window-point win (point-max))
          (let ((old-max (with-current-buffer buf (point-max))))
            (with-current-buffer buf
              (quoth--insert-at-eof "appended text"))
            (should (= (window-point win) (point-max)))
            (should (> (with-current-buffer buf (point-max)) old-max)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/insert-at-eof-accepts-a-position ()
  "Insertion at an explicit position must tag exactly that span."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "before\n")
          (let ((pos (point)))
            (quoth--insert-at-eof "middle" (list 'foo 'bar) pos)
            (should (eq (get-text-property pos 'foo) 'bar))
            (should (string= (buffer-substring pos (+ pos (length "middle")))
                             "middle"))
            ;; Inserting at a position must not clobber point-max content.
            (should (string-match-p "before" (buffer-string))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/append-as-user-input-delegates-to-insert-at-eof ()
  "Appending user input must preserve a scrolled-back window point.
Unlike a raw `insert', which leaves the chase of window point to the
caller, `quoth--append-as-user-input' must route through
`quoth--insert-at-eof' so a scrolled-back window keeps its place."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "line one\nline two\n"))
        (let ((win (display-buffer buf t)))
          (select-window win)
          (set-window-point win 9)
          (let ((saved-win-point (window-point win)))
            (with-current-buffer buf
              (quoth--append-as-user-input buf "INSERTED CONTENT"))
            (should (= (window-point win) saved-win-point)))))
    (quoth-test--cleanup)))

;;; Custom input ring

(ert-deftest quoth-test/custom-input-ring-initialized ()
  "Quoth--input-ring should be a ring in a quoth buffer."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (boundp 'quoth--input-ring))
          (should (ring-p quoth--input-ring))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/custom-input-ring-add ()
  "Quoth--input-ring-add should add input to the ring."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (setq quoth--input-ring (make-ring quoth-input-ring-size))
          (quoth--input-ring-add "first prompt")
          (should (= (ring-length quoth--input-ring) 1))
          (should (string= "first prompt" (ring-ref quoth--input-ring 0)))
          (quoth--input-ring-add "second prompt")
          (should (= (ring-length quoth--input-ring) 2))
          (should (string= "second prompt" (ring-ref quoth--input-ring 0)))
          (should (string= "first prompt" (ring-ref quoth--input-ring 1)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/custom-input-ring-add-skips-duplicate ()
  "Quoth--input-ring-add should not add consecutive duplicate entries."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (setq quoth--input-ring (make-ring quoth-input-ring-size))
          (quoth--input-ring-add "same prompt")
          (should (= (ring-length quoth--input-ring) 1))
          (quoth--input-ring-add "same prompt")
          (should (= (ring-length quoth--input-ring) 1))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/custom-input-ring-add-skips-empty ()
  "Quoth--input-ring-add should not add empty strings."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (setq quoth--input-ring (make-ring quoth-input-ring-size))
          (quoth--input-ring-add "")
          (should (= (ring-length quoth--input-ring) 0))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/custom-input-ring-read-from-file ()
  "Quoth--input-ring-read should read history from file."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (tmpfile (make-temp-file "quoth-ring-test")))
        (with-temp-buffer
          (insert "line one\nline two\nline three\n")
          (write-region (point-min) (point-max) tmpfile nil 'quiet))
        (with-current-buffer buf
          (setq quoth--input-ring (make-ring quoth-input-ring-size))
          (let ((quoth--input-ring-file-name tmpfile))
            (quoth--input-ring-read))
          (should (= (ring-length quoth--input-ring) 3))
          (should (string= "line three" (ring-ref quoth--input-ring 0)))
          (should (string= "line two" (ring-ref quoth--input-ring 1)))
          (should (string= "line one" (ring-ref quoth--input-ring 2))))
        (when (file-exists-p tmpfile) (delete-file tmpfile)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/custom-input-ring-write-to-file ()
  "Quoth--input-ring-write should write history to file."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (tmpfile (make-temp-file "quoth-ring-test")))
        (with-current-buffer buf
          (setq quoth--input-ring (make-ring quoth-input-ring-size))
          (quoth--input-ring-add "alpha")
          (quoth--input-ring-add "beta")
          (let ((quoth--input-ring-file-name tmpfile))
            (quoth--input-ring-write))
          (with-temp-buffer
            (insert-file-contents tmpfile)
            (goto-char (point-min))
            (should (search-forward "beta" nil t))
            (should (search-forward "alpha" nil t))))
        (when (file-exists-p tmpfile) (delete-file tmpfile)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/send-input-adds-to-custom-ring ()
  "Quoth-send-input should add prompt to quoth--input-ring."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "history test")
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc)))
              (call-interactively #'quoth-send-input))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))
          (should (> (ring-length quoth--input-ring) 0))
          (should (string-match-p "history test"
                                  (ring-ref quoth--input-ring 0)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/no-placeholder-process ()
  "The quoth buffer should not require a placeholder process for input."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (get-buffer-process (current-buffer)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/input-previous-inserts-from-ring ()
  "\\[quoth--input-previous] inserts the previous ring input."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (quoth--input-ring-add "old prompt one")
          (quoth--input-ring-add "old prompt two")
          (setq-local quoth--input-ring-index 0)
          (goto-char (point-max))
          (quoth--input-previous)
          (should (string= "old prompt two"
                           (buffer-substring-no-properties
                            (marker-position quoth--input-start-marker)
                            (line-end-position))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/input-next-inserts-from-ring ()
  "\\[quoth--input-next] inserts the next (more recent) ring input."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (setq quoth--input-ring (make-ring quoth-input-ring-size))
          (quoth--input-ring-add "old prompt one")
          (quoth--input-ring-add "old prompt two")
          (setq-local quoth--input-ring-index 1)
          (goto-char (point-max))
          (quoth--input-next)
          (should (string= "old prompt two"
                           (buffer-substring-no-properties
                            (marker-position quoth--input-start-marker)
                            (line-end-position))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/input-ring-file-name-default ()
  "`quoth--input-ring-file-name' defaults to a file in `user-emacs-directory'."
  (should (string= quoth--input-ring-file-name
                   (expand-file-name "quoth-history" user-emacs-directory))))

;;; Mode parent resolution

(ert-deftest quoth-test/mode-parent-is-text-mode ()
  "The quoth buffer's major mode is the parent mode.
It derives from `text-mode' (or `markdown-mode'), never `comint-mode'.
There is no separate `quoth-mode' major mode."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq major-mode quoth--parent-mode))
          (should (derived-mode-p 'text-mode))
          (should-not (derived-mode-p 'comint-mode))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/clear-buffer-prompt-has-quoth-properties ()
  "After quoth-clear-buffer, the new separator should have quoth properties."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (call-interactively #'quoth-clear-buffer)
          (goto-char (point-min))
          (should (search-forward "---" nil t))
          (should-not (get-text-property (match-beginning 0) 'field))))
    (quoth-test--cleanup)))

;;; Optional markdown-mode base

(ert-deftest quoth-test/parent-mode-is-text-or-markdown ()
  "`quoth--parent-mode' is either `text-mode' or `markdown-mode'."
  (should (memq quoth--parent-mode '(text-mode markdown-mode))))

(ert-deftest quoth-test/mode-derives-from-parent-mode ()
  "The quoth buffer major mode should derive from quoth--parent-mode."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (derived-mode-p quoth--parent-mode))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/can-type-after-prompt ()
  "User should be able to type after the prompt."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert-and-inherit "hello")
          (goto-char (point-min))
          (should (search-forward "hello" nil t))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/input-area-is-editable ()
  "After a response cycle, the new input area should be editable."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (quoth-test--simulate-response "response")
          (goto-char (point-max))
          (insert-and-inherit "new input")
          (goto-char (point-min))
          (should (search-forward "new input" nil t))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/clear-buffer-keeps-prompt-readable-input ()
  "Quoth-clear-buffer should reset the buffer so input is editable again."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (call-interactively #'quoth-clear-buffer)
          (goto-char (point-max))
          (insert-and-inherit "hello")
          (goto-char (point-min))
          (should (search-forward "hello" nil t))))
    (quoth-test--cleanup)))

(defun quoth-test--cleanup-registry ()
  "Purge `quoth--root-buffer-alist' and kill the buffers it names."
  (dolist (entry quoth--root-buffer-alist)
    (when (get-buffer (cdr entry))
      (kill-buffer (cdr entry))))
  (setq quoth--root-buffer-alist nil))

(ert-deftest quoth-test/current-buffer-uses-default-directory-root ()
  "`quoth--current-quoth-buffer' should use `default-directory' as root."
  (unwind-protect
      (let* ((root (expand-file-name "quoth-test-x" temporary-file-directory))
             (buf (with-temp-buffer
                    (setq default-directory root)
                    (quoth--current-quoth-buffer))))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string= (quoth--canonical-root quoth--project-root)
                           (quoth--canonical-root root)))))
    (quoth-test--cleanup-registry)))

(ert-deftest quoth-test/current-buffer-uses-project-root ()
  "`quoth--current-quoth-buffer' should prefer the project root."
  (cl-letf (((symbol-function 'project-current)
             (lambda (&optional _dir)
               (list 'vc 'Git "/tmp/quoth-proj-root/"))))
    (unwind-protect
        (let* ((root (expand-file-name "quoth-test-x" temporary-file-directory))
               (buf (with-temp-buffer
                      (setq default-directory root)
                      (quoth--current-quoth-buffer))))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (string= (quoth--canonical-root quoth--project-root)
                             (quoth--canonical-root
                              "/tmp/quoth-proj-root/")))))
      (quoth-test--cleanup-registry))))

(ert-deftest quoth-test/current-buffer-reuses-existing-buffer ()
  "Resolving the same root twice should return the same buffer."
  (unwind-protect
      (let* ((root (expand-file-name "quoth-test-x" temporary-file-directory))
             (buf1 (with-temp-buffer
                     (setq default-directory root)
                     (quoth--current-quoth-buffer)))
             (buf2 (with-temp-buffer
                     (setq default-directory root)
                     (quoth--current-quoth-buffer))))
        (should (eq buf1 buf2)))
    (quoth-test--cleanup-registry)))

(ert-deftest quoth-test/buffer-name-uses-root-basename ()
  "`quoth--buffer-name-for-root' should use the root directory's basename."
  (should (string= (quoth--buffer-name-for-root "/tmp/foo/") "*quoth:foo*"))
  (should (string= (quoth--buffer-name-for-root "~/x/y/") "*quoth:y*")))

(ert-deftest quoth-test/buffer-name-same-basename-distinct-roots-collide ()
  "Two roots with the same basename should get distinct buffer names."
  (let ((quoth--root-buffer-alist nil))
    (should (string= (quoth--buffer-name-for-root "/tmp/foo/") "*quoth:foo*"))
    (should (string= (quoth--buffer-name-for-root "/tmp/bar/foo/") "*quoth:foo(2)*"))))

(ert-deftest quoth-test/buffer-name-stable-per-root ()
  "Re-resolving a root should return the same name (no growing suffix)."
  (let ((quoth--root-buffer-alist nil))
    (quoth--buffer-name-for-root "/tmp/foo/")
    (should (string= (quoth--buffer-name-for-root "/tmp/bar/foo/") "*quoth:foo(2)*"))
    ;; Resolving either root again must not change the mapping.
    (should (string= (quoth--buffer-name-for-root "/tmp/foo/") "*quoth:foo*"))
    (should (string= (quoth--buffer-name-for-root "/tmp/bar/foo/") "*quoth:foo(2)*"))))

(ert-deftest quoth-test/buffer-name-trailing-slash-canonicalized ()
  "Roots differing only in trailing slash should map to the same name."
  (let ((quoth--root-buffer-alist nil))
    (should (string= (quoth--buffer-name-for-root "/tmp/foo") "*quoth:foo*"))
    (should (string= (quoth--buffer-name-for-root "/tmp/foo/") "*quoth:foo*"))))

(ert-deftest quoth-test/buffer-name-root-slash-fallback ()
  "The root \"/\" has no basename and should get a fallback name."
  (should (string= (quoth--buffer-name-for-root "/") "*quoth:root*")))

(ert-deftest quoth-test/buffer-name-three-way-collision ()
  "Three roots with the same basename should be suffixed 2 and 3."
  (let ((quoth--root-buffer-alist nil))
    (should (string= (quoth--buffer-name-for-root "/a/foo/") "*quoth:foo*"))
    (should (string= (quoth--buffer-name-for-root "/b/foo/") "*quoth:foo(2)*"))
    (should (string= (quoth--buffer-name-for-root "/c/foo/") "*quoth:foo(3)*"))))

(ert-deftest quoth-test/buffer-name-fresh-registry-registers-root ()
  "Resolving a root should register it in `quoth--root-buffer-alist'."
  (let ((quoth--root-buffer-alist nil))
    (quoth--buffer-name-for-root "/tmp/x/foo/")
    (should (assoc "/tmp/x/foo/" quoth--root-buffer-alist))
    (should (equal (alist-get "/tmp/x/foo/" quoth--root-buffer-alist nil nil #'equal)
                   "*quoth:foo*"))))

;;; 33. Conversation history extraction: tagged regions -> turns

;;; These tests pin the contract of the history extraction:
;;; `quoth--history-turns' reads the buffer's tagged regions (prompt
;;; markers, user input, responses, reasoning) and produces a list of
;;; message alists (not (ROLE . TEXT) conses) that the hyper provider
;;; re-sends.  Role tags (`quoth-role') are applied by
;;; `quoth--insert-input-separator' (separator) / `quoth-send-input'
;;; (user, at send time) and `quoth--tag-response-region'
;;; (assistant/reasoning); the builder groups the buffer by prompt so
;;; the pending prompt is never included.

(defun quoth-test--msg-role (msg)
  "Return the `role' of message alist MSG."
  (cdr (assoc 'role msg)))

(defun quoth-test--msg-content (msg)
  "Return the `content' of message alist MSG, or nil."
  (cdr (assoc 'content msg)))

(defun quoth-test--seed-exchange (prompt-text reply-text)
  "Seed a completed exchange in the current quoth buffer.
Types PROMPT-TEXT and tags it `user' explicitly (no after-change hook),
then simulates a completed exchange: response region REPLY-TEXT tagged
as the turn's answer, then a fresh input separator.  Returns the
completed prompt's ID."
  (let ((prompt-id quoth--prompt-id))
    (goto-char (point-max))
    (let ((start (point)))
      (insert prompt-text)
      (put-text-property start (point) 'quoth-region-type 'user)
      (put-text-property start (point) 'quoth-prompt-id prompt-id))
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (insert reply-text)
      (quoth--tag-response-region response-start (point) prompt-id))
    (goto-char (point-max))
    ;; Anticipate the newline the separator insertion would leave; it
    ;; must not become part of the user turn.
    (when (eq (char-before (point)) ?\n)
      (delete-region (1- (point)) (point)))
    (setq-local quoth--prompt-id (quoth--generate-id))
    (quoth--insert-input-separator)
    prompt-id))

(ert-deftest quoth-test/history-turns-nil-when-only-one-prompt ()
  "With a single (pending) prompt there is no history to extract."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null (quoth--history-turns quoth--prompt-id)))))
    (quoth-test--cleanup)))

;;; Turn divider: a `---' between the user turn and its response.

(defun quoth-test--seed-user-separator (prompt-text reasoning-text answer-text)
  "Seed a turn with a user separator, as `quoth-send-input' does.
Types PROMPT-TEXT and tags it `user' explicitly (no after-change hook),
inserts the separator via `quoth--insert-user-separator', then streams
REASONING-TEXT and ANSWER-TEXT and finalizes.  Returns the completed
prompt's ID."
  (let ((prompt-id quoth--prompt-id))
    (goto-char (point-max))
    (let ((start (point)))
      (insert prompt-text)
      (put-text-property start (point) 'quoth-region-type 'user)
      (put-text-property start (point) 'quoth-prompt-id prompt-id))
    (goto-char (line-end-position))
    (newline)
    (quoth--insert-user-separator)
    (setq-local quoth--response-start (point-marker))
    (let ((proc (make-pipe-process :name "quoth-hyper-test-div"
                                   :noquery t :coding 'binary)))
      (process-put proc :quoth-target (current-buffer))
      (unwind-protect
          (progn
            (quoth--append-delta reasoning-text 'reasoning)
            (quoth--append-delta answer-text 'content)
            (quoth--finalize-response))
        (delete-process proc)))
    (goto-char (point-max))
    (when (eq (char-before (point)) ?\n)
      (delete-region (1- (point)) (point)))
    (setq-local quoth--prompt-id (quoth--generate-id))
    (quoth--insert-input-separator)
    prompt-id))

(ert-deftest quoth-test/user-separator-inserted-before-response ()
  "Test that the user separator is inserted before the response.
The `quoth--insert-user-separator' function places a `---' between the
user text and the streamed response, tagged `user-separator'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-user-separator
                     "describe this file"
                     "The user wants me to describe the file."
                     "This is the answer.")))
            (ignore id)
            (goto-char (point-min))
            (search-forward "describe this file")
            ;; The user separator sits right after the user text, framed by
            ;; a blank line above and below (mirroring the input separator).
            (let* ((sep (text-property-any (point) (point-max)
                                           'quoth-region-type 'user-separator))
                   (sep-end (or (next-single-property-change sep 'quoth-region-type
                                                             nil (point-max))
                                (point-max))))
              (should sep)
              (should (string= (buffer-substring-no-properties (1- sep) sep-end)
                               "\n---\n\n"))
              ;; The blank line below the divider is part of the separator.
              (should (eq (get-text-property (1- sep-end) 'quoth-region-type)
                          'user-separator)))
            ;; The response text follows the separator.
            (search-forward "This is the answer.")
            (should (eq (get-text-property (match-beginning 0) 'quoth-region-type)
                        'response)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/user-separator-ignored-by-history-turns ()
  "Test that the user separator does not leak into reconstructed history.
A turn with reasoning + separator yields exactly `user' then
`assistant' messages."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-user-separator
                     "describe this file"
                     "The user wants me to describe the file."
                     "This is the answer.")))
            (ignore id)
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (quoth-test--msg-role (nth 0 msgs)) "user"))
              (should (string= (quoth-test--msg-content (nth 0 msgs))
                               "describe this file"))
              (should (equal (quoth-test--msg-role (nth 1 msgs)) "assistant"))
              (should (string= (quoth-test--msg-content (nth 1 msgs))
                               "This is the answer."))
              (should-not (cl-some (lambda (m) (string-match-p "---"
                                                               (or (quoth-test--msg-content m) "")))
                                   msgs))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-excludes-pending-prompt ()
  "The pending (current) prompt never appears in the messages.
It is being sent when the history is extracted."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((_completed-id (quoth-test--seed-exchange "first prompt" "first reply")))
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (quoth-test--msg-role (car msgs)) "user"))
              (should (equal (quoth-test--msg-content (car msgs)) "first prompt"))))))
    (quoth-test--cleanup)))

;;; Helper: seed an exchange that carries a tool call.
(defun quoth-test--seed-tool-exchange (prompt-text answer-text tool-calls)
  "Seed an exchange and return the completed prompt's ID.
PROMPT-TEXT is the user input (tagged `user' explicitly, no
after-change hook), ANSWER-TEXT is the assistant answer, and
TOOL-CALLS is a list of plists (:name :id :args-json :result :exit)
rendered as tool blocks before the answer, tagged the way the streaming
machinery tags them."
  (let ((prompt-id quoth--prompt-id))
    (goto-char (point-max))
    (let ((start (point)))
      (insert prompt-text)
      (put-text-property start (point) 'quoth-region-type 'user)
      (put-text-property start (point) 'quoth-prompt-id prompt-id))
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (dolist (tc tool-calls)
        (quoth--tool-block-insert tc prompt-id))
      ;; The answer follows the tool block at point-max (tool-block-insert
      ;; now leaves point at EOF).
      (goto-char (point-max))
      (insert answer-text)
      (quoth--tag-response-region response-start (point) prompt-id))
    (goto-char (point-max))
    ;; Anticipate the newline the separator insertion would leave; it
    ;; must not become part of the user turn.
    (when (eq (char-before (point)) ?\n)
      (delete-region (1- (point)) (point)))
    (setq-local quoth--prompt-id (quoth--generate-id))
    (quoth--insert-input-separator)
    prompt-id))

(ert-deftest quoth-test/answer-text-excludes-tool-blocks ()
  "Test that the answer text excludes rendered tool blocks.
`quoth-get-response-text' must not include the rendered tool block in
the assistant answer.  The tool blocks are display decoration around
the raw tool result; the assistant turn carries only the model's own
answer text."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-tool-exchange
                     "run ls"
                     "Here is the listing: AGENTS.md"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (let ((answer (quoth-get-response-text id)))
              (should (string-match-p "Here is the listing: AGENTS.md" answer))
              (should-not (string-match-p "tool:" answer))
              (should-not (string-match-p "<command>" answer))
              (should-not (string-match-p "<output>" answer))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/tool-rounds-raw-output ()
  "Test that tool rounds emit the raw result as the tool content.
The `quoth--tool-rounds' function emits the raw result, not the
rendered decoration."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-tool-exchange
                     "run ls"
                     "Here is the listing"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (let* ((msgs (quoth--tool-rounds id))
                   (tool-msg (cl-find "tool" msgs :key #'quoth-test--msg-role :test #'string=)))
              (should tool-msg)
              (should (string-match-p "<command>ls</command>" (quoth-test--msg-content tool-msg)))
              (should (string-match-p "<output>" (quoth-test--msg-content tool-msg)))
              (should (string-match-p "<exit_code>0</exit_code>" (quoth-test--msg-content tool-msg)))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-tool-exchange ()
  "A completed exchange with a tool call emits user + assistant(tool_calls)
+ tool + trailing assistant answer, reconstructed from the buffer."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-tool-exchange
                     "run ls"
                     "Listing done"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (ignore id)
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 4))
              (should (equal (quoth-test--msg-role (nth 0 msgs)) "user"))
              (should (equal (quoth-test--msg-role (nth 1 msgs)) "assistant"))
              (should (vectorp (cdr (assoc 'tool_calls (nth 1 msgs)))))
              (should (equal (quoth-test--msg-role (nth 2 msgs)) "tool"))
              (should (string-match-p "<command>ls</command>"
                                      (quoth-test--msg-content (nth 2 msgs))))
              ;; The answer text seeded after the tool block is a trailing
              ;; plain assistant message.
              (should (equal (quoth-test--msg-role (nth 3 msgs)) "assistant"))
              (should (string= (quoth-test--msg-content (nth 3 msgs)) "Listing done"))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-carries-tool-metadata ()
  "Test that the assistant message carries the tool metadata.
It carries the call's id, name, and args from the `quoth-tool-call'
property, and the tool result pairs with the same id."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-tool-exchange
                     "run ls"
                     "Listing done"
                     (list (list :name "bash" :id "call_1"
                                 :args-json "{\"command\":\"ls\"}"
                                 :result "<command>ls</command>\n<output>\nAGENTS.md\n</output>\n<exit_code>0</exit_code>"
                                 :exit 0)))))
            (ignore id)
            (let* ((msgs (quoth--history-turns quoth--prompt-id))
                   (assistant (nth 1 msgs))
                   (tool (nth 2 msgs))
                   (tc (aref (cdr (assoc 'tool_calls assistant)) 0)))
              (should (= (length msgs) 4))
              (should (string= (cdr (assoc 'id tc)) "call_1"))
              (should (string= (cdr (assoc 'name (cdr (assoc 'function tc)))) "bash"))
              (should (string= (cdr (assoc 'arguments (cdr (assoc 'function tc))))
                               "{\"command\":\"ls\"}"))
              (should (string= (cdr (assoc 'tool_call_id tool)) "call_1"))
              (let ((content (quoth-test--msg-content tool)))
                (should (string-match-p "<command>ls</command>" content))
                (should-not (string-match-p "tool:" content)))
              ;; Trailing answer after the tool block.
              (should (equal (quoth-test--msg-role (nth 3 msgs)) "assistant"))
              (should (string= (quoth-test--msg-content (nth 3 msgs)) "Listing done"))))))))

(ert-deftest quoth-test/history-turns-skips-metadataless-tool-span ()
  "A `tool'-typed span without `quoth-tool-call' metadata is skipped.
It contributes no message: the server can pair a `role: \"tool\"' result
only with a matching assistant `tool_calls' declaration, and a bare
message with no call id has none."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (let ((start (point)))
            (insert "run ls")
            (put-text-property start (point) 'quoth-region-type 'user)
            (put-text-property start (point) 'quoth-prompt-id quoth--prompt-id))
          (goto-char (point-max))
          (newline)
          (let ((response-start (point)))
            (let ((inhibit-modification-hooks t))
              (insert "**tool block**\nraw")
              (put-text-property response-start (point)
                                 'quoth-region-type 'tool)
              (put-text-property response-start (point) 'quoth-prompt-id quoth--prompt-id)
              (put-text-property response-start (point) 'quoth-response-to quoth--prompt-id))
            (quoth--tag-response-region response-start (point) quoth--prompt-id))
          (goto-char (point-max))
          (newline)
          (delete-region (1- (point)) (point))
          (setq-local quoth--prompt-id (quoth--generate-id))
          (quoth--insert-input-separator)
          (let* ((msgs (quoth--history-turns quoth--prompt-id))
                 (roles (mapcar #'quoth-test--msg-role msgs)))
            ;; Only the user message survives; the tool span is skipped.
            (should (equal roles '("user")))
            (should-not (cl-find "tool" msgs
                                 :key #'quoth-test--msg-role :test #'string=)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-includes-multiple-exchanges ()
  "Two completed exchanges both appear, oldest first."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((_id1 (quoth-test--seed-exchange "first prompt" "first reply"))
                (_id2 (quoth-test--seed-exchange "second prompt" "second reply")))
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 4))
              (should (equal (quoth-test--msg-role (nth 0 msgs)) "user"))
              (should (equal (quoth-test--msg-content (nth 0 msgs)) "first prompt"))
              (should (equal (quoth-test--msg-role (nth 1 msgs)) "assistant"))
              (should (equal (quoth-test--msg-content (nth 1 msgs)) "first reply"))
              (should (equal (quoth-test--msg-role (nth 2 msgs)) "user"))
              (should (equal (quoth-test--msg-content (nth 2 msgs)) "second prompt"))
              (should (equal (quoth-test--msg-role (nth 3 msgs)) "assistant"))
              (should (equal (quoth-test--msg-content (nth 3 msgs)) "second reply"))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-omits-unanswered-prompt-text ()
  "An unanswered prompt contributes its user text but no assistant turn."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (quoth-test--seed-exchange "first prompt" "first reply")))
            (goto-char (point-max))
            (insert "second prompt")
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (ignore id1)
              (should (= (length msgs) 2))
              (should (equal (quoth-test--msg-content (car msgs)) "first prompt"))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-user-text-skips-response-region ()
  "The user message never leaks the assistant reply text.
The response region shares the `quoth-prompt-id' tag."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((completed-id (quoth-test--seed-exchange "hello" "answer text")))
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (ignore completed-id)
              (should (equal (quoth-test--msg-content (car msgs)) "hello"))
              (should (equal (quoth-test--msg-content (cadr msgs)) "answer text"))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/user-turn-text-excludes-separator ()
  "Test that the user turn text excludes the separator line.
`quoth--user-turn-text' returns the typed input only."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (let ((start (point)))
            (insert "hello world")
            (put-text-property start (point) 'quoth-region-type 'user)
            (put-text-property start (point) 'quoth-prompt-id quoth--prompt-id))
          (should (equal (quoth--user-turn-text quoth--prompt-id)
                         "hello world"))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/user-turn-text-includes-appended-input ()
  "`quoth--user-turn-text' returns typed input plus appended content.
Content appended via `quoth--append-as-user-input' is tagged `user',
so extraction reads it back as part of the turn."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (goto-char (point-max))
            (let ((start (point)))
              (insert "hello")
              (put-text-property start (point) 'quoth-region-type 'user)
              (put-text-property start (point) 'quoth-prompt-id quoth--prompt-id))
            (quoth--append-as-user-input buf "```emacs-lisp\n(code)\n```")
            (let ((text (quoth--user-turn-text quoth--prompt-id)))
              (should (string-match-p "hello" text))
              (should (string-match-p "(code)" text)))))
      (quoth-test--cleanup))))

;; Helper: seed an exchange whose response carries a reasoning span.
(defun quoth-test--seed-reasoning-exchange (prompt-text reasoning-text answer-text)
  "Seed an exchange whose response carries a reasoning span.
Types PROMPT-TEXT and tags it `user' explicitly (no after-change hook);
streams REASONING-TEXT then ANSWER-TEXT as one response, tagged as the
streaming machinery tags it (reasoning span over the CoT, response for
the answer).  Returns the prompt ID."
  (let ((prompt-id quoth--prompt-id))
    (goto-char (point-max))
    (let ((start (point)))
      (insert prompt-text)
      (put-text-property start (point) 'quoth-region-type 'user)
      (put-text-property start (point) 'quoth-prompt-id prompt-id))
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      (insert reasoning-text "\n\n" answer-text)
      ;; Tag the whole response, then re-tag the CoT span as reasoning.
      (quoth--tag-response-region response-start (point) prompt-id)
      (let ((inhibit-modification-hooks t)
            (rs (+ response-start (length reasoning-text))))
        (put-text-property response-start rs 'quoth-region-type 'reasoning)))
    (goto-char (point-max))
    ;; Anticipate the newline the separator insertion would leave; it
    ;; must not become part of the user turn.
    (when (eq (char-before (point)) ?\n)
      (delete-region (1- (point)) (point)))
    (setq-local quoth--prompt-id (quoth--generate-id))
    (quoth--insert-input-separator)
    prompt-id))

(ert-deftest quoth-test/history-turns-excludes-reasoning-by-default ()
  "By default the assistant message carries only the answer text.
Here `quoth-hyper-history-include-reasoning' is nil, so the CoT span is
dropped."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-reasoning-exchange
                     "question" "step one\nstep two" "final answer")))
            (ignore id)
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (quoth-test--msg-content (car msgs)) "question"))
              (should (equal (quoth-test--msg-content (cadr msgs)) "final answer"))))))
    (quoth-test--cleanup)))

;; Helper: seed an exchange with a multi-round tool loop.  Round 1
;; streams reasoning then content then inserts a tool block; round 2
;; streams reasoning then content.  Tagged exactly as the tool loop
;; tags it via `quoth--tag-response-region' after each round.
(defun quoth-test--seed-tool-loop-exchange (prompt-text r1-reasoning r1-content
                                                        tool-calls r2-reasoning r2-content)
  "Seed a two-round tool-loop exchange for PROMPT-TEXT.
Round 1 streams R1-REASONING then R1-CONTENT then TOOL-CALLS (a list
of plists rendered as tool blocks); round 2 streams R2-REASONING then
R2-CONTENT.  Returns the completed prompt's ID."
  (let ((prompt-id quoth--prompt-id))
    (goto-char (point-max))
    (insert prompt-text)
    (goto-char (point-max))
    (newline)
    (let ((response-start (point)))
      ;; Round 1: reasoning, content, then the tool block.
      (setq-local quoth--response-start (point-marker))
      (quoth--append-delta r1-reasoning 'reasoning)
      (quoth--append-delta r1-content 'content)
      (dolist (tc tool-calls)
        (quoth--tool-block-insert tc prompt-id))
      (quoth--tag-response-region (marker-position quoth--response-start)
                                  (point-max) prompt-id)
      (quoth--reasoning-reset)
      ;; Round 2: final reasoning and content, no more tools.
      (setq-local quoth--response-start (point-marker))
      (quoth--append-delta r2-reasoning 'reasoning)
      (quoth--append-delta r2-content 'content)
      (quoth--tag-response-region (marker-position quoth--response-start)
                                  (point-max) prompt-id)
      (quoth--reasoning-reset))
    (goto-char (point-max))
    (when (eq (char-before (point)) ?\n)
      (delete-region (1- (point)) (point)))
    (setq-local quoth--prompt-id (quoth--generate-id))
    (quoth--insert-input-separator)
    prompt-id))

(ert-deftest quoth-test/tool-rounds-no-spurious-unknown-tool ()
  "Test that a multi-round tool exchange emits one message per round.
Each round contributes exactly its assistant `tool_calls' + `tool'
pair and nothing between rounds; every tool message carries a real
call id from the block's `quoth-tool-call' property."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-tool-loop-exchange
                     "push to remotes"
                     "The user wants to push this to remotes."
                     "You have two remotes: `github` and `origin`."
                     (list (list :name "exec_command" :id "call_1"
                                 :args-json "{\"cmd\":\"git remote -v\"}"
                                 :result "github\tgit@github.com:chestso/quoth.git"
                                 :exit 0))
                     "GitHub pushed successfully."
                     "GitHub pushed. Now to Codeberg")))
            (let ((msgs (quoth--tool-rounds id)))
              (should (= (length msgs) 3))
              ;; assistant(tool_calls) + tool pair, then the final
              ;; plain assistant answer; no `unknown' tool message.
              (should (equal (quoth-test--msg-role (nth 0 msgs)) "assistant"))
              (should (equal (quoth-test--msg-role (nth 1 msgs)) "tool"))
              (should (string= (cdr (assoc 'tool_call_id (nth 1 msgs))) "call_1"))
              (should (equal (quoth-test--msg-role (nth 2 msgs)) "assistant"))
              (should (string-match-p "Now to Codeberg"
                                      (quoth-test--msg-content (nth 2 msgs))))
              (should-not (cl-find "unknown" msgs
                                   :key (lambda (m) (cdr (assoc 'tool_call_id m)))
                                   :test #'string=))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/tool-rounds-reasoning-stays-reasoning ()
  "Test that second-round reasoning stays tagged as reasoning.
The span must stay tagged `reasoning', not be overwritten to
`response' by the round's re-tag.

When reasoning was overwritten, history replay folded the CoT into the
assistant content and, combined with the fence bug, emitted it as a
spurious tool result."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-tool-loop-exchange
                     "push to remotes"
                     "R1 reasoning"
                     "R1 content"
                     (list (list :name "exec_command" :id "call_1"
                                 :args-json "{\"cmd\":\"git status\"}"
                                 :result "nothing to commit" :exit 0))
                     "R2 reasoning"
                     "R2 final answer")))
            (let ((msgs (quoth--tool-rounds id)))
              (should (= (length msgs) 3))
              ;; Final assistant message must carry only the answer,
              ;; never the CoT text.
              (let ((final (quoth-test--msg-content (nth 2 msgs))))
                (should (string-match-p "R2 final answer" final))
                (should-not (string-match-p "R2 reasoning" final))))
            ;; The reasoning spans themselves must be tagged reasoning.
            (let ((pos (point-min)))
              (while (< pos (point-max))
                (let ((type (get-text-property pos 'quoth-region-type))
                      (end (or (next-single-property-change pos 'quoth-region-type
                                                            nil (point-max))
                               (point-max))))
                  (when (eq type 'response)
                    (should-not (string-match-p "R2 reasoning"
                                                (buffer-substring-no-properties
                                                 pos (min end (+ pos 40))))))
                  (setq pos end)))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-reasoning-fold-keeps-final-summary ()
  "Test that a reasoning fold keeps the final summary in replay.
A fold between a tool round and the final summary must not drop the
summary from replay.  The fold marker is a display-only
`before-string' on the body overlay, so the reasoning region is
contiguous in the buffer and `quoth--tool-rounds' sees the full
response."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Seed a tool round, then reasoning long enough to fold
          ;; (> `quoth-reasoning-preview-lines' lines), then a summary.
          (goto-char (point-max))
          (insert "what is this file?")
          (goto-char (line-end-position))
          (newline)
          (quoth--insert-user-separator)
          (setq-local quoth--response-start (point-marker))
          (let ((pid quoth--prompt-id))
            (let ((proc (make-pipe-process :name "quoth-fold-replay"
                                           :noquery t :coding 'binary)))
              (process-put proc :quoth-target (current-buffer))
              (quoth--append-delta "Let me check the file." 'reasoning)
              (quoth--tool-block-insert
               (list :name "exec_command" :id "call_1"
                     :args-json "{\"cmd\":\"head -100 quoth.el\"}"
                     :result "Process exited with code 0\nOutput:\n;;; header"
                     :exit 0)
               pid)
              (quoth--tag-response-region (marker-position quoth--response-start)
                                          (point-max) pid)
              (quoth--reasoning-reset)
              (setq-local quoth--response-start (point-marker))
              (quoth--append-delta
               (mapconcat #'identity (make-list 11 "think hard.") "\n")
               'reasoning)
              (quoth--append-delta "FINAL SUMMARY" 'content)
              (quoth--finalize-response)
              (delete-process proc))
            (let* ((msgs (quoth--tool-rounds pid))
                   (last-msg (car (last msgs)))
                   (roles (mapcar (lambda (m) (cdr (assoc 'role m))) msgs)))
              ;; Two tool rounds' worth: assistant(tool_calls) + tool,
              ;; then a trailing assistant with the final summary.
              (should (equal roles
                             '("assistant" "tool" "assistant")))
              (should (string= (quoth-test--msg-content last-msg) "FINAL SUMMARY"))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/history-turns-splits-reasoning-when-enabled ()
  "Test that reasoning is split out when history includes reasoning.
The assistant message gains a reasoning_content field holding the CoT
text."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (quoth-hyper-history-include-reasoning t))
        (with-current-buffer buf
          (let ((id (quoth-test--seed-reasoning-exchange
                     "question" "step one\nstep two" "final answer")))
            (ignore id)
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (quoth-test--msg-content (car msgs)) "question"))
              (should (equal (quoth-test--msg-content (cadr msgs)) "final answer"))
              (should (equal (cdr (assoc 'reasoning_content (cadr msgs)))
                             "step one\nstep two"))))))
    (quoth-test--cleanup)))
(ert-deftest quoth-test/history-limit-caps-turns ()
  "`quoth-hyper-history-limit' caps the prior exchanges; the tail stays."
  (let ((quoth-hyper-history-limit 1))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((_id1 (quoth-test--seed-exchange "first" "one")))
              (let ((_id2 (quoth-test--seed-exchange "second" "two")))
                (let ((msgs (quoth--history-turns quoth--prompt-id)))
                  (should (= (length msgs) 2))
                  (should (equal (quoth-test--msg-content (car msgs)) "second"))
                  (should (equal (quoth-test--msg-content (cadr msgs)) "two")))))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/history-limit-zero-disables ()
  "`quoth-hyper-history-limit' 0 means no history at all."
  (let ((quoth-hyper-history-limit 0))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((_id1 (quoth-test--seed-exchange "first" "one")))
              (should (null (quoth--history-turns quoth--prompt-id))))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/history-turns-always-fresh ()
  "Extraction reads the live buffer; no cache can go stale."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (let ((id1 (quoth-test--seed-exchange "first" "reply")))
            (let ((msgs (quoth--history-turns quoth--prompt-id)))
              (should (= (length msgs) 2))
              (should (equal (quoth-test--msg-content (car msgs)) "first"))
              (should (equal (quoth-test--msg-content (cadr msgs)) "reply")))
            ;; Editing a completed region is reflected immediately.
            (let ((rs (text-property-any (point-min) (point-max)
                                         'quoth-response-to id1)))
              (delete-region rs (1+ rs)))
            (should-not (equal (quoth--history-turns quoth--prompt-id)
                               (list (list (cons 'role "user") (cons 'content "first"))
                                     (list (cons 'role "assistant") (cons 'content "reply"))))))))
    (quoth-test--cleanup)))

;;; 100. Undo: programmatic changes are not undoable

(ert-deftest quoth-test/undo-init-leaves-empty-list ()
  "Fresh buffer init should leave an empty undo list."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null buffer-undo-list))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/undo-user-typing-records-entries ()
  "User typing at the prompt should be recorded in the undo list."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null buffer-undo-list))
          (goto-char (point-max))
          (insert "hello")
          (should buffer-undo-list)
          (should (consp buffer-undo-list))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/undo-response-cycle-not-recorded ()
  "Stream deltas, finalize, and prompt insertion should not record undo."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null buffer-undo-list))
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          ;; Clear undo entries from the setup typing so we can test
          ;; that the response cycle alone records nothing.
          (setq buffer-undo-list nil)
          (quoth-test--simulate-response "response text")
          ;; Programmatic changes should not have recorded undo.
          (should (null buffer-undo-list))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/undo-after-response-user-typing-is-undoable ()
  "User typing after a response cycle should still be undoable."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          (setq buffer-undo-list nil)
          (quoth-test--simulate-response "response text")
          (should (null buffer-undo-list))
          (goto-char (point-max))
          (insert "new input")
          (should buffer-undo-list)
          (should (consp buffer-undo-list))))
    (quoth-test--cleanup)))

;;; Stale-tagged user text is retagged at send time

(ert-deftest quoth-test/send-input-retags-stale-user-text ()
  "quoth-send-input tags the input region as 'user even when the text
inherited stale tags (e.g. yank, undo) from the divider."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (second-id nil))
        (with-current-buffer buf
          ;; Send a first prompt to get a second prompt area.
          (goto-char (point-max))
          (insert "first prompt")
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc)))
              (quoth-send-input))
            (quoth-test--with-immediate-schedule
             (funcall (quoth-provider-completion-action
                       quoth-active-provider)))
            (when (process-live-p fake-proc)
              (delete-process fake-proc)))
          ;; second-id is the new prompt (created by finalize).
          (setq second-id quoth--prompt-id)
          ;; Simulate stale tags: insert multi-line text and corrupt
          ;; its region-type to 'separator (as would happen if text
          ;; inherited properties from a yank-undo into the separator).
          (goto-char (point-max))
          (insert "line one\nline two\nline three")
          (let ((input-start (marker-position quoth--input-start-marker))
                (inhibit-modification-hooks t))
            (put-text-property input-start (point-max)
                               'quoth-region-type 'separator))
          ;; Verify the text is stale before send.
          (should (eq (get-text-property
                       (marker-position quoth--input-start-marker)
                       'quoth-region-type)
                      'separator))
          ;; Send the stale-tagged input.
          (let ((fake-proc (quoth-test--live-pipe-proc)))
            (set-process-buffer fake-proc (current-buffer))
            (cl-letf (((symbol-function #'make-process)
                       (lambda (&rest _) fake-proc)))
              (quoth-send-input))
            (when (process-live-p fake-proc)
              (delete-process fake-proc))))
        ;; History reconstruction sees the multi-line text as user input.
        (with-current-buffer buf
          (should (string-match "line one"
                                (quoth--user-turn-text second-id)))))
    (quoth-test--cleanup)))

;;; 20b. Usage accumulation

(ert-deftest quoth-test/merge-usage-sums-two-rounds ()
  "Two per-request usage plists accumulate into one.
The the core sums :input-tokens, :output-tokens, :cached-tokens, and
:cost-value; :cost-unit is taken from the first round and preserved."
  (let* ((round1 (list :input-tokens 8846
                       :output-tokens 311
                       :cached-tokens 0
                       :cost-unit "hc"
                       :cost-value 0.27852))
         (round2 (list :input-tokens 8923
                       :output-tokens 68
                       :cached-tokens 8320
                       :cost-unit "hc"
                       :cost-value 0.0432696))
         (acc (quoth--merge-usage nil round1))
         (acc2 (quoth--merge-usage acc round2)))
    (should (= (plist-get acc :input-tokens) 8846))
    (should (= (plist-get acc :output-tokens) 311))
    (should (= (plist-get acc :cost-value) 0.27852))
    (should (= (plist-get acc2 :input-tokens) 17769))
    (should (= (plist-get acc2 :output-tokens) 379))
    (should (= (plist-get acc2 :cached-tokens) 8320))
    (should (string= (plist-get acc2 :cost-unit) "hc"))
    (should (= (plist-get acc2 :cost-value) (+ 0.27852 0.0432696)))))

(ert-deftest quoth-test/merge-usage-preserves-first-cost-unit ()
  "The :cost-unit from the first round is preserved across merges."
  (let* ((round1 (list :input-tokens 60 :output-tokens 40
                       :cost-unit "hc" :cost-value 0.1))
         (round2 (list :input-tokens 90 :output-tokens 110
                       :cost-unit "X" :cost-value 0.2))
         (acc (quoth--merge-usage (quoth--merge-usage nil round1) round2)))
    (should (string= (plist-get acc :cost-unit) "hc"))
    (should (= (plist-get acc :input-tokens) 150))
    (should (= (plist-get acc :output-tokens) 150))))

(ert-deftest quoth-test/accumulate-usage-sums-per-request ()
  "quoth--accumulate-usage reads from the provider and sums."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let* ((usage-alist (list (cons "prompt_tokens" 60)
                                    (cons "completion_tokens" 40)
                                    (cons "cost" (list (cons "hypercredits" 0.5)))))
                 (proc (make-pipe-process :name "fake" :noquery t))
                 (provider quoth-active-provider))
            (process-put proc :quoth-sse (list :usage usage-alist))
            (setf (quoth-provider-request provider)
                  (list :stage-process nil :curl proc :done-p t))
            (setq-local quoth--usage-acc nil)
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 60))
            (should (= (plist-get quoth--usage-acc :output-tokens) 40))
            (should (= (plist-get quoth--usage-acc :cost-value) 0.5))
            (process-put proc :quoth-sse
                         (list :usage
                               (list (cons "prompt_tokens" 150)
                                     (cons "completion_tokens" 110)
                                     (cons "cost"
                                           (list (cons "hypercredits" 0.3))))))
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 210))
            (should (= (plist-get quoth--usage-acc :output-tokens) 150))
            (should (= (plist-get quoth--usage-acc :cost-value) 0.8))
            (delete-process proc)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/accumulate-usage-takes-accumulated-verbatim ()
  "When :accumulated is t, the send loop takes values verbatim (no sum)."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let* ((provider quoth-active-provider)
                 (proc (make-pipe-process :name "fake2" :noquery t))
                 (orig-fn (symbol-function 'quoth-provider--usage)))
            (setf (quoth-provider-request provider)
                  (list :stage-process nil :curl proc :done-p t))
            (fset 'quoth-provider--usage
                  (lambda (_p _proc)
                    (list :input-tokens 999
                          :output-tokens 111
                          :cost-unit "X"
                          :cost-value 1.5
                          :accumulated t)))
            (setq-local quoth--usage-acc nil)
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 999))
            (should (= (plist-get quoth--usage-acc :output-tokens) 111))
            (should (= (plist-get quoth--usage-acc :cost-value) 1.5))
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 999))
            (should (= (plist-get quoth--usage-acc :output-tokens) 111))
            (should (= (plist-get quoth--usage-acc :cost-value) 1.5))
            (fset 'quoth-provider--usage orig-fn)
            (delete-process proc)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/accumulate-usage-persists-across-prompts ()
  "quoth--accumulate-usage is session-cumulative: a new prompt's usage
is ADDED to the prior prompt's total, not reset.  The only reset is
`quoth-clear-buffer'."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let* ((usage-alist (list (cons "prompt_tokens" 60)
                                    (cons "completion_tokens" 40)
                                    (cons "cost" (list (cons "hypercredits" 0.5)))))
                 (proc (make-pipe-process :name "fake" :noquery t))
                 (provider quoth-active-provider))
            (process-put proc :quoth-sse (list :usage usage-alist))
            (setf (quoth-provider-request provider)
                  (list :stage-process nil :curl proc :done-p t))
            ;; First prompt accumulates.
            (setq-local quoth--prompt-id "p1")
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 60))
            ;; A new prompt's usage is ADDED to the running session total.
            (setq-local quoth--prompt-id "p2")
            (process-put proc :quoth-sse
                         (list :usage
                               (list (cons "prompt_tokens" 150)
                                     (cons "completion_tokens" 110)
                                     (cons "cost"
                                           (list (cons "hypercredits" 0.3))))))
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 210))
            (should (= (plist-get quoth--usage-acc :output-tokens) 150))
            (should (= (plist-get quoth--usage-acc :cost-value) 0.8))
            (delete-process proc)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/accumulate-usage-keeps-same-prompt ()
  "Same prompt ID accumulates across rounds without resetting."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let* ((usage-alist (list (cons "prompt_tokens" 60)
                                    (cons "completion_tokens" 40)
                                    (cons "cost" (list (cons "hypercredits" 0.5)))))
                 (proc (make-pipe-process :name "fake" :noquery t))
                 (provider quoth-active-provider))
            (process-put proc :quoth-sse (list :usage usage-alist))
            (setf (quoth-provider-request provider)
                  (list :stage-process nil :curl proc :done-p t))
            (setq-local quoth--prompt-id "p1")
            (quoth--accumulate-usage)
            (process-put proc :quoth-sse
                         (list :usage
                               (list (cons "prompt_tokens" 150)
                                     (cons "completion_tokens" 110)
                                     (cons "cost"
                                           (list (cons "hypercredits" 0.3))))))
            (quoth--accumulate-usage)
            (should (= (plist-get quoth--usage-acc :input-tokens) 210))
            (should (= (plist-get quoth--usage-acc :output-tokens) 150))
            (delete-process proc)))
      (quoth-test--cleanup))))

;;; 18b. Header line: usage segment

(ert-deftest quoth-test/header-line-shows-no-usage-before-response ()
  "Before any response, the header has no usage segment."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--usage-acc nil)
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string= h "(my-model  -)")))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-line-shows-usage-after-accumulation ()
  "After usage is accumulated, the header shows in/out tokens, cost,
and cache percentage.  Input and output tokens are shown separately
(\='^\=' prefixed arrows), and the cache percentage divides cached by
INPUT tokens only."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--usage-acc
                        (list :input-tokens 8923
                              :output-tokens 68
                              :cached-tokens 8320
                              :cost-unit "hc"
                              :cost-value 0.0432696))
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              ;; `%%' is the mode-line escape for a literal `%' (the raw
              ;; header-line-format string stores the escaped form).
              (should (string= h
                               "(my-model  \u21918.9k \u219368 hc0.043 93%%  -)")))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-line-shows-dollars-when-currency-dollars ()
  "With dollars currency, the header shows $ instead of hc."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--usage-acc
                        (list :input-tokens 8846
                              :output-tokens 311
                              :cached-tokens 0
                              :cost-unit "$"
                              :cost-value 0.013926))
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string= h
                               "(my-model  \u21918.8k \u2193311 $0.0139 0%%  -)")))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-line-cache-percent-divides-input-only ()
  "Cache percentage is cached/input, not cached/(input+output).
The input-based percentage is 50%."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--usage-acc
                        (list :input-tokens 1000
                              :output-tokens 5000
                              :cached-tokens 500
                              :cost-unit "hc"
                              :cost-value 0.01))
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string-match-p "50%%" h))
              (should-not (string-match-p "8%%" h)))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/header-line-no-cache-key-omits-cache-segment ()
  "A usage plist without :cached-tokens omits the cache percentage."
  (let ((quoth-model "my-model"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--usage-acc
                        (list :input-tokens 100
                              :output-tokens 20
                              :cost-unit "hc"
                              :cost-value 0.01))
            (quoth--update-header-line)
            (let ((h (format "%s" header-line-format)))
              (should (string= h
                               "(my-model  \u2191100 \u219320 hc0.010  -)")))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/group-number-compact-formats ()
  "quoth--group-number-compact formats with k/M suffixes."
  (should (string= (quoth--group-number-compact 0) "0"))
  (should (string= (quoth--group-number-compact 999) "999"))
  (should (string= (quoth--group-number-compact 1000) "1.0k"))
  (should (string= (quoth--group-number-compact 8991) "9.0k"))
  (should (string= (quoth--group-number-compact 1000000) "1.0M")))
(ert-deftest quoth-test/history-turns-excludes-system-pane ()
  "A `system'-tagged pane inside a response span is never re-sent.
Even if a `system' region carries `quoth-response-to', history
reconstruction skips it like reasoning/tool text; the interrupted
partial is still included as plain assistant content."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Build a completed prior prompt whose response span contains
          ;; a contiguous system-tagged pane in the middle.
          (let* ((pid quoth--prompt-id)
                 (resp-start nil)
                 (pane-start nil)
                 (pane-end nil)
                 (resp-end nil))
            (let ((us (point-max)))
              (insert "hi")
              (put-text-property us (point) 'quoth-region-type 'user)
              (put-text-property us (point) 'quoth-prompt-id pid))
            (goto-char (point-max)) (newline)
            (setq resp-start (point))
            (insert "partial answer ")
            (setq pane-start (point))
            (insert "> **Error:** boom")
            (setq pane-end (point))
            (insert " tail")
            (setq resp-end (point-max))
            (put-text-property resp-start pane-start
                               'quoth-region-type 'response)
            (put-text-property pane-start pane-end
                               'quoth-region-type 'system)
            (put-text-property pane-end resp-end
                               'quoth-region-type 'response)
            (put-text-property resp-start resp-end 'quoth-response-to pid)
            (put-text-property resp-start resp-end 'quoth-prompt-id pid)
            (put-text-property resp-start resp-end 'quoth-interrupted 'error)
            ;; Rotate to a new pending prompt.
            (setq-local quoth--prompt-id (quoth--generate-id)))
          (let* ((msgs (quoth--history-turns quoth--prompt-id))
                 (all-content (mapconcat 'quoth-test--msg-content msgs "")))
            (should (string-match-p "partial answer" all-content))
            (should-not (string-match-p "boom" all-content)))))
    (quoth-test--cleanup)))

(provide 'quoth-test-buffer)
;;; quoth-test-buffer.el ends here
