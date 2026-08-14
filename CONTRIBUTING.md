# Contributing to crush.el

Thanks for your interest in crush.el! This is a small, pre-alpha
GNU Emacs package. The sections below describe how to contribute
effectively. For how the code is structured, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Code of Conduct

Be respectful and constructive. This project follows the usual
open-source norms: no harassment, no personal attacks, disagreement
about code, not people.

## Reporting Bugs

Before opening an issue:

1. Check [TODO.md](TODO.md) — the feature/roadmap notes may already
   cover it.
2. Search existing issues for duplicates.
3. Include:
   - Emacs version (`emacs --version`)
   - `crush.el` version or the commit you're on
   - Whether `markdown-mode` is installed (many read-only / font
     rendering bugs only reproduce with it)
   - The backend in use (`crush-backend-type`: `hyper` default or `run`)
   - A minimal repro: steps, expected behavior, actual behavior
   - If a request failed, the request/response log (attach the
     `*crush-debug*` buffer contents; never paste tokens)

## Setup

```sh
git clone <repo> && cd crush.el
```

Requires Emacs 28.1+. Optionally install `markdown-mode` (MELPA) —
the chat buffer falls back to `text-mode`, and the markdown-dependent
tests are skipped without it.

## Development Workflow

After making changes:

```sh
sh test/run-tests.sh   # must pass: byte-compile (no new warnings) + ERT suite
sh format.sh           # format Elisp, Markdown, Shell, Python
```

The test runner treats byte-compiler warnings as errors-in-waiting:
do not introduce new ones. `format.sh` must produce no further
changes before you push.

### Test-driven changes

- Write a failing test first, confirm it fails, then implement, then
  confirm the full suite is green (the package follows this flow
  strictly).
- Tests are ERT, organized by topic under `test/` (`crush-test-buffer.el`,
  `crush-test-hyper.el`, `crush-test-backend.el`, ...). Harness helpers
  (`crush-test--with-mock`, `crush-test--with-hyper-server`) travel
  with their topic file.
- New behavior gets a test; the suite currently runs 300+ tests in
  ~20 seconds.

## Code Style

- Emacs Lisp, following the built-in conventions (see `elisp` manual)
  plus the project's: public symbols `crush-*`, internals `crush--*`;
  checkdoc-clean docstrings; no new byte-compiler warnings.
- Keep functions short and prefer `let` bindings over deep nesting
  (the codebase's reading order is documented in ARCHITECTURE.md).
- Respect the "no overlay faces / text-property read-only / markdown
  validity" invariants in ARCHITECTURE.md — they are load-bearing.
- Commit messages: concise, explain _why_; reference any related
  issue/PR.

## Pull Requests

- Base your work on `master`.
- One logical change per PR; small PRs review faster.
- Update tests and (if user-visible) README.md / TODO.md.
- Ensure `sh test/run-tests.sh` and `sh format.sh` are clean.
- Describe what changed and why in the PR body.

## Scope & Roadmap

crush.el is pre-alpha: breaking changes are welcome when they improve
the design — don't preserve quirks out of caution. Bigger ideas are
tracked in [TODO.md](TODO.md) (provider features, tooling, MCP
support, persistence); check it before starting something large so
effort isn't duplicated.

## License

MIT — by contributing you agree to license your contribution under
the same terms (see [LICENSE](LICENSE)).
