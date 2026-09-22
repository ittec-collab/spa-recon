#!/usr/bin/env bash
# lib/guides.sh — keyword-driven per-endpoint testing guides
#
# Paths are matched by substring, not by exact path, so any app's
# /api/v2/payments matches the money-path guide, /v3/users matches
# the collection guide, and so on.

[ -n "${_SPA_GUIDES_LOADED:-}" ] && return 0
readonly _SPA_GUIDES_LOADED=1

endpoint_guide() {
  local path="$1"
  local low
  low="$(printf '%s' "$path" | tr 'A-Z' 'a-z')"

  # ---------- public form ----------
  if [[ "$low" =~ (contact|feedback|inquiry|complaint|report-abuse|report-bug|submit) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — public form</div>
  <ul>
    <li>Rate limit: 20 rapid posts from one IP. <span class="finding">Finding if all 200</span></li>
    <li>Stored XSS: inject <code>&lt;img src=x onerror=alert(1)&gt;</code> in every text field; view where staff reads it.</li>
    <li>Blind OOB: <code>dalfox scan "URL" -d '{...FUZZ...}' --blind-oob</code></li>
    <li>Email header injection: <code>\r\nBcc: x@y.com</code> in <code>email</code> / <code>subject</code>.</li>
    <li>Size: 10 MB body — reject or crash?</li>
    <li>Client-supplied metadata: is IP / user-agent stored and later trusted?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- websocket ----------
  if [[ "$low" =~ (^|/)(ws|websocket|socket)(/|$) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — WebSocket</div>
  <ul>
    <li>Unauth connect: <code>websocat ws://HOST/path</code> — accepted? <span class="finding">Finding if yes</span></li>
    <li>Subscribe to admin channel: <code>{"action":"subscribe","channel":"admin"}</code>.</li>
    <li>Token in query: <code>?token=...</code> — validated?</li>
    <li>Message size: huge payloads — crash or reject?</li>
    <li>CSRF: does an attacker page with <code>new WebSocket()</code> inherit your cookies?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- money path ----------
  if [[ "$low" =~ (order|checkout|payment|wallet|transaction|balance|credit|charge|refund|billing|invoice|subscription|plan|package|price|cart|coupon|voucher|discount|redeem) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — money path</div>
  <ul>
    <li>Negative quantity: <code>{"quantity":-1}</code> — does the balance go up?</li>
    <li>Zero quantity: <code>{"quantity":0}</code> — free order?</li>
    <li>Price tampering: <code>{"price":0.01}</code>, <code>{"amount":0}</code> — client-supplied cost trusted?</li>
    <li>Float abuse: <code>{"quantity":1.000001}</code>, <code>{"quantity":1e10}</code>.</li>
    <li>IDOR: swap any ID in path or body for another user's.</li>
    <li>Replay: send the same order twice — double-charge or double-credit?</li>
    <li>Coupon abuse: stack codes, reuse expired, apply your own to another user.</li>
    <li>Catalog leak: hidden/soft-deleted entries, internal SKUs, cost prices.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- admin boundary ----------
  if [[ "$low" =~ (^|/)(admin|manage|management|role|permission|staff|internal|superuser)(/|$) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — admin boundary</div>
  <ul>
    <li>Role gate: hit as a regular user — 403 expected. <span class="finding">Finding if 200</span></li>
    <li>Hidden data: if 200, look for other users' records in the response.</li>
    <li>Mass assign: can a normal user set <code>role</code> / <code>is_admin</code> elsewhere and land here?</li>
    <li>Debug paths: <code>/admin/debug</code>, <code>/admin/metrics</code>, <code>/admin/env</code>.</li>
    <li>Forced browsing: guess sibling admin routes from the JS bundle.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- file upload ----------
  if [[ "$low" =~ (upload|attachment|media|avatar|photo|/files?(/|$)) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — file handling</div>
  <ul>
    <li>Content-type bypass: upload <code>.php</code> as <code>image/png</code>.</li>
    <li>Double extension: <code>shell.php.png</code>, <code>shell.png.php</code>.</li>
    <li>Path traversal: filename <code>../../etc/passwd</code>.</li>
    <li>Size: 100 MB — reject or crash?</li>
    <li>Metadata: SVG with embedded JS, EXIF with payload.</li>
    <li>Retrieval: is the file served back with the original MIME or <code>text/html</code>?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- ssrf ----------
  if [[ "$low" =~ (webhook|callback|hook|notify|proxy|fetch|import) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — URL handler (SSRF)</div>
  <ul>
    <li>Internal probe: <code>http://169.254.169.254/</code>, <code>http://127.0.0.1:22/</code>.</li>
    <li>DNS callback: <code>http://your-collaborator/</code> — see who dials out.</li>
    <li>Scheme tricks: <code>file://</code>, <code>gopher://</code>, <code>dict://</code>.</li>
    <li>Redirect follow: does the server follow 302 to internal?</li>
    <li>Host bypass: <code>http://attacker.com@127.0.0.1/</code>, <code>http://127.0.0.1.nip.io/</code>.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- export ----------
  if [[ "$low" =~ (export|download|backup|dump|report|csv|pdf$|xlsx) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — export</div>
  <ul>
    <li>Scope: does the export respect user boundaries, or return all records?</li>
    <li>Format switch: <code>?format=json</code>, <code>?format=csv</code> — different data?</li>
    <li>Parameter injection: <code>?columns=password_hash</code>, <code>?include=all</code>.</li>
    <li>Path traversal: <code>?file=../../etc/passwd</code>.</li>
    <li>Auth bypass: request without a token.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- second factor ----------
  if [[ "$low" =~ (totp|2fa|mfa|otp|one-time|verify-code|recovery-code) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — second factor</div>
  <ul>
    <li>Rate limit: loop 100 codes (<code>000000</code>..<code>000099</code>); 429 expected. <span class="finding">Finding if none</span></li>
    <li>Time window: is a code accepted after 30s / 60s?</li>
    <li>Replay: same code twice in a row?</li>
    <li>Setup replay: call setup twice — are both secrets valid?</li>
    <li>Recovery codes: regenerate invalidates old ones?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- password flow ----------
  if [[ "$low" =~ (password|forgot|reset|recover) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — password flow</div>
  <ul>
    <li>Enumeration: same request for a registered vs. unregistered identity — identical response? <span class="finding">Finding if different</span></li>
    <li>Token entropy: trigger 5 resets, compare tokens received.</li>
    <li>Token reuse: complete a reset, replay the same token.</li>
    <li>Token binding: does the token work for a different user?</li>
    <li>Old-password: does change succeed without <code>old_password</code>? <span class="finding">Finding if yes</span></li>
    <li>Host header injection: <code>Host: attacker.com</code> — does the reset link point there?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- login ----------
  if [[ "$low" =~ (^|/)(login|signin|sign-in|authenticate|auth/token|oauth/token)(/|$) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — authentication entry</div>
  <ul>
    <li>Rate limit: loop 30 wrong-password requests, watch for 429. <span class="finding">Finding if all 401</span></li>
    <li>User enum: same request for a real user vs. random — compare status, message, timing.</li>
    <li>Policy: try <code>a</code>, <code>password</code>, a known-breached value.</li>
    <li>Malformed input: <code>username[]=x</code>, <code>null</code>, oversized fields.</li>
    <li>Response shape: token in body, in cookie, or both? Capture it — later tests need it.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- register ----------
  if [[ "$low" =~ (register|signup|sign-up|create-account|enroll) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — registration</div>
  <ul>
    <li>Enumerate: register an existing identity, then a fresh one — compare responses.</li>
    <li>Policy: send <code>password=a</code> then <code>password=12345678</code> — read the rules.</li>
    <li>Mass assignment: add <code>is_admin:true</code>, <code>role:"admin"</code>, <code>verified:true</code>.</li>
    <li>Rate limit: 20 rapid registrations from one IP.</li>
    <li>Verification bypass: can you log in before verifying the email?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- session management ----------
  if [[ "$low" =~ (logout|refresh|session|revoke) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — session management</div>
  <ul>
    <li>Logout invalidation: call it, then re-use the same token. <span class="finding">Finding if still 200</span></li>
    <li>Refresh rotation: call refresh, then again with the same token. <span class="finding">Finding if both succeed</span></li>
    <li>Refresh reuse after logout: refresh → logout → refresh with same token.</li>
    <li>Alg confusion: if the token is a JWT, try <code>alg:none</code> and RS→HS.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- search / filter ----------
  if [[ "$low" =~ (search|query|filter|lookup|find|suggest|autocomplete) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — query / filter</div>
  <ul>
    <li>SQLi: <code>' OR 1=1--</code>, <code>' UNION SELECT NULL--</code>, <code>1 AND SLEEP(5)--</code>.</li>
    <li>NoSQLi: <code>{"$ne":null}</code>, <code>{"$gt":""}</code>.</li>
    <li>Boolean blind: <code>?q=test' AND 1=1--</code> vs <code>?q=test' AND 1=2--</code> — different lengths?</li>
    <li>Wildcard DoS: <code>?q=*</code>, <code>?q=%</code> — expensive query?</li>
    <li>Reflection: does the term appear unescaped in the response?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- job trigger ----------
  if [[ "$low" =~ (generate|build|render|job|task|run|execute|deploy|queue|schedule) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — job trigger</div>
  <ul>
    <li>Cost: does one call consume tokens / credits / quota? Note the wallet before/after.</li>
    <li>Rate limit: 20 parallel calls — is there a cap?</li>
    <li>Auth bypass: call without a token; call with an expired one.</li>
    <li>Input injection: strings that flow into a code generator or shell — try <code>"; id"</code>, <code>"../../etc/passwd"</code>, <code>"$(id)"</code>.</li>
    <li>Idempotency: does the same request trigger twice?</li>
    <li>SSRF: does any URL in the body cause a server-side fetch?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- user-owned resource ----------
  if [[ "$low" =~ (project|workspace|board|task|card|document|folder) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — user-owned resource</div>
  <ul>
    <li>IDOR read: <code>GET {path}/{id}</code> with an id you don't own. <span class="finding">Finding if 200</span></li>
    <li>IDOR update: same PATCH / PUT with a foreign id.</li>
    <li>Enumerate: ids 1..100 in a loop — any 200s that aren't yours?</li>
    <li>Mass assign: add <code>user_id</code>, <code>owner_id</code>, <code>team_id</code> to the create body.</li>
    <li>List scope: does <code>GET {path}</code> only return your own rows?</li>
    <li>Pagination: <code>?limit=-1</code>, <code>?offset=9999</code> — bulk leak?</li>
    <li>Query tampering: <code>?user_id=other</code>, <code>?filter[user_id]=other</code>.</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- user content ----------
  if [[ "$low" =~ (ticket|issue|post|comment|message|support|chat|note|review|thread) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — user content</div>
  <ul>
    <li>IDOR read: <code>GET {path}/{id}</code> with an id you don't own. <span class="finding">Finding if 200</span></li>
    <li>IDOR update: same PATCH with a foreign id.</li>
    <li>Enumerate: ids 1..100 in a loop — any 200s that aren't yours?</li>
    <li>Mass assign: add <code>user_id</code>, <code>owner_id</code>, <code>status</code> to the create body.</li>
    <li>Stored XSS: inject <code>&lt;img src=x onerror=alert(1)&gt;</code> in every text field; view where staff reads it.</li>
    <li>State: can a normal user flip a status only an admin should?</li>
    <li>Upload: does the create body accept an attachment URL from another user?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- current identity ----------
  if [[ "$low" =~ (/me(/|$)|profile|account|current-user|whoami|identity) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — current identity</div>
  <ul>
    <li>Field leak: read the response for hashes, internal IDs, <code>is_admin</code>, <code>role</code>, soft-delete flags, timestamps.</li>
    <li>PATCH mass-assign: <code>{"is_admin":true}</code>, <code>{"role":"admin"}</code>, <code>{"email":"admin@x.com"}</code>, <code>{"verified":true}</code>. <span class="finding">Finding if applied</span></li>
    <li>Identity swap: PATCH <code>id</code> or <code>user_id</code> — can you change who you are?</li>
    <li>Token validity after change: does the old token still resolve?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- collection ----------
  if [[ "$low" =~ (^|/)(users|list|all|index|feed|items|collection|records)(/|$) ]]; then
    cat <<'GUIDE'
<div class="usage-guide">
  <div class="usage-guide-title">How to test — collection</div>
  <ul>
    <li>Auth scope: does it only return records you should see?</li>
    <li>Pagination abuse: <code>?limit=99999</code>, <code>?offset=-1</code>, <code>?page=0</code>.</li>
    <li>Filter bypass: <code>?role=admin</code>, <code>?is_deleted=true</code>, <code>?user_id=other</code>.</li>
    <li>Sort injection: <code>?sort=password</code>, <code>?order=id DESC--</code>.</li>
    <li>Field leak: read the response for fields not shown in the UI.</li>
    <li>Enumerate: loop ids 1..N — any 200s that aren't yours?</li>
  </ul>
</div>
GUIDE
    return
  fi

  # ---------- generic fallback ----------
  local recon_dir="$2"
  local base_url="$3"
  local verbs=""
  if [ -n "$recon_dir" ] && [ -n "$base_url" ] && [ -s "$recon_dir/methods-valid.tsv" ]; then
    verbs="$(awk -F'\t' -v u="$base_url$path" '$3 == u { print $1 }' \
      "$recon_dir/methods-valid.tsv" 2>/dev/null \
      | sort -u | tr '\n' ' ' | sed 's/ $//')"
  fi

  cat <<GUIDE
<div class="usage-guide">
  <div class="usage-guide-title">How to test</div>
  <ul>
    <li>Methods accepted here: <code>${verbs:-GET}</code>.</li>
    <li>Auth boundary: call with no token, an expired token, a token from another user.</li>
    <li>IDOR: if the path contains an ID, swap it for one you don't own.</li>
    <li>Mass assignment: add <code>id</code>, <code>user_id</code>, <code>role</code>, <code>is_admin</code>, <code>created_at</code> to the body.</li>
    <li>Info leak: read the response and error messages for hashes, paths, internal IDs, stack traces.</li>
    <li>Rate limit: rapid-fire 30 requests, check for 429.</li>
    <li>Injection: any string parameter is a candidate for SQLi / SSTI / command injection.</li>
    <li>Content-type confusion: try <code>application/xml</code>, <code>application/x-www-form-urlencoded</code>.</li>
  </ul>
</div>
GUIDE
}