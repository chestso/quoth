;;; quoth-json.el --- JSON decode/encode abstraction, native C when possible  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas Christensen

;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;; Keywords: comm, tools

;; This file is part of Quoth.

;; Quoth is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A thin JSON decode/encode abstraction.  Emacs ships a native C JSON
;; engine (`json-parse-string' / `json-serialize', gated by
;; `json-available-p') since Emacs 27 that is far faster than the pure
;; Elisp `json.el' parser.  Quoth decodes one SSE event payload per
;; streamed delta -- hundreds per long conversation -- so decoding is
;; the hot path and measurably faster in C (~14x in a micro-benchmark on
;; a typical payload).  This module routes decoding through the native
;; engine and keeps everything at the single, normalized API point below,
;; so swapping engines later is a one-file change.
;;
;;    - `quoth-json-read'  JSON string -> ALIST (the shape
;;      `json-read-from-string' returned), or nil when malformed.
;;    - `quoth-json-write' Lisp value -> JSON string.
;;
;; Why alists: every consumer walks decoded objects with `assoc' and
;; `quoth--openai-alist-get', so `quoth-json-read' drives the native
;; parser with `:object-type 'alist' to preserve that interface, and keys
;; come back in document order exactly as before.
;;
;; Representation parity: `json.el' maps JSON `null' -> nil and
;; `false' -> `:json-false', whereas the native engine's defaults are
;; `:null' and `:false'.  `quoth-json-read' passes `:null-object nil'
;; and `:false-object :json-false' so callers (and tests, e.g. an
;; optional tool arg decoded from `\"workdir\":null') keep the exact
;; `json.el' contract and cannot tell which engine produced the object.
;;
;; Encoding stays on `json-encode'.  The write inputs are string-keyed
;; alists (request bodies built from buffer metadata), and the native
;; `json-serialize' requires symbol keys for alist/plist objects or a
;; hash-table for string keys -- so pushing it would need a whole-tree
;; key-normalization walk per request, negating the speedup.  Encoding
;; runs once per request (not per delta), so it is not the hot path.
;; `quoth-json-write' is still the single swap point if a native-safe
;; fast path ever arrives.
;;
;; The pretty-printer is deliberately NOT routed through this module:
;; the native engine has no pretty-printer, so `quoth--openai-json-pretty'
;; keeps using `json-pretty-print'.

;;; Code:

(require 'json)

(declare-function json-parse-string "json.c" (string &rest args))

(defconst quoth-json-native-p
  (and (fboundp 'json-parse-string) (json-available-p))
  "Non-nil when the native C JSON parser is available.")

(defun quoth-json-read (json-string)
  "Decode JSON-STRING into an alist, or nil when malformed.
Objects decode as alists (the source order `json-read-from-string'
returned, which Quoth consumers walk with `assoc').  JSON `null'
decodes to nil and `false' to `:json-false', matching `json.el'.
Returns nil on invalid input instead of signaling."
  (ignore-errors
    (if quoth-json-native-p
        (json-parse-string json-string
                           :object-type 'alist
                           :null-object nil
                           :false-object :json-false)
      (json-read-from-string json-string))))

(defun quoth-json-write (object)
  "Encode OBJECT (alist / vector / scalar) into a JSON string.
Objects use string keys (`(KEY . VAL)') as `json-encode' expects, so
this stays on `json-encode' -- the native serializer would need a
tree walk to convert string-keyed alists.  See the module header."
  (json-encode object))

(provide 'quoth-json)
;;; quoth-json.el ends here
