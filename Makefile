SHELL := /bin/sh

VERSION ?=

.PHONY: all help test check format version check-version dist release clean

all: check
.DEFAULT_GOAL := help

help:
	@echo "quoth developer targets"
	@echo "  make test                     run byte-compile + ERT suite"
	@echo "  make check                    version gate + tests"
	@echo "  make format                   format Elisp / Markdown / Shell / Python"
	@echo "  make version                  print the ;;; Version: header"
	@echo "  make check-version            verify header matches the current git tag"
	@echo "  make dist                     build the package tarball from the current tag"
	@echo "  make release VERSION=x.y.z    bump header, commit, tag (push manual)"
	@echo "  make clean                    remove byte-compiled and cache artifacts"

test:
	./scripts/test.sh

check: check-version test

format:
	./scripts/format.sh

version:
	./scripts/version.sh

check-version:
	./scripts/check-version.sh

dist:
	./scripts/dist.sh

release:
	./scripts/release.sh

clean:
	@find . -type f -name '*.elc' -delete
	@find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
	@rm -rf .quoth
