# spa-recon

Endpoint enumeration and reporting for single-page applications.

Point it at a React, Vue, Angular, Svelte, Next.js, or Nuxt app. It crawls
with a headless browser, pulls the JS bundle, extracts every path the
frontend knows about, probes each one, and produces a self-contained
HTML/PDF report with copy-pasteable curl commands and per-endpoint test
playbooks.

## Install

```bash
git clone https://github.com/<you>/spa-recon.git
cd spa-recon
./install.sh
```

Or manually:

```bash
make install              # → ~/.local/bin/spa-recon, spa-report
make install PREFIX=/usr/local
```

### Dependencies

Runtime:
- `bash` 4.0+
- `curl`, `jq`, `grep`, `sed`, `awk`, `comm`

Go tools (installed automatically if missing from `PATH`):
- [katana](https://github.com/projectdiscovery/katana) — headless crawler
- [jsluice](https://github.com/BishopFox/jsluice) — JS path extractor

Install them once:

```bash
go install github.com/projectdiscovery/katana/cmd/katana@latest
go install github.com/BishopFox/jsluice/cmd/jsluice@latest
```

PDF output requires one of: `chromium`, `wkhtmltopdf`, or `weasyprint`.

## Quick start

```bash
spa-recon http://127.0.0.1/ ./recon --report --pdf --open
```

That produces `./recon/report.html` (and `.pdf`), plus raw artifacts.

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

## What the report contains

For every endpoint method the router accepts:

- **HOW TO TEST** — a playbook matched by path keyword (money path, auth flow, IDOR candidates, SSRF surface, file handling, admin boundary, etc.)
- **FIELDS** — required field names, sourced from the 422 body, the JS bundle, or a path heuristic (in that order)
- **curl** — copy-pasteable, with the correct content-type and body
- **frontend call** — the bundle snippet that issues the request
- **raw 422** — the server's own validation response

Plus summary tables: probed paths, accepted methods, auth-required, wrong-method, server errors, schema exposure.

## Layout

```
spa-recon/
├── spa-recon.sh         # scan entry point
├── spa-report.sh        # report entry point
├── lib/                 # sourced shell modules
│   ├── common.sh
│   ├── auth.sh
│   ├── fields.sh
│   ├── guides.sh
│   ├── render.sh
│   └── recon.sh
├── templates/
│   ├── report.html
│   └── report.css
├── Makefile
├── install.sh
└── README.md
```

## Development

```bash
make lint      # shellcheck
make fmt       # shfmt (requires shfmt)
make test      # lint + --help smoke tests
```

## License

MIT — see `LICENSE`.