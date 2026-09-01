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
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

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
(require 'quoth-provider)   ; session slots, active-provider, model generic, change hook
(require 'quoth-openai)     ; quoth-model, quoth-openai-default-model

(defvar transient--original-buffer)

(defmacro quoth--select-in-origin (&rest body)
  "Evaluate BODY in the buffer that invoked the transient."
  `(with-current-buffer (or transient--original-buffer
                            (current-buffer))
     ,@body))

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

(defun quoth--select-apply-thinking (value)
  "Set `quoth--session-thinking' to VALUE in the current buffer.
VALUE is one of t (on), :json-false (off), or nil (unset)."
  (setq-local quoth--session-thinking value))

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
Only context window and per-token costs appear; the model id is shown
by the caller."
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
  (or (and quoth-active-provider
           (quoth-provider-p quoth-active-provider)
           (quoth-provider-model quoth-active-provider))
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

(defun quoth--select-effort-matrix-cell (thinking effort-p)
  "Return the reasoning outcome cell for THINKING with EFFORT-P.
THINKING is `off', `on', or `unset'; EFFORT-P is non-nil when a
`reasoning_effort' would be sent.  Behavior is provider specific
(validated on the hyper provider with `deepseek-v4-pro-0813'):
`thinking: false' suppresses reasoning when sent alone, but sending
`reasoning_effort' alongside re-enables the reasoning trace."
  (pcase thinking
    ('off (if effort-p "reasoning" "direct (no reason)"))
    ('on "reasoning")
    ('unset (if effort-p "reasoning" "provider default"))
    (_ "?")))

(defun quoth--select-info-reasoning-matrix (&rest _)
  "Return a compact visual matrix of the thinking/effort interplay.
Validated on the hyper provider (`deepseek-v4-pro-0813'): `thinking:
false' suppresses reasoning only when sent without `reasoning_effort';
sending one re-enables the reasoning trace."
  (quoth--select-in-origin
   (let* ((headers '("" "effort unset" "effort set"))
          (rows (list
                 (list "thinking off"
                       (quoth--select-effort-matrix-cell 'off nil)
                       (quoth--select-effort-matrix-cell 'off t))
                 (list "thinking on"
                       (quoth--select-effort-matrix-cell 'on nil)
                       (quoth--select-effort-matrix-cell 'on t))
                 (list "thinking unset"
                       (quoth--select-effort-matrix-cell 'unset nil)
                       (quoth--select-effort-matrix-cell 'unset t))))
          (all (cons headers rows))
          (widths (cl-loop for c below (length headers)
                           collect (1+ (apply #'max
                                              (mapcar (lambda (row)
                                                        (length (nth c row)))
                                                      all)))))
          (fmt (concat "%-" (number-to-string (nth 0 widths)) "s   %-"
                       (number-to-string (nth 1 widths)) "s   %-"
                       (number-to-string (nth 2 widths)) "s")))
     (concat
      "Reasoning outcome (hyper; tested on deepseek-v4-pro-0813):"
      "\n"
      (mapconcat (lambda (row) (apply #'format fmt row)) all "\n")))))

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
    (run-hooks 'quoth-after-model-change-hook)
    (message "Model: %s"
	     (or (and (not (string= choice "default")) choice)
		 quoth-openai-default-model))))

(defun quoth--select-thinking-toggle (&rest _)
  "Toggle thinking on/off for the current buffer.
Cycles off -> on -> off; the unset (provider default) state is only
reachable via `quoth--select-defaults-apply'."
  (interactive)
  (quoth--select-apply-thinking (if (eq quoth--session-thinking t)
                                    :json-false
                                  t)))

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

(defconst quoth--select-info-labels
  '("provider" "model" "thinking" "effort")
  "Labels shown by the selector info lines, in display order.")

(defun quoth--select-label (label)
  "Return \"LABEL:\" padded so the value column aligns across lines.
The colon stays immediately after LABEL; padding is inserted after
the colon to align the value with the longest selector label."
  (concat label ":"
          (make-string
           (- (apply #'max (mapcar #'length quoth--select-info-labels))
              (length label))
           ?\s)
          " "))

(defun quoth--select-info-thinking (&rest _)
  "Return the thinking state as a suffix description.
nil means the key is omitted (provider default); t sends
`thinking: true'; :json-false sends `thinking: false'."
  (quoth--select-in-origin
   (format "%s%s" (quoth--select-label "thinking")
           (cond
            ((eq quoth--session-thinking t) "on")
            ((eq quoth--session-thinking :json-false) "off")
            (t "unset (provider default)")))))

(defun quoth--select-info-effort (&rest _)
  "Return the effort level as a suffix description.
When `quoth--session-reasoning-effort' is nil, no reasoning_effort
is sent on the request, so the gateway applies its own default;
show \='unset\=' in that case, with the catalog documented default
as a hint when available."
  (quoth--select-in-origin
   (let* ((entry (quoth--select-effective-model-entry))
          (catalog-default (and entry
                                (plist-get entry :default-reasoning-effort)))
          (levels (and entry (plist-get entry :reasoning-levels))))
     (format "%s%s%s" (quoth--select-label "effort")
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
  "Return the active provider name as a suffix description."
  (quoth--select-in-origin
   (format "%s%s" (quoth--select-label "provider") (or quoth-active-provider-name "hyper"))))

(defun quoth--select-info-model (&rest _)
  "Return the current model with pricing detail as a suffix description."
  (quoth--select-in-origin
   (let* ((models  (and quoth-active-provider
                        (quoth-provider-p quoth-active-provider)
                        (quoth-provider--models quoth-active-provider)))
          (current (quoth--select-current-model))
          (prices  (and models current
                        (quoth--select-model-detail models current))))
     (string-trim
      (format "%s%s%s" (quoth--select-label "model")
              (or current "-")
              (if prices (format "  (%s)" prices) ""))))))

(defun quoth--select-provider-switch (&rest _)
  "Switch the active provider (placeholder — only hyper is registered)."
  (interactive)
  (let* ((names (mapcar (lambda (e) (plist-get e :name)) quoth-providers))
	 (choice (completing-read "Provider: " names nil t)))
    (when choice
      (setq quoth-active-provider-name choice)
      (message "Provider: %s" choice))))


(transient-define-prefix quoth-select-model-menu ()
                         "Model and attribute selector for Quoth."
                         [("p" quoth--select-provider-switch
                           :description quoth--select-info-provider :transient t)
                          ("m" quoth--select-model-picker
                           :description quoth--select-info-model :transient t)
                          ("t" quoth--select-thinking-toggle
                           :description quoth--select-info-thinking
                           :transient t :if quoth--select-can-reason-p)
                          ("e" quoth--select-effort-picker
                           :description quoth--select-info-effort
                           :transient t :if quoth--select-has-reasoning-levels-p)]
                         [(" " :info* #'quoth--select-info-reasoning-matrix :format "%d"
                           :if quoth--select-can-reason-p)]
                         [("d" quoth--select-defaults-apply
                           :description "use provider defaults" :transient t)
                          ("q" transient-quit-one :description "quit")])

(provide 'quoth-select)
;;; quoth-select.el ends here
