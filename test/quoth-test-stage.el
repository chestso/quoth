;;; quoth-test-stage.el --- tests for the staged system-prompt send  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase E topic tests: the async git stage behind
;; `quoth-openai--system-prompt-async', the request handle covering
;; both stages of a send, the preparing/streaming phase handoff, and
;; the banned-blocking-primitive lint.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ert)
(require 'quoth)
(require 'quoth-openai)
(require 'quoth-provider)
(require 'quoth-hyper-provider)

(defvar quoth-test--root)
(declare-function quoth-test--fresh-buffer "quoth-test" (&optional prefetch))
(declare-function quoth-test--cleanup "quoth-test" ())

(defvar quoth-test--stage--git-commands nil
  "Commands captured by the faked `make-process' during a stage test.")

(defmacro quoth-test--with-stage (&rest body)
  "Run BODY with the schedule flattened and `make-process' faked.
`quoth--schedule' runs its function inline, and `make-process'
spawns a command-less pipe process instead of a real git subprocess,
capturing the command list in `quoth-test--stage--git-commands'.  The
real stage still exposes its sentinel on the process via
`:quoth-stage-sentinel', which the tests invoke by hand (the fake
process installs no filter/sentinel of its own, so reaping it never
delivers twice)."
  (declare (indent 0))
  `(let ((quoth-test--stage--git-commands nil))
     (cl-letf (((symbol-function 'quoth--schedule)
                (lambda (fn) (funcall fn) nil))
               ((symbol-function 'make-process)
                (lambda (&rest props)
                  (push (plist-get props :command)
                        quoth-test--stage--git-commands)
                  (make-pipe-process
                   :name "quoth-test-stage"
                   :noquery t :coding 'binary))))
       ,@body)))

(defun quoth-test--fill-stage (proc raw)
  "Feed RAW through the real stage filter into PROC, then reap it.
Deletes PROC first: sentinels only run once the process is not live,
and the real sentinel is invoked by hand so delivery is exactly once."
  (should (processp proc))
  (quoth-openai--stage-filter proc raw)
  (delete-process proc)
  (funcall (process-get proc :quoth-stage-sentinel) proc "deleted\n"))

(defmacro quoth-test--with-fake-stage (&rest body)
  "Run BODY with `quoth-openai--system-prompt-stage' stubbed.
The stage is a fake pipe process (no git subprocess) whose sentinel
parses RAW through the real marker parser and delivers the assembled
prompt to the captured ON-READY — the real stage's delivery contract
without the git side."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'quoth-openai--system-prompt-stage)
              (lambda (_buf _key on-ready)
                (let ((proc (make-pipe-process
                             :name "quoth-test-stage"
                             :noquery t :coding 'binary)))
                  (process-put
                   proc :quoth-stage-sentinel
                   (quoth-openai--make-stage-sentinel
                    (lambda (git-section)
                      (funcall on-ready
                               (quoth-openai--assemble-stage-prompt
                                git-section)))))
                  proc))))
     ,@body))

(defun quoth-test--stage-repo-root ()
  "Return the repository root directory for stage tests.
Searches upward from this file (or `default-directory') for
`quoth.el', so the lint and the git-stage tests resolve sources both
when run from the repo root and from test/."
  (let ((dir (file-name-directory
              (or load-file-name buffer-file-name
                  (expand-file-name "quoth-test-stage.el" default-directory)))))
    (while (and dir (not (file-exists-p (expand-file-name "quoth.el" dir))))
      (setq dir (file-name-directory (directory-file-name dir))))
    dir))

(defmacro quoth-test--with-prompt-buffer (&rest body)
  "Run BODY in a temp buffer primed for a system-prompt stage test.
The buffer sits in the repository root (a git repo, so the stage
spawns) with context discovery disabled and the prompt cache empty."
  (declare (indent 0))
  `(with-temp-buffer
     (setq-local default-directory (quoth-test--stage-repo-root))
     (setq-local quoth-openai-context-paths nil)
     (setq-local quoth-openai-global-context-paths nil)
     (setq-local quoth-openai--cached-system-prompt nil)
     (setq-local quoth-openai--cache-key nil)
     ,@body))

;;; 1. Cache hit: delivery is inline, no stage spawns

(ert-deftest quoth-test/stage-cache-hit-delivers-inline ()
  "A cache hit delivers the cached prompt synchronously and spawns
no git process."
  (quoth-test--with-stage
   (quoth-test--with-prompt-buffer
    (setq-local quoth-openai--cached-system-prompt "CACHED")
    (setq-local quoth-openai--cache-key
                (quoth-openai--stage-prompt-key))
    (let ((calls 0)
          (stage nil))
      (setq stage
            (quoth-openai--system-prompt-async
             (current-buffer)
             (lambda (prompt)
               (setq calls (1+ calls))
               (should (string= prompt "CACHED")))))
      (should (= calls 1))
      (should-not stage)
      (should-not quoth-test--stage--git-commands)))))

;;; 2. Cache miss: the git stage delivers the assembled prompt

(ert-deftest quoth-test/stage-miss-runs-git-stage ()
  "A miss spawns one marker-delimited git process for the whole
stage; the sentinel's delivery carries the parsed git section and
lands in the prompt cache."
  (quoth-test--with-stage
   (quoth-test--with-prompt-buffer
    (let ((delivered nil))
      (let ((stage (quoth-openai--system-prompt-async
                    (current-buffer)
                    (lambda (prompt) (setq delivered prompt)))))
        (should (processp stage))
        (should (equal quoth-test--stage--git-commands
                       (list (list shell-file-name shell-command-switch
                                   (quoth-openai--git-command)))))
        (should-not delivered)
        (quoth-test--fill-stage
         stage
         "BRANCH_MARKER\nmaster\nSTATUS_MARKER\n M file\nCOMMITS_MARKER\nabc def\n")
        (should (string-match-p "Current branch: master" delivered))
        (should (string-match-p "M file" delivered))
        (should (string-match-p "abc def" delivered))
        (should (string= delivered quoth-openai--cached-system-prompt))
        (should-not (process-live-p stage)))))))

(ert-deftest quoth-test/stage-garbage-output-degrades ()
  "Git failure (garbage output, no markers) still delivers exactly
one prompt; the unparsable section degrades rather than erroring."
  (quoth-test--with-stage
   (quoth-test--with-prompt-buffer
    (let ((calls 0)
          (delivered nil))
      (let ((stage (quoth-openai--system-prompt-async
                    (current-buffer)
                    (lambda (prompt)
                      (setq calls (1+ calls))
                      (setq delivered prompt)))))
        (quoth-test--fill-stage stage "fatal: not a git repository\n")
        (should (= calls 1))
        (should (stringp delivered))
        (should (string= delivered quoth-openai--cached-system-prompt)))))))

(ert-deftest quoth-test/stage-no-git-dir-delivers-gitless ()
  "A non-git directory delivers the gitless prompt synchronously: no
stage process, no git section."
  (quoth-test--with-stage
   (with-temp-buffer
     (setq-local default-directory "/tmp/")
     (setq-local quoth-openai-context-paths nil)
     (setq-local quoth-openai-global-context-paths nil)
     (setq-local quoth-openai--cached-system-prompt nil)
     (setq-local quoth-openai--cache-key nil)
     (let ((delivered nil))
       (should-not
        (quoth-openai--system-prompt-async
         (current-buffer)
         (lambda (prompt) (setq delivered prompt))))
       (should (stringp delivered))
       (should (string= delivered quoth-openai--cached-system-prompt))
       (should-not (string-match-p "Git status" delivered))
       (should-not quoth-test--stage--git-commands)))))

(ert-deftest quoth-test/stage-timeout-delivers-gitless ()
  "A stage past `quoth-openai-git-timeout' is aborted and delivers
without waiting for git."
  (let ((quoth-openai-git-timeout 0.01))
    (quoth-test--with-stage
     (quoth-test--with-prompt-buffer
      (let ((delivered nil))
        (let ((stage (quoth-openai--system-prompt-async
                      (current-buffer)
                      (lambda (_prompt) (setq delivered t)))))
          (should (processp stage))
          (should-not delivered)
          ;; Let the timeout timer fire (the abort delivers inline via
          ;; the flattened schedule).
          (sleep-for 0.05)
          (should delivered)
          (should-not (process-live-p stage))))))))

;;; 3. The request handle: shape, activity, interrupt

(ert-deftest quoth-test/stage-handle-shape ()
  "A send returns a handle covering both stages (:stage-process,
:curl, :done-p), not a raw process; cleanup clears it."
  (let ((default-directory quoth-test--root)
        (quoth-openai-context-paths nil)
        (quoth-openai-global-context-paths nil))
    (with-current-buffer (get-buffer-create "*quoth-test-stage-handle*")
      (quoth-test--with-fake-stage
       (let* ((provider (quoth-make-hyper-provider
                         :buffer (current-buffer)
                         :working-directory default-directory
                         :base-url "http://127.0.0.1:1"
                         :token "tok"))
              (handle (quoth-provider-send-prompt provider "hi")))
         (should (listp handle))
         (should (processp (plist-get handle :stage-process)))
         (should-not (plist-get handle :curl))
         (should-not (plist-get handle :done-p))
         (should (quoth-provider-active-p provider))
         (quoth-provider-cleanup provider)
         (should-not (quoth-provider-request provider))
         (should-not (quoth-provider-active-p provider)))))))

(ert-deftest quoth-test/stage-active-p-covers-both-stages ()
  "`quoth-provider-active-p' is true with only the stage live and
true again once the curl transport takes over; with both dead it is
nil."
  (let ((default-directory quoth-test--root)
        (quoth-openai-context-paths nil)
        (quoth-openai-global-context-paths nil))
    (with-current-buffer (get-buffer-create "*quoth-test-stage-active*")
      (quoth-test--with-fake-stage
       (let* ((curl (make-pipe-process :name "quoth-test-curl" :noquery t))
              (provider (quoth-make-hyper-provider
                         :buffer (current-buffer)
                         :working-directory default-directory
                         :base-url "http://127.0.0.1:1"
                         :token "tok")))
         (cl-letf (((symbol-function 'quoth-openai-request)
                    (lambda (&rest _args) curl)))
           (unwind-protect
               (let ((handle (quoth-provider-send-prompt provider "hi")))
                 ;; Stage live, curl not yet fired.
                 (should (quoth-provider-active-p provider))
                 (should-not (plist-get handle :curl))
                 ;; The stage lands; curl takes over the handle.
                 (quoth-test--fill-stage
                  (plist-get handle :stage-process) "")
                 (should (eq (plist-get handle :curl) curl))
                 (should (quoth-provider-active-p provider))
                 ;; Both dead: inactive.
                 (delete-process curl)
                 (should-not (quoth-provider-active-p provider)))
             (when (process-live-p curl) (delete-process curl))
             (quoth-provider-cleanup provider))))))))

(ert-deftest quoth-test/stage-interrupt-aborts-both-stages ()
  "`quoth-provider-interrupt' kills the live stage and aborts the
curl transport, clearing the handle and the completion action."
  (let ((default-directory quoth-test--root)
        (quoth-openai-context-paths nil)
        (quoth-openai-global-context-paths nil))
    (with-current-buffer (get-buffer-create "*quoth-test-stage-interrupt*")
      (quoth-test--with-fake-stage
       (let* ((provider (quoth-make-hyper-provider
                         :buffer (current-buffer)
                         :working-directory default-directory
                         :base-url "http://127.0.0.1:1"
                         :token "tok"))
              (aborted nil)
              (handle (quoth-provider-send-prompt provider "hi")))
         (unwind-protect
             (progn
               (setf (quoth-provider-completion-action provider)
                     (lambda () 'done))
               (setf (plist-get handle :curl)
                     (make-pipe-process :name "quoth-test-curl" :noquery t))
               (cl-letf (((symbol-function 'quoth-openai-abort)
                          (lambda (_proc) (setq aborted t))))
                 (quoth-provider-interrupt provider))
               (should aborted)
               (should-not (process-live-p
                            (plist-get handle :stage-process)))
               (should-not (quoth-provider-request provider))
               (should-not (quoth-provider-completion-action provider)))
           (quoth-provider-cleanup provider)))))))

;;; 4. Phase: preparing while staged, streaming once curl fires

(ert-deftest quoth-test/stage-send-preparing-then-streaming ()
  "`quoth--send-prompt' enters `preparing' while the system prompt
stage is in flight; when the stage delivers, the phase moves to
`streaming' and the curl transport sits in the handle."
  (let ((default-directory quoth-test--root)
        (quoth-openai-context-paths nil)
        (quoth-openai-global-context-paths nil))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (setq-local quoth-openai--cached-system-prompt nil)
          (setq-local quoth-openai-context-paths nil)
          (setq-local quoth-openai-global-context-paths nil)
          (setq-local quoth-active-provider
                      (quoth-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"))
          (quoth-test--with-fake-stage
           (cl-letf (((symbol-function 'quoth-openai-request)
                      (lambda (&rest _args)
                        (make-pipe-process
                         :name "quoth-test-curl" :noquery t))))
             (quoth--send-prompt "hi")
             (should (eq (plist-get quoth--phase :phase) 'preparing))
             (should (quoth--busy-p))
             (should (quoth-provider-active-p quoth-active-provider))
             (let ((handle (quoth-provider-request quoth-active-provider)))
               (quoth-test--fill-stage
                (plist-get handle :stage-process) "")
               (should (eq (plist-get quoth--phase :phase) 'streaming))
               (should (processp (plist-get handle :curl)))
               (should (quoth-provider-active-p quoth-active-provider))))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/stage-on-ready-streaming-only-when-busy ()
  "The staged delivery moves a busy buffer to `streaming'; a buffer
that went idle meanwhile (interrupted mid-stage) stays idle."
  (let ((default-directory quoth-test--root)
        (quoth-openai-context-paths nil)
        (quoth-openai-global-context-paths nil))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (setq-local quoth-openai--cached-system-prompt nil)
          (setq-local quoth-openai-context-paths nil)
          (setq-local quoth-openai-global-context-paths nil)
          (setq-local quoth-active-provider
                      (quoth-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"))
          (quoth-test--with-fake-stage
           (cl-letf (((symbol-function 'quoth-openai-request)
                      (lambda (&rest _args)
                        (make-pipe-process
                         :name "quoth-test-curl" :noquery t))))
             ;; Busy: the delivery moves the phase to streaming.
             (quoth--phase-set 'preparing)
             (let ((h1 (quoth-provider-send-prompt
                        quoth-active-provider "hi"
                        :buffer (current-buffer))))
               (quoth-test--fill-stage (plist-get h1 :stage-process) "")
               (should (eq (plist-get quoth--phase :phase) 'streaming)))
             ;; Idle: a late delivery must not resurrect the phase.
             (quoth--phase-set 'idle)
             (let ((h2 (quoth-provider-send-prompt
                        quoth-active-provider "hi"
                        :buffer (current-buffer))))
               (quoth-test--fill-stage (plist-get h2 :stage-process) "")
               (should (eq (plist-get quoth--phase :phase) 'idle))))))
      (quoth-test--cleanup))))

;;; 5. Tool-calls / usage read through the handle

(ert-deftest quoth-test/stage-tool-calls-usage-read-handle ()
  "`quoth-provider--tool-calls' and `quoth-provider--usage' read the
curl process through the handle's :curl key; a raw process where the
handle belongs reads as no request."
  (let* ((provider (quoth-make-hyper-provider
                    :buffer (current-buffer)
                    :working-directory default-directory))
         (tool-calls
          (vector (list (cons 'id "call_1")
                        (cons 'type "function")
                        (cons 'function
                              (list (cons 'name "bash")
                                    (cons 'arguments "{}"))))))
         (usage-alist (list (cons "prompt_tokens" 60)
                            (cons "completion_tokens" 40)
                            (cons "cost"
                                  (list (cons "hypercredits" 0.5)))))
         (curl (make-pipe-process :name "quoth-test-curl" :noquery t))
         (handle (list :stage-process nil :curl curl :done-p t)))
    (unwind-protect
        (progn
          (process-put curl :quoth-sse
                       (list :tool-calls tool-calls :usage usage-alist))
          (should (equal (quoth-provider--tool-calls provider handle)
                         tool-calls))
          (let ((usage (quoth-provider--usage provider handle)))
            (should (= (plist-get usage :input-tokens) 60))
            (should (= (plist-get usage :output-tokens) 40))
            (should (= (plist-get usage :cost-value) 0.5))
            (should-not (plist-get usage :accumulated)))
          ;; A raw process is not a handle: no request to read.
          (should-not (quoth-provider--tool-calls provider curl))
          (should-not (quoth-provider--usage provider curl)))
      (delete-process curl))))

;;; 6. Buffer init prefetches the staged prompt

(ert-deftest quoth-test/stage-init-prefetches-system-prompt ()
  "Buffer init prefetches the staged system prompt so the first send
then hits the prompt cache."
  (let ((calls 0))
    (cl-letf (((symbol-function 'quoth-openai--system-prompt-async)
               (lambda (_buf _on-ready) (setq calls (1+ calls)) nil)))
      (unwind-protect
          (let ((quoth-provider-models-prefetch nil))
            (quoth-test--fresh-buffer))
        (should (= calls 1))
        (setq calls 0)
        (quoth-test--cleanup)))))

;;; 7. The banned-primitive lint

(defun quoth-test--lint-sources ()
  "Return the runtime source files for the banned-primitive lint."
  '("quoth.el" "quoth-provider.el" "quoth-openai.el"
    "quoth-hyper-provider.el" "quoth-tools.el" "quoth-process.el"
    "quoth-searxng.el" "quoth-select.el" "quoth-json.el"
    "quoth-xxh3.el"))

(ert-deftest quoth-test/lint-no-blocking-primitives-in-runtime ()
  "Runtime sources contain no blocking process/network primitives.
Banned: `url-retrieve-synchronously', `shell-command-to-string',
`call-process', `process-wait', `sleep-for', and `sit-for' as a wait.
`accept-process-output' is permitted only as the zero-timeout poll in
`quoth-process--collect-final' and the stage/catalog sentinels' drain
(the same pattern).  Tests and `quoth-debug-tools.el' (user-invoked
diagnostics) are exempt."
  (let* ((root (quoth-test--stage-repo-root))
         (sources (quoth-test--lint-sources))
         (banned '("url-retrieve-synchronously" "shell-command-to-string"
                   "call-process" "process-wait" "sleep-for" "sit-for"))
         (violations nil))
    (should root)
    (dolist (source sources)
      (let ((file (expand-file-name source root)))
        (should (file-exists-p file))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (point) (line-end-position))))
              (dolist (name banned)
                ;; A real call site, not a declare-function stub.
                (when (and (string-match-p name line)
                           (not (string-match-p "declare-function" line)))
                  (push (format "%s:%d: %s" source
                                (line-number-at-pos)
                                (string-trim line))
                        violations)))
              ;; Only actual call forms (open paren), not docstring
              ;; or comment mentions; the permitted zero-timeout
              ;; poll is a call whose second timeout argument is 0.
              (when (string-match-p "(accept-process-output" line)
                (unless (or (string-match-p "declare-function" line)
                            (string-match-p
                             "(accept-process-output[^()]*0)"
                             line))
                  (push (format "%s:%d: %s (non-zero/nil timeout)"
                                source (line-number-at-pos)
                                (string-trim line))
                        violations)))
              (forward-line 1))))))
    (should (equal violations nil))))

(provide 'quoth-test-stage)
;;; quoth-test-stage.el ends here
