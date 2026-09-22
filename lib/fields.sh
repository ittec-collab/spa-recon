#!/usr/bin/env bash
# lib/fields.sh — three-tier field resolver
#
# Tier 1: 422 response body (authoritative — server tells us the fields)
# Tier 2: JS bundle analysis (AST via Node if available, regex fallback)
# Tier 3: path-keyword heuristics
#
# Every function takes RECON_DIR / BASE_URL as explicit arguments so
# the module is testable in isolation.

[ -n "${_SPA_FIELDS_LOADED:-}" ] && return 0
readonly _SPA_FIELDS_LOADED=1

# ============================================================
# locating the AST resolver + its node_modules
#
# Search order:
#   1. next to this file (development checkout)
#   2. $PREFIX/share/spa-recon/lib (installed)
#   3. ~/.local/share/spa-recon/lib
#   4. /usr/local/share/spa-recon/lib
#   5. /usr/share/spa-recon/lib
# ============================================================
_find_resolver() {
  local self_dir
  self_dir="$(dirname "${BASH_SOURCE[0]}")"

  local d
  for d in \
      "$self_dir" \
      "${PREFIX:-}/share/spa-recon/lib" \
      "$HOME/.local/share/spa-recon/lib" \
      "/usr/local/share/spa-recon/lib" \
      "/usr/share/spa-recon/lib"; do
    [ -n "$d" ] && [ -f "$d/js-resolver.mjs" ] && { printf '%s' "$d/js-resolver.mjs"; return 0; }
  done
  return 1
}

_find_node_modules() {
  local self_dir
  self_dir="$(dirname "${BASH_SOURCE[0]}")"

  local d
  for d in \
      "$self_dir/../node/node_modules" \
      "${PREFIX:-}/share/spa-recon/node/node_modules" \
      "$HOME/.local/share/spa-recon/node/node_modules" \
      "/usr/local/share/spa-recon/node/node_modules" \
      "/usr/share/spa-recon/node/node_modules"; do
    [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# ============================================================
# 422 extraction
# ============================================================
extract_422_block() {
  local url="$1" recon_dir="$2"
  local file="$recon_dir/422-bodies.txt"
  [ -s "$file" ] || return 0

  awk -v want="$url" '
    BEGIN { in_block = 0 }
    /^=== / {
      if (in_block) exit
      line = $0
      sub(/^=== /, "", line)
      sub(/ ===$/, "", line)
      sub(/^[A-Z]+ /, "", line)
      if (line == want) in_block = 1
      next
    }
    in_block { print }
  ' "$file"
}

extract_422_body() {
  local verb="$1" url="$2" recon_dir="$3"
  local file="$recon_dir/422-bodies.txt"
  [ -s "$file" ] || return 0

  awk -v want="=== $verb $url ===" '
    $0 == want { capture = 1; next }
    capture && /^=== / { exit }
    capture { print }
  ' "$file"
}

extract_422_fields() {
  local url="$1" recon_dir="$2"
  local block
  block="$(extract_422_block "$url" "$recon_dir")"
  [ -n "$block" ] || return 0

  local fields
  fields=$(printf '%s' "$block" \
    | jq -r '.detail[]?.loc[-1] // empty' 2>/dev/null)

  if [ -z "$fields" ]; then
    fields=$(printf '%s' "$block" \
      | jq -r '
          .errors[]?.field
          // .errors[]?.param
          // .missing[]?
          // .invalid_fields[]?.field
          // empty
        ' 2>/dev/null)
  fi

  printf '%s' "$fields" | sort -u | grep -v '^$' || true
}

# ============================================================
# Tier 2 — fields from the JS bundle
#
# Preferred: Node + @babel/core AST resolver (catches wrappers,
#            local function calls, spread, JSON.stringify).
# Fallback:  regex on a 1200-byte window around the URL.
# ============================================================
extract_fields_from_js() {
  local path="$1" recon_dir="$2"
  local js_dir="$recon_dir/js"
  [ -d "$js_dir" ] || return 0

  local search="${path%%\$\{*}"
  [ ${#search} -lt 6 ] && return 0

  # ---------- try AST resolver first ----------
  if command -v node >/dev/null 2>&1; then
    local resolver modules
    if resolver="$(_find_resolver)" && [ -n "$resolver" ]; then
      modules="$(_find_node_modules 2>/dev/null)" || modules=""

      local f out
      for f in "$js_dir"/*.js; do
        [ -f "$f" ] || continue
        grep -qF "$search" "$f" 2>/dev/null || continue
        out=$(node "$resolver" "$f" "$search" 2>/dev/null)
        if [ -n "$out" ]; then
          printf '%s\n' "$out"
          return 0
        fi
      done
    fi
  fi

  # ---------- fall back to regex ----------
  extract_fields_from_js_regex "$path" "$recon_dir"
}

# regex-based fallback — kept for environments without Node
extract_fields_from_js_regex() {
  local path="$1" recon_dir="$2"
  local js_dir="$recon_dir/js"
  [ -d "$js_dir" ] || return 0

  local search="${path%%\$\{*}"
  [ ${#search} -lt 10 ] && return 0

  local f offset
  for f in "$js_dir"/*.js; do
    [ -f "$f" ] || continue
    offset=$(grep -aboF "$search" "$f" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$offset" ] && break
  done
  [ -z "${offset:-}" ] && return 0

  local window=150
  local start=$(( offset > window ? offset - window : 0 ))
  local len=$(( window * 2 + ${#search} ))
  local chunk
  chunk=$(dd if="$f" bs=1 skip="$start" count="$len" 2>/dev/null)
  [ -z "$chunk" ] && return 0

  # reject route-map chunks: >1 URL means a route table, not a call site
  local url_count
  url_count=$(printf '%s' "$chunk" \
    | grep -oE '"/[a-zA-Z0-9_./?&=${}-]{4,}"' | wc -l)
  [ "$url_count" -gt 1 ] && return 0

  local best="" best_count=0
  local blk n
  while IFS= read -r blk; do
    [ -z "$blk" ] && continue
    n=$(printf '%s' "$blk" | grep -oP '\b[a-zA-Z_$][a-zA-Z0-9_$]*\s*:' | wc -l)
    if [ "$n" -gt "$best_count" ]; then
      best="$blk"; best_count="$n"
    fi
  done < <(printf '%s' "$chunk" | grep -oP '\{[^{}]{10,800}\}')

  [ -z "$best" ] && return 0
  [ "$best_count" -lt 2 ] && return 0

  printf '%s' "$best" \
    | grep -oP '\b[a-zA-Z_$][a-zA-Z0-9_$]*(?=\s*:)' \
    | grep -vEx 'method|headers|body|data|signal|cache|credentials|mode|redirect|referrer|url|uri|params|query|options|config|onUploadProgress|responseType|timeout|withCredentials|transformRequest|transformResponse|baseURL' \
    | awk '!seen[$0]++'
}

# ============================================================
# Tier 3 — infer fields from the path
# ============================================================
infer_fields_from_path() {
  local verb="$1" path="$2"
  local low
  low="$(printf '%s' "$path" | tr 'A-Z' 'a-z')"

  case "$verb" in
    GET|DELETE) return ;;
  esac

  case "$low" in
    *login*|*signin*|*sign-in*|*authenticate*)
      printf 'username\npassword\n'; return ;;
    *register*|*signup*|*sign-up*|*create-account*)
      printf 'name\nemail\npassword\n'; return ;;
    *forgot-password*|*password/forgot*|*password/forget*)
      printf 'email\n'; return ;;
    *reset-password*|*password/reset*)
      printf 'reset_token\nnew_password\n'; return ;;
    *change-password*|*password/change*|*password/update*)
      printf 'old_password\nnew_password\n'; return ;;
    *refresh-token*|*token/refresh*|*/refresh*)
      printf 'refresh_token\n'; return ;;
    *logout*|*sign-out*)
      return ;;
  esac

  if [[ "$low" =~ (totp|2fa|mfa|otp|one-time|two-factor) ]]; then
    if [[ "$low" =~ (setup|enable|register|enroll|init) ]]; then
      return
    elif [[ "$low" =~ (recovery|backup) ]]; then
      return
    else
      printf 'code\n'; return
    fi
  fi

  if [[ "$low" =~ (token-order|order|checkout|purchase|cart|basket|buy) ]]; then
    printf 'package_id\nquantity\n'; return
  fi
  if [[ "$low" =~ (ticket|issue|bug|support) ]]; then
    printf 'title\ndescription\n'; return
  fi
  if [[ "$low" =~ (contact|feedback|inquiry|complaint|report-bug) ]]; then
    printf 'name\nemail\nsubject\nmessage\n'; return
  fi
  if [[ "$low" =~ (comment|note|reply) ]]; then
    printf 'body\n'; return
  fi
  if [[ "$low" =~ (post|article|blog|entry) ]]; then
    printf 'title\nbody\n'; return
  fi
  if [[ "$low" =~ (project|workspace|board|task|card|folder|document) ]]; then
    printf 'name\ndescription\n'; return
  fi
  if [[ "$low" =~ (/me$|/me/|profile|account|current-user|whoami) ]]; then
    printf 'name\nemail\n'; return
  fi
  if [[ "$low" =~ (user|member|staff|employee) ]]; then
    printf 'name\nemail\nrole\n'; return
  fi
  if [[ "$low" =~ (product|item|package|sku|catalog) ]]; then
    printf 'name\nprice\ndescription\n'; return
  fi
  if [[ "$low" =~ (coupon|voucher|discount|promo) ]]; then
    printf 'code\n'; return
  fi
  if [[ "$low" =~ (upload|attachment|media|file) ]]; then
    printf 'file\n'; return
  fi
  if [[ "$low" =~ (webhook|callback|hook) ]]; then
    printf 'url\nsecret\n'; return
  fi
  if [[ "$low" =~ (search|query|lookup|find) ]]; then
    printf 'query\n'; return
  fi
  if [[ "$low" =~ (generate|build|render|deploy) ]]; then
    printf 'name\nconfig\n'; return
  fi
  if [[ "$low" =~ (invite|share) ]]; then
    printf 'email\n'; return
  fi
  if [[ "$low" =~ (verify|validate|confirm) ]]; then
    printf 'token\n'; return
  fi

  case "$verb" in
    POST|PUT|PATCH) printf 'name\n' ;;
  esac
}

# ============================================================
# Resolver — tiers 1 → 2 → 3, cached per (verb, path)
# ============================================================
declare -A FIELDS_CACHE=()

resolve_fields() {
  local verb="$1" url="$2" path="$3" recon_dir="$4"
  local cache_key="$verb $path"

  if [ -n "${FIELDS_CACHE[$cache_key]:-}" ]; then
    printf '%s\n' "${FIELDS_CACHE[$cache_key]}"
    return
  fi

  local fields=""
  fields="$(extract_422_fields "$url" "$recon_dir")"
  if [ -z "$fields" ]; then
    fields="$(extract_fields_from_js "$path" "$recon_dir")"
  fi
  if [ -z "$fields" ]; then
    fields="$(infer_fields_from_path "$verb" "$path")"
  fi

  FIELDS_CACHE["$cache_key"]="$fields"
  printf '%s\n' "$fields"
}

# ============================================================
# Example values — driven by field name
# ============================================================
example_value() {
  local name="$1"
  local low
  low="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"

  case "$low" in
    email|e-mail|mail)                    printf 'you@example.com' ;;
    *email*)                              printf 'you@example.com' ;;
    username|user|login|handle)           printf 'testuser' ;;
    *password*|passwd|pass)               printf 'Passw0rd!' ;;
    confirm*|*_confirm|repeat*)           printf 'Passw0rd!' ;;
    name|full_name|display_name)          printf 'Test User' ;;
    first_name|firstname)                 printf 'Test' ;;
    last_name|lastname|surname)           printf 'User' ;;
    phone|phone_number|mobile)            printf '+15555550100' ;;
    *token*|*code*|otp|verification_code) printf '123456' ;;
    *amount*|*price*|*cost*)              printf '1.00' ;;
    *quantity*|*count*|*number*)          printf '1' ;;
    *url*|*uri*|*link*|*callback*|*href*) printf 'https://example.com' ;;
    *id|id_*|*_id)                        printf '1' ;;
    *enabled|is_*|has_*)                  printf 'true' ;;
    title|subject|summary|label)          printf 'Test Title' ;;
    body|content|message|text|description|note) printf 'Test message' ;;
    address|street)                       printf '123 Test St' ;;
    city)                                 printf 'Springfield' ;;
    country|country_code)                 printf 'US' ;;
    zip|postal_code)                      printf '12345' ;;
    date|*_at|*_date|*_time)              printf '2026-01-01T00:00:00Z' ;;
    role|type|kind|category|status)       printf 'test' ;;
    slug|key|alias)                       printf 'test-slug' ;;
    config|metadata|payload|data)         printf '{}' ;;
    tags|labels)                          printf 'test' ;;
    file|attachment)                      printf '@/tmp/test.txt' ;;
    secret|api_key|apikey|client_secret)  printf 'redacted-secret' ;;
    *)                                    printf 'value' ;;
  esac
}

build_body_json() {
  local fields="$1"
  local json='{' first=1 f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ $first -eq 1 ] || json+=','
    case "$f" in
      config|metadata|payload|data)
        json+="\"$f\":{}" ;;
      *enabled|is_*|has_*)
        json+="\"$f\":true" ;;
      *quantity*|*count*|*id)
        json+="\"$f\":1" ;;
      *)
        json+="\"$f\":\"$(example_value "$f")\"" ;;
    esac
    first=0
  done <<< "$fields"
  json+='}'
  printf '%s' "$json"
}

build_body_form() {
  local fields="$1" out="" f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -n "$out" ] && out+=" "
    out+="--data-urlencode '$f=$(example_value "$f")'"
  done <<< "$fields"
  printf '%s' "$out"
}