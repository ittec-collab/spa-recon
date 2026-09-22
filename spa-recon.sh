#!/usr/bin/env bash
# spa-recon.sh — SPA endpoint enumeration pipeline
#
# Usage:  spa-recon.sh <base-url> [output-dir] [flags]
# Docs:   README.md

set -uo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.1.1"

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
  printf 'spa-recon: cannot locate lib/ (looked next to script and in share/)\n' >&2
  exit 1
}

# shellcheck source=/dev/null
. "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/recon.sh"

# ============================================================
# argument parsing
# ============================================================
REPORT=0
PDF=0
OPEN=0
NO_KATANA=0
NO_HEADLESS=0
CLI_TOKEN=""
CLI_COOKIE=""
CLI_BASIC=""
declare -a CLI_HEADERS=()
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report)      REPORT=1; shift ;;
    --pdf)         REPORT=1; PDF=1; shift ;;
    --open)        REPORT=1; OPEN=1; shift ;;
    --no-katana)   NO_KATANA=1; shift ;;
    --no-headless) NO_HEADLESS=1; shift ;;
    --token)       CLI_TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --cookie)      CLI_COOKIE="${2:?--cookie needs a value}"; shift 2 ;;
    --basic)       CLI_BASIC="${2:?--basic needs user:pass}"; shift 2 ;;
    --header)      CLI_HEADERS+=("${2:?--header needs k:v}"); shift 2 ;;
    -h|--help)     recon_usage; exit 0 ;;
    -V|--version)  printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
    --)            shift; POSITIONAL+=("$@"); break ;;
    -*)            printf 'unknown flag: %s\n\n' "$1" >&2; recon_usage >&2; exit 1 ;;
    *)             POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"
[ $# -ge 1 ] || { recon_usage >&2; exit 1; }

# ============================================================
# load ./.spa-reconrc if present (sourced, bash syntax)
# ============================================================
if [ -n "${SPA_RECONRC:-}" ] && [ -f "$SPA_RECONRC" ]; then
  # shellcheck disable=SC1090
  . "$SPA_RECONRC"
elif [ -f "./.spa-reconrc" ]; then
  # shellcheck disable=SC1091
  . ./.spa-reconrc
fi

BASE="${1%/}"
OUT="${2:-./spa-recon-$(date +%Y%m%d-%H%M%S)}"

# ============================================================
# resolve credentials — CLI wins over env / config
# ============================================================
SPA_TOKEN="${CLI_TOKEN:-${SPA_TOKEN:-}}"
SPA_COOKIE="${CLI_COOKIE:-${SPA_COOKIE:-}}"
SPA_BASIC="${CLI_BASIC:-${SPA_BASIC:-}}"
if [ ${#CLI_HEADERS[@]} -gt 0 ]; then
  SPA_HEADERS="$(IFS=';'; echo "${CLI_HEADERS[*]}")"
fi

# Export every flag so run_recon sees them regardless of caller
export NO_KATANA NO_HEADLESS

# ============================================================
# run
# ============================================================
run_recon "$BASE" "$OUT"

if [ "$REPORT" = "1" ]; then
  report_args=("$OUT")
  [ "$PDF"  = "1" ] && report_args+=(--pdf)
  [ "$OPEN" = "1" ] && report_args+=(--open)

  # prefer the sibling script if present (dev checkout);
  # otherwise use the installed copy on $PATH
  if [ -x "$SELF_DIR/spa-report.sh" ]; then
    "$SELF_DIR/spa-report.sh" "${report_args[@]}" \
      || warn "report generation failed"
  elif command -v spa-report >/dev/null 2>&1; then
    spa-report "${report_args[@]}" \
      || warn "report generation failed"
  else
    warn "spa-report not found — skipping report"
  fi
fi