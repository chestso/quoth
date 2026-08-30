;;; quoth-test-commands.el --- Command and insertion tests for quoth  -*- lexical-binding: t; -*-
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
;;; quoth-minor-mode and quoth-chat-mode keymaps, attachment insertion and formatting.

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

;;; 8. Selection insertion during running process

(ert-deftest quoth-test/insert-selection-works-while-process-running ()
  "`quoth-insert-selection' should work even while the provider is active.
Context insertion does not touch the transport."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setf (quoth-provider-transport-process quoth-active-provider)
                  (make-process
                   :name "quoth-test-fake"
                   :buffer buf
                   :command '("sleep" "30")
                   :connection-type 'pipe
                   :noquery t)))
          ;; Use a temp buffer as the source
          (with-temp-buffer
            (insert "some selected code\n")
            (quoth-insert-selection (point-min) (point-max)))
          ;; The selection should have been inserted into the quoth buffer
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "some selected code" nil t))
            (quoth-provider-cleanup quoth-active-provider)))
      (quoth-test--cleanup))))

;;; Minor mode

(ert-deftest quoth-test/minor-mode-defined ()
  "Quoth-minor-mode should be defined as a minor mode."
  (should (boundp 'quoth-minor-mode))
  (should (fboundp 'quoth-minor-mode)))

(ert-deftest quoth-test/minor-mode-keymap-has-bindings ()
  "Quoth-minor-mode-map should have the expected keybindings."
  (let ((map (symbol-value 'quoth-minor-mode-map)))
    (should (keymapp map))
    (should (eq (lookup-key map (kbd "C-c C-s")) #'quoth-insert-selection))
    (should (eq (lookup-key map (kbd "C-c C-b")) #'quoth-insert-buffer))
    (should (eq (lookup-key map (kbd "C-c C-p")) #'quoth-insert-filepath))
    (should (eq (lookup-key map (kbd "C-c C-c")) #'quoth))))

(ert-deftest quoth-test/minor-mode-toggle ()
  "Quoth-minor-mode should toggle on and off in a source buffer."
  (with-temp-buffer
    (insert "hello")
    (should-not quoth-minor-mode)
    (quoth-minor-mode 1)
    (should quoth-minor-mode)
    (quoth-minor-mode -1)
    (should-not quoth-minor-mode)))

;;; quoth-insert-buffer

(ert-deftest quoth-test/insert-buffer-inserts-entire-buffer ()
  "Quoth-insert-buffer should insert the entire buffer as an org source block."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "line one\nline two\nline three\n")
          (setq-local buffer-file-name "/fake/path/src/foo.el")
          (quoth-insert-buffer)
          (with-current-buffer (quoth-test--buffer-name)
            (goto-char (point-min))
            ;; File path appears before content in the org block
            (should (search-forward "src/foo.el" nil t))
            (should (search-forward "line one" nil t))
            (should (search-forward "line three" nil t))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/insert-buffer-no-file-shows-no-file ()
  "Quoth-insert-buffer should show (no file) when buffer has no file."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "content\n")
          (setq-local buffer-file-name nil)
          (quoth-insert-buffer)
          (with-current-buffer (quoth-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "(no file)" nil t))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/insert-buffer-works-while-process-running ()
  "Quoth-insert-buffer should work even when a quoth process is running."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (progn
          (quoth-test--fresh-buffer)
          (with-current-buffer (quoth-test--buffer-name)
            (setf (quoth-provider-transport-process quoth-active-provider)
                  (make-process
                   :name "quoth-test-fake"
                   :buffer (current-buffer)
                   :command '("sleep" "30")
                   :connection-type 'pipe
                   :noquery t)))
          (with-temp-buffer
            (insert "buffer content\n")
            (quoth-insert-buffer))
          (with-current-buffer (quoth-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "buffer content" nil t))
            (quoth-provider-cleanup quoth-active-provider)))
      (quoth-test--cleanup))))

;;; quoth-insert-filepath

(ert-deftest quoth-test/insert-filepath-inserts-path ()
  "Quoth-insert-filepath should insert the file path as context."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "some code\n")
          (setq-local buffer-file-name "/fake/path/src/bar.el")
          (quoth-insert-filepath)
          (with-current-buffer (quoth-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "/fake/path/src/bar.el" nil t))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/insert-filepath-no-file-errors ()
  "Quoth-insert-filepath should error when buffer has no file."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "some code\n")
          (setq-local buffer-file-name nil)
          (should-error (quoth-insert-filepath)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/insert-filepath-uses-relative-path ()
  "Quoth-insert-filepath should use a path relative to project root."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "code\n")
          ;; Set buffer-file-name to something under the cwd
          (setq-local buffer-file-name
                      (expand-file-name "test/quoth-mode-test.el"
                                        default-directory))
          (quoth-insert-filepath)
          (with-current-buffer (quoth-test--buffer-name)
            (goto-char (point-min))
            ;; Should contain a relative path, not absolute
            (should (search-forward "test/quoth-mode-test.el" nil t))))
      (quoth-test--cleanup))))

;;; quoth-insert-selection via minor mode keymap

(ert-deftest quoth-test/insert-selection-via-minor-mode-key ()
  "Quoth-insert-selection should be callable via the minor mode keybinding."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-temp-buffer
          (insert "selected text\n")
          (goto-char (point-min))
          (set-mark (point))
          (forward-word)
          (quoth-minor-mode 1)
          ;; Verify the keybinding resolves to the right command
          (let ((binding (key-binding (kbd "C-c C-s"))))
            (should (eq binding #'quoth-insert-selection)))
          ;; Call the command directly
          (call-interactively #'quoth-insert-selection)
          (with-current-buffer (quoth-test--buffer-name)
            (goto-char (point-min))
            (should (search-forward "selected" nil t)))
          (quoth-minor-mode -1))
      (quoth-test--cleanup))))

;;; 21. Inserted content has prompt-id properties

(ert-deftest quoth-test/init-buffer-is-idempotent ()
  "An initialized quoth buffer resists re-initialization:
regenerating the prompt ID or clobbering existing state must not happen.
Regression: with markdown-mode as the parent, major-mode is markdown-mode,
not quoth-mode, so the old 'eq major-mode' guard failed to detect an
already-initialized buffer and re-initialized it."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((id1 quoth--prompt-id)
                  (marker1 quoth--prompt-start-marker))
              (quoth--init-buffer buf)
              (should (string= id1 quoth--prompt-id))
              (should (eq marker1 quoth--prompt-start-marker)))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/inserted-content-has-prompt-id ()
  "Inserted content via quoth-insert-selection should have quoth-prompt-id."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((prompt-id quoth--prompt-id))
              (with-temp-buffer
                (insert "selected code\n")
                (setq-local buffer-file-name "/test/file.el")
                (quoth-insert-selection (point-min) (point-max)))
              (goto-char (point-min))
              (should (search-forward "selected code" nil t))
              (let ((pid (get-text-property (- (point) 5) 'quoth-prompt-id)))
                (should pid)
                (should (string= pid prompt-id))))))
      (quoth-test--cleanup))))

;;; 33. Region type tagging: inserted content

(ert-deftest quoth-test/inserted-content-tagged-as-user ()
  "Test that inserted content blocks are tagged with quoth-region-type 'user."
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
            (let ((region-type (get-text-property (match-beginning 0) 'quoth-region-type)))
              (should (eq region-type 'user)))))
      (quoth-test--cleanup))))

;;; 37. Attachment formatting: markdown fenced blocks

(ert-deftest quoth-test/format-selection-emits-fenced-block ()
  "`quoth--format-selection' emits a markdown fenced code block.
The block carries an Attachment header line."
  (let ((buf (quoth-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (with-temp-buffer
            (insert "line one\nline two\n")
            (let ((formatted (quoth--format-selection "src/file.el" "src/file.el"
                                                      (point-min) (1- (point-max)))))
              (should (string-match-p "\\*\\*Attachment: src/file.el (lines 1-2)\\*\\*" formatted))
              (should (string-match-p "```emacs-lisp" formatted))
              (should (string-match-p "```" formatted)))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/format-selection-fence-grows-for-nested-backticks ()
  "`quoth--format-selection' widens the fence when the selection
contains backtick runs, so nested fences never close the block early."
  (let ((buf (quoth-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (with-temp-buffer
            (insert "here is a ``` fenced snippet
and a ````` longer run
")
            (let ((formatted (quoth--format-selection "src/file.md" "src/file.md"
                                                      (point-min) (1- (point-max)))))
              ;; The opening fence must be longer than the longest inner run.
              (should (string-match-p "\n``````markdown\n" formatted))
              (should (string-match-p "``````$" formatted)))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/format-selection-uses-relative-path ()
  "Attachment paths use the pre-resolved relative path as-is."
  (let ((buf (quoth-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((formatted (quoth--format-selection "/tmp/proj/src/file.el"
                                                    "src/file.el" 1 5)))
            (should (string-match-p "src/file.el" formatted))
            (should-not (string-match-p "/tmp/proj/src" formatted))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/format-selection-no-file ()
  "Quoth--format-selection without a file should use (no file)."
  (let ((buf (quoth-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((formatted (quoth--format-selection nil nil 1 5)))
            (should (string-match-p "(no file)" formatted))))
      (quoth-test--cleanup))))

;;; 37b. Attachment language from extension

(ert-deftest quoth-test/lang-from-extension ()
  "Quoth--lang-from-extension should map extensions to markdown languages."
  (let ((buf (quoth-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (string= (quoth--lang-from-extension "file.el") "emacs-lisp"))
          (should (string= (quoth--lang-from-extension "file.go") "go"))
          (should (string= (quoth--lang-from-extension "file.yaml") "yaml"))
          (should (string= (quoth--lang-from-extension "file.yml") "yaml"))
          (should (string= (quoth--lang-from-extension "foo.unknown")
                           "plaintext")))
      (quoth-test--cleanup))))

;;; 38. Inserted content text properties

;;; 39. Filepath insertion (link form)

(ert-deftest quoth-test/insert-filepath-emits-link ()
  "`quoth-insert-filepath' inserts a markdown link as user input.
It sets quoth-region-type 'user."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (let ((project-root default-directory))
            (with-current-buffer buf
              (with-temp-buffer
                (setq-local buffer-file-name (expand-file-name "file.go" project-root))
                (quoth-insert-filepath))
              (goto-char (point-min))
              (should (search-forward "[file.go](file.go)" nil t))
              (let ((region-type (get-text-property (match-beginning 0) 'quoth-region-type)))
                (should (eq region-type 'user))))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/sentinel-no-longer-fontifies ()
  "Finalize should tag the response but create no overlays."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "test")
          (goto-char (point-max))
          (newline)
          (setq-local quoth--response-start (point-marker))
          ;; Stream content through the facade, then finalize.
          (goto-char (point-max))
          (setq-local quoth--response-start (point-marker))
          (quoth-facade--append-delta "**bold** text" 'content)
          (quoth-facade--finalize)
          (goto-char (point-min))
          (should (search-forward "bold" nil t))
          ;; Finalize must create no quoth overlays.
          (should-not (cl-some (lambda (ov) (overlay-get ov 'quoth-overlay))
                               (overlays-in (point-min) (point-max))))
          ;; The response is still tagged
          (should (eq (get-text-property (match-beginning 0) 'quoth-region-type) 'response))))
    (quoth-test--cleanup)))

;;; 41. Integration: attachment insertion does not fontify

(ert-deftest quoth-test/insert-selection-creates-no-overlays ()
  "Inserting a selection should not create quoth overlays."
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
            ;; No quoth overlays from attachment insertion
            (should-not (cl-some (lambda (ov) (overlay-get ov 'quoth-overlay))
                                 (overlays-in (point-min) (point-max))))))
      (quoth-test--cleanup))))

;;; quoth-chat-mode minor mode

(ert-deftest quoth-test/chat-mode-is-defined ()
  "Quoth-chat-mode should be defined as a minor mode."
  (should (boundp 'quoth-chat-mode))
  (should (fboundp 'quoth-chat-mode)))

(ert-deftest quoth-test/chat-mode-enabled-in-quoth-buffer ()
  "Quoth-chat-mode should be enabled in quoth buffers."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should quoth-chat-mode)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/chat-mode-has-keymap ()
  "Quoth-chat-mode-map should have the expected keybindings.
All commands live under the `C-c c' prefix so they do not conflict
with markdown-mode's `C-c C-*' bindings."
  (let ((map (symbol-value 'quoth-chat-mode-map))
        (cmd (symbol-value 'quoth-chat-command-map)))
    (should (keymapp map))
    (should (eq (lookup-key map (kbd "C-c c")) cmd))
    (should (eq (lookup-key cmd (kbd "s")) #'quoth-send-input))
    (should (eq (lookup-key cmd (kbd "i")) #'quoth-interrupt))
    (should (eq (lookup-key cmd (kbd "k")) #'quoth-clear-buffer))
    ;; markdown-mode's C-c C-* bindings must not be shadowed.
    (should-not (lookup-key map (kbd "C-c C-c")))
    (should-not (lookup-key map (kbd "C-c C-k")))
    (should-not (lookup-key map (kbd "C-c C-s")))
    (should-not (lookup-key map (kbd "C-c C-i")))
    (should (eq (lookup-key map (kbd "TAB")) #'quoth--reasoning-tab))
    (should (eq (lookup-key map (kbd "<C-return>")) #'quoth-send-input))
    (should (eq (lookup-key map (kbd "M-p")) #'quoth--input-previous))
    (should (eq (lookup-key map (kbd "M-n")) #'quoth--input-next))))

(ert-deftest quoth-test/chat-mode-c-c-c-s-sends-input ()
  "`C-c c s' in a quoth buffer should resolve to quoth-send-input."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq (key-binding (kbd "C-c c s")) #'quoth-send-input))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/chat-mode-does-not-add-after-change-hook ()
  "`quoth-chat-mode' does NOT add an after-change-functions hook.
User input is tagged at send time, not live; the header-line is kept
fresh by `post-command-hook' alone."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (memq #'quoth--after-change after-change-functions))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/chat-mode-adds-post-command-hook ()
  "`quoth-chat-mode' adds `quoth--update-header-line' to `post-command-hook'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (should (memq #'quoth--update-header-line post-command-hook))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/chat-mode-disable-removes-hooks ()
  "Disabling quoth-chat-mode should remove its hooks."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (quoth-chat-mode -1)
          (should-not (memq #'quoth--update-header-line post-command-hook))))
    (quoth-test--cleanup)))

(provide 'quoth-test-commands)
;;; quoth-test-commands.el ends here
