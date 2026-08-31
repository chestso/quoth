;;; quoth-select.el --- Transient model selector for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;;; Keywords: tools, ai, convenience
;;; Prefix: quoth-

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

;; Transient-based model selector for quoth.  Provides a popup menu
;; (C-c c m) for choosing a model from the active provider's catalog,
;; toggling thinking/reasoning attributes, and showing model prices.
;; The selector layer owns the UI; it applies choices through the
;; provider generics (`quoth-provider--models',
;; `quoth-provider--apply-model') and sets per-session attributes in
;; buffer-local variables (`quoth--session-thinking',
;; `quoth--session-reasoning-effort').

;;; Code:

(require 'cl-lib)
(require 'transient)

;; quoth.el loads this file at the end of its body (after `provide'),
;; so the core is fully available before this file's body runs.
;; All cross-references are declared below for byte-compilation.

(defvar quoth--session-thinking)
(defvar transient--original-buffer)

(defmacro quoth--select-in-origin (&rest body)
  "Evaluate BODY in the buffer that invoked the transient."
  `(with-current-buffer (or transient--original-buffer
                            (current-buffer))
     ,@body))
(defvar quoth--session-reasoning-effort)
(defvar quoth-active-provider)
(defvar quoth-model)
(defvar quoth-openai-default-model)
(defvar quoth-providers)
(defvar quoth-active-provider-name)
(declare-function quoth-provider-p "quoth-provider" (object))
(declare-function quoth-provider--models "quoth-provider" (provider))
(declare-function quoth-provider--apply-model "quoth-provider" (provider model-entry))
(declare-function quoth--update-header-line "quoth.el" ())
(declare-function quoth-hyper-provider-p "quoth-hyper-provider" (object))
(declare-function quoth-hyper-provider-model "quoth-hyper-provider" (object))

;;; Helper functions (testable without transient UI)

(defun quoth--model-choices (models)
  "Build (ID . DISPLAY) completion pairs from MODELS (a list of plists).
DISPLAY annotates each model with name, context window, input cost,
and reasoning support, aligned in fixed-width columns."
  (mapcar
   (lambda (m)
     (let ((id    (or (plist-get m :id) "?"))
           (name  (or (plist-get m :name) "?"))
           (ctx   (or (plist-get m :context-window) "?"))
           (cost  (plist-get m :cost-in))
           (reason (plist-get m :can-reason)))
       (cons id
             (string-trim
              (format "%-22s %-18s %8s  $%6s/1M in  %s"
                      id name ctx
                      (if (numberp cost)
                          (format "%.2f" cost)
                        "?")
                      (if reason "reason" "no reason"))))))
   models))

(defun quoth--select-current-model-entry (models model-id)
  "Find the model entry with :id MODEL-ID in MODELS, or nil."
  (cl-find model-id models
           :test #'string=
           :key (lambda (m) (plist-get m :id))))

(defun quoth--select-apply-thinking (enabled)
  "Set `quoth--session-thinking' to ENABLED in the current buffer."
  (setq-local quoth--session-thinking
              (if enabled t nil)))

(defun quoth--select-apply-effort (effort)
  "Set `quoth--session-reasoning-effort' to EFFORT in the current buffer."
  (setq-local quoth--session-reasoning-effort
              (if effort effort nil)))

(defun quoth--select-apply-defaults ()
  "Clear both session attribute slots, reverting to provider defaults."
  (setq-local quoth--session-thinking nil)
  (setq-local quoth--session-reasoning-effort nil))

(defun quoth--select-model-detail (models model-id)
  "Return a pricing/context string for the model with :id MODEL-ID, or nil.
The model id and name are shown on the `Model' header line above, so
only context window and per-token costs appear here."
  (let ((m (quoth--select-current-model-entry models model-id)))
    (when m
      (let ((ctx   (or (plist-get m :context-window) "?"))
            (cin   (plist-get m :cost-in))
            (cout  (plist-get m :cost-out))
            (ccin  (plist-get m :cost-in-cached)))
        (string-trim
         (format "ctx %s  $%s/1M in · $%s/1M out · cached $%s"
                 ctx
                 (if (numberp cin) (format "%.2f" cin) "?")
                 (if (numberp cout) (format "%.2f" cout) "?")
                 (if (numberp ccin) (format "%.2f" ccin) "?")))))))

;;; Transient menu
(defun quoth--select-current-model ()
  "Return the effective model id for the current buffer, or nil."
  (or (and (quoth-hyper-provider-p quoth-active-provider)
           (quoth-hyper-provider-model quoth-active-provider))
      quoth-openai-default-model))

(defun quoth--select-effective-model-entry ()
  "Return the model plist for the effective model, or nil."
  (let* ((models (and quoth-active-provider
                      (quoth-provider-p quoth-active-provider)
                      (quoth-provider--models quoth-active-provider)))
         (current (quoth--select-current-model)))
    (and models current
         (quoth--select-current-model-entry models current))))

(defun quoth--select-can-reason-p ()
  "Return non-nil if the current model supports reasoning."
  (quoth--select-in-origin
   (let ((entry (quoth--select-effective-model-entry)))
     (and entry (plist-get entry :can-reason)))))

(defun quoth--select-has-reasoning-levels-p ()
  "Return non-nil if the current model has reasoning levels to pick from."
  (quoth--select-in-origin
   (let ((entry (quoth--select-effective-model-entry)))
     (and entry
          (let ((levels (plist-get entry :reasoning-levels)))
            (and (consp levels) levels))))))


(defun quoth--select-model-picker (&rest _)
  "Prompt for a model from the active provider's catalog."
  (interactive)
  (let* ((models (and quoth-active-provider
		      (quoth-provider-p quoth-active-provider)
		      (quoth-provider--models quoth-active-provider)))
	 (choices (if models
		      (quoth--model-choices models)
		    (list (cons quoth-openai-default-model
				(format "%s (default)"
					quoth-openai-default-model)))))
	 (choice (completing-read
		  "Model: "
		  (cons (cons "default" "default (provider default)")
			choices)
		  nil t nil)))
    (if (string= choice "default")
	(progn
	  (setq quoth-model nil)
	  (when (and quoth-active-provider
		     (quoth-provider-p quoth-active-provider))
	    (quoth-provider--apply-model
	     quoth-active-provider '(:id nil))))
      (setq quoth-model choice)
      (when (and quoth-active-provider
		 (quoth-provider-p quoth-active-provider))
	(quoth-provider--apply-model
	 quoth-active-provider
	 (list :id choice))))
    (quoth--update-header-line)
    (message "Model: %s"
	     (or (and (not (string= choice "default")) choice)
		 quoth-openai-default-model))))

(defun quoth--select-thinking-toggle (&rest _)
  "Toggle thinking on/off for the current buffer."
  (interactive)
  (quoth--select-apply-thinking (not quoth--session-thinking)))

(defun quoth--select-effort-picker (&rest _)
  "Prompt for a reasoning effort level from the current model's levels."
  (interactive)
  (let ((entry (quoth--select-effective-model-entry)))
    (if entry
	(let ((levels (plist-get entry :reasoning-levels)))
	  (if (and levels (consp levels))
	      (let ((choice (completing-read "Effort: " levels nil t)))
		(when choice
		  (quoth--select-apply-effort choice)
		  (message "Effort: %s" choice)))
	    (message "Effort: no reasoning levels for this model")))
      (message "Effort: no model catalog available"))))

(defun quoth--select-defaults-apply (&rest _)
  "Revert to provider defaults for model attributes."
  (interactive)
  (quoth--select-apply-defaults))

(defun quoth--select-info-thinking (&rest _)
  "Return the thinking state for the info line.
When `quoth--session-thinking' is nil, no thinking flag is sent on
the request, so the gateway applies its own default; show that as
\='unset\=' rather than the misleading \='off\='."
  (quoth--select-in-origin
   (format "Thinking  %s"
           (cond
            (quoth--session-thinking "on")
            (t "unset (provider default)")))))

(defun quoth--select-info-effort (&rest _)
  "Return the effort level for the info line.
When `quoth--session-reasoning-effort' is nil, no reasoning_effort
is sent on the request, so the gateway applies its own default;
show \='unset\=' in that case, with the catalog documented default
as a hint when available."
  (quoth--select-in-origin
   (let* ((entry (quoth--select-effective-model-entry))
          (catalog-default (and entry
                                (plist-get entry :default-reasoning-effort)))
          (levels (and entry (plist-get entry :reasoning-levels))))
     (format "Effort    %s%s"
             (cond
              (quoth--session-reasoning-effort
               (format "%s (explicit)" quoth--session-reasoning-effort))
              (catalog-default
               (format "unset (provider default: %s)" catalog-default))
              (t "unset (provider default)"))
             (if (and levels (consp levels))
                 (format "  (levels: %s)"
                         (mapconcat #'identity levels " "))
               "")))))



(defun quoth--select-info-provider (&rest _)
  "Return the active provider name for the info line."
  (quoth--select-in-origin
   (format "Provider  %s" (or quoth-active-provider-name "hyper"))))

(defun quoth--select-info-model (&rest _)
  "Return the current model with pricing detail for the info line."
  (quoth--select-in-origin
   (let* ((models  (and quoth-active-provider
                        (quoth-provider-p quoth-active-provider)
                        (quoth-provider--models quoth-active-provider)))
          (current (quoth--select-current-model))
          (prices  (and models current
                        (quoth--select-model-detail models current))))
     (string-trim
      (format "Model     %s%s"
              (or current "-")
              (if prices (format "  (%s)" prices) ""))))))

(transient-define-prefix quoth-select-model-menu ()
                         "Model and attribute selector for Quoth."
                         [:description quoth--select-info-provider
		                       ("p" "provider" quoth--select-provider-switch :transient t)]
                         [:description quoth--select-info-model
		                       ("m" "model" quoth--select-model-picker :transient t)]
                         [:description quoth--select-info-thinking
		                       ("t" "toggle thinking" quoth--select-thinking-toggle
		                        :transient t :if quoth--select-can-reason-p)]
                         [:description quoth--select-info-effort
		                       ("e" "effort" quoth--select-effort-picker
		                        :transient t :if quoth--select-has-reasoning-levels-p)]
                         [:description "Defaults"
		                       ("d" "use provider defaults" quoth--select-defaults-apply
		                        :transient t)]
                         ["Actions"
                          ("q" "quit" transient-quit-one)])

(defun quoth--select-provider-switch (&rest _)
  "Switch the active provider (placeholder — only hyper is registered)."
  (interactive)
  (let* ((names (mapcar (lambda (e) (plist-get e :name)) quoth-providers))
	 (choice (completing-read "Provider: " names nil t)))
    (when choice
      (setq quoth-active-provider-name choice)
      (message "Provider: %s" choice))))

(provide 'quoth-select)
;;; quoth-select.el ends here
