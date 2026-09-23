# spa-recon

**Endpoint enumeration and reporting toolkit for single-page applications.**

Point it at a React, Vue, Angular, Svelte, Next.js, or Nuxt app. It crawls
with a headless browser, pulls the JS bundle, extracts every path the
frontend knows about, probes each one, enumerates HTTP methods, captures
422 validation bodies, resolves required request fields from three
independent sources, and produces a self-contained HTML/PDF report with
copy-pasteable curl commands and per-endpoint test playbooks.

---

## Why spa-recon?

Existing tools solve parts of this problem. None solve all of it.

| Tool | Approach | What it misses |
| :--- | :--- | :--- |
| **JSRecon** | AST (esprima) + secrets + sourcemaps | No method enumeration, no 422 capture, no testing guides, no PDF |
| **Anastasis** | Passive sources + AST (tree-sitter) + params | Engine only — no crawl, no probe, no report |
| **jstangle** | Deobfuscation + AST (Vigolium engine) | Engine only — no crawl, no probe, no report |
| **apiscope** | Crawl + schema inference from JSON | No field extraction from 422, no method enum, no guides |
| **ShadowPath** | SPA crawl + subdomain enum | No AST parsing, no field extraction, no guides |
| **apicg** | JS extraction + spec harvesting | No 422 capture, no method enum, no guides |
| **Trident** | Full vulnerability scanner | Endpoint discovery is a side effect, not the core |

**spa-recon is the missing middle.** It is a complete pipeline, not an
engine. It does three things no other tool does:

### 1. 422 validation body capture → authoritative field names

Most tools guess request body fields from the JS bundle. spa-recon sends
an empty body (`-d '{}'`) to every write endpoint, reads the server's 422
validation response, and extracts the exact required field names. This
is the ground truth — the server itself is telling us what it wants.

```json
{
  "detail": [
    {"loc": ["body", "requester_user_id"], "msg": "Field required"},
    {"loc": ["body", "created_by_user_id"], "msg": "Field required"},
    {"loc": ["body", "subject"], "msg": "Field required"},
    {"loc": ["body", "description"], "msg": "Field required"}
  ]
}
```

### 2. Method enumeration on every write-capable endpoint

OPTIONS is usually blocked. spa-recon tries GET, POST, PUT, PATCH, and
DELETE on every endpoint that returned 401/403/405, and records which
methods the router actually accepts. The report shows the real method
matrix, not a guess.

### 3. Per-endpoint testing guides

No other tool generates testing guidance. spa-recon matches every
endpoint against 18 keyword patterns and emits a tailored playbook:

- `/api/v1/token-orders` → negative quantity, price tampering, replay
- `/auth/login` → rate limit, user enumeration, password policy
- `/api/v1/tickets` → IDOR, mass assignment, stored XSS
- `/auth/totp/verify` → rate-limit 6-digit codes, replay window
- `/webhooks` → SSRF via internal addresses, DNS callback

Each playbook includes copy-pasteable commands and marks what
constitutes a finding.

---

## Install

```bash
git clone https://github.com/ittec-collab/spa-recon
cd spa-recon
./install.sh
```

Or via Make:

```bash
make install              # → ~/.local/bin/spa-recon, spa-report
make install PREFIX=/usr/local
```

### Dependencies

Required:
- `bash` 4.0+
- `curl`, `jq`, `grep`, `sed`, `awk`, `comm`

Optional (installer detects and installs automatically):
- **Node.js 18+** → AST field resolver (`@babel/core` + `@babel/parser`)
- **Go 1.21+** → `katana` (headless crawler) + `jsluice` (JS path extractor)
- **chromium / wkhtmltopdf / weasyprint** → PDF output

If Node or Go is missing, the script still works with reduced accuracy —
it falls back to regex field extraction and HTML-only JS discovery.

---

## Quick start

```bash
spa-recon http://127.0.0.1/ ./recon --report --pdf --open
```

That produces:

```
./recon/
├── report.html           self-contained, dark theme, print-friendly
├── report.pdf            if a PDF renderer is available
├── SUMMARY.txt           one-page summary
├── probe.tsv             status + content-type per path
├── methods-valid.tsv     router-accepted method/path pairs
├── 422-bodies.txt        validation responses (authoritative fields)
├── needs-auth.txt        401 endpoints
├── wrong-method.txt      405 endpoints
├── schema-hits.txt       real OpenAPI/Swagger docs if any
├── js/                   downloaded JS bundles
└── logs/                 raw katana output + catch-all check
```

---

## Authenticated scan

```bash
# FastAPI form-encoded login
TOKEN=$(curl -s -X POST http://target/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'username=you@example.com' \
  --data-urlencode 'password=YourPass' | jq -r '.access_token')

spa-recon http://target/ ./recon-auth --token "$TOKEN" --report
```

Cookie sessions, Basic auth, and custom headers also supported:

```bash
spa-recon http://target/ --cookie "session=abc; csrf=xyz"
spa-recon http://target/ --basic "user:pass"
spa-recon http://target/ --header "X-Api-Key: deadbeef"
```

Or drop a `.spa-reconrc` next to your invocation and skip the flags:

```bash
cp .spa-reconrc.example .spa-reconrc
$EDITOR .spa-reconrc
spa-recon http://target/ ./recon
```

---

## How field extraction works

spa-recon uses a three-tier resolver. Each tier is tried in order and
the first non-empty result wins.

| Tier | Source | Reliability | Example |
| :--- | :--- | :--- | :--- |
| **1** | 422 validation body | Authoritative | Server says `requester_user_id`, `subject` |
| **2** | AST analysis of JS bundle | 85–95% | Bundle contains `Qb("POST", url, {name, db_driver})` |
| **3** | Path keyword heuristics | 60–70% | `/orders` → `package_id`, `quantity` |

### The AST resolver

The resolver detects HTTP calls by **pattern**, not by function name:

```javascript
// All of these are detected — regardless of wrapper name
Qb("POST",   "/api/v1/tickets", {subject, description})
ft("PATCH",  `/api/v1/tickets/${id}`, body)
Ba("POST",   "/api/v1/contact-messages", {name, email, subject, message})
fetch("/api/v1/x", {method: "POST", body: JSON.stringify({a, b})})
axios.post("/api/v1/x", {a, b})
```

Key correctness guarantees:

- **Boundary-aware URL matching** — `/api/v1/my-projects` will not match
  `/api/v1/my-projects/generate`
- **Scope-aware identifier resolution** — function parameters are never
  resolved against top-level bindings, even when a minifier reuses the
  same short name
- **Route-map rejection** — `{me: "/auth/me", wallet: "/api/wallet"}`
  is not treated as a request body
- **Local function chasing** — `JSON.stringify(buildPayload(x))` is
  resolved by walking into `buildPayload`
- **Spread handling** — `{...base, extra: 1}` merges both key sets

---

## What the report contains

For every endpoint method the router accepts:

- **HOW TO TEST** — a playbook matched by path keyword
- **FIELDS** — required field names with the verb they apply to
- **curl** — copy-pasteable, correct content-type and body
- **frontend call** — the bundle snippet that issues the request
- **raw 422** — the server's own validation response

Plus summary tables: probed paths, accepted methods, auth-required,
wrong-method, server errors, schema exposure.

---

## Layout

```
spa-recon/
├── spa-recon.sh         # scan entry point
├── spa-report.sh        # report entry point
├── lib/                 # sourced shell modules
│   ├── common.sh        # log, escape, css classes
│   ├── recon.sh         # crawl, probe, enumerate
│   ├── auth.sh          # per-(verb,path) auth map, form detection
│   ├── fields.sh        # three-tier field resolver
│   ├── guides.sh        # keyword-matched testing playbooks
│   ├── render.sh        # HTML templates + substitution
│   └── js-resolver.mjs  # AST resolver (Babel + createRequire)
├── templates/
│   ├── report.html      # {{placeholder}} skeleton
│   └── report.css       # styling
├── test/
│   └── resolver.test.mjs
├── Makefile
└── install.sh
```

---

## Development

```bash
make test       # node --test + --help smoke tests
make lint       # shellcheck
make fmt        # shfmt
make uninstall  # remove installed files
```

### Running the resolver standalone

```bash
node lib/js-resolver.mjs ./app.bundle.js "/api/v1/tickets"
```

Output is one field name per line, sorted and deduped.

---

## License

MIT — see `LICENSE`.