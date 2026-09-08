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
;; the cache; the suffix gates re-run after every suffix command
;; (`:refresh-suffixes') and when a background refresh lands
;; (`quoth-provider-models-hook' through `quoth--select-refresh-menu'),
;; so `t'/`e' follow the current model instead of the one the menu
;; opened with.

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
(declare-function quoth--group-number-compact "quoth.el" (n))
(declare-function quoth-provider-cleanup "quoth-provider" (provider &rest _))

(defmacro quoth--select-in-origin (&rest body)
  "Evaluate BODY in the buffer that invoked the transient."
  `(with-current-buffer (or transient--original-buffer
                            (current-buffer))
     ,@body))

;;; Helper functions (testable without transient UI)

(defun quoth--model-price (cost)
  "Format the per-1M-token price COST compactly for the suffix.
Sub-dollar prices keep two decimals, sub-dime ones three \(the
distinguishing digits live there); zero renders bare.  Returns nil
for non-numbers."
  (when (numberp cost)
    (cond ((zerop cost) "$0/1M")
          ((< cost 0.1) (format "$%.3f/1M" cost))
          (t            (format "$%.2f/1M" cost)))))

(defun quoth--model-price-part (cost label)
  "Return the suffix part for COST prefixed by LABEL, or nil.
LABEL positions the price \(\"in\", \"out\", \"cache-write\",
\"cache-hit\"); an unreported COST drops the whole part, label
included."
  (let ((price (quoth--model-price cost)))
    (and price (format "%s %s" label price))))

(defun quoth--model-suffix (models id)
  "Return the display suffix annotating model ID in MODELS, or nil.
Renders the catalog fields the protocol normalizes: display name,
context window, per-token input/output costs, the two cache prices
\(write: building a fresh prefix; hit: the conversation's turns
after the first), reasoning-effort levels, and vision support —
each part present only when the catalog reports it, joined by two
spaces with a two-space lead \(completion UIs concatenate the
suffix directly onto the candidate).  Returns nil when ID names
no catalog entry."
  (let ((m (quoth--select-current-model-entry models id)))
    (when m
      (let* ((name (and (not (equal (plist-get m :name) id))
                        (plist-get m :name)))
             (ctx  (plist-get m :context-window))
             (lev  (plist-get m :reasoning-levels))
             (vis  (plist-get m :supports-attachments))
             (parts (delq nil
                          (list name
                                (when (numberp ctx)
                                  (format "%s ctx"
                                          (quoth--group-number-compact ctx)))
                                (quoth--model-price-part
                                 (plist-get m :cost-in) "in")
                                (quoth--model-price-part
                                 (plist-get m :cost-out) "out")
                                (quoth--model-price-part
                                 (plist-get m :cost-cache-write)
                                 "cache-write")
                                (quoth--model-price-part
                                 (plist-get m :cost-cache-hit)
                                 "cache-hit")
                                (when (and (consp lev) lev)
                                  (format "effort %s"
                                          (mapconcat #'identity lev "|")))
                                (when vis "vision")))))
        (when parts
          (concat "  " (mapconcat #'identity parts "  ")))))))

(defun quoth--model-affixation (models)
  "Return the affixation function annotating MODELS' candidates.
Takes the visible candidate list and returns \(CANDIDATE \"\"
SUFFIX) triples: the id stays the sole completion text \(matching
and the returned string are untouched), while the suffix carries
the model's name, pricing, and capabilities; `default' annotates
as the provider default.  The suffix rides the stock
`completions-annotations' face, so every completion UI \(the
\*Completions\* buffer, icomplete, vertico, marginalia) renders it
dim and consistent."
  (lambda (cands)
    (mapcar (lambda (c)
              (list c ""
                    (propertize
                     (if (string= c "default")
                         "  provider default"
                       (or (quoth--model-suffix models c) ""))
                     'face 'completions-annotations)))
            cands)))

(defun quoth--model-completion-table (models)
  "Return a completion table over the ids in MODELS plus `default'.
A table function answering the `metadata' action: candidates
complete, match, and return as the bare id \(free-form qualified
ids such as \"ollama/gemma\" still pass through), and the metadata
carries the `quoth-model' category plus the affixation function
from `quoth--model-affixation', so the minibuffer shows each
model's name, pricing, and capabilities next to its id."
  (let ((ids (mapcar (lambda (m) (plist-get m :id)) models)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          (list 'metadata
                (cons 'category 'quoth-model)
                (cons 'affixation-function
                      (quoth--model-affixation models)))
        (complete-with-action action (cons "default" ids) string pred)))))

(defun quoth--select-current-model-entry (models model-id)
  "Find the model entry with :id MODEL-ID in MODELS, or nil."
  (cl-find model-id models
           :test #'string=
           :key (lambda (m) (plist-get m :id))))

(defun quoth--select-apply-thinking (value)
  "Set `quoth--session-thinking' to VALUE in the current buffer.
VALUE is :json-false (send `thinking: false', silencing reasoning)
or nil (unset: omit the key, the provider default applies)."
  (setq-local quoth--session-thinking value))

(defun quoth--select-apply-effort (effort)
  "Set `quoth--session-reasoning-effort' to EFFORT in the current buffer."
  (setq-local quoth--session-reasoning-effort
              (if effort effort nil)))

(defun quoth--select-apply-defaults ()
  "Clear both session attribute slots, reverting to provider defaults."
  (setq-local quoth--session-thinking nil)
  (setq-local quoth--session-reasoning-effort nil))

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

(defun quoth--select-has-reasoning-levels-p ()
  "Return non-nil if the current model has reasoning levels to pick from."
  (quoth--select-in-origin
   (let ((entry (quoth--select-effective-model-entry)))
     (and entry
          (let ((levels (plist-get entry :reasoning-levels)))
            (and (consp levels) levels))))))

(defun quoth--select-model-picker (&rest _)
  "Prompt for a model from the active provider's catalog.
Reads the catalog from the protocol's global cache; a cold cache is
usually seeded from the bundled snapshot first
\(`quoth-provider--models-seed'), and the static fallback covers the
seed-less cases while a background refresh runs, with the message
noting it.  The completion table annotates every candidate with its
name, pricing, and capabilities \(see `quoth--model-suffix').  The
choice writes the buffer's session model (and the provider's model
slot cache) plus the sticky `quoth-model-by-provider' entry;
`default' clears all three.  A provider-qualified id
\(\"ollama/gemma\") typed free-form switches the buffer to that
provider and sets the bare model in one step."
  (interactive)
  (let* ((models (and quoth-active-provider
		      (quoth-provider-p quoth-active-provider)
		      (quoth-provider-models-cached quoth-active-provider)))
	 (cold (null models))
	 (fallback (quoth--select-current-model))
	 (table (if models
		    (quoth--model-completion-table models)
		  (list fallback)))
	 (choice (completing-read
		  "Model: "
		  table
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
  "Toggle reasoning on/off for the current buffer.
Cycles unset -> off -> unset.  Every thinking model reasons by
default with no field sent, so the toggle's only wire effect is the
off state: `thinking: false' silences the reasoning trace.  The
off state is lost when a `reasoning_effort' is picked (see
`quoth--select-effort-picker'); the unset (provider default) state
is also reachable via `quoth--select-defaults-apply'."
  (interactive)
  (quoth--select-apply-thinking
   (if (eq quoth--session-thinking :json-false) nil :json-false)))

(defun quoth--select-effort-picker (&rest _)
  "Prompt for a reasoning effort level from the current model's levels.
Picking a level implies reasoning on: an explicit `reasoning_effort'
overrides `thinking: false' on the wire, so a prior reasoning-off
toggle is cleared when the level is applied."
  (interactive)
  (let ((entry (quoth--select-effective-model-entry)))
    (if entry
	(let ((levels (plist-get entry :reasoning-levels)))
	  (if (and levels (consp levels))
	      (let ((choice (completing-read "Effort: " levels nil t)))
		(when choice
		  (quoth--select-apply-effort choice)
		  (quoth--select-apply-thinking nil)
		  (message "Effort: %s" choice)))
	    (message "Effort: no reasoning levels for this model")))
      (message "Effort: no model catalog available"))))

(defun quoth--select-defaults-apply (&rest _)
  "Revert to provider defaults for model attributes."
  (interactive)
  (quoth--select-apply-defaults))

(defconst quoth--select-info-labels
  '("provider" "model" "reasoning" "effort")
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
  "Return the reasoning state as a suffix description.
nil means the key is omitted (every thinking model reasons by
default); :json-false sends `thinking: false', silencing the
reasoning trace."
  (quoth--select-in-origin
   (format "%s%s" (quoth--select-label "reasoning")
           (if (eq quoth--session-thinking :json-false)
               "off (thinking: false)"
             "on (provider default)"))))

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
  "Return the current model with pricing detail as a suffix description.
The detail is the same affixation suffix the model read renders
\(`quoth--model-suffix'), so the menu's `m' line and the
minibuffer candidates show identical pricing and capability text."
  (quoth--select-in-origin
   (let* ((models  (and quoth-active-provider
                        (quoth-provider-p quoth-active-provider)
                        (quoth-provider-models-cached quoth-active-provider)))
          (current (quoth--select-current-model))
          (prices  (and models current
                        (quoth--model-suffix models current))))
     (string-trim
      (format "%s%s%s" (quoth--select-label "model")
              (or current "-")
              (if prices prices ""))))))

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
when the landing refresh rebuilds the menu through
`quoth--select-refresh-menu'."
  (interactive)
  (when (and quoth-active-provider
             (quoth-provider-p quoth-active-provider))
    (quoth-provider-models-refresh quoth-active-provider 'force)
    (message "refreshing model catalog...")))

(defun quoth--select-refresh-menu ()
  "Rebuild an open selector menu, re-running its suffix gates.
Transient evaluates the `:if' gate \(`quoth--select-has-reasoning-levels-p')
only while building the layout, so the suffix set is otherwise frozen
at the model the menu opened with: switching provider or model
in-session, or a catalog
refresh landing while the menu is open, would leave the thinking and
effort suffixes stuck in the state of the old catalog entry.  This
rebuilds the layout of the
visible menu so the gates follow the current buffer state.  Do
nothing when the menu is closed, suspended \(e.g. behind a suffix's
minibuffer read), or another transient is active."
  (when (and transient--prefix
             (eq (oref transient--prefix command)
                 'quoth-select-model-menu)
             (memq transient--transient-map
                   overriding-terminal-local-map))
    (transient--refresh-transient)))

;; A catalog refresh landing while the menu is open rebuilds it; the
;; suffix commands themselves are covered by the prefix's
;; `:refresh-suffixes'.
(add-hook 'quoth-provider-models-hook #'quoth--select-refresh-menu)

(transient-define-prefix quoth-select-model-menu ()
                         "Model and attribute selector for Quoth."
                         :refresh-suffixes t
                         [("p" quoth--select-provider-switch
                           :description quoth--select-info-provider :transient t)
                          ("m" quoth--select-model-picker
                           :description quoth--select-info-model :transient t)
                          ("t" quoth--select-thinking-toggle
                           :description quoth--select-info-thinking
                           :transient t)
                          ("e" quoth--select-effort-picker
                           :description quoth--select-info-effort
                           :transient t :if quoth--select-has-reasoning-levels-p)]
                         [("g" quoth--select-refresh-catalog
                           :description "refresh model catalog" :transient t)
                          ("d" quoth--select-defaults-apply
                           :description "use provider defaults" :transient t)
                          ("q" transient-quit-one :description "quit")])

(provide 'quoth-select)
;;; quoth-select.el ends here
