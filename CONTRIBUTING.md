# Contributing to Quoth

Thanks for your interest in Quoth! This is a small, pre-alpha
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
   - `Quoth` version or the commit you're on
   - Whether `markdown-mode` is installed (many font rendering bugs
     only reproduce with it)
   - The provider in use (hyper, via the Charm Hyper gateway)
   - A minimal repro: steps, expected behavior, actual behavior
   - If a request failed, the request/response log (attach the
     `*quoth-debug*` buffer contents; never paste tokens)

## Setup

```sh
git clone <repo> && cd quoth
```

Requires Emacs 28.1+. Optionally install `markdown-mode` (MELPA) —
the chat buffer falls back to `text-mode`, and the markdown-dependent
tests are skipped without it.

## Development Workflow

After making changes:

```sh
make check      # version gate + tests (byte-compile + ERT)
make test-wire  # full suite including the :integration wire tests
make format     # format Elisp, Markdown, Shell, Python
```

`make test` / `make check` run the fast default suite, which skips the
live-server `:integration` wire tests (they need emacs+curl plus the
dummy HTTP servers and are opt-in via `make test-wire`).

The test runner treats byte-compiler warnings as errors-in-waiting:
do not introduce new ones. `make format` must produce no further
changes before you push.

### Test-driven changes

- Write a failing test first, confirm it fails, then implement, then
  confirm the full suite is green (the package follows this flow
  strictly).
- Tests are ERT, organized by topic under `test/` (`quoth-test-buffer.el`,
  `quoth-test-hyper.el`, `quoth-test-openai.el`, `quoth-test-tools.el`, ...).
  Harness helpers (`quoth-test--with-hyper-server`) travel
  with their topic file.
- New behavior gets a test; the suite runs 400+ tests. Default `make test`
  (~440 tests, skipping `:integration`) is fast; `make test-wire` adds the
  live-server tests (454 total).

## Code Style

- Emacs Lisp, following the built-in conventions (see `elisp` manual)
  plus the project's: public symbols `quoth-*`, internals `quoth--*`;
  checkdoc-clean docstrings; no new byte-compiler warnings.
- Keep functions short and prefer `let` bindings over deep nesting
  (the codebase's reading order is documented in ARCHITECTURE.md).
- Respect the "no overlay faces / markdown validity" invariants in
  ARCHITECTURE.md — they are load-bearing.
- Commit messages: concise, explain _why_; reference any related
  issue/PR.

## Pull Requests

- Base your work on `master`.
- One logical change per PR; small PRs review faster.
- Update tests and (if user-visible) README.md / TODO.md.
- Ensure `make check` and `make format` are clean.
- Describe what changed and why in the PR body.

## Scope & Roadmap

Quoth is pre-alpha: breaking changes are welcome when they improve
the design — don't preserve quirks out of caution. Bigger ideas are
tracked in [TODO.md](TODO.md) (provider features, tooling, MCP
support, persistence); check it before starting something large so
effort isn't duplicated.

## License

MIT — by contributing you agree to license your contribution under
the same terms (see [LICENSE](LICENSE)).
