# reflowtext-fixtures

Showcase documents for [ReflowText](https://reflowtext.com): one folder per file type, at most five files each.

Every file here was written for this repository. The companies, products, people and places in them are fictional: Meridian Payments (a settlement platform), Halcyon Instruments (a synthesizer maker), Kestrel Ridge Observatory, Glen Aster Park and others. Any resemblance to real organisations is unintended. Public facts such as currency codes, country names and star names are used as facts.

Released under [CC0 1.0](LICENSE): use them for anything, no attribution needed.

## Documents

### `md/` — Markdown
| File | What it shows |
|---|---|
| `meridian-01-architecture.md` | Platform architecture: a layered Mermaid diagram, large tables, callouts |
| `meridian-02-request-flow.md` | Request flow: a sequence diagram, a state diagram, tables |
| `meridian-03-data-model.md` | Data model: an ER diagram, a pie chart, a Gantt chart, tables |
| `mermaid-showcase.md` | Twelve kinds of Mermaid diagram, all about one synthesizer |
| `inline-svg-showcase.md` | Ten inline SVG graphics inside Markdown |

### `mdx/` — MDX
| File | What it shows |
|---|---|
| `all-components-tour.mdx` | A launch-readiness page: alerts, callouts, tabs, accordion, steps, findings, data table, charts |
| `architecture-findings.mdx` | An architecture review: a metric, a filterable findings table, a chart |
| `charts.mdx` | Bar, line and pie charts drawn from Markdown tables |
| `json-explorer.mdx` | A configuration reference with explorable JSON |
| `file-tree.mdx` | Project layouts in three file-tree styles |

The `reflow:` frontmatter key opts a file into ReflowText's MDX components.

### `html/` — HTML
`analytics-dashboard.html`, `charts-gallery.html`, `documentation.html`, `invoice-report.html`, `landing-page.html`: five self-contained, designed pages.

### `pdf/` — PDF
| File | What it shows |
|---|---|
| `research-paper.pdf` | 8-page two-column paper: equations, SVG figures, tables, proofs, references |
| `annual-report.pdf` | 46 landscape pages: chapter openers, charts, pull quotes, financial statements |
| `multilingual-charter.pdf` | One short charter in 12 languages: right-to-left Arabic and Hebrew, vertical Japanese |
| `scanned-field-notes.pdf` | A 5-page photocopy-style scan with handwriting and stamps, no text layer |
| `design-spec-sheet.pdf` | A synthesizer datasheet: product drawing, spec grid, block diagram, dimensions |

## Structured data

### `json/` — JSON
| File | What it shows |
|---|---|
| `meridian-settlement.openapi.json` | OpenAPI 3.1: 22 paths, webhooks, 70+ schemas, discriminated `oneOf` |
| `halcyon-patch.schema.json` | JSON Schema 2020-12: 30 `$defs`, recursion, conditionals |
| `tidewater-design-tokens.json` | Design tokens: colour ramps, light and dark roles, type, spacing, motion |
| `halcyon-patch-library.json` | Deep, wide data: banks of synth patches with nested modulation |
| `glen-aster-trails.geo.json` | GeoJSON trail network using every geometry type |

### `xml/` — XML
| File | What it shows |
|---|---|
| `halcyon-field-notes-drift.xml` | A long-form essay: sections, notes, tables, CDATA listings, entities |
| `kestrel-observing-log.xml` | 185 uniform records, made for a grid; validates against `xsd/kestrel-observing-log.xsd` |
| `meridian-ledger-node.config.xml` | A commented configuration with three namespaces |
| `meridian-settlement-batch.xml` | A settlement batch; validates against `xsd/meridian-settlement.xsd` |
| `orders.xml` | An order book; validates against `xsd/orders.xsd` |

### `xsd/` — XML Schema
| File | What it shows |
|---|---|
| `meridian-settlement.xsd` | Extension, restriction, substitution groups, key/keyref |
| `halcyon-instrument.xsd` | Unions, lists, mixed content, `xs:all`, wildcards, recursion |
| `kestrel-observing-log.xsd` + `kestrel-common.xsd` | A schema pair joined by `xs:include` |
| `orders.xsd` | Sequence, choice and all; facets; key/keyref |

## Code and text

Two files per type, each a small, complete piece of work:

| Folder | Files |
|---|---|
| `c/` | `ring_buffer.c`, `oscillator.c` |
| `cpp/` | `fixed_point.hpp`, `settlement_batcher.cpp` |
| `csharp/` | `SettlementReport.cs`, `IntervalTree.cs` |
| `css/` | `harbor-theme.css`, `synth-panel.css` |
| `csv/` | `meridian-payouts.csv`, `tern-patch-bank.csv` |
| `go/` | `pipeline.go`, `route.go` |
| `ini/` | `settlement-service.ini`, `tern-editor.cfg` |
| `java/` | `PaymentStateMachine.java`, `DuplicateGuard.java` |
| `javascript/` | `money.mjs`, `scope-animation.js` |
| `jsonl/` | `payment-events.jsonl`, `support-conversations.jsonl` |
| `kotlin/` | `PatchSync.kt`, `RiskRules.kt` |
| `log/` | `settlement-service.log`, `access.log` |
| `php/` | `SettlementBatchService.php`, `instrument-catalogue.view.php` |
| `python/` | `patch_model.py`, `reconcile_cli.py` |
| `ruby/` | `sequencer_dsl.rb`, `Rakefile.rb` |
| `rust/` | `wire_record.rs`, `payout_service.rs` |
| `shell/` | `deploy-ledger.sh`, `logslice.sh` |
| `sql/` | `settlement_schema.sql`, `0042_split_payout_attempts.sql` |
| `swift/` | `PatchBrowserView.swift`, `RateLimiter.swift` |
| `text/` | `the-tuner-of-lantern-street.txt`, `tidewater-8-release-notes.txt` |
| `toml/` | `settlement-worker.toml`, `Cargo.toml` |
| `typescript/` | `state-machine.ts`, `dom-kit.ts` |
| `yaml/` | `settlement-worker.k8s.yaml`, `firmware-pipeline.yaml` |

Network addresses use the documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and domains use `example.com`. Secrets are the placeholder `REPLACE_ME`.
