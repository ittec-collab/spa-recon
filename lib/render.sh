#!/usr/bin/env bash
# lib/render.sh — HTML report rendering and template substitution
#
# The entry point is render_report(recon_dir, out_html, want_pdf, want_open).

[ -n "${_SPA_RENDER_LOADED:-}" ] && return 0
readonly _SPA_RENDER_LOADED=1

report_usage() {
  cat <<EOF
Usage: spa-report.sh <recon-dir> [output.html] [flags]

Flags:
  --pdf        force PDF generation
  --no-pdf     skip PDF generation
  --open       open the report when done
  -h, --help   show this help
  -V, --version

Environment:
  SPA_REPORT_TPL_DIR   directory containing report.html and report.css
EOF
}

# ============================================================
# table / list renderers
# ============================================================
render_probe_table() {
  local recon_dir="$1"
  local file="$recon_dir/probe.tsv"
  if [ ! -s "$file" ]; then echo '<p class="empty">(none)</p>'; return; fi
  printf '<table><thead><tr><th>Status</th><th>Content-Type</th><th>URL</th></tr></thead><tbody>\n'
  while IFS=$'\t' read -r code ctype url; do
    printf '<tr><td class="code %s">%s</td><td class="ctype">%s</td><td class="url">%s</td></tr>\n' \
      "$(status_class "$code")" "$(esc "$code")" "$(esc "$ctype")" "$(esc "$url")"
  done < "$file"
  printf '</tbody></table>\n'
}

render_methods_table() {
  local file="$1"
  if [ ! -s "$file" ]; then echo '<p class="empty">(none)</p>'; return; fi
  printf '<table><thead><tr><th>Method</th><th>Status</th><th>URL</th></tr></thead><tbody>\n'
  while IFS=$'\t' read -r verb code url; do
    printf '<tr><td><span class="method %s">%s</span></td><td class="code %s">%s</td><td class="url">%s</td></tr>\n' \
      "$(method_class "$verb")" "$(esc "$verb")" \
      "$(status_class "$code")" "$(esc "$code")" "$(esc "$url")"
  done < "$file"
  printf '</tbody></table>\n'
}

render_list() {
  local file="$1"
  if [ ! -s "$file" ]; then echo '<p class="empty">(none)</p>'; return; fi
  printf '<ul class="endpoint-list">\n'
  while read -r line; do
    [ -z "$line" ] && continue
    printf '<li><code>%s</code></li>\n' "$(esc "$line")"
  done < "$file"
  printf '</ul>\n'
}

# ============================================================
# frontend JS context — show the call site
# ============================================================
extract_js_context() {
  local endpoint="$1" recon_dir="$2"
  local js_dir="$recon_dir/js"
  local window=150

  [ -d "$js_dir" ] || return 0
  local search="${endpoint%%\$\{*}"
  [ -z "$search" ] && return 0

  local f offset snippet
  for f in "$js_dir"/*.js; do
    [ -f "$f" ] || continue
    offset=$(grep -aboF "$search" "$f" 2>/dev/null | head -1 | cut -d: -f1)
    [ -z "$offset" ] && continue

    local start=$(( offset > window ? offset - window : 0 ))
    local len=$(( window * 2 + ${#search} ))
    snippet=$(dd if="$f" bs=1 skip="$start" count="$len" 2>/dev/null \
      | tr '\n\r\t' '   ' \
      | sed -E 's/ {2,}/ /g; s/^ +//; s/ +$//')

    if printf '%s' "$snippet" | grep -qE '(fetch\(|axios|\.post\(|\.get\(|\.patch\(|\.put\(|\.delete\(|method:|body:|data:|JSON\.stringify|\$http|\$\.ajax)'; then
      printf '%s' "$snippet"
      return 0
    fi
  done
}

# ============================================================
# curl snippet — auth per (verb, path)
# ============================================================
curl_snippet() {
  local verb="$1" url="$2" path="$3" recon_dir="$4" base_url="$5"
  local auth_hdr=""
  needs_auth_for "$verb" "$path" && auth_hdr=' -H "Authorization: Bearer $TOKEN"'

  case "$verb" in
    GET|DELETE)
      printf 'curl -s -X %s%s \\\n  %s | jq .' \
        "$verb" "$auth_hdr" "$url"
      return
      ;;
  esac

  local fields
  fields="$(resolve_fields "$verb" "$url" "$path" "$recon_dir")"

  if [ -z "$fields" ]; then
    printf 'curl -s -X %s%s \\\n  %s | jq .' \
      "$verb" "$auth_hdr" "$url"
    return
  fi

  if is_form_endpoint "$path" "$base_url" "$recon_dir"; then
    local body
    body="$(build_body_form "$fields")"
    printf 'curl -s -X %s%s \\\n  -H "Content-Type: application/x-www-form-urlencoded" \\\n  %s \\\n  %s | jq .' \
      "$verb" "$auth_hdr" "$body" "$url"
  else
    local body
    body="$(build_body_json "$fields")"
    printf 'curl -s -X %s%s \\\n  -H "Content-Type: application/json" \\\n  -d '"'"'%s'"'"' \\\n  %s | jq .' \
      "$verb" "$auth_hdr" "$body" "$url"
  fi
}

# ============================================================
# usage section — the main endpoint playbook
# ============================================================
render_usage_section() {
  local recon_dir="$1" base_url="$2"
  local file="$recon_dir/methods-valid.tsv"
  if [ ! -s "$file" ]; then
    echo '<p class="empty">(none — no valid method/path combinations found)</p>'
    return
  fi

  local tmp="$recon_dir/.usage-pairs.tmp"
  awk -F'\t' '{print $3"\t"$1}' "$file" \
    | sort -u \
    | awk -F'\t' '
        { if ($1 != last) { if (last != "") print ""; last=$1; print $1"\t"$2 }
          else print $1"\t"$2 }
      ' > "$tmp"

  local current_url="" current_path=""
  while IFS=$'\t' read -r url verb; do
    [ -z "$url" ] && continue
    local path="${url#$base_url}"

    if [ "$url" != "$current_url" ]; then
      [ -n "$current_url" ] && printf '</div>\n'
      current_url="$url"
      current_path="$path"

      printf '<div class="usage-block">\n'
      printf '<div class="usage-head"><code class="usage-path">%s</code></div>\n' \
        "$(esc "$current_path")"

      endpoint_guide "$current_path" "$recon_dir" "$base_url"

      # Chips for whichever write verb carries a body
      local chip_verb="" chip_fields=""
      for v in POST PUT PATCH; do
        local st="${METHOD_STATUS[$v $current_path]:-}"
        [ -z "$st" ] && continue
        [ "$st" = "404" ] && continue
        [ "$st" = "405" ] && continue
        local f
        f="$(resolve_fields "$v" "$url" "$current_path" "$recon_dir")"
        if [ -n "$f" ]; then
          chip_verb="$v"
          chip_fields="$f"
          break
        fi
      done

      if [ -n "$chip_fields" ]; then
        printf '<div class="usage-fields">\n'
        printf '  <span class="usage-fields-label">Fields <span class="usage-fields-verb">%s</span></span>\n' "$chip_verb"
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          printf '  <code>%s</code>\n' "$(esc "$f")"
        done <<< "$chip_fields"
        printf '</div>\n'
      fi

      local js_ctx
      js_ctx="$(extract_js_context "$current_path" "$recon_dir")"
      if [ -n "$js_ctx" ]; then
        printf '<details class="usage-ctx">\n'
        printf '  <summary>frontend call (from JS bundle)</summary>\n'
        printf '  <pre class="usage-ctx-body"><code>%s</code></pre>\n' \
          "$(esc "$js_ctx")"
        printf '</details>\n'
      fi
    fi

    printf '<div class="usage-method-row">\n'
    printf '  <span class="method %s">%s</span>\n' \
      "$(method_class "$verb")" "$(esc "$verb")"
    printf '  <pre class="usage-cmd"><code>%s</code></pre>\n' \
      "$(esc "$(curl_snippet "$verb" "$url" "$current_path" "$recon_dir" "$base_url")")"

    local body_422
    body_422="$(extract_422_body "$verb" "$url" "$recon_dir")"
    if [ -n "$body_422" ]; then
      printf '  <details class="usage-422">\n'
      printf '    <summary>raw 422 response</summary>\n'
      printf '    <pre class="usage-422-body"><code>%s</code></pre>\n' \
        "$(esc "$body_422")"
      printf '  </details>\n'
    fi

    printf '</div>\n'
  done < "$tmp"
  [ -n "$current_url" ] && printf '</div>\n'

  rm -f "$tmp"
}

# ============================================================
# template substitution — perl, so & and \ in values are safe
# ============================================================
substitute_template() {
  perl -e '
    use strict; use warnings;
    my @keys = qw(
      CSS SPA_WARN AUTH_NOTE USAGE_SECTION METHODS_TABLE PROBE_TABLE
      AUTH_LIST WRONG_METHOD_LIST FORBIDDEN_LIST SERVER_ERRORS_LIST
      SCHEMA_LIST CATCHALL
      BASE_URL FRAMEWORK GEN_TIME HOST RECON_DIR SCRIPT_NAME
      JS_COUNT PATH_COUNT API_COUNT UI_COUNT
      N_AUTH N_FORBID N_405 N_5XX N_JSON N_SPA N_VALIDM N_SCHEMA
    );
    local $/;
    my $tpl = <STDIN>;
    for my $k (@keys) {
      my $val = $ENV{"RPT_$k"};
      $val = "" unless defined $val;
      my $ph = "{{$k}}";
      my $i = 0;
      while (($i = index($tpl, $ph, $i)) >= 0) {
        $tpl = substr($tpl, 0, $i) . $val . substr($tpl, $i + length($ph));
        $i += length($val);
      }
    }
    print $tpl;
  '
}

# ============================================================
# entry point
# ============================================================
render_report() {
  local recon_dir="$1" out_html="$2" want_pdf="$3" want_open="$4"

  # Locate templates
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local tpl_dir=""
  for d in "${SPA_REPORT_TPL_DIR:-}" "$self_dir/templates" "$PWD/templates" "$PWD"; do
    if [ -n "$d" ] && [ -f "$d/report.html" ] && [ -f "$d/report.css" ]; then
      tpl_dir="$d"
      break
    fi
  done
  [ -n "$tpl_dir" ] || {
    printf 'templates not found: report.html + report.css\n' >&2
    printf 'looked in:\n  %s\n  %s/templates\n  %s/templates\n  %s\n' \
      "${SPA_REPORT_TPL_DIR:-<unset>}" "$self_dir" "$PWD" "$PWD" >&2
    exit 1
  }
  log "templates: $tpl_dir"

  # Gather scalar data
  local base_url framework gen_time hostname_
  base_url="$(grep -oP 'summary for \K.*' "$recon_dir/SUMMARY.txt" 2>/dev/null | head -1)"
  [ -z "$base_url" ] && base_url="(unknown)"
  framework="$(slurp "$recon_dir/framework.txt")"
  [ -z "$framework" ] && framework="unknown"
  gen_time="$(date -Iseconds)"
  hostname_="$(hostname)"

  # Build auth state before rendering
  build_auth_maps "$recon_dir" "$base_url"

  local js_count path_count api_count ui_count
  js_count=$(count_lines   "$recon_dir/js-urls.txt")
  path_count=$(count_lines "$recon_dir/paths.clean.txt")
  api_count=$(count_lines  "$recon_dir/api-paths.txt")
  ui_count=$(count_lines   "$recon_dir/ui-paths.txt")

  local n_auth n_forbid n_405 n_5xx n_json n_spa n_validm n_schema
  n_auth=$(count_lines     "$recon_dir/needs-auth.txt")
  n_forbid=$(count_lines   "$recon_dir/forbidden.txt")
  n_405=$(count_lines      "$recon_dir/wrong-method.txt")
  n_5xx=$(count_lines      "$recon_dir/server-errors.txt")
  n_json=$(count_lines     "$recon_dir/json-200.txt")
  n_spa=$(count_lines      "$recon_dir/spa-catchall.txt")
  n_validm=$(count_lines   "$recon_dir/methods-valid.tsv")
  n_schema=$(count_lines   "$recon_dir/schema-hits.txt")

  local catchall
  catchall="$(slurp "$recon_dir/logs/catchall-check.txt")"
  [ -z "$catchall" ] && catchall="(not run)"

  local spa_warn=""
  if grep -q 'html' <<< "$catchall"; then
    spa_warn='<div class="alert warn"><strong>SPA catch-all detected.</strong> Every path returning <code>200 text/html</code> is the SPA router serving <code>index.html</code>, not a real endpoint. Only JSON and non-200 responses indicate actual routes.</div>'
  fi

  local auth_note=""
  if [ -s "$recon_dir/needs-auth.txt" ] && [ ! -f "$recon_dir/probe-authed.tsv" ]; then
    auth_note='<div class="alert warn"><strong>Anonymous scan.</strong> Field chips below are inferred from the JS bundle or from the endpoint path. Re-run <code>spa-recon.sh</code> with <code>--token</code> or <code>--cookie</code> to capture the exact validation shapes from authenticated 422 responses.</div>'
  fi

  # Render dynamic blocks
  log "rendering report blocks"
  local usage_section methods_table probe_table
  local auth_list wrong_method_list forbidden_list server_errors_list schema_list

  usage_section="$(render_usage_section "$recon_dir" "$base_url")"
  methods_table="$(render_methods_table "$recon_dir/methods-valid.tsv")"
  probe_table="$(render_probe_table "$recon_dir")"
  auth_list="$(render_list "$recon_dir/needs-auth.txt")"
  wrong_method_list="$(render_list "$recon_dir/wrong-method.txt")"
  forbidden_list="$(render_list "$recon_dir/forbidden.txt")"
  server_errors_list="$(render_list "$recon_dir/server-errors.txt")"
  schema_list="$(render_list "$recon_dir/schema-hits.txt")"

  # Export for perl
  export RPT_SPA_WARN="$spa_warn"
  export RPT_AUTH_NOTE="$auth_note"
  export RPT_USAGE_SECTION="$usage_section"
  export RPT_METHODS_TABLE="$methods_table"
  export RPT_PROBE_TABLE="$probe_table"
  export RPT_AUTH_LIST="$auth_list"
  export RPT_WRONG_METHOD_LIST="$wrong_method_list"
  export RPT_FORBIDDEN_LIST="$forbidden_list"
  export RPT_SERVER_ERRORS_LIST="$server_errors_list"
  export RPT_SCHEMA_LIST="$schema_list"
  export RPT_CATCHALL="$(esc "$catchall")"
  export RPT_BASE_URL="$(esc "$base_url")"
  export RPT_FRAMEWORK="$(esc "$framework")"
  export RPT_GEN_TIME="$(esc "$gen_time")"
  export RPT_HOST="$(esc "$hostname_")"
  export RPT_RECON_DIR="$(esc "$recon_dir")"
  export RPT_SCRIPT_NAME="spa-report.sh"
  export RPT_JS_COUNT="$js_count"
  export RPT_PATH_COUNT="$path_count"
  export RPT_API_COUNT="$api_count"
  export RPT_UI_COUNT="$ui_count"
  export RPT_N_AUTH="$n_auth"
  export RPT_N_FORBID="$n_forbid"
  export RPT_N_405="$n_405"
  export RPT_N_5XX="$n_5xx"
  export RPT_N_JSON="$n_json"
  export RPT_N_SPA="$n_spa"
  export RPT_N_VALIDM="$n_validm"
  export RPT_N_SCHEMA="$n_schema"

  export RPT_CSS="$(< "$tpl_dir/report.css")"

  # Fill and write
  log "writing HTML report → $out_html"
  mkdir -p "$(dirname "$out_html")"
  substitute_template < "$tpl_dir/report.html" > "$out_html"
  ok "wrote: $out_html"

  # ---------- PDF ----------
  if [ "$want_pdf" = "1" ]; then
    local pdf="${out_html%.html}.pdf"
    local renderer=""
    for c in chromium chromium-browser google-chrome google-chrome-stable; do
      command -v "$c" >/dev/null 2>&1 && { renderer="$c"; break; }
    done

    if [ -n "$renderer" ]; then
      log "rendering PDF with $renderer"
      if "$renderer" --headless --disable-gpu --no-sandbox \
                     --no-pdf-header-footer \
                     --print-to-pdf-no-header \
                     --print-to-pdf="$pdf" \
                     "file://$(realpath "$out_html")" >/dev/null 2>&1; then
        ok "wrote: $pdf"
      else
        warn "PDF conversion failed"
      fi
    elif command -v wkhtmltopdf >/dev/null 2>&1; then
      log "rendering PDF with wkhtmltopdf"
      wkhtmltopdf --enable-local-file-access "$out_html" "$pdf" >/dev/null 2>&1 \
        && ok "wrote: $pdf" || warn "PDF conversion failed"
    elif command -v weasyprint >/dev/null 2>&1; then
      log "rendering PDF with weasyprint"
      weasyprint "$out_html" "$pdf" >/dev/null 2>&1 \
        && ok "wrote: $pdf" || warn "PDF conversion failed"
    else
      warn "no PDF renderer found — install chromium, wkhtmltopdf, or weasyprint"
    fi
  fi

  # ---------- open ----------
  if [ "$want_open" = "1" ]; then
    local target="$out_html"
    [ -f "${out_html%.html}.pdf" ] && target="${out_html%.html}.pdf"
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$target" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
      open "$target" >/dev/null 2>&1 &
    fi
  fi
}