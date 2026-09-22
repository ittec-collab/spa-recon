#!/usr/bin/env bash
# install.sh — install spa-recon to $(PREFIX) (default: ~/.local)
#
# What it does:
#   1. Copies spa-recon / spa-report + lib + templates
#   2. If node + npm are present, installs @babel/core + @babel/parser
#      into a private node_modules tree for the AST field resolver
#   3. If go is present, installs katana + jsluice
#   4. Prints a PATH hint if $BINDIR isn't on it
#
# Every step is optional — the scripts work with reduced accuracy if
# Node or Go are missing.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/spa-recon"
LIBDIR="$SHAREDIR/lib"
TPLDIR="$SHAREDIR/templates"
NODEDIR="$SHAREDIR/node"

command -v install >/dev/null || { echo "need coreutils 'install'"; exit 1; }

# ============================================================
# 1. shell scripts + templates
# ============================================================
install -d "$BINDIR" "$LIBDIR" "$TPLDIR"

install -m 0755 "$SRC_DIR/spa-recon.sh"  "$BINDIR/spa-recon"
install -m 0755 "$SRC_DIR/spa-report.sh" "$BINDIR/spa-report"
install -m 0644 "$SRC_DIR/lib/"*.sh              "$LIBDIR/"
install -m 0644 "$SRC_DIR/templates/report.html" "$TPLDIR/"
install -m 0644 "$SRC_DIR/templates/report.css"  "$TPLDIR/"

# ============================================================
# 2. Node AST resolver (optional)
# ============================================================
install -m 0644 "$SRC_DIR/lib/js-resolver.mjs" "$LIBDIR/" 2>/dev/null || true

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  echo
  echo "node detected: $(node --version)"
  echo "installing @babel/core + @babel/parser for AST field extraction..."

  install -d "$NODEDIR"
  if [ ! -f "$NODEDIR/package.json" ]; then
    cat > "$NODEDIR/package.json" <<'JSON'
{
  "name": "spa-recon-deps",
  "private": true,
  "type": "module"
}
JSON
  fi

  if ( cd "$NODEDIR" && npm install --silent --no-audit --no-fund \
         @babel/core @babel/parser ); then
    echo "  installed to $NODEDIR/node_modules"
  else
    echo "  warn: npm install failed — AST resolver will not be available"
  fi
else
  echo
  echo "node/npm not found — skipping AST resolver install"
  echo "  spa-recon will fall back to regex field extraction."
  echo "  install Node.js 18+ and re-run to enable it."
fi

# ============================================================
# 3. Go tools (optional)
# ============================================================
if command -v go >/dev/null 2>&1; then
  echo
  echo "go detected: $(go version | awk '{print $3}')"
  GOPATH_BIN="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin"

  install_go() {
    local pkg="$1" bin="$2"
    if [ -x "$GOPATH_BIN/$bin" ]; then
      echo "  $bin already installed"
    else
      echo "  installing $bin..."
      if go install "$pkg" 2>&1 | sed 's/^/    /'; then
        echo "  $bin installed"
      else
        echo "  warn: failed to install $bin"
      fi
    fi
  }

  install_go "github.com/projectdiscovery/katana/cmd/katana@latest" katana
  install_go "github.com/BishopFox/jsluice/cmd/jsluice@latest"      jsluice
else
  echo
  echo "go not found — skipping katana + jsluice"
  echo "  spa-recon will use the HTML fallback for JS discovery."
fi

# ============================================================
# 4. PATH check
# ============================================================
echo
echo "installed:"
echo "  $BINDIR/spa-recon"
echo "  $BINDIR/spa-report"
echo "  $SHAREDIR/"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo
     echo "add $BINDIR to PATH:"
     echo "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.bashrc"
     echo "  source ~/.bashrc"
     ;;
esac