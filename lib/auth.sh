#!/usr/bin/env bash
# lib/auth.sh — auth state and form-vs-JSON detection
#
# Two maps are built from the scan artifacts:
#   AUTH_PATHS[path]              — needs auth on at least one verb
#   METHOD_STATUS["VERB path"]    — status for a specific verb
#
# The (verb, path) lookup wins, so a POST-only public endpoint can
# coexist with an auth-gated GET on the same path.

declare -A AUTH_PATHS=()
declare -A METHOD_STATUS=()
declare -A FORM_CACHE=()

build_auth_maps() {
  local recon_dir="$1"
  local base_url="$2"
  local url verb code p

  for f in "$recon_dir/needs-auth.txt" "$recon_dir/forbidden.txt"; do
    [ -s "$f" ] || continue
    while read -r url; do
      [ -z "$url" ] && continue
      AUTH_PATHS["${url#$base_url}"]=1
    done < "$f"
  done

  if [ -s "$recon_dir/methods.tsv" ]; then
    while IFS=$'\t' read -r verb code url; do
      [ -z "$url" ] && continue
      p="${url#$base_url}"
      METHOD_STATUS["$verb $p"]="$code"
      case "$code" in
        401|403) AUTH_PATHS["$p"]=1 ;;
      esac
    done < "$recon_dir/methods.tsv"
  fi
}

needs_auth_for() {
  local verb="$1" path="$2"
  local st="${METHOD_STATUS[$verb $path]:-}"
  if [ -n "$st" ]; then
    [ "$st" = "401" ] || [ "$st" = "403" ]
    return
  fi
  [ -n "${AUTH_PATHS[$path]:-}" ]
}

# Form detection:
# - Tier 1: 422 body has `"input": null` → server didn't parse JSON
# - Tier 2: path keyword (login/signin/token) → assume form
is_form_endpoint() {
  local path="$1" base_url="$2" recon_dir="$3"
  local url="$base_url$path"

  if [ -n "${FORM_CACHE[$path]:-}" ]; then
    [ "${FORM_CACHE[$path]}" = "1" ]
    return $?
  fi

  local block
  block="$(extract_422_block "$url" "$recon_dir")"
  if [ -n "$block" ]; then
    if printf '%s' "$block" \
         | jq -e '[.detail[]? | select(.input == null)] | length > 0' \
             >/dev/null 2>&1; then
      FORM_CACHE["$path"]=1
      return 0
    fi
  fi

  local low
  low="$(printf '%s' "$path" | tr 'A-Z' 'a-z')"
  if [[ "$low" =~ (^|/)(login|signin|sign-in|authenticate|oauth/token|token)(/|$) ]]; then
    FORM_CACHE["$path"]=1
    return 0
  fi

  FORM_CACHE["$path"]=0
  return 1
}