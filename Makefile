# spa-recon — Makefile
#
# Usage:
#   make install       install everything the environment supports
#   make install-node  only the Node AST resolver deps
#   make install-go    only katana + jsluice
#   make uninstall     remove all installed files
#   make test          smoke test
#   make lint          shellcheck
#   make fmt           shfmt
#   make clean         remove local scan artifacts

PREFIX   ?= $(HOME)/.local
BINDIR   := $(PREFIX)/bin
SHAREDIR := $(PREFIX)/share/spa-recon
LIBDIR   := $(SHAREDIR)/lib
TPLDIR   := $(SHAREDIR)/templates
NODEDIR  := $(SHAREDIR)/node

.PHONY: help install install-node install-go uninstall test test-smoke test-resolver lint fmt clean

# ------------------------------------------------------------
# help
# ------------------------------------------------------------
help:
	@echo "spa-recon build targets"
	@echo
	@echo "  make install          install scripts (and deps if tools present)"
	@echo "  make install-node     install @babel/core + @babel/parser"
	@echo "  make install-go       install katana + jsluice"
	@echo "  make uninstall        remove installed files"
	@echo "  make test             smoke test"
	@echo "  make lint             shellcheck"
	@echo "  make fmt              shfmt"
	@echo "  make clean            remove scan output"

# ------------------------------------------------------------
# install — scripts, then best-effort optional deps
# ------------------------------------------------------------
install:
	@install -d "$(BINDIR)" "$(LIBDIR)" "$(TPLDIR)"
	@install -m 0755 spa-recon.sh  "$(BINDIR)/spa-recon"
	@install -m 0755 spa-report.sh "$(BINDIR)/spa-report"
	@install -m 0644 lib/*.sh              "$(LIBDIR)/"
	@install -m 0644 templates/report.html "$(TPLDIR)/"
	@install -m 0644 templates/report.css  "$(TPLDIR)/"
	@if [ -f lib/js-resolver.mjs ]; then \
		install -m 0644 lib/js-resolver.mjs "$(LIBDIR)/"; \
	fi
	@echo "installed to $(BINDIR)"
	@echo "  $(BINDIR)/spa-recon"
	@echo "  $(BINDIR)/spa-report"
	@$(MAKE) --no-print-directory install-node
	@$(MAKE) --no-print-directory install-go

# ------------------------------------------------------------
# optional: Node AST resolver
# ------------------------------------------------------------
install-node:
	@if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then \
		echo; \
		echo "node detected: $$(node --version)"; \
		echo "installing @babel/core + @babel/parser..."; \
		install -d "$(NODEDIR)"; \
		if [ ! -f "$(NODEDIR)/package.json" ]; then \
			printf '{"name":"spa-recon-deps","private":true,"type":"module"}\n' \
				> "$(NODEDIR)/package.json"; \
		fi; \
		( cd "$(NODEDIR)" && npm install --silent --no-audit --no-fund \
		    @babel/core @babel/parser ) \
			&& echo "  installed to $(NODEDIR)/node_modules" \
			|| echo "  warn: npm install failed"; \
	else \
		echo; \
		echo "node/npm not found — skipping AST resolver"; \
	fi

# ------------------------------------------------------------
# optional: Go tools
# ------------------------------------------------------------
install-go:
	@if command -v go >/dev/null 2>&1; then \
		echo; \
		echo "go detected: $$(go version | awk '{print $$3}')"; \
		GOPATH_BIN="$$(go env GOPATH)/bin"; \
		for tool in \
			"github.com/projectdiscovery/katana/cmd/katana@latest:katana" \
			"github.com/BishopFox/jsluice/cmd/jsluice@latest:jsluice"; do \
			pkg="$${tool%%:*}"; bin="$${tool##*:}"; \
			if [ -x "$$GOPATH_BIN/$$bin" ]; then \
				echo "  $$bin already installed"; \
			else \
				echo "  installing $$bin..."; \
				go install "$$pkg" 2>&1 | sed 's/^/    /' \
					&& echo "  $$bin installed" \
					|| echo "  warn: failed to install $$bin"; \
			fi; \
		done; \
	else \
		echo; \
		echo "go not found — skipping katana + jsluice"; \
	fi

# ------------------------------------------------------------
# uninstall
# ------------------------------------------------------------
uninstall:
	@rm -f "$(BINDIR)/spa-recon" "$(BINDIR)/spa-report"
	@rm -rf "$(SHAREDIR)"
	@echo "removed from $(PREFIX)"

# ------------------------------------------------------------
# tests
#
# Two layers:
#   test          — smoke test + resolver tests (if node + file present)
#   test-resolver — resolver tests only
#   test-smoke    — bash scripts only
#
# No pytest, no bats, no framework. node --test is built-in since Node 18.
# ------------------------------------------------------------
test: test-smoke test-resolver

test-smoke:
	@bash spa-recon.sh  --help >/dev/null && echo "  ✓ recon --help"
	@bash spa-report.sh --help >/dev/null && echo "  ✓ report --help"
	@bash spa-recon.sh  --version
	@bash spa-report.sh --version

test-resolver:
	@if [ ! -f lib/js-resolver.mjs ]; then \
		echo "  - resolver not present, skipping"; \
	elif ! command -v node >/dev/null 2>&1; then \
		echo "  - node not installed, skipping"; \
	elif [ ! -f test/resolver.test.mjs ]; then \
		echo "  - test/resolver.test.mjs not found, skipping"; \
	else \
		node --test test/resolver.test.mjs; \
	fi

# ------------------------------------------------------------
# lint / fmt
# ------------------------------------------------------------
lint:
	@command -v shellcheck >/dev/null || { echo "install shellcheck"; exit 1; }
	shellcheck -S error spa-recon.sh spa-report.sh lib/*.sh

fmt:
	@command -v shfmt >/dev/null || { echo "install shfmt"; exit 1; }
	shfmt -i 2 -ci -w spa-recon.sh spa-report.sh lib/*.sh

# ------------------------------------------------------------
# clean local scan artifacts
# ------------------------------------------------------------
clean:
	@rm -rf ./recon-* ./spa-recon-* ./*.pdf
	@echo cleaned