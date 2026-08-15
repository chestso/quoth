;;; crush-test-commands.el --- Command and insertion tests for crush  -*- lexical-binding: t; -*-
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
;;; crush-minor-mode and crush-chat-mode keymaps, attachment insertion and formatting.

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

;;; 8. Selection insertion during running process

(ert-deftest crush-test/insert-selection-works-while-process-running ()
  "`crush-insert-selection' should work even when `crush-process' is non-nil."
  (let ((default-directory crush-test--root))
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

;;; Minor mode

(ert-deftest crush-test/minor-mode-defined ()
  "Crush-minor-mode should be defined as a minor mode."
  (should (boundp 'crush-minor-mode))
  (should (fboundp 'crush-minor-mode)))

(ert-deftest crush-test/minor-mode-keymap-has-bindings ()
  "Crush-minor-mode-map should have the expected keybindings."
  (let ((map (symbol-value 'crush-minor-mode-map)))
    (should (keymapp map))
    (should (eq (lookup-key map (kbd "C-c C-s")) #'crush-insert-selection))
    (should (eq (lookup-key map (kbd "C-c C-b")) #'crush-insert-buffer))
    (should (eq (lookup-key map (kbd "C-c C-p")) #'crush-insert-filepath))
    (should (eq (lookup-key map (kbd "C-c C-c")) #'crush))))

(ert-deftest crush-test/minor-mode-toggle ()
  "Crush-minor-mode should toggle on and off in a source buffer."
  (with-temp-buffer
    (insert "hello")
    (should-not crush-minor-mode)
    (crush-minor-mode 1)
    (should crush-minor-mode)
    (crush-minor-mode -1)
    (should-not crush-minor-mode)))

;;; crush-insert-buffer

(ert-deftest crush-test/insert-buffer-inserts-entire-buffer ()
  "Crush-insert-buffer should insert the entire buffer as an org source block."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "line one\nline two\nline three\n")
          (setq-local buffer-file-name "/fake/path/src/foo.el")
          (crush-insert-buffer)
          (with-current-buffer (crush-test--buffer-name)
            (goto-char (point-min))
            ;; File path appears before content in the org block
            (should (search-forward "src/foo.el" nil t))
            (should (search-forward "line one" nil t))
            (should (search-forward "line three" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-buffer-no-file-shows-no-file ()
  "Crush-insert-buffer should show (no file) when buffer has no file."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "content\n")
          (setq-local buffer-file-name nil)
          (crush-insert-buffer)
          (with-current-buffer (crush-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "(no file)" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-buffer-works-while-process-running ()
  "Crush-insert-buffer should work even when a crush process is running."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (progn
          (crush-test--fresh-buffer)
          (with-current-buffer (crush-test--buffer-name)
            (setq-local crush-process (make-process
                                       :name "crush-test-fake"
                                       :buffer (current-buffer)
                                       :command '("sleep" "30")
                                       :connection-type 'pipe
                                       :noquery t)))
          (with-temp-buffer
            (insert "buffer content\n")
            (crush-insert-buffer))
          (with-current-buffer (crush-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "buffer content" nil t))
            (when (process-live-p crush-process)
              (interrupt-process crush-process))
            (setq-local crush-process nil)))
      (crush-test--cleanup))))

;;; crush-insert-filepath

(ert-deftest crush-test/insert-filepath-inserts-path ()
  "Crush-insert-filepath should insert the file path as context."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "some code\n")
          (setq-local buffer-file-name "/fake/path/src/bar.el")
          (crush-insert-filepath)
          (with-current-buffer (crush-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "/fake/path/src/bar.el" nil t))))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-filepath-no-file-errors ()
  "Crush-insert-filepath should error when buffer has no file."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "some code\n")
          (setq-local buffer-file-name nil)
          (should-error (crush-insert-filepath)))
      (crush-test--cleanup))))

(ert-deftest crush-test/insert-filepath-uses-relative-path ()
  "Crush-insert-filepath should use a path relative to project root."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "code\n")
          ;; Set buffer-file-name to something under the cwd
          (setq-local buffer-file-name
                      (expand-file-name "test/crush-mode-test.el"
                                        default-directory))
          (crush-insert-filepath)
          (with-current-buffer (crush-test--buffer-name)
            (goto-char (point-min))
            ;; Should contain a relative path, not absolute
            (should (search-forward "test/crush-mode-test.el" nil t))))
      (crush-test--cleanup))))

;;; crush-insert-selection via minor mode keymap

(ert-deftest crush-test/insert-selection-via-minor-mode-key ()
  "Crush-insert-selection should be callable via the minor mode keybinding."
  (let ((default-directory crush-test--root))
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
          (with-current-buffer (crush-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "selected" nil t)))
          (crush-minor-mode -1))
      (crush-test--cleanup))))

;;; 21. Attachments have attachment-id and prompt-id properties

(ert-deftest crush-test/init-buffer-is-idempotent ()
  "An initialized crush buffer resists re-initialization:
regenerating the prompt ID or clobbering existing state must not happen.
Regression: with markdown-mode as the parent, major-mode is markdown-mode,
not crush-mode, so the old 'eq major-mode' guard failed to detect an
already-initialized buffer and re-initialized it."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((id1 crush--prompt-id)
                  (marker1 crush--prompt-start-marker))
              (crush--init-buffer buf)
              (should (string= id1 crush--prompt-id))
              (should (eq marker1 crush--prompt-start-marker)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/attachment-has-properties ()
  "Inserted attachments should have crush-attachment-id and crush-prompt-id properties."
  (let ((default-directory crush-test--root))
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

;;; 33. Region type tagging: attachment

(ert-deftest crush-test/attachment-region-tagged-as-attachment ()
  "Attachment blocks should be tagged with crush-region-type 'attachment."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            ;; Insert selection from temp buffer
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name "/test/file.el")
              (crush-insert-selection (point-min) (point-max)))
            ;; Check that the attachment has crush-region-type 'attachment
            (goto-char (point-min))
            (should (search-forward "Attachment:" nil t))
            (let ((region-type (get-text-property (match-beginning 0) 'crush-region-type)))
              (should (eq region-type 'attachment)))))
      (crush-test--cleanup))))

;;; 37. Attachment formatting: markdown fenced blocks

(ert-deftest crush-test/format-selection-emits-fenced-block ()
  "`crush--format-selection' emits a markdown fenced code block.
The block carries an Attachment header line."
  (let ((buf (crush-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((formatted (crush--format-selection "src/file.el" (point-min) (point-max))))
            (should (string-match-p "\\*\\*Attachment: src/file.el (lines 1-1)\\*\\*" formatted))
            (should (string-match-p "```emacs-lisp" formatted))
            (should (string-match-p "```" formatted))))
      (crush-test--cleanup))))

(ert-deftest crush-test/format-selection-uses-relative-path ()
  "Attachment paths are relative to the project root (or `default-directory')."
  (let ((buf (crush-test--fresh-buffer))
        (crush-working-directory "/tmp/proj"))
    (unwind-protect
        (with-current-buffer buf
          (setq-local default-directory "/tmp/proj/")
          (let ((formatted (crush--format-selection "/tmp/proj/src/file.el" 1 5)))
            (should (string-match-p "src/file.el" formatted))
            (should-not (string-match-p "/tmp/proj/src" formatted))))
      (crush-test--cleanup))))

(ert-deftest crush-test/format-selection-no-file ()
  "Crush--format-selection without a file should use (no file)."
  (let ((buf (crush-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((formatted (crush--format-selection nil 1 5)))
            (should (string-match-p "(no file)" formatted))))
      (crush-test--cleanup))))

;;; 37b. Attachment language from extension

(ert-deftest crush-test/lang-from-extension ()
  "Crush--lang-from-extension should map extensions to markdown languages."
  (let ((buf (crush-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (string= (crush--lang-from-extension "file.el") "emacs-lisp"))
          (should (string= (crush--lang-from-extension "file.go") "go"))
          (should (string= (crush--lang-from-extension "file.yaml") "yaml"))
          (should (string= (crush--lang-from-extension "file.yml") "yaml"))
          (should (string= (crush--lang-from-extension "foo.unknown")
                           "plaintext")))
      (crush-test--cleanup))))

;;; 38. Attachment text properties

(ert-deftest crush-test/attachment-has-filename-lines-properties ()
  "Inserted attachments carry `crush-filename' and `crush-lines'.
These live on the header line, relative to the project root."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (with-temp-buffer
              (insert "selected code\n")
              (setq-local buffer-file-name
                          (expand-file-name "src/file.el" default-directory))
              (crush-insert-selection (point-min) (point-max)))
            (goto-char (point-min))
            (should (search-forward "Attachment:" nil t))
            (should (string= (get-text-property (match-beginning 0) 'crush-filename) "src/file.el"))
            (should (string= (get-text-property (match-beginning 0) 'crush-lines) "1-2"))))
      (crush-test--cleanup))))

;;; 39. Filepath attachment (link form)

(ert-deftest crush-test/insert-filepath-emits-link ()
  "`crush-insert-filepath' inserts a markdown link attachment.
It sets crush-region-type 'attachment and a project-root-relative path."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (let ((project-root default-directory))
            (with-current-buffer buf
              (with-temp-buffer
                (setq-local buffer-file-name (expand-file-name "file.go" project-root))
                (crush-insert-filepath))
              (goto-char (point-min))
              (should (search-forward "[file.go](file.go)" nil t))
              (let ((region-type (get-text-property (match-beginning 0) 'crush-region-type)))
                (should (eq region-type 'attachment)))
              (should (string= (get-text-property (match-beginning 0) 'crush-filename) "file.go")))))
      (crush-test--cleanup))))

(ert-deftest crush-test/sentinel-no-longer-fontifies ()
  "Finalize should tag the response but create no overlays."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local crush--response-start (point-marker))
          ;; Stream content through the facade, then finalize.
          (goto-char (point-max))
          (setq-local crush--response-start (point-marker))
          (crush-facade--append-delta "**bold** text" 'content)
          (crush-facade--finalize)
          (goto-char (point-min))
          (should (search-forward "bold" nil t))
          ;; Finalize must create no crush overlays.
          (should-not (cl-some (lambda (ov) (overlay-get ov 'crush-overlay))
                               (overlays-in (point-min) (point-max))))
          ;; The response is still tagged
          (should (eq (get-text-property (match-beginning 0) 'crush-region-type) 'response))))
    (crush-test--cleanup)))

;;; 41. Integration: attachment insertion does not fontify

(ert-deftest crush-test/insert-selection-creates-no-overlays ()
  "Inserting a selection should not create crush overlays."
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
            ;; No crush overlays from attachment insertion
            (should-not (cl-some (lambda (ov) (overlay-get ov 'crush-overlay))
                                 (overlays-in (point-min) (point-max))))))
      (crush-test--cleanup))))

;;; crush-chat-mode minor mode

(ert-deftest crush-test/chat-mode-is-defined ()
  "Crush-chat-mode should be defined as a minor mode."
  (should (boundp 'crush-chat-mode))
  (should (fboundp 'crush-chat-mode)))

(ert-deftest crush-test/chat-mode-enabled-in-crush-buffer ()
  "Crush-chat-mode should be enabled in crush buffers."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush-chat-mode)))
    (crush-test--cleanup)))

(ert-deftest crush-test/chat-mode-has-keymap ()
  "Crush-chat-mode-map should have the expected keybindings.
All commands live under the `C-c c' prefix so they do not conflict
with markdown-mode's `C-c C-*' bindings."
  (let ((map (symbol-value 'crush-chat-mode-map))
        (cmd (symbol-value 'crush-chat-command-map)))
    (should (keymapp map))
    (should (eq (lookup-key map (kbd "RET")) #'crush-send-input))
    (should (eq (lookup-key map (kbd "C-c c")) cmd))
    (should (eq (lookup-key cmd (kbd "s")) #'crush-send-input))
    (should (eq (lookup-key cmd (kbd "i")) #'crush-interrupt))
    (should (eq (lookup-key cmd (kbd "k")) #'crush-clear-buffer))
    (should (eq (lookup-key cmd (kbd "a")) #'crush-insert-selection))
    ;; markdown-mode's C-c C-* bindings must not be shadowed.
    (should-not (lookup-key map (kbd "C-c C-c")))
    (should-not (lookup-key map (kbd "C-c C-k")))
    (should-not (lookup-key map (kbd "C-c C-s")))
    (should-not (lookup-key map (kbd "C-c C-i")))
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
  "`crush-chat-mode' adds `crush--after-change' to `after-change-functions'."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (memq #'crush--after-change after-change-functions))))
    (crush-test--cleanup)))

(ert-deftest crush-test/chat-mode-adds-post-command-hook ()
  "`crush-chat-mode' adds `crush--update-header-line' to `post-command-hook'."
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

(provide 'crush-test-commands)
;;; crush-test-commands.el ends here
