#!/usr/bin/env bash
# lib/common.sh — shared helpers (colors, logging, escaping)

# Guard against double-sourcing
[ -n "${_SPA_COMMON_LOADED:-}" ] && return 0
readonly _SPA_COMMON_LOADED=1

# ---------- logging ----------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- html ----------
# Escape for HTML content context (text nodes, <pre>, <code>).
# Only & and < need escaping — " and > stay literal.
esc() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  printf '%s' "$s"
}

# ---------- files ----------
count_lines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
slurp()       { [ -f "$1" ] && cat "$1" || true; }

# ---------- css classes ----------
method_class() {
  case "$1" in
    GET)       echo "m-get"  ;;
    POST)      echo "m-post" ;;
    PUT|PATCH) echo "m-put"  ;;
    DELETE)    echo "m-del"  ;;
    *)         echo ""       ;;
  esac
}

status_class() {
  case "$1" in
    2*) echo "s2xx" ;;
    3*) echo "s3xx" ;;
    4*) echo "s4xx" ;;
    5*) echo "s5xx" ;;
    *)  echo ""     ;;
  esac
}