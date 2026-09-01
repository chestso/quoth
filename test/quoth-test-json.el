;;; quoth-test-json.el --- JSON abstraction tests for quoth  -*- lexical-binding: t; -*-
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
;;; Exercises `quoth-json-read' / `quoth-json-write': alist shape,
;;; `null'->nil and `false'->:json-false parity with `json.el', and
;;; malformed-input behavior.

;;; Code:

(declare-function quoth-json-read "quoth-json" (json-string))
(declare-function quoth-json-write "quoth-json" (object))

(require 'ert)
(require 'cl-lib)

(ert-deftest quoth-test/json-read-decodes-alist ()
  "`quoth-json-read' yields an alist in source order, like `json.el'."
  (should (equal (quoth-json-read "{\"a\":1,\"b\":2}")
                 '((a . 1) (b . 2)))))

(ert-deftest quoth-test/json-read-null-maps-to-nil ()
  "JSON `null' decodes to nil, matching `json.el' semantics."
  (should (equal (quoth-json-read "{\"a\":null,\"b\":[null]}")
                 '((a) (b . [nil])))))

(ert-deftest quoth-test/json-read-false-maps-to-json-false ()
  "JSON `false' decodes to `:json-false', matching `json.el'."
  (should (equal (quoth-json-read "{\"a\":false}")
                 '((a . :json-false)))))

(ert-deftest quoth-test/json-read-malformed-yields-nil ()
  "Malformed JSON returns nil rather than signaling."
  (should (null (quoth-json-read "not json")))
  (should (null (quoth-json-read "{\"a\""))))

(ert-deftest quoth-test/json-write-round-trips-alist ()
  "`quoth-json-write' encodes an alist into a JSON string."
  (should (equal (quoth-json-write '((a . 1) (b . [2 3])))
                 "{\"a\":1,\"b\":[2,3]}")))

(ert-deftest quoth-test/json-read-write-parity ()
  "A decoded object re-encodes to equivalent JSON."
  (let ((obj (quoth-json-read "{\"a\":1,\"b\":[2,3],\"c\":null}")))
    (should (equal (quoth-json-write obj)
                   "{\"a\":1,\"b\":[2,3],\"c\":null}"))))

(provide 'quoth-test-json)
;;; quoth-test-json.el ends here
