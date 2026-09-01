;;; quoth-test-json.el --- tests for the quoth-json abstraction  -*- lexical-binding: t; -*-

(declare-function quoth-json-read "quoth-json" (json-string))
(declare-function quoth-json-write "quoth-json" (object))

;;; Commentary:
;;; Exercises `quoth-json-read' / `quoth-json-write': alist shape,
;;; `null'->nil and `false'->:json-false parity with `json.el', and
;;; malformed-input behavior.

;;; Code:

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
