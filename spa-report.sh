#!/usr/bin/env bash
# spa-report.sh — render spa-recon.sh artifacts as a self-contained HTML report
#
# Usage:  spa-report.sh <recon-dir> [output.html] [--pdf|--no-pdf] [--open]
# Docs:   README.md

set -uo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.1.0"

SELF_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

# ============================================================
# locate lib/ — dev checkout (./lib) or installed (../share/spa-recon/lib)
# ============================================================
LIB_DIR=""
for _d in \
    "$SELF_DIR/lib" \
    "$SELF_DIR/../share/spa-recon/lib" \
    "$HOME/.local/share/spa-recon/lib" \
    "/usr/local/share/spa-recon/lib" \
    "/usr/share/spa-recon/lib"; do
  if [ -f "$_d/common.sh" ]; then
    LIB_DIR="$(cd "$_d" && pwd)"
    break
  fi
done
[ -n "$LIB_DIR" ] || {
  printf 'spa-report: cannot locate lib/ (looked next to script and in share/)\n' >&2
  exit 1
}

# shellcheck source=/dev/null
. "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/auth.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/fields.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/guides.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/render.sh"

# ============================================================
# argument parsing
# ============================================================
WANT_PDF=1
WANT_OPEN=0
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --pdf)        WANT_PDF=1; shift ;;
    --no-pdf)     WANT_PDF=0; shift ;;
    --open)       WANT_OPEN=1; shift ;;
    -h|--help)    report_usage; exit 0 ;;
    -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
    --)           shift; POSITIONAL+=("$@"); break ;;
    -*)           printf 'unknown flag: %s\n\n' "$1" >&2; report_usage >&2; exit 1 ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"
[ $# -ge 1 ] || { report_usage >&2; exit 1; }

RECON_DIR="$1"
OUT_HTML="${2:-$RECON_DIR/report.html}"
[ -d "$RECON_DIR" ] || { printf 'not a directory: %s\n' "$RECON_DIR" >&2; exit 1; }

render_report "$RECON_DIR" "$OUT_HTML" "$WANT_PDF" "$WANT_OPEN"