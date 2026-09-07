;;; quoth-ollama-provider.el --- Ollama Cloud provider for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1"))
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

;; The Ollama Cloud provider for quoth.el: streamed chat completions
;; against ollama.com's OpenAI-compatible surface (`/v1'), a thin
;; subclass of the shared `quoth-openai-provider' base.  The native
;; `/api' surface is used for exactly one thing the OpenAI protocol
;; cannot do: the model catalog, assembled from `GET /api/tags'
;; (membership) plus a parallel `POST /api/show' fan-out (capabilities
;; and context length).  See OLLAMA-CLOUD-API.md for the API reference.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'subr-x)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The shared OpenAI-provider base pulls the protocol, the wire
;;; client, and the context assembly.
(eval-and-compile
  (dolist (dep '("quoth-openai-provider"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(declare-function quoth--openai-alist-get "quoth-openai-client" (key alist))
(declare-function quoth--debug-log "quoth.el" (category message))
(declare-function quoth-openai-provider--token-from-auth-source
                  "quoth-openai-provider" (host user label custom))
(declare-function quoth-openai-provider--models-seed-read
                  "quoth-openai-provider" (file decode))

(defcustom quoth-ollama-base-url "https://ollama.com/v1"
  "Base URL of the Ollama OpenAI-compatible endpoint.
Chat completions ride `BASE-URL/chat/completions'; the native catalog
endpoints (`/api/tags', `/api/show') derive from the server root.
Overridden by the OLLAMA_URL environment variable when set."
  :type 'string
  :group 'quoth-ollama)

(defcustom quoth-ollama-token #'quoth-ollama--token-from-auth-source
  "Bearer access token for Ollama Cloud.
Get one at `https://ollama.com/settings/keys`.

May be a string, a function of no arguments that returns the token,
or nil to request without a token.  The default looks the token up in
`auth-source' (see `quoth-ollama--token-from-auth-source')."
  :type '(choice (function-item quoth-ollama--token-from-auth-source)
                 (const :tag "No token" nil)
                 string
                 function)
  :group 'quoth-ollama)

(cl-defstruct (quoth-ollama-provider
               (:include quoth-openai-provider (type 'ollama))
               (:constructor nil)
               (:constructor quoth-make-ollama-provider
                             (&key buffer working-directory base-url token model
                                   &aux (type 'ollama) (completion-action nil)))
               (:copier nil))
  "Provider that talks to Ollama Cloud's OpenAI-compatible surface.")

(defun quoth-ollama--token-from-auth-source ()
  "Return the ollama bearer token from `auth-source'.
Looks up host `ollama.com' with user `apikey'.  Signals an error
when no secret is found, with setup instructions."
  (quoth-openai-provider--token-from-auth-source
   "ollama.com" "apikey" "ollama" "quoth-ollama-token"))

(defun quoth-ollama--resolve-token (token)
  "Resolve TOKEN to a bearer token string, or nil.
TOKEN may be nil, a string, or a function of no arguments returning
either.  Functions are called and the result is resolved recursively."
  (quoth-openai-provider--resolve-token token))

(defun quoth-ollama--base-url (provider)
  "Return PROVIDER's resolved OpenAI base URL.
The provider slot wins, then the OLLAMA_URL environment variable,
then the `quoth-ollama-base-url' default."
  (or (quoth-ollama-provider-base-url provider)
      (getenv "OLLAMA_URL")
      quoth-ollama-base-url))

(defun quoth-ollama--api-root (base-url)
  "Return the native API root for the server behind BASE-URL.
The provider targets `.../v1' (the OpenAI surface); the native
catalog endpoints live at the server root: `https://ollama.com/v1'
maps to `https://ollama.com/api'.  A trailing `/v1' is stripped; a
base URL without it is used as-is."
  (let ((root (if (string-suffix-p "/v1" base-url)
                  (substring base-url 0 (- (length base-url) 3))
                base-url)))
    (concat root "/api")))

(defun quoth-ollama--resolve-token-for (provider)
  "Return the resolved bearer token for PROVIDER.
The provider's token slot wins over `quoth-ollama-token'."
  (quoth-ollama--resolve-token
   (or (quoth-ollama-provider-token provider) quoth-ollama-token)))

;;; Model catalog: /api/tags + /api/show fan-out.

(defun quoth-ollama--tags-names (obj)
  "Return the model names listed by a parsed /api/tags object OBJ.
The `models' array's `name' fields carry the membership; anything
else is informational.  Returns a list of strings, or nil when the
shape is wrong."
  (let ((models (and obj (quoth--openai-alist-get "models" obj))))
    (when (vectorp models)
      (delq nil
            (mapcar (lambda (m)
                      (let ((name (and m
                                       (quoth--openai-alist-get "name" m))))
                        (and (stringp name) name)))
                    (append models nil))))))

(defun quoth-ollama--context-length (model-info)
  "Return the context length from a parsed MODEL-INFO alist, or nil.
The key is architecture-prefixed (`gptoss.context_length',
`gemma4.context_length'), so the `.context_length' suffix is matched,
not a fixed key name.  Keys arrive as symbols or strings depending on
the JSON engine, so both shapes match."
  (when (and model-info (consp model-info))
    (let ((hit (cl-find-if
                (lambda (cell)
                  (let ((key (and (consp cell) (car cell))))
                    (and (or (stringp key) (symbolp key))
                         (string-suffix-p
                          ".context_length"
                          (if (symbolp key) (symbol-name key) key)))))
                model-info)))
      (and hit (numberp (cdr hit)) (cdr hit)))))

(defun quoth-ollama--normalize-model (id capabilities context-length)
  "Normalize one catalog entry into the protocol model plist.
ID is the model name; CAPABILITIES is the vector (or list) of
capability strings from /api/show; CONTEXT-LENGTH is the decoded
`<arch>.context_length'.  The cloud reports no pricing or
default-max-tokens, so those keys stay nil and the selector renders
its `?' placeholders.  Used by both the bundled-seed reader and the
live refresh, so the two are byte-compatible."
  (let ((caps (if (vectorp capabilities)
                  (append capabilities nil)
                capabilities)))
    (list :id id
          :name id
          :context-window context-length
          :default-max-tokens nil
          :cost-in nil
          :cost-out nil
          :cost-cache-write nil
          :cost-cache-hit nil
          :can-reason (and (member "thinking" caps) t)
          :reasoning-levels nil
          :default-reasoning-effort nil
          :supports-attachments (and (member "vision" caps) t))))

(defconst quoth-ollama--models-seed-file "quoth-ollama-models.json"
  "Bundled catalog snapshot that seeds the ollama model catalog.
Regenerated by `make models`; shipped in the package tarball.")

(defun quoth-ollama--models-seed-read (file)
  "Read the bundled catalog snapshot FILE into normalized plists.
The snapshot is a JSON array, one object per model, with the keys
`id', `capabilities', `context_length', `parameter_size', and
`quantization_level'.  Returns nil when FILE is missing, unreadable,
or unparseable — the seed is absent, never an error, so the cache
read falls through to the cold fallback path."
  (quoth-openai-provider--models-seed-read
   file
   (lambda (m)
     (let ((id (and m (quoth--openai-alist-get "id" m))))
       (and (stringp id)
            (quoth-ollama--normalize-model
             id
             (quoth--openai-alist-get "capabilities" m)
             (quoth--openai-alist-get "context_length" m)))))))

(defun quoth-ollama--show-one-async (api token name on-done)
  "Fetch one model's /api/show metadata and deliver the normalized plist.
API is the native catalog root; NAME is the model name; TOKEN is the
resolved bearer (or nil).  ON-DONE receives the plist, or nil when the
show fails."
  (quoth-openai-provider--fetch-json
   (concat api "/show")
   token "POST"
   (quoth-json-write `((model . ,name)))
   (lambda (show)
     (funcall on-done
              (when show
                (let ((caps (quoth--openai-alist-get "capabilities" show))
                      (mi (quoth--openai-alist-get "model_info" show)))
                  (quoth-ollama--normalize-model
                   name caps (quoth-ollama--context-length mi))))))))

(defun quoth-ollama--show-all-async (api token names on-done)
  "Fan out one POST /api/show per name in NAMES, all in parallel.
API is the native catalog root and TOKEN the resolved bearer (or
nil).  The join is all-or-nothing: every show must land, or ON-DONE
receives nil overall (a single flaky show keeps the previous cache
entry).  On success ON-DONE receives the normalized plist list in
NAMES order."
  (let* ((pending (length names))
         (results (make-vector (length names) nil))
         (failed nil))
    (cl-loop for name in names
             for i from 0
             ;; Bind the index per iteration: the async callback must
             ;; see this round's slot, not the loop's final value.
             do (let ((slot i))
                  (quoth-ollama--show-one-async
                   api token name
                   (lambda (entry)
                     (if (null entry)
                         (setq failed t)
                       (aset results slot entry))
                     ;; Join: deliver once every show landed.
                     (setq pending (1- pending))
                     (when (zerop pending)
                       (funcall on-done
                                (unless failed
                                  (append results nil))))))))))

(defun quoth-ollama--fetch-models-async (provider on-done)
  "Fetch the model catalog for PROVIDER, delivering it to ON-DONE once.
The catalog is assembled in two steps: `GET /api/tags` yields the
model names, then one `POST /api/show' per name — all spawned in
parallel — contributes capabilities and the context length.  The
join is all-or-nothing: every show must land, or the whole fetch
delivers nil (the cache keeps its previous entry).  ON-DONE receives
the normalized plist list, or nil.  Returns the tags curl process."
  (let ((token (quoth-ollama--resolve-token-for provider))
        (api (quoth-ollama--api-root (quoth-ollama--base-url provider))))
    (quoth-openai-provider--fetch-json
     (concat api "/tags")
     token "GET" nil
     (lambda (tags)
       (let ((names (quoth-ollama--tags-names tags)))
         (if (null names)
             ;; No membership: an empty or broken tags fetch fails the
             ;; whole catalog (an empty cloud is not a catalog).
             (progn
               (quoth--debug-log
                'model-catalog "ollama tags fetch failed")
               (funcall on-done nil))
           (quoth-ollama--show-all-async
            api token names on-done)))))))

;;; Ollama provider methods.

(cl-defmethod quoth-openai-provider--provider-token
  ((_provider quoth-ollama-provider))
  "The ollama token defcustom."
  quoth-ollama-token)

(cl-defmethod quoth-provider--body-extras ((_provider quoth-ollama-provider))
  "Return ollama's body extras: the usage-stream option.
Ollama's usage rides a final chunk gated on
`stream_options.include_usage' (the chunk's empty `choices' array is
tolerated by the SSE parser)."
  '((stream_options .
                    ((include_usage . t)))))

(cl-defmethod quoth-provider--models-key ((provider quoth-ollama-provider))
  "The ollama catalog key: the PROVIDER type and the resolved base URL."
  (cons 'ollama (quoth-ollama--base-url provider)))

(cl-defmethod quoth-provider--models-seed ((provider quoth-ollama-provider))
  "Seed the catalog for PROVIDER from the bundled snapshot.
Reads `quoth-ollama--models-seed-file' next to this module through the
same normalize pipeline as the live refresh, so the seed is
byte-compatible with what the network refresh delivers and the
override is a plain cache overwrite.  Only the default server is
seeded: a custom base URL (`OLLAMA_URL' or `quoth-ollama-base-url')
points at another server and gets no snapshot.  Returns nil when the
file is missing or bad — never an error."
  (when (string= (quoth-ollama--base-url provider)
                 quoth-ollama-base-url)
    (quoth-ollama--models-seed-read
     (expand-file-name quoth-ollama--models-seed-file
                       quoth-openai-provider--models-seed-directory))))

(cl-defmethod quoth-provider--models-async ((provider quoth-ollama-provider)
                                            on-done)
  "Fetch the ollama model catalog for PROVIDER and deliver the plists.
The tags + show fan-out runs in `quoth-ollama--fetch-models-async';
ON-DONE receives the model list, or nil when the fetch fails.  Returns
the tags curl process."
  (quoth-ollama--fetch-models-async provider on-done))

(provide 'quoth-ollama-provider)
;;; quoth-ollama-provider.el ends here
