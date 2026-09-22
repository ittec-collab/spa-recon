# Changelog

## [2.1.0] — 2026-09-22

### Added
- Multi-file project layout (`lib/`, `templates/`)
- Data-driven auth map — per (verb, path), from scan artifacts
- Three-tier field resolver (422 / JS bundle / path heuristic)
- Keyword-driven endpoint guides (no hardcoded paths)
- Framework detection (Next.js, Nuxt, SvelteKit, React, Vue, Angular)
- `--cookie`, `--basic`, `--header` auth options
- `.spa-reconrc` config file support

### Fixed
- Route-map false positives in JS field extraction
- Auth header no longer applied to public methods on mixed-auth paths
- Contact-form endpoints get the public-form guide, not the user-content one

## [2.0.0]

- Renamed from single-script to `spa-recon` / `spa-report`
- External HTML/CSS templates

## [1.0.0]

- Initial release