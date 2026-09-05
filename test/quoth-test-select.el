;;; quoth-test-select.el --- Active provider + model selector tests for quoth  -*- lexical-binding: t; -*-
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
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;;; THE SOFTWARE.

;;; Commentary:
;;; Tests for the active-provider registry, provider generics for model
;;; catalogs, session attribute variables, and the transient selector
;;; entrypoints (bypassing transient UI, driving the apply functions
;;; directly).

;;; Code:

(require 'ert)
(require 'cl-lib)

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

(defvar quoth-test--root)
(declare-function quoth-test--fresh-buffer "quoth-test" ())
(declare-function quoth-test--cleanup "quoth-test" ())
(declare-function quoth-test--with-hyper-server "quoth-test-hyper" (mode body-fn))

;;; 101. Provider registry

(ert-deftest quoth-test/registry-has-hyper-by-default ()
  "The default `quoth-providers' registry contains one entry: hyper."
  (let ((quoth-providers nil))
    (should (string= (plist-get (car quoth-providers-default) :name) "hyper"))
    (should (eq (plist-get (car quoth-providers-default) :type) 'hyper))
    (should (functionp (plist-get (car quoth-providers-default) :factory)))))

(ert-deftest quoth-test/registry-default-provider-name ()
  "`quoth-active-provider-name' defaults to \"hyper\"."
  (should (string= (default-value (quote quoth-active-provider-name)) "hyper")))

(ert-deftest quoth-test/instantiate-provider-returns-hyper ()
  "`quoth--instantiate-provider' builds a hyper provider from the registry."
  (let ((buf (generate-new-buffer " *quoth-test-instantiate*")))
    (with-current-buffer buf
      (let ((provider (quoth--instantiate-provider "hyper" buf default-directory)))
        (should (quoth-hyper-provider-p provider))
        (should (string= (quoth-hyper-provider-base-url provider)
                         quoth-hyper-base-url))
        (should (eq (quoth-provider-buffer provider) buf))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;;; 102. Provider generics: models + apply-model

(ert-deftest quoth-test/provider-models-generic-default-is-nil ()
  "The base `quoth-provider--models-async' delivers nil for a bare provider."
  (let ((provider (make-quoth-provider))
        (delivered nil))
    (should (null (quoth-provider--models-async
                   provider (lambda (models) (push models delivered)))))
    (should (equal delivered '(nil)))))

(ert-deftest quoth-test/provider-apply-model-generic-default-is-nil ()
  "The base `quoth-provider--apply-model' returns nil for a bare provider."
  (let ((provider (make-quoth-provider)))
    (should (null (quoth-provider--apply-model provider '(:id "x"))))))

(ert-deftest quoth-test/hyper-provider-models-normalizes-plist ()
  "`quoth-provider--models-async' on hyper delivers structured plists."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :working-directory default-directory
                   :base-url "http://127.0.0.1:1"))
        (delivered nil))
    (cl-letf (((symbol-function 'quoth-hyper--fetch-models-async)
               (lambda (_base _token on-done)
                 (funcall on-done
                          (cons '((default_large_model_id . "qwen3.7-plus"))
                                (vector
                                 (list (cons "id" "deepseek-v4-flash-0731")
                                       (cons "name" "DeepSeek V4 Flash")
                                       (cons "cost_per_1m_in" 0.1)
                                       (cons "cost_per_1m_out" 0.3)
                                       (cons "cost_per_1m_in_cached" 0.07)
                                       (cons "cost_per_1m_out_cached" 0.03)
                                       (cons "context_window" 131072)
                                       (cons "default_max_tokens" 8192)
                                       (cons "can_reason" t)
                                       (cons "reasoning_levels"
                                             (vector "low" "medium" "high"))
                                       (cons "default_reasoning_effort" "high")
                                       (cons "supports_attachments" t))
                                 (list (cons "id" "mini-no-reason")
                                       (cons "name" "Mini No Reason")
                                       (cons "cost_per_1m_in" 0.05)
                                       (cons "cost_per_1m_out" 0.1)
                                       (cons "cost_per_1m_in_cached" 0.0)
                                       (cons "cost_per_1m_out_cached" 0.0)
                                       (cons "context_window" 32768)
                                       (cons "default_max_tokens" 4096)
                                       (cons "can_reason" :json-false)
                                       (cons "reasoning_levels" (vector))
                                       (cons "default_reasoning_effort" nil)
                                       (cons "supports_attachments"
                                             :json-false))))))))
      (quoth-provider--models-async
       provider (lambda (models) (push models delivered)))
      (let ((models (car delivered)))
        (should (= (length models) 2))
        (let ((m1 (car models)))
          (should (string= (plist-get m1 :id) "deepseek-v4-flash-0731"))
          (should (string= (plist-get m1 :name) "DeepSeek V4 Flash"))
          (should (= (plist-get m1 :context-window) 131072))
          (should (= (plist-get m1 :default-max-tokens) 8192))
          (should (= (plist-get m1 :cost-in) 0.1))
          (should (= (plist-get m1 :cost-out) 0.3))
          (should (= (plist-get m1 :cost-cache-write) 0.07))
          (should (= (plist-get m1 :cost-cache-hit) 0.03))
          (should (eq (plist-get m1 :can-reason) t))
          (should (equal (plist-get m1 :reasoning-levels)
                         '("low" "medium" "high")))
          (should (string= (plist-get m1 :default-reasoning-effort) "high"))
          (should (eq (plist-get m1 :supports-attachments) t)))
        (let ((m2 (cadr models)))
          (should (string= (plist-get m2 :id) "mini-no-reason"))
          (should-not (eq (plist-get m2 :can-reason) t))
          (should (null (plist-get m2 :reasoning-levels))))))))

(ert-deftest quoth-test/hyper-provider-apply-model-sets-slot ()
  "`quoth-provider--apply-model' on hyper sets the model slot from the plist."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :working-directory default-directory)))
    (quoth-provider--apply-model provider '(:id "qwen3.7-plus"))
    (should (string= (quoth-hyper-provider-model provider) "qwen3.7-plus"))))

(ert-deftest quoth-test/hyper-provider-models-nil-on-fetch-failure ()
  "`quoth-provider--models-async' delivers nil when the fetch fails."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :working-directory default-directory
                   :base-url "http://127.0.0.1:1"))
        (delivered nil))
    (cl-letf (((symbol-function 'quoth-hyper--fetch-models-async)
               (lambda (_base _token on-done)
                 (funcall on-done nil))))
      (quoth-provider--models-async
       provider (lambda (models) (push models delivered)))
      (should (equal delivered '(nil))))))

;;; 103. Session attributes: buffer-local, no globals

(ert-deftest quoth-test/session-attrs-are-buffer-local ()
  "`quoth--session-thinking' and `-reasoning-effort' are buffer-local.
Once set in a buffer, the value is local to that buffer (defvar-local)."
  (with-temp-buffer
    (setq-local quoth--session-thinking t)
    (setq-local quoth--session-reasoning-effort "high")
    (should (local-variable-p (quote quoth--session-thinking)))
    (should (local-variable-p (quote quoth--session-reasoning-effort)))
    (should (eq quoth--session-thinking t))
    (should (string= quoth--session-reasoning-effort "high"))))

(ert-deftest quoth-test/compose-session-attrs-land-in-body ()
  "Session thinking + effort land in the request body when set."
  (let ((quoth--session-thinking t)
        (quoth--session-reasoning-effort "high"))
    (let ((req (quoth-openai-compose-request "P" "my-model")))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest quoth-test/compose-defaults-omit-attrs ()
  "With session slots nil, neither thinking nor effort appears in the body."
  (let (quoth--session-thinking quoth--session-reasoning-effort)
    (let ((req (quoth-openai-compose-request "P" "m")))
      (should-not (assq 'thinking req))
      (should-not (assq 'reasoning_effort req)))))

(ert-deftest quoth-test/compose-thinking-only-omits-effort ()
  "Thinking on, effort nil: body has thinking, no reasoning_effort."
  (let ((quoth--session-thinking t)
        quoth--session-reasoning-effort)
    (let ((req (quoth-openai-compose-request "P" "m")))
      (should (eq (alist-get 'thinking req) t))
      (should-not (assq 'reasoning_effort req)))))

(ert-deftest quoth-test/compose-effort-without-thinking-sends-effort ()
  "Effort set but thinking unset: no thinking key, but effort is sent."
  (let (quoth--session-thinking
        (quoth--session-reasoning-effort "high"))
    (let ((req (quoth-openai-compose-request "P" "m")))
      (should-not (assq 'thinking req))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest quoth-test/compose-thinking-off-sends-false-and-effort ()
  "Thinking off (:json-false) sends `thinking: false'; effort still sent."
  (let ((quoth--session-thinking :json-false)
        (quoth--session-reasoning-effort "high"))
    (let ((req (quoth-openai-compose-request "P" "m")))
      (should (eq (alist-get 'thinking req) :json-false))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

;;; 104. Select-model via the new apply path

(ert-deftest quoth-test/select-model-applies-via-provider-generic ()
  "`quoth-select-model' applies the chosen model through the provider.
The choice goes through `quoth-provider--apply-model', not a direct
setf."
  (let ((quoth-model nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _)
                         (list '(:id "qwen3.7-plus" :name "Qwen" :can-reason t
                                     :reasoning-levels ("low" "medium" "high" "max")
                                     :default-reasoning-effort "max"))))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "qwen3.7-plus")))
              (quoth-select-model))
            (should (string= (quoth-hyper-provider-model quoth-active-provider)
                             "qwen3.7-plus"))
            (should (string= quoth-model "qwen3.7-plus"))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/select-model-default-clears-slot ()
  "Choosing 'default' clears the provider model slot."
  (let ((quoth-model "qwen3.7-plus"))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setf (quoth-hyper-provider-model quoth-active-provider) "qwen3.7-plus")
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _) nil))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "default")))
              (quoth-select-model))
            (should (null (quoth-hyper-provider-model quoth-active-provider)))
            (should (null quoth-model))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/select-model-fallback-on-no-models ()
  "When the catalog fetch returns nil, a fallback list is offered."
  (let ((quoth-model nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _) nil))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (_prompt coll &rest _)
                         (should (assoc quoth-openai-default-model coll))
                         "qwen3.7-plus")))
              (quoth-select-model))
            (should (string= (quoth-hyper-provider-model quoth-active-provider)
                             "qwen3.7-plus"))
            (should (string= quoth-model "qwen3.7-plus"))))
      (quoth-test--cleanup))))

;;; 105. Persistence: savehist registration

(ert-deftest quoth-test/savehist-registers-provider-and-model ()
  "Savehist registers the provider name and model after loading.
`quoth-active-provider-name' and `quoth-model' are registered with
`savehist-additional-variables'."
  (require 'savehist)
  (should (memq 'quoth-active-provider-name
                (default-value 'savehist-additional-variables)))
  (should (memq 'quoth-model
                (default-value 'savehist-additional-variables))))

(provide 'quoth-test-select)
;;; quoth-test-select.el ends here

;;; 106. Transient selector: affixation and apply functions

(ert-deftest quoth-test/select-model-choices-builds-affixation ()
  "`quoth--model-choices' returns (ID . DISPLAY) pairs with price info."
  (let ((models (list '(:id "qwen3.7-plus" :name "Qwen 3.7 Plus"
                            :context-window 262144 :cost-in 0.2 :cost-out 0.6
                            :can-reason t
                            :reasoning-levels ("low" "medium" "high" "max"))
                      '(:id "mini-no-reason" :name "Mini No Reason"
                            :context-window 32768 :cost-in 0.05 :cost-out 0.1
                            :can-reason nil :reasoning-levels nil))))
    (let ((choices (quoth--model-choices models)))
      (should (= (length choices) 2))
      (should (string= (car (car choices)) "qwen3.7-plus"))
      (should (string-match-p "Qwen 3.7 Plus" (cdr (car choices))))
      (should (string-match-p "262144" (cdr (car choices))))
      (should (string-match-p "0.20" (cdr (car choices))))
      (should (string-match-p "reason" (cdr (car choices))))
      (should (string-match-p "no reason" (cdr (cadr choices)))))))

(ert-deftest quoth-test/select-apply-thinking-sets-session ()
  "`quoth--select-apply-thinking' sets the buffer-local session slot."
  (with-temp-buffer
    (quoth--select-apply-thinking t)
    (should (eq quoth--session-thinking t))
    (quoth--select-apply-thinking :json-false)
    (should (eq quoth--session-thinking :json-false))
    (quoth--select-apply-thinking nil)
    (should (null quoth--session-thinking))))

(ert-deftest quoth-test/select-effort-matrix-cell ()
  "`quoth--select-effort-matrix-cell' reflects the observed interplay."
  (should (string= (quoth--select-effort-matrix-cell 'off nil)
                   "direct (no reason)"))
  (should (string= (quoth--select-effort-matrix-cell 'off t)
                   "reasoning"))
  (should (string= (quoth--select-effort-matrix-cell 'on nil)
                   "reasoning"))
  (should (string= (quoth--select-effort-matrix-cell 'on t)
                   "reasoning"))
  (should (string= (quoth--select-effort-matrix-cell 'unset nil)
                   "provider default"))
  (should (string= (quoth--select-effort-matrix-cell 'unset t)
                   "reasoning")))

(ert-deftest quoth-test/select-thinking-toggle-cycles-on-off ()
  "`quoth--select-thinking-toggle' cycles on -> off -> on, never unset."
  (with-temp-buffer
    ;; unset -> on
    (quoth--select-thinking-toggle)
    (should (eq quoth--session-thinking t))
    ;; on -> off
    (quoth--select-thinking-toggle)
    (should (eq quoth--session-thinking :json-false))
    ;; off -> on
    (quoth--select-thinking-toggle)
    (should (eq quoth--session-thinking t))))

(ert-deftest quoth-test/select-apply-effort-sets-session ()
  "`quoth--select-apply-effort' sets the buffer-local session slot."
  (with-temp-buffer
    (quoth--select-apply-effort "high")
    (should (string= quoth--session-reasoning-effort "high"))
    (quoth--select-apply-effort nil)
    (should (null quoth--session-reasoning-effort))))

(ert-deftest quoth-test/select-apply-defaults-clears-session ()
  "`quoth--select-apply-defaults' clears both session slots."
  (with-temp-buffer
    (setq-local quoth--session-thinking t)
    (setq-local quoth--session-reasoning-effort "high")
    (quoth--select-apply-defaults)
    (should (null quoth--session-thinking))
    (should (null quoth--session-reasoning-effort))))

(ert-deftest quoth-test/select-current-model-entry ()
  "`quoth--select-current-model-entry' finds the active model in a list."
  (let ((models (list '(:id "a" :name "A")
                      '(:id "b" :name "B"))))
    (should (string= (plist-get (quoth--select-current-model-entry models "a") :id) "a"))
    (should (null (quoth--select-current-model-entry models "z")))))

;;; 107. Conditional visibility predicates

(ert-deftest quoth-test/select-can-reason-p-with-reasoning-model ()
  "`quoth--select-can-reason-p' returns non-nil for a reasoning model."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (transient--original-buffer (current-buffer)))
	(cl-letf (((symbol-function 'quoth-provider-p)
		   (lambda (&rest _) t))
		  ((symbol-function 'quoth-provider-models-cached)
		   (lambda (&rest _)
		     (list '(:id "m" :can-reason t
				 :reasoning-levels ("low" "high")))))
		  ((symbol-function 'quoth-provider-model)
		   (lambda (&rest _) "m")))
	  (should (quoth--select-can-reason-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(ert-deftest quoth-test/select-can-reason-p-with-non-reasoning-model ()
  "`quoth--select-can-reason-p' returns nil for a non-reasoning model."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (transient--original-buffer (current-buffer)))
	(cl-letf (((symbol-function 'quoth-provider-p)
		   (lambda (&rest _) t))
		  ((symbol-function 'quoth-provider-models-cached)
		   (lambda (&rest _)
		     (list '(:id "m" :can-reason nil
				 :reasoning-levels nil))))
		  ((symbol-function 'quoth-provider-model)
		   (lambda (&rest _) "m")))
	  (should-not (quoth--select-can-reason-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(ert-deftest quoth-test/select-has-reasoning-levels-p-with-levels ()
  "`quoth--select-has-reasoning-levels-p' returns non-nil when levels exist."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (transient--original-buffer (current-buffer)))
	(cl-letf (((symbol-function 'quoth-provider-p)
		   (lambda (&rest _) t))
		  ((symbol-function 'quoth-provider-models-cached)
		   (lambda (&rest _)
		     (list '(:id "m" :can-reason t
				 :reasoning-levels ("low" "high")))))
		  ((symbol-function 'quoth-provider-model)
		   (lambda (&rest _) "m")))
	  (should (quoth--select-has-reasoning-levels-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(ert-deftest quoth-test/select-has-reasoning-levels-p-without-levels ()
  "`quoth--select-has-reasoning-levels-p' returns nil when no levels."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (transient--original-buffer (current-buffer)))
	(cl-letf (((symbol-function 'quoth-provider-p)
		   (lambda (&rest _) t))
		  ((symbol-function 'quoth-provider-models-cached)
		   (lambda (&rest _)
		     (list '(:id "m" :can-reason t
				 :reasoning-levels nil))))
		  ((symbol-function 'quoth-provider-model)
		   (lambda (&rest _) "m")))
	  (should-not (quoth--select-has-reasoning-levels-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(provide 'quoth-test-select)
;;; quoth-test-select.el ends here
