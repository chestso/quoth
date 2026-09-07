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
;; (C-c \" m) for choosing a model from the active provider's catalog,
;; toggling thinking/reasoning attributes, and showing model prices.
;; The selector layer owns the UI; it reads the catalog through the
;; protocol's global cache (`quoth-provider-models-cached' — never a
;; fetch), applies choices through the provider generic
;; `quoth-provider--apply-model', and sets per-session attributes in
;; buffer-local variables (`quoth--session-thinking',
;; `quoth--session-reasoning-effort').  The `g' suffix force-refreshes
;; the cache; the menu redraws when a background refresh lands
;; (`quoth-provider-models-hook').

;;; Code:

(require 'cl-lib)
(require 'transient)

;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: `quoth-provider'
;;; first, then `quoth-openai-client'.
(eval-and-compile
  (dolist (dep '("quoth-provider" "quoth-openai-client"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defvar transient--original-buffer)

;; The selector calls core functions defined in `quoth.el' and the
;; provider protocol; the declarations keep the byte-compiler happy
;; without loading the core from here.
(declare-function quoth--provider-default-model "quoth.el" (name))
(declare-function quoth--instantiate-provider "quoth.el" (name buf dir))
(declare-function quoth--seed-session-model "quoth.el" ())
(declare-function quoth--set-model-spec "quoth.el" (spec))
(declare-function quoth--set-model-default "quoth.el" ())
(declare-function quoth--apply-model-spec "quoth.el" (spec))
(declare-function quoth-provider-cleanup "quoth-provider" (provider &rest _))

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
MODELS is the model list (plists) to look the id up in.
Context window and per-token costs appear; the model id is shown
by the caller.  The two cache prices (write: what building a fresh
prefix costs; hit: what a conversation's turns after the first
actually bill) appear when the catalog reports them.  Segments join
with two spaces."
  (let ((m (quoth--select-current-model-entry models model-id)))
    (when m
      (let ((ctx   (or (plist-get m :context-window) "?"))
            (cin   (plist-get m :cost-in))
            (cout  (plist-get m :cost-out))
            (write (plist-get m :cost-cache-write))
            (hit   (plist-get m :cost-cache-hit)))
        (string-trim
         (mapconcat
          #'identity
          (delq nil
                (list (format "ctx %s" ctx)
                      (if (numberp cin)
                          (format "$%.2f/1M in" cin)
                        "$?/1M in")
                      (if (numberp cout)
                          (format "$%.2f/1M out" cout)
                        "$?/1M out")
                      (when (numberp write)
                        (format "cache-write $%.2f/1M" write))
                      (when (numberp hit)
                        (format "cache-hit $%.2f/1M" hit))))
          "  "))))))

;;; Transient menu
(defun quoth--select-current-model ()
  "Return the effective model id for the current buffer, or nil.
Reads the buffer's session model slot; when nil, the resolved
provider-chain default (sticky entry, registry :default-model, global
default)."
  (or quoth--session-model
      (quoth--provider-default-model quoth--session-provider)))

(defun quoth--select-effective-model-entry ()
  "Return the model plist for the effective model, or nil.
Reads the catalog from the protocol's global cache; a cold cache
returns nil (the menu's `g' suffix or the buffer-init prefetch warms
it)."
  (let* ((models (and quoth-active-provider
                      (quoth-provider-p quoth-active-provider)
                      (quoth-provider-models-cached quoth-active-provider)))
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
\(the matrix wording was validated on the hyper provider with
`deepseek-v4-pro-0813'): `thinking: false' suppresses reasoning when
sent alone, but sending `reasoning_effort' alongside re-enables the
reasoning trace."
  (pcase thinking
    ('off (if effort-p "reasoning" "direct (no reason)"))
    ('on "reasoning")
    ('unset (if effort-p "reasoning" "provider default"))
    (_ "?")))

(defun quoth--select-info-reasoning-matrix (&rest _)
  "Return a compact visual matrix of the thinking/effort interplay.
The wording is validated on the hyper provider
\(`deepseek-v4-pro-0813'): `thinking: false' suppresses reasoning only
when sent without `reasoning_effort'; sending one re-enables the
reasoning trace.  Other providers may differ — the server decides what
the keys mean."
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
      "Reasoning outcome (hyper-tested; provider-dependent):"
      "\n"
      (mapconcat (lambda (row) (apply #'format fmt row)) all "\n")))))

(defun quoth--select-model-picker (&rest _)
  "Prompt for a model from the active provider's catalog.
Reads the catalog from the protocol's global cache; a cold cache is
usually seeded from the bundled snapshot first
\(`quoth-provider--models-seed'), and the static fallback covers the
seed-less cases while a background refresh runs, with the message
noting it.  The choice writes the buffer's session model (and the
provider's model slot cache) plus the sticky
`quoth-model-by-provider' entry; `default' clears all three.  A
provider-qualified id (\"ollama/gemma\") typed free-form switches the
buffer to that provider and sets the bare model in one step."
  (interactive)
  (let* ((models (and quoth-active-provider
		      (quoth-provider-p quoth-active-provider)
		      (quoth-provider-models-cached quoth-active-provider)))
	 (cold (null models))
	 (fallback (quoth--select-current-model))
	 (choices (if models
		      (quoth--model-choices models)
		    (list (cons fallback
				(format "%s (default)" fallback)))))
	 (choice (completing-read
		  "Model: "
		  (cons (cons "default" "default (provider default)")
			choices)
		  ;; Require-match is off: candidates are the active
		  ;; provider's catalog, but a provider-qualified id
		  ;; ("ollama/gemma") typed free-form routes through
		  ;; `quoth--set-model-spec' to another provider.
		  nil nil nil)))
    (if (string= choice "default")
	(quoth--set-model-default)
      (quoth--set-model-spec choice))
    (when cold
      (quoth-provider-models-refresh quoth-active-provider)
      (message "fetching model catalog..."))
    (message "Model: %s" (or quoth--session-model fallback))))

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
   (format "%s%s" (quoth--select-label "provider")
           (or quoth--session-provider "hyper"))))

(defun quoth--select-info-model (&rest _)
  "Return the current model with pricing detail as a suffix description."
  (quoth--select-in-origin
   (let* ((models  (and quoth-active-provider
                        (quoth-provider-p quoth-active-provider)
                        (quoth-provider-models-cached quoth-active-provider)))
          (current (quoth--select-current-model))
          (prices  (and models current
                        (quoth--select-model-detail models current))))
     (string-trim
      (format "%s%s%s" (quoth--select-label "model")
              (or current "-")
              (if prices (format "  (%s)" prices) ""))))))

(defun quoth--select-provider-switch (&rest _)
  "Switch the active provider for the current buffer.
Buffer-local only: routes through `quoth--apply-model-spec', which
writes `quoth--session-provider', aborts any active request on the
old provider, reinstantiates `quoth-active-provider', re-seeds the
session model from the new provider's chain (sticky
`quoth-model-by-provider' entry, registry `:default-model', global
default), keeps thinking/effort \(provider-agnostic), prefetches the
catalog, and refreshes the header line through
`quoth-after-model-change-hook'.  The sticky entry for the new
provider is preserved, not overwritten: switching carries the last
model used there, so this command never writes the sticky alist.
Never writes a global: the default for new buffers is
`quoth-default-provider' and changes only through Customize or
`setq'."
  (interactive)
  (let* ((names (mapcar (lambda (e) (plist-get e :name)) quoth-providers))
	 (choice (completing-read "Provider: " names nil t)))
    (when (and choice (not (string-empty-p choice))
	       (not (string= choice quoth--session-provider)))
      (let ((model (quoth--provider-default-model choice)))
	(quoth--apply-model-spec
	 (list :provider choice :model model))
	(message "Provider: %s" choice)))))

(defun quoth--select-refresh-catalog (&rest _)
  "Force-refresh the model catalog cache and redraw the menu.
The refreshed descriptions (model prices, reasoning levels) recompute
on the next draw; a landing refresh runs
`quoth-provider-models-hook', which also triggers a redraw when the
menu is visible."
  (interactive)
  (when (and quoth-active-provider
             (quoth-provider-p quoth-active-provider))
    (quoth-provider-models-refresh quoth-active-provider 'force)
    (message "refreshing model catalog...")))

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
                         [("g" quoth--select-refresh-catalog
                           :description "refresh model catalog" :transient t)
                          ("d" quoth--select-defaults-apply
                           :description "use provider defaults" :transient t)
                          ("q" transient-quit-one :description "quit")])

(provide 'quoth-select)
;;; quoth-select.el ends here
