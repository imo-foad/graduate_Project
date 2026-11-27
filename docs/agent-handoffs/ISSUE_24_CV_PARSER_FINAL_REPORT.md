# Issue #24 — CV extraction quality for Arabic DOCX and multi-column PDFs

**Status:** parser fixes are implemented and measured on a versioned synthetic corpus; the HTTP
evaluation suite could not be executed in this environment. Issue #24 must stay open: synthetic fixtures
are not evidence about real CVs, and a consented, anonymized corpus is still required.

- **Base:** `main` at `c44aaf4217f45d41b58b83cdd6618b71f5e34b7f`
- **Branch:** `fix/issue-24-cv-parser-quality`
- **Branch HEAD at report time:** `f5db8db` (this report commit follows it)
- **Pull request:** not created — this environment has no authenticated GitHub write API
- **CI:** https://github.com/imo-foad/graduate_Project/actions/runs/45955978804 (static job passed; the database and seed jobs failed during the disposable-stack steps, and their logs are not readable without repository-admin credentials)

## Initial defect

1. An Arabic DOCX fixture containing `وSQL` / `وKotlin` extracted neither skill.
2. A two-column PDF merged an employer cell into the job title
   (`job_title: "product analyst bright analytics"`), and multi-column/table layouts produced
   experience, certification and course false positives and misses.
3. Negative fixtures extracted placeholder headings as data: certifications `None`, `N/A`,
   `لا يوجد`, courses `لا توجد`, plus headings such as `المهارات` and echoed skill lines.

## Root cause

- **Arabic-attached Latin skills:** matching used a token boundary that rejected a Latin token preceded
  by an Arabic letter. `وSQL` is one whitespace-delimited token (`و` + `SQL`), so the boundary check never
  considered `SQL` a standalone candidate. The same applied to `ب`/`ل`/`ك` prefixes.
- **DOCX structure:** the DOCX reader concatenated every `<w:t>` run with a space and flattened
  `<w:tab/>`/paragraph/table boundaries into one line, so a table row (`employer | title | dates`) lost
  its cell separation and bullet items merged with headings.
- **PDF layout:** text was produced by joining PDF.js items in content-stream order. Two-column CVs
  therefore interleaved left/right columns, attaching the employer to the title and disconnecting dates
  from their entries.
- **Structured extraction:** section headings were matched with a narrow list, two-line experience
  headers were not joined, and placeholder values (`None`, `N/A`, `لا يوجد`, `لا توجد`) were accepted as
  entries.

## Changes implemented

| File | Change |
| --- | --- |
| `supabase/functions/_shared/pdf-layout.ts` | New layout-aware reconstruction: group items into visual lines by baseline, detect two-column documents from a stable x-gap, emit column-by-column reading order, preserve single-column order, and keep large intra-line gaps as field separators. |
| `supabase/functions/_shared/cv-file-parser.ts` | DOCX scanner now separates paragraphs, list items, tabs and table cells (with a DTD guard and bounded XML size); PDF path calls `layoutPdfText` instead of concatenating items. |
| `supabase/functions/_shared/cv-extract.ts` | `normalizeCvMatchText` (NFC/NFKC, diacritics, tatweel, Arabic punctuation, whitespace) used for matching only; `buildTermMatcher` accepts script-aware boundaries: a Latin term may start after an Arabic clitic letter but never inside a longer Latin token. Original text is preserved for suggestions. |
| `supabase/functions/_shared/cv-structured-extract.ts` | Broader AR/EN section headings, two-line experience headers, employer/title split on the layout separator, placeholder/negative filtering, and heading lines no longer become certifications/courses. |
| `scripts/cv-fixture-generator.mjs` | Deterministic PDF (single/two-column, positioned text runs) and DOCX (paragraphs, bullets, tables, raw `document.xml`) builders used by the corpus and tests. |
| `scripts/cv-parser-metrics.mjs` | Field-level scoring (`scoreScenario`/`aggregateScores`/`gateReport`), per-field TP/FP/FN/precision/recall/F1, failure categories, negative violations, corpus validation. |
| `tests/fixtures/cv-parser/corpus.v1.json` + `README.md` | 13 versioned synthetic scenarios with ground truth and a README describing generation and the absence of real personal data. |
| `scripts/evaluate-cv-parser-local.mjs` | Rewritten to run the corpus through the real local `parse-cv` HTTP function, assert suggestion counts/kinds and PENDING status, and fail on any quality gate, regression or negative violation. |
| `tests/integration/cv-parser-robustness.integration.mjs` | Malformed/empty/encrypted/oversized/41-page PDFs, bad ZIP/DOCX, DTD/XXE, type mismatch, foreign user, duplicate and concurrent parses, unicode, suggestion lifecycle. |
| Tests | `tests/pdf-layout.test.ts` (6), `tests/cv-parser-metrics.test.ts` (8), `tests/cv-extract.test.ts` (+4), `tests/cv-structured-extract.test.ts` (+5). |
| Docs/CI | README CV section, `docs/ANDROID_INTEGRATION.md`, workflow `node --check` entries, runner step, `tests/workflow_lint.py` corpus/gate assertions, baseline handoff. |

## New synthetic fixtures

13 scenarios (`corpus.v1`, 11 positive + 2 negative):

| ID | Format | Language | What it exercises |
| --- | --- | --- | --- |
| `en-pdf-single-column-v1` | PDF | en | single-column baseline |
| `ar-docx-attached-skills-v1` | DOCX | ar | `وSQL`, `وKotlin` attached-clitic skills |
| `en-pdf-merged-header-v1` | PDF | en | employer/title separated by a large gap |
| `en-pdf-two-column-sidebar-v1` | PDF | en | sidebar column, reading order |
| `en-docx-table-experience-v1` | DOCX | en | table cells, two experience rows |
| `en-pdf-alternate-headings-v1` | PDF | en | alternate section headings |
| `ar-docx-table-mixed-v1` | DOCX | ar-en | Arabic table + embedded Latin skills |
| `en-docx-bullets-v1` | DOCX | en | bullet lists |
| `en-pdf-current-and-numeric-dates-v1` | PDF | en | `Present`, numeric dates, two entries |
| `negative-en-pdf-v1` | PDF | en | `None`/`N/A` must not become data |
| `negative-ar-docx-v1` | DOCX | ar | `لا يوجد`/`لا توجد` must not become data |
| `mixed-docx-certifications-courses-v1` | DOCX | ar-en | certification + course sections |
| `en-pdf-multiple-entries-v1` | PDF | en | three experience entries |

No real CV content is included; every document is generated from short synthetic strings.

## Before/after precision and recall

Same corpus, same scoring module, same generator: `main` `c44aaf4` parser vs this branch. Measured by
executing the repository's TypeScript parser modules under Deno 2.9.8 (the modules themselves are
unchanged by the harness) and scoring every scenario.

| Field | Before TP/FP/FN | Before P / R / F1 | After TP/FP/FN | After P / R / F1 | Gate |
| --- | --- | --- | --- | --- | --- |
| Skills | 46 / 0 / 2 | 100.0% / 95.8% / 97.9% | 48 / 0 / 0 | 100.0% / 100.0% / 100.0% | 95/95 **PASSED** |
| Experience fields | 54 / 1 / 12 | 98.2% / 81.8% / 89.3% | 66 / 0 / 0 | 100.0% / 100.0% / 100.0% | 90/90 **PASSED** |
| Certification fields | 20 / 4 / 7 | 83.3% / 74.1% / 78.4% | 27 / 0 / 0 | 100.0% / 100.0% / 100.0% | 95/95 **PASSED** |
| Course fields | 29 / 6 / 6 | 82.9% / 82.9% / 82.9% | 35 / 0 / 0 | 100.0% / 100.0% / 100.0% | 95/95 **PASSED** |

Before, the gate report failed on experience recall, certification precision/recall and course
precision/recall. After, every field gate passes.

## Arabic regression result

`ar-docx-attached-skills-v1`: before, expected `SQL` and `Kotlin` were both missing
(`ARABIC SQL,KOTLIN false`); after, both are extracted (`ARABIC SQL,KOTLIN true`). The fix is a
script-aware boundary plus Arabic normalization, not a per-skill special case; `cv-extract.test.ts`
covers `وSQL`, `بKotlin`, Arabic diacritics/tatweel, Arabic punctuation, English-inside-Arabic text and
the negative case where a Latin skill is a substring of a longer token (e.g. `JavaScript` inside
`JavaScriptEngineer` must not match).

## Multi-column regression result

`en-pdf-merged-header-v1`: before, the fields were
`["company_name: bright analytics", "job_title: product analyst"]` expected but actual
`["job_title: product analyst bright analytics"]` (the employer was appended to the title). After, the
parser returns the two expected fields and no merged title; the harness reports
`MERGED HEADER FIELDS [] []`. `pdf-layout.test.ts` also covers single-column order preservation, a
number-only column not being mistaken for a text column, and gap-based field separation.

## Negative test results

Before: violations `certifications: None`, `courses: N/A`, `certifications: لا يوجد`,
`courses: لا توجد` (and heading lines leaked into courses). After: `NEGATIVE VIOLATIONS []`, both
negative fixtures produce zero suggestions, and heading-only lines are not emitted as entries.

## HTTP integration results

- `npm run evaluate:cv:local` (real gateway + Storage + `parse-cv`): **NOT RUN / BLOCKED_ENVIRONMENT** —
  this sandbox has no Docker daemon or Supabase CLI, so the local stack cannot start.
- `tests/integration/cv-parser-robustness.integration.mjs`: **NOT RUN** for the same reason; syntax
  checked and wired into `scripts/run-local-integrations.sh`.
- GitHub Actions database job: **FAILED** during the disposable-stack stage, before the HTTP suites, and
  its logs are not readable from here (**BLOCKED_ENVIRONMENT**).

The quality gates above were therefore measured through the parser modules and the corpus, not through
the HTTP function; the HTTP evaluator that enforces the same gates in CI is new but has not been observed
running.

## Full test results

| Command | Result |
| --- | --- |
| `npm test` | **PASSED** — 210 tests, 210 pass, 0 fail |
| `python3 -m unittest tests/contract_openapi.py` | **PASSED** — 24 tests |
| `python3 -m unittest tests/workflow_lint.py` | **PASSED** — 15 tests |
| Deno corpus harness (13 scenarios, same modules) | **PASSED** — 4/4 field gates, no negative violations, Arabic and merged-header regressions fixed |
| Node focused tests (`pdf-layout`, `cv-extract`, `cv-structured-extract`, `cv-parser-metrics`) | **PASSED** — 34 tests, 34 pass, 0 fail |
| Real PostgreSQL 17.12 + pgTAP 1.3.3 (18 files, 718 assertions) | **PASSED** — schema unchanged by this branch, re-verified on the same migration set |
| GitHub Actions | static **PASSED**; database and seed jobs **FAILED** in the disposable-stack steps |

## Failures discovered and fixed during this work

- Arabic clitic boundary hid Latin skills (fixed in `buildTermMatcher`).
- DOCX table cells and bullets collapsed into one line (fixed in the DOCX tokenizer).
- PDF content-stream order merged columns (fixed in `pdf-layout.ts`).
- Two-line experience headers and alternate headings were missed (fixed in structured extraction).
- Placeholder values and heading lines were emitted as certifications/courses (fixed).
- A metrics test initially compared arrays by reference; the assertion was corrected to a structural
  comparison (test bug, not a product change).
- `evaluate-cv-parser-local.mjs` previously deleted metadata directly with a service-role `DELETE`; the
  supported owner RPC `delete_cv_document` is now used, and `tests/seed.test.ts` asserts that cleanup
  uses the owner token instead of an unauthenticated service-role call.

## Tests not run and reasons

- HTTP parser evaluation and the robustness integration: no local Supabase stack (BLOCKED_ENVIRONMENT).
- CI database job: failed before the HTTP stage; logs unavailable (BLOCKED_ENVIRONMENT).
- Real-CV accuracy: no consented, anonymized corpus exists (OUT_OF_SCOPE / blocked on the owner).
- OCR: explicitly out of scope.

## Security review

- Parsing still requires an authenticated owner; `parse-cv` checks `auth.getUser()` and document
  ownership, and the robustness suite asserts a foreign user cannot parse another graduate's CV.
- No embedded content is executed, no external relationship/URL is fetched, the DOCX DTD/`DOCTYPE` guard
  remains, and page/XML/size limits are unchanged.
- Suggestions remain `PENDING` until the graduate confirms; confirmed skills still drive recommendation
  invalidation through the existing RPCs (unchanged).
- No CV text, extracted values, credentials or storage paths are logged by the new code.

## Remaining product/external limitations

- Accuracy evidence is synthetic only. The parser is **not** proven accurate on real-world CVs.
- OCR / scanned PDFs remain unsupported and must not be advertised.
- The HTTP evaluation gates have not been observed passing in CI or locally in this environment.
- Two structural PDFs (heavy graphics, tables spanning columns) may still be misread; the layout module
  is a targeted correction, not a general layout engine, and low-confidence output is preferred to
  confident wrong data where sections cannot be identified.

## Branch / PR / CI

- Branch: `fix/issue-24-cv-parser-quality`
- HEAD: `f5db8db` (report commit adds this file)
- PR: **not created** — compare URL:
  `https://github.com/imo-foad/graduate_Project/compare/main...fix/issue-24-cv-parser-quality`
- CI: https://github.com/imo-foad/graduate_Project/actions/runs/45955978804 — static **PASSED**,
  database and seed jobs **FAILED** (logs require admin access).

## Issue state recommendation

**Keep #24 open.** The deterministic parser defects are fixed and measured, but the issue's completion
gate requires evaluation on a representative, owner-approved, consented and anonymized real-CV corpus.
Synthetic fixtures do not satisfy that criterion.
