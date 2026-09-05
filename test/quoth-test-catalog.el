;;; quoth-test-catalog.el --- Model-catalog cache tests for quoth  -*- lexical-binding: t; -*-
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
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:

;; The protocol-owned model-catalog cache (`quoth-provider.el'): the
;; async `quoth-provider--models-async' generic, the global TTL cache
;; with stale-while-revalidate, in-flight dedup, the
;; `quoth-provider-models-hook', and the selector's cache-only reads.
;; All tests stub the async generic with an inline fake; the wire
;; round trip lives in quoth-test-hyper's :integration tests.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth" "quoth-provider"))
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

(declare-function quoth-test--with-models-cache "quoth-test" (fn))
(declare-function quoth-test--with-immediate-schedule "quoth-test" (&rest body))

(defun quoth-test--models (&rest entries)
  "Return a fake catalog list with ENTRIES ids."
  (mapcar (lambda (id) (list :id id :name (upcase id))) entries))

(defun quoth-test--with-models (models fn)
  "Run FN with `quoth-provider--models-async' faked to deliver MODELS.
The fake records fetches in FETCHES (a counter closure result list).
FN receives the fetch-count accessor."
  (let ((fetches 0))
    (cl-letf (((symbol-function 'quoth-provider--models-async)
               (lambda (_provider on-done)
                 (setq fetches (1+ fetches))
                 (funcall on-done models)
                 nil)))
      (funcall fn (lambda () fetches)))))

;;; 1. Cache shape and reads

(ert-deftest quoth-test/catalog-cache-key-from-provider ()
  "The cache key derives from the provider type and its models key."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :base-url "http://example/v1")))
    (should (equal (quoth-provider--models-key provider)
                   '(hyper . "http://example/v1")))))

(ert-deftest quoth-test/catalog-cached-reads-empty-cache ()
  "A read against an empty cache returns nil without fetching."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-models
        (quoth-test--models "a" "b")
        (lambda (fetches)
          (should (null (quoth-provider-models-cached provider)))
          (should (= (funcall fetches) 0))))))))

(ert-deftest quoth-test/catalog-refresh-writes-cache-and-runs-hook ()
  "A refresh fetches asynchronously, writes the cache, and runs the hook."
  (quoth-test--with-models-cache
   (lambda ()
     (let* ((provider (quoth-make-hyper-provider
                       :buffer (current-buffer)
                       :base-url "http://example/v1"))
            (hook-runs 0))
       (let ((quoth-provider-models-hook
              (list (lambda () (setq hook-runs (1+ hook-runs))))))
         (quoth-test--with-models
          (quoth-test--models "a" "b")
          (lambda (fetches)
            (should (quoth-provider-models-refresh provider))
            (should (= (funcall fetches) 1))
            (should (= hook-runs 1))
            (should (equal (quoth-provider-models-cached provider)
                           (quoth-test--models "a" "b")))
            ;; A second read hits the cache: no fetch, no hook.
            (should (equal (quoth-provider-models-cached provider)
                           (quoth-test--models "a" "b")))
            (should (= (funcall fetches) 1))
            (should (= hook-runs 1)))))))))

(ert-deftest quoth-test/catalog-refresh-inflight-dedup ()
  "Concurrent refreshes for one key share a single fetch."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1"))
           (delivered 0))
       (cl-letf (((symbol-function 'quoth-provider--models-async)
                  (lambda (_provider on-done)
                    ;; The fetch "completes" only when the test pumps.
                    (setq delivered (1+ delivered))
                    (setq quoth-test--catalog--deliver on-done)
                    nil)))
         (defvar quoth-test--catalog--deliver nil)
         (should (quoth-provider-models-refresh provider))
         ;; The next two dedup onto the in-flight fetch.
         (should-not (quoth-provider-models-refresh provider))
         (should-not (quoth-provider-models-refresh provider))
         ;; One in-flight fetch for the three refresh calls.
         (should (= delivered 1))
         (funcall quoth-test--catalog--deliver
                  (quoth-test--models "a"))
         (should (= delivered 1))
         (should (equal (quoth-provider-models-cached provider)
                        (quoth-test--models "a"))))))))

(ert-deftest quoth-test/catalog-ttl-fresh-read-no-refetch ()
  "A fresh entry (inside the TTL) reads without a background refresh."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-models
        (quoth-test--models "a")
        (lambda (fetches)
          (quoth-provider-models-refresh provider)
          ;; A fresh read: cache hit, no fetch.
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "a")))
          (should (= (funcall fetches) 1))))))))

(ert-deftest quoth-test/catalog-stale-read-refreshes-in-background ()
  "A stale entry (past the TTL) reads immediately and refetches."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-models
        (quoth-test--models "old")
        (lambda (fetches)
          ;; Seed an expired entry.
          (puthash (quoth-provider--models-key provider)
                   (cons (quoth-test--models "old") (- (float-time) 999))
                   quoth-provider--models-cache)
          ;; The stale hit returns the old list...
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "old")))
          ;; ...and kicked exactly one background refresh.
          (should (= (funcall fetches) 1))))))))

(ert-deftest quoth-test/catalog-stale-read-refreshes-once ()
  "Repeated reads of one stale entry kick one background refresh."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-models
        (quoth-test--models "old")
        (lambda (fetches)
          (puthash (quoth-provider--models-key provider)
                   (cons (quoth-test--models "old") (- (float-time) 999))
                   quoth-provider--models-cache)
          (quoth-provider-models-cached provider)
          (quoth-provider-models-cached provider)
          (quoth-provider-models-cached provider)
          ;; The in-flight dedup collapses the three reads into one
          ;; background fetch (the fake delivers inline, but the first
          ;; fetch clears the in-flight entry before the second read).
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "old")))
          (should (= (funcall fetches) 1))))))))

(ert-deftest quoth-test/catalog-force-refresh-bypasses-ttl ()
  "A forced refresh refetches a fresh entry."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-models
        (quoth-test--models "fresh")
        (lambda (fetches)
          (quoth-provider-models-refresh provider)
          (should (= (funcall fetches) 1))
          ;; Force: refetch despite the fresh entry.
          (should (quoth-provider-models-refresh provider 'force))
          (should (= (funcall fetches) 2))))))))

(ert-deftest quoth-test/catalog-failed-fetch-keeps-stale-entry ()
  "A fetch delivering nil (failure) leaves the cached entry untouched."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (let ((fetches 0))
         (cl-letf (((symbol-function 'quoth-provider--models-async)
                    (lambda (_provider on-done)
                      (setq fetches (1+ fetches))
                      (funcall on-done nil)
                      nil)))
           (should (quoth-provider-models-refresh provider))
           ;; A failed fetch writes nothing.
           (should (null (quoth-provider-models-cached provider)))
           ;; Seed a stale entry; the SWR refresh keeps it on failure.
           (puthash (quoth-provider--models-key provider)
                    (cons (quoth-test--models "old") (- (float-time) 999))
                    quoth-provider--models-cache)
           (should (equal (quoth-provider-models-cached provider)
                          (quoth-test--models "old")))
           ;; A failed refresh does not restamp the entry, so each
           ;; stale read re-kicks one background fetch.
           (should (equal (quoth-provider-models-cached provider)
                          (quoth-test--models "old")))
           (should (= fetches 3))))))))

(ert-deftest quoth-test/catalog-keys-are-per-provider-and-base ()
  "Providers with different base URLs never share cache entries."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((a (quoth-make-hyper-provider :buffer (current-buffer)
                                         :base-url "http://a/v1"))
           (b (quoth-make-hyper-provider :buffer (current-buffer)
                                         :base-url "http://b/v1")))
       (let ((fetches 0))
         (cl-letf (((symbol-function 'quoth-provider--models-async)
                    (lambda (provider on-done)
                      (setq fetches (1+ fetches))
                      (funcall on-done
                               (quoth-test--models
                                (if (string= (quoth-hyper-provider-base-url
                                              provider)
                                             "http://a/v1")
                                    "a" "b")))
                      nil)))
           (quoth-provider-models-refresh a)
           (quoth-provider-models-refresh b)
           (should (equal (quoth-provider-models-cached a)
                          (quoth-test--models "a")))
           (should (equal (quoth-provider-models-cached b)
                          (quoth-test--models "b")))
           (should (= fetches 2))))))))

;;; 2. The async generic

(ert-deftest quoth-test/catalog-base-async-generic-delivers-nil ()
  "The base `quoth-provider--models-async' delivers nil (no catalog)."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (make-quoth-provider))
           (delivered nil))
       (should-not (quoth-provider--models-async
                    provider (lambda (models) (push models delivered))))
       (should (equal delivered '(nil)))))))

;;; 3. Selector reads only the cache

(ert-deftest quoth-test/catalog-selector-reads-cache-only ()
  "`quoth--select-effective-model-entry' reads the cache, never fetches.
With an empty cache and a fetch-counting fake, the selector predicates
see no models and no fetch fires."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((buf (generate-new-buffer " *catalog-selector*")))
       (unwind-protect
           (with-current-buffer buf
             (let ((quoth-active-provider
                    (quoth-make-hyper-provider :buffer buf
                                               :base-url "http://example/v1"))
                   (transient--original-buffer buf))
               (cl-letf (((symbol-function 'quoth-provider-model)
                          (lambda (&rest _) "m")))
                 (quoth-test--with-models
                  (quoth-test--models "m")
                  (lambda (fetches)
                    (should (null (quoth--select-effective-model-entry)))
                    (should-not (quoth--select-can-reason-p))
                    (should-not (quoth--select-has-reasoning-levels-p))
                    (should (= (funcall fetches) 0))
                    ;; Warm the cache: the entry appears without fetching.
                    (quoth-provider-models-refresh quoth-active-provider)
                    (should (equal
                             (quoth--select-effective-model-entry)
                             (car (quoth-test--models "m"))))
                    (should (= (funcall fetches) 1)))))))
         (when (buffer-live-p buf) (kill-buffer buf)))))))

;;; 4. The bundled seed

(defun quoth-test--with-seeded-models (seed live fn)
  "Run FN with the seed generic faked to SEED and the async generic
faked to deliver LIVE.  FN receives the fetch counter.  The fetch
completes inline, so post-read assertions see the delivered state."
  (let ((fetches 0))
    (cl-letf (((symbol-function 'quoth-provider--models-seed)
               (lambda (_provider) seed))
              ((symbol-function 'quoth-provider--models-async)
               (lambda (_provider on-done)
                 (setq fetches (1+ fetches))
                 (funcall on-done live)
                 nil)))
      (funcall fn (lambda () fetches)))))

(defun quoth-test--with-seeded-models-pending (seed fn)
  "Run FN with the seed generic faked to SEED and the async generic
started but not yet delivered.  FN receives the pending ON-DONE
delivery function alongside the fetch counter; the cache keeps the
seeded entry until FN pumps."
  (let ((fetches 0) (deliver nil))
    (cl-letf (((symbol-function 'quoth-provider--models-seed)
               (lambda (_provider) seed))
              ((symbol-function 'quoth-provider--models-async)
               (lambda (_provider on-done)
                 (setq fetches (1+ fetches))
                 (setq deliver on-done)
                 nil)))
      (funcall fn (lambda () fetches) (lambda (models) (funcall deliver models))))))

(ert-deftest quoth-test/catalog-seed-fills-cold-cache-read ()
  "A cache miss stores the bundled seed, stamped stale (FETCHED-AT 0),
and the read returns the seeded models immediately while the
kicked refresh is still in flight."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-seeded-models-pending
        (quoth-test--models "seeded")
        (lambda (_fetches deliver)
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "seeded")))
          (let ((entry (gethash (quoth-provider--models-key provider)
                                quoth-provider--models-cache)))
            (should (equal (car entry) (quoth-test--models "seeded")))
            (should (= (cdr entry) 0.0)))
          ;; Pump the in-flight fetch: the live catalog overrides.
          (funcall deliver (quoth-test--models "live"))
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "live")))))))))

(ert-deftest quoth-test/catalog-seed-read-kicks-background-refresh ()
  "The seeded entry counts as stale: the first read kicks exactly one
background refresh, and the live fetch overrides the seed."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-seeded-models
        (quoth-test--models "seeded")
        (quoth-test--models "live")
        (lambda (fetches)
          ;; The first read returns the seed and starts a fetch.
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "seeded")))
          (should (= (funcall fetches) 1))
          ;; The inline fake already delivered: the live catalog
          ;; replaced the seed and restamped the entry.
          (let ((entry (gethash (quoth-provider--models-key provider)
                                quoth-provider--models-cache)))
            (should (equal (car entry) (quoth-test--models "live")))
            (should (> (cdr entry) 0.0)))
          ;; Further reads hit the fresh entry: no more fetches.
          (should (equal (quoth-provider-models-cached provider)
                         (quoth-test--models "live")))
          (should (= (funcall fetches) 1))))))))

(ert-deftest quoth-test/catalog-seed-absent-cold-fallback-intact ()
  "A nil seed (no snapshot, or an unparseable one) leaves the cache
cold: the read returns nil and the caller's static fallback applies."
  (quoth-test--with-models-cache
   (lambda ()
     (let ((provider (quoth-make-hyper-provider
                      :buffer (current-buffer)
                      :base-url "http://example/v1")))
       (quoth-test--with-seeded-models
        nil
        (quoth-test--models "live")
        (lambda (_fetches)
          (should (null (quoth-provider-models-cached provider)))
          (should (null (gethash (quoth-provider--models-key provider)
                                 quoth-provider--models-cache)))))))))

(ert-deftest quoth-test/catalog-hyper-seed-gated-on-base-url ()
  "The hyper seed method only fires for the default gateway base URL;
a custom base URL gets no snapshot."
  (let ((file (make-temp-file "quoth-seed-" nil ".json"
                              "{\"name\":\"Charm Hyper\",\"models\":[]}")))
    (unwind-protect
        (let ((quoth-hyper--models-seed-directory
               (file-name-directory file))
              (quoth-hyper--models-seed-file
               (file-name-nondirectory file))
              ;; Unset HYPER_URL so the default gateway applies.
              (process-environment
               (cl-remove-if (lambda (env)
                               (string-prefix-p "HYPER_URL=" env))
                             process-environment)))
          ;; A custom base URL: no seed.
          (should (null (quoth-provider--models-seed
                         (quoth-make-hyper-provider
                          :buffer (current-buffer)
                          :base-url "http://other/v1"))))
          ;; The default gateway: the seed reads the snapshot (the
          ;; empty models array parses; absent-vs-invalid is
          ;; exercised by the seed-read tests below).
          (should (null (quoth-provider--models-seed
                         (quoth-make-hyper-provider
                          :buffer (current-buffer))))))
      (delete-file file))))

(ert-deftest quoth-test/catalog-hyper-seed-read-parses-snapshot ()
  "`quoth-hyper--models-seed-read' normalizes a snapshot through the
same parse + normalize pipeline as the live fetch."
  (let* ((body (concat "{\"name\":\"Charm Hyper\",\"models\":[{"
                       "\"id\":\"deepseek-v4-flash\","
                       "\"name\":\"DeepSeek V4 Flash\","
                       "\"cost_per_1m_in\":0.2,"
                       "\"cost_per_1m_out\":0.4,"
                       "\"cost_per_1m_in_cached\":0,"
                       "\"cost_per_1m_out_cached\":0.04,"
                       "\"context_window\":1000000,"
                       "\"default_max_tokens\":384000,"
                       "\"can_reason\":true,"
                       "\"reasoning_levels\":[\"high\",\"xhigh\"],"
                       "\"default_reasoning_effort\":\"high\","
                       "\"supports_attachments\":false}]}"))
         (file (make-temp-file "quoth-seed-" nil ".json" body))
         (models (quoth-hyper--models-seed-read file)))
    (unwind-protect
        (let ((m (car models)))
          (should (= (length models) 1))
          (should (string= (plist-get m :id) "deepseek-v4-flash"))
          (should (= (plist-get m :cost-cache-write) 0))
          (should (= (plist-get m :cost-cache-hit) 0.04))
          (should (equal (plist-get m :reasoning-levels) '("high" "xhigh")))
          (should (eq (plist-get m :can-reason) t)))
      (delete-file file))))

(ert-deftest quoth-test/catalog-hyper-seed-read-absent-not-error ()
  "A missing or unparseable snapshot yields a nil seed, never an
error — absent is distinct from rejected."
  (should (null (quoth-hyper--models-seed-read "/nonexistent/path/x.json")))
  (let ((file (make-temp-file "quoth-seed-" nil ".json" "{not json")))
    (unwind-protect
        (should (null (quoth-hyper--models-seed-read file)))
      (delete-file file))))

(ert-deftest quoth-test/catalog-select-model-detail-shape ()
  "`quoth--select-model-detail' annotates uncached in/out plus, when
the catalog reports them, both cache prices under their truthful
labels (write and hit); segments join with two spaces."
  (let ((entry (list :id "m" :name "M" :context-window 1000
                     :cost-in 1.5 :cost-out 2.5
                     :cost-cache-write 0.75
                     :cost-cache-hit 0.25)))
    (let ((detail (quoth--select-model-detail (list entry) "m")))
      (should (string= detail
                       (concat "ctx 1000  $1.50/1M in  $2.50/1M out"
                               "  cache-write $0.75/1M"
                               "  cache-hit $0.25/1M"))))
    ;; Without the cache prices both segments are simply absent.
    (let ((detail (quoth--select-model-detail
                   (list (list :id "m" :context-window 100
                               :cost-in 1 :cost-out 1))
                   "m")))
      (should (string-match-p "ctx 100" detail))
      (should-not (string-match-p "cache-write" detail))
      (should-not (string-match-p "cache-hit" detail)))))

(ert-deftest quoth-test/catalog-hyper-seed-read-real-snapshot ()
  "The tracked snapshot parses and normalizes: a non-empty model list
with an :id on every entry.  No hardcoded model ids — the assertion
must not rot as the gateway rotates models."
  (let* ((dir (file-name-directory (locate-library "quoth-test-catalog")))
         (file (expand-file-name "../quoth-hyper-models.json" dir))
         (models (and (file-exists-p file)
                      (quoth-hyper--models-seed-read file))))
    (should (consp models))
    (should (cl-every (lambda (m) (stringp (plist-get m :id))) models))))

;;; 5. The transient g suffix

(ert-deftest quoth-test/catalog-transient-has-force-refresh-suffix ()
  "The selector menu declares a `g' suffix force-refreshing the cache.
Transient builds its layout lazily, so the assertion reads the menu's
suffix declaration: the `g' key binds `quoth--select-refresh-catalog',
which forces a cache refresh."
  (let* ((source (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name "quoth-select.el"
                                      (if load-file-name
                                          (file-name-directory load-file-name)
                                        default-directory)))
                   (buffer-string)))
         (menu-start (string-match "transient-define-prefix quoth-select-model-menu"
                                   source)))
    (should menu-start)
    (let ((menu-source (substring source menu-start)))
      (should (string-match-p
               "(\"g\" quoth--select-refresh-catalog" menu-source)))))

(ert-deftest quoth-test/catalog-select-model-uses-cache ()
  "`quoth-select-model' reads the cache and offers the cached models.
A cold cache falls back to the static list while a refresh runs."
  (quoth-test--with-models-cache
   (lambda ()
     (unwind-protect
         (with-current-buffer (quoth-test--fresh-buffer)
           (quoth-test--with-models
            (quoth-test--models "qwen3.7-plus")
            (lambda (fetches)
              ;; Cold cache: the fallback list, one background refresh.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt coll &rest _)
                           (should (assoc "qwen3.7-plus" coll))
                           "qwen3.7-plus")))
                (quoth-select-model))
              (should (= (funcall fetches) 1))
              (should (string= (quoth-hyper-provider-model
                                quoth-active-provider)
                               "qwen3.7-plus"))
              ;; Warm cache: the cached list, no further fetch.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt coll &rest _)
                           (should (assoc "qwen3.7-plus" coll))
                           "qwen3.7-plus")))
                (quoth-select-model))
              (should (= (funcall fetches) 1)))))

       (quoth-test--cleanup)))))

(ert-deftest quoth-test/catalog-buffer-init-prefetches ()
  "`quoth--init-buffer' prefetches the catalog for new buffers."
  (quoth-test--with-models-cache
   (lambda ()
     (unwind-protect
         (quoth-test--with-models
          (quoth-test--models "a")
          (lambda (fetches)
            (quoth-test--fresh-buffer 'prefetch)
            (should (= (funcall fetches) 1))))
       (quoth-test--cleanup)))))

(provide 'quoth-test-catalog)
;;; quoth-test-catalog.el ends here
