#!/usr/bin/env bash
# lib/recon.sh — crawl, extract, probe, enumerate
#
# Entry point: run_recon <base-url> <output-dir>

[ -n "${_SPA_RECON_LOADED:-}" ] && return 0
readonly _SPA_RECON_LOADED=1

recon_usage() {
  cat <<EOF
Usage: spa-recon.sh <base-url> [output-dir] [flags]

Flags:
  --report              generate HTML report after scan
  --pdf                 also produce PDF (implies --report)
  --open                open report when done (implies --report)
  --token <tok>         bearer token for authenticated probing
  --cookie <str>        cookie header
  --basic <user:pass>   HTTP Basic auth
  --header <k:v>        extra header (repeatable)
  --no-katana           skip katana, use HTML fallback only
  --no-headless         run katana without a headless browser
  -h, --help            show this help
  -V, --version         print version

Environment:
  SPA_TOKEN / SPA_COOKIE / SPA_BASIC / SPA_HEADERS

Config:
  ./.spa-reconrc is sourced if present (bash syntax)
EOF
}

# ============================================================
# framework detection
# ============================================================
detect_framework() {
  local h="$1"
  [ -f "$h" ] || { echo "unknown"; return; }

  if grep -q '__NEXT_DATA__\|/_next/' "$h" 2>/dev/null; then echo "nextjs"
  elif grep -q '__NUXT__\|/_nuxt/' "$h" 2>/dev/null; then echo "nuxt"
  elif grep -q '_app/immutable\|sveltekit' "$h" 2>/dev/null; then echo "sveltekit"
  elif grep -qE 'ng-version|ng-app|_ngcontent' "$h" 2>/dev/null; then echo "angular"
  elif grep -qiE '<div id="root">|__REACT|_reactRootContainer' "$h" 2>/dev/null; then echo "react"
  elif grep -qiE '<div id="app">|__VUE|data-v-' "$h" 2>/dev/null; then echo "vue"
  elif grep -qi 'ember' "$h" 2>/dev/null; then echo "ember"
  elif grep -qi 'solid-js\|data-solid' "$h" 2>/dev/null; then echo "solid"
  elif grep -qi 'qwik\|data-qwik' "$h" 2>/dev/null; then echo "qwik"
  else echo "unknown"
  fi
}

# ============================================================
# url normalization
#
# Katana emits absolute URLs (http://host/path). The HTML-scrape
# fallback emits relative paths (/path) or protocol-relative (//host).
# Deduplicate by prefixing relative forms with $BASE so both forms
# of the same URL collapse to one line under `sort -u`.
# ============================================================
normalize_urls() {
  local base="$1"
  awk -v base="$base" '
    /^[[:space:]]*$/       { next }
    /^https?:\/\//         { print; next }
    /^\/\//                { print "https:"$0; next }
    /^\//                  { print base $0; next }
    { print }
  '
}

# ============================================================
# main pipeline
# ============================================================
run_recon() {
  local BASE="${1%/}"
  local OUT="$2"

  # ---------- flag defaults (guard against unbound variables) ----------
  : "${NO_KATANA:=0}"
  : "${NO_HEADLESS:=0}"

  mkdir -p "$OUT"/{js,logs}

  local SELF_DIR
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local GOPATH_BIN
  GOPATH_BIN="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin"
  local JSLUICE="$GOPATH_BIN/jsluice"
  local KATANA="$GOPATH_BIN/katana"

  export LC_ALL=C

  # ---------- auth args ----------
  declare -a AUTH=()
  if [ -n "${SPA_TOKEN:-}" ]; then
    AUTH+=(-H "Authorization: Bearer $SPA_TOKEN")
  fi
  if [ -n "${SPA_COOKIE:-}" ]; then
    AUTH+=(-H "Cookie: $SPA_COOKIE")
  fi
  if [ -n "${SPA_BASIC:-}" ]; then
    AUTH+=(-u "$SPA_BASIC")
  fi
  if [ -n "${SPA_HEADERS:-}" ]; then
    local _h
    IFS=';' read -ra _hdrs <<< "$SPA_HEADERS"
    for _h in "${_hdrs[@]}"; do
      _h="${_h#"${_h%%[![:space:]]*}"}"
      _h="${_h%"${_h##*[![:space:]]}"}"
      [ -n "$_h" ] && AUTH+=(-H "$_h")
    done
  fi
  local UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"

  if [ ${#AUTH[@]} -gt 0 ]; then
    log "authenticated mode: ${#AUTH[@]} auth argument(s)"
  else
    log "anonymous mode"
  fi

  # ---------- 0. dependency check ----------
  log "checking dependencies"
  local tool
  for tool in curl jq grep sed sort awk comm; do
    command -v "$tool" >/dev/null || die "missing: $tool"
  done
  [ -x "$JSLUICE" ] || warn "jsluice not found — install: go install github.com/BishopFox/jsluice/cmd/jsluice@latest"
  [ -x "$KATANA"  ] || warn "katana not found — install: go install github.com/projectdiscovery/katana/cmd/katana@latest"

  # ---------- 1. fetch entry HTML ----------
  log "fetching entry HTML"
  curl -sL -A "$UA" "${AUTH[@]}" "$BASE/" -o "$OUT/logs/root.html" || true
  local html_size
  html_size=$(wc -c < "$OUT/logs/root.html" 2>/dev/null || echo 0)
  ok "root HTML: $html_size bytes"

  # ---------- 2. framework detection ----------
  local FRAMEWORK
  FRAMEWORK="$(detect_framework "$OUT/logs/root.html")"
  printf '%s\n' "$FRAMEWORK" > "$OUT/framework.txt"
  ok "framework: $FRAMEWORK"

  # ---------- 3. crawl with katana ----------
  : > "$OUT/logs/katana-all.txt"

  if [ "$NO_KATANA" = "1" ]; then
    warn "skipping katana (--no-katana)"
  elif [ -x "$KATANA" ]; then
    log "katana: crawling $BASE"
    local katana_args=(
      -u "$BASE"
      -fs fqdn
      -jc -jsl -xhr
      -d 5 -timeout 20 -silent
      -o "$OUT/logs/katana-all.txt"
    )
    if [ "$NO_HEADLESS" != "1" ]; then
      katana_args+=(-hl -no-sandbox -pls domcontentloaded -dwt 10)
      local c
      for c in chromium chromium-browser google-chrome google-chrome-stable; do
        command -v "$c" >/dev/null 2>&1 && { katana_args+=(-system-chrome); break; }
      done
    fi
    if [ -n "${SPA_HEADERS:-}" ]; then
      katana_args+=(-H "$SPA_HEADERS")
    fi
    "$KATANA" "${katana_args[@]}" 2>"$OUT/logs/katana.err" \
      || warn "katana exited with warnings (see $OUT/logs/katana.err)"
  else
    warn "katana not installed — using HTML fallback"
  fi

  # Pull URLs out of the entry HTML as a fallback source
  grep -oE '(src|href)="[^"]+"' "$OUT/logs/root.html" 2>/dev/null \
    | sed -E 's/^(src|href)="//; s/"$//' >> "$OUT/logs/katana-all.txt" || true

  # Normalize the merged list — relative paths get $BASE prefixed so
  # the HTML-extracted form dedupes against katana's absolute form.
  normalize_urls "$BASE" < "$OUT/logs/katana-all.txt" \
    | sort -u > "$OUT/logs/katana-all.txt.norm"
  mv "$OUT/logs/katana-all.txt.norm" "$OUT/logs/katana-all.txt"

  # Split JS assets from live URLs.
  # The `grep -vE '\$'` drops template-literal fragments
  # (e.g. bare `/$`) that would otherwise inflate the count.
  grep -E '\.js($|\?|#)' "$OUT/logs/katana-all.txt" 2>/dev/null \
    | grep -vE '\$' \
    | sed 's/[?#].*//' | sort -u > "$OUT/js-urls.txt"
  grep -vE '\.js($|\?|#)' "$OUT/logs/katana-all.txt" 2>/dev/null \
    | grep -vE '\$' \
    | sed 's/[?#].*//' | sort -u > "$OUT/katana-urls.txt"

  # ---------- 4. fallback JS discovery ----------
  if [ ! -s "$OUT/js-urls.txt" ]; then
    log "fallback: scraping HTML for JS assets"
    {
      grep -oE '<script[^>]+src="[^"]+"' "$OUT/logs/root.html" 2>/dev/null \
        | grep -oE 'src="[^"]+"' | sed 's/^src="//; s/"$//'
      grep -oE '<link[^>]+rel="modulepreload"[^>]+href="[^"]+"' "$OUT/logs/root.html" 2>/dev/null \
        | grep -oE 'href="[^"]+"' | sed 's/^href="//; s/"$//'
      grep -oE '<link[^>]+as="script"[^>]+href="[^"]+"' "$OUT/logs/root.html" 2>/dev/null \
        | grep -oE 'href="[^"]+"' | sed 's/^href="//; s/"$//'
    } | normalize_urls "$BASE" | sort -u > "$OUT/js-urls.txt"
  fi

  # Framework-specific extra chunk discovery
  case "$FRAMEWORK" in
    nextjs)
      grep -oE '/_next/static/[^"]+\.js' "$OUT/logs/root.html" 2>/dev/null \
        | normalize_urls "$BASE" >> "$OUT/js-urls.txt" || true
      ;;
    nuxt)
      grep -oE '/_nuxt/[^"]+\.js' "$OUT/logs/root.html" 2>/dev/null \
        | normalize_urls "$BASE" >> "$OUT/js-urls.txt" || true
      ;;
    sveltekit)
      grep -oE '/_app/immutable/[^"]+\.js' "$OUT/logs/root.html" 2>/dev/null \
        | normalize_urls "$BASE" >> "$OUT/js-urls.txt" || true
      ;;
  esac

  sort -u "$OUT/js-urls.txt" -o "$OUT/js-urls.txt"
  ok "found $(wc -l < "$OUT/js-urls.txt") JS file(s)"

  # ---------- 5. download JS ----------
  log "downloading JS assets"
  while read -r u; do
    [ -z "$u" ] && continue
    local fname
    fname="$(basename "${u%%\?*}")"
    [ -z "$fname" ] && fname="index.js"
    curl -sL -A "$UA" "${AUTH[@]}" "$u" -o "$OUT/js/$fname" || warn "failed: $u"
  done < "$OUT/js-urls.txt"

  # ---------- 6. extract paths ----------
  log "extracting paths"
  : > "$OUT/paths.txt"

  if [ -x "$JSLUICE" ]; then
    local f
    for f in "$OUT"/js/*.js; do
      [ -f "$f" ] || continue
      "$JSLUICE" urls "$f" 2>/dev/null \
        | jq -r '.url // empty' 2>/dev/null \
        >> "$OUT/paths.txt" || true
    done
  fi

  local f
  for f in "$OUT"/js/*.js; do
    [ -f "$f" ] || continue
    grep -oE '"/[a-zA-Z0-9_./{}:$@~-]+"' "$f" 2>/dev/null | tr -d '"' >> "$OUT/paths.txt"
    grep -oE "'/[a-zA-Z0-9_./{}:$@~-]+'" "$f" 2>/dev/null | tr -d "'" >> "$OUT/paths.txt"
    grep -oE '`/[a-zA-Z0-9_./{}:$@~-]+`' "$f" 2>/dev/null | tr -d '`' >> "$OUT/paths.txt"
  done

  # ---------- 7. clean + classify ----------
  log "cleaning path list"

  # `grep -vE '\$$'` drops any path ending in a dollar sign —
  # those come from JS template literals like `/${var}` where the
  # variable name was stripped, leaving a bare `/$` fragment.
  sed 's/[?#].*//' "$OUT/paths.txt" \
    | grep -E '^/' \
    | grep -vE '\$\{|%7B|\.\.' \
    | grep -vE '\$$' \
    | grep -vE '\.(css|js|map|png|jpe?g|gif|svg|ico|woff2?|ttf|eot|webp|avif|mp4|webm|pdf|zip|gz)$' \
    | grep -vE '^/(index\.html|dashboard\.html|pages/:)' \
    | grep -vE 'errorCorrectionLevel|react\.dev|node_modules|webpack|sourceMappingURL' \
    | grep -vE '^/(//|$)' \
    | sed 's:/$::' \
    | sort -u > "$OUT/paths.clean.txt"

  grep -E '^/(api|graphql|rest|v[0-9]+|_next/data|_nuxt)/' "$OUT/paths.clean.txt" \
    | sort -u > "$OUT/api-paths.txt"
  grep -E '^/(auth|oauth|session|token|login|logout|register|signup|account|password|user|admin)' \
    "$OUT/paths.clean.txt" | sort -u >> "$OUT/api-paths.txt"
  sort -u "$OUT/api-paths.txt" -o "$OUT/api-paths.txt"

  sort -u "$OUT/paths.clean.txt" -o "$OUT/paths.clean.txt"
  comm -23 "$OUT/paths.clean.txt" "$OUT/api-paths.txt" > "$OUT/ui-paths.txt"

  ok "api-paths.txt: $(wc -l < "$OUT/api-paths.txt")  ui-paths.txt: $(wc -l < "$OUT/ui-paths.txt")"

  # ---------- 8. probe every path (GET) ----------
  log "probing paths (GET)"
  sed "s|^|$BASE|" "$OUT/paths.clean.txt" > "$OUT/urls.txt"

  : > "$OUT/probe.tsv"
  while read -r u; do
    [ -z "$u" ] && continue
    local code ctype
    read -r code ctype < <(
      curl -s -o /dev/null -m 10 -A "$UA" "${AUTH[@]}" \
        -w '%{http_code} %{content_type}' "$u"
    )
    printf '%s\t%s\t%s\n' "$code" "$ctype" "$u" >> "$OUT/probe.tsv"
  done < "$OUT/urls.txt"

  {
    printf '\n%-6s %-30s %s\n' "CODE" "CONTENT-TYPE" "URL"
    printf '%-6s %-30s %s\n' "----" "------------" "---"
    sort -n "$OUT/probe.tsv" | awk -F'\t' '{printf "%-6s %-30s %s\n", $1, $2, $3}'
  } >&2

  # ---------- 9. classify ----------
  grep -P '^401\t' "$OUT/probe.tsv"       | cut -f3 > "$OUT/needs-auth.txt"
  grep -P '^403\t' "$OUT/probe.tsv"       | cut -f3 > "$OUT/forbidden.txt"
  grep -P '^405\t' "$OUT/probe.tsv"       | cut -f3 > "$OUT/wrong-method.txt"
  grep -P '^5[0-9]{2}\t' "$OUT/probe.tsv" | cut -f3 > "$OUT/server-errors.txt"
  grep -P '^200\t.*json' "$OUT/probe.tsv" | cut -f3 > "$OUT/json-200.txt"
  grep -P '^200\t.*html' "$OUT/probe.tsv" | cut -f3 > "$OUT/spa-catchall.txt"

  ok "needs-auth:    $(wc -l < "$OUT/needs-auth.txt")"
  ok "wrong-method:  $(wc -l < "$OUT/wrong-method.txt")"
  ok "server-errors: $(wc -l < "$OUT/server-errors.txt")"
  ok "json 200s:     $(wc -l < "$OUT/json-200.txt")"
  ok "spa catch-all: $(wc -l < "$OUT/spa-catchall.txt")"

  # ---------- 10. SPA catch-all check ----------
  log "verifying SPA catch-all behavior"
  local random_path="$BASE/__spa-recon-$(date +%s%N)"
  local rand_code rand_type
  read -r rand_code rand_type < <(
    curl -s -o /dev/null -m 10 -A "$UA" "${AUTH[@]}" \
      -w '%{http_code} %{content_type}' "$random_path"
  )
  printf 'random path -> %s %s\n' "$rand_code" "$rand_type" \
    | tee "$OUT/logs/catchall-check.txt"

  if grep -q 'html' <<< "$rand_type" && [ "$rand_code" = "200" ]; then
    warn "server returns 200 text/html for unknown paths — 200/html entries are SPA fallback"
  fi

  # ---------- 11. method enumeration ----------
  log "enumerating HTTP methods (401/403/405 targets)"
  cat "$OUT/needs-auth.txt" "$OUT/wrong-method.txt" "$OUT/forbidden.txt" 2>/dev/null \
    | sort -u > "$OUT/method-targets.txt"

  : > "$OUT/methods.tsv"
  while read -r u; do
    [ -z "$u" ] && continue
    local verb code
    for verb in GET POST PUT PATCH DELETE; do
      code=$(curl -s -o /dev/null -m 10 -X "$verb" \
        -A "$UA" "${AUTH[@]}" \
        -H 'Content-Type: application/json' -d '{}' \
        -w '%{http_code}' "$u")
      printf '%s\t%s\t%s\n' "$verb" "$code" "$u" >> "$OUT/methods.tsv"
    done
  done < "$OUT/method-targets.txt"

  awk -F'\t' '$2 != "404" && $2 != "405"' "$OUT/methods.tsv" \
    | sort -u > "$OUT/methods-valid.tsv"

  if [ -s "$OUT/methods-valid.tsv" ]; then
    {
      printf '\nValid method/path combinations (router accepted):\n'
      awk -F'\t' '{printf "  %-7s %s\t-> %s\n", $1, $2, $3}' "$OUT/methods-valid.tsv"
    } >&2
  fi

  # ---------- 12. capture 422 validation bodies ----------
  log "capturing 422 validation responses (schema hints)"
  : > "$OUT/422-bodies.txt"

  grep -P '\t(422|400)\t' "$OUT/methods.tsv" 2>/dev/null \
    | awk -F'\t' '{print $1"\t"$3}' | sort -u \
    | while IFS=$'\t' read -r verb url; do
        [ -z "$url" ] && continue
        printf '=== %s %s ===\n' "$verb" "$url" >> "$OUT/422-bodies.txt"
        curl -s -X "$verb" \
          -A "$UA" "${AUTH[@]}" \
          -H 'Content-Type: application/json' \
          -d '{}' -m 10 "$url" >> "$OUT/422-bodies.txt" 2>&1
        printf '\n\n' >> "$OUT/422-bodies.txt"
      done

  local count_422
  count_422=$(grep -c '^===' "$OUT/422-bodies.txt" 2>/dev/null || echo 0)
  if [ "$count_422" -gt 0 ]; then
    ok "wrote 422-bodies.txt ($count_422 endpoint(s))"
  else
    warn "no validation responses captured"
  fi

  # ---------- 13. schema / docs ----------
  log "checking for API schema exposure"
  : > "$OUT/schema-hits.txt"
  local path
  for path in \
      /openapi.json /openapi.yaml /swagger.json /swagger.yaml \
      /api-docs /redoc /api/v1/openapi.json /api/v1/swagger.json \
      /api/v1/docs /api/openapi.json /api/swagger.json \
      /api/swagger-ui.html /v2/api-docs /v3/api-docs \
      /graphql /graphiql /.well-known/openid-configuration; do
    local code ctype
    read -r code ctype < <(
      curl -s -o /dev/null -m 10 -A "$UA" "${AUTH[@]}" \
        -w '%{http_code} %{content_type}' "$BASE$path"
    )
    if [ "$code" = "200" ] && ! grep -q 'text/html' <<< "$ctype"; then
      printf '%s %s\t%s\n' "$code" "$ctype" "$path" | tee -a "$OUT/schema-hits.txt"
    fi
  done
  [ -s "$OUT/schema-hits.txt" ] \
    && warn "real schema/doc endpoints found" \
    || ok "no real schema endpoints (all 200s were SPA fallback)"

  # ---------- 14. authenticated re-probe summary ----------
  if [ ${#AUTH[@]} -gt 0 ] && [ -s "$OUT/needs-auth.txt" ]; then
    log "writing authenticated probe summary"
    : > "$OUT/probe-authed.tsv"
    while read -r u; do
      [ -z "$u" ] && continue
      local code
      code=$(curl -s -o /dev/null -m 10 -A "$UA" "${AUTH[@]}" \
        -w '%{http_code}' "$u")
      printf '%s\t%s\n' "$code" "$u" >> "$OUT/probe-authed.tsv"
    done < "$OUT/needs-auth.txt"
  fi

  # ---------- 15. summary ----------
  cat > "$OUT/SUMMARY.txt" <<EOF
spa-recon summary for $BASE
generated: $(date -Iseconds)
framework: $FRAMEWORK
output:    $OUT
mode:      $([ ${#AUTH[@]} -gt 0 ] && echo "authenticated" || echo "anonymous")

JS assets fetched   : $(wc -l < "$OUT/js-urls.txt")
paths discovered   : $(wc -l < "$OUT/paths.clean.txt")
api-ish paths      : $(wc -l < "$OUT/api-paths.txt")
ui paths           : $(wc -l < "$OUT/ui-paths.txt")

probe results:
  401 (auth needed)   : $(wc -l < "$OUT/needs-auth.txt")
  403 (forbidden)     : $(wc -l < "$OUT/forbidden.txt")
  405 (wrong method)  : $(wc -l < "$OUT/wrong-method.txt")
  5xx (server errors) : $(wc -l < "$OUT/server-errors.txt")
  200 json            : $(wc -l < "$OUT/json-200.txt")
  200 html (SPA)      : $(wc -l < "$OUT/spa-catchall.txt")
  422 bodies captured : $count_422

artifacts:
  probe.tsv            probe results (status / content-type / url)
  methods.tsv          full method matrix per target
  methods-valid.tsv    router-accepted method/path pairs
  422-bodies.txt       validation responses (schema hints)
  schema-hits.txt      real schema/doc endpoints, if any
  framework.txt        detected framework
  js/                  downloaded JS bundles
  logs/                raw katana output and probe logs
EOF

  echo >&2
  ok "done. artifacts in $OUT/"
  cat "$OUT/SUMMARY.txt" >&2
}