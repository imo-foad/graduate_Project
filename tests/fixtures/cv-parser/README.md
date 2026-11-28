# CV parser evaluation corpus (synthetic)

`corpus.v1.json` is the versioned ground truth for the local CV parser benchmark
(`scripts/evaluate-cv-parser-local.mjs`). It is **entirely synthetic**.

## Why this directory exists

Issue #24 requires measured extraction quality rather than a printout that looks green. This corpus
gives every scenario explicit expected fields — skills, work experience, certifications, courses —
and, for negative fixtures, fields that must **not** be extracted. It also carries regression fixtures
for the two observed failures:

- `ar-docx-attached-skills-v1`: Arabic DOCX where the conjunction `و` is attached directly to Latin
  skill names (`وSQL`, `وKotlin`). It must extract SQL and Kotlin.
- `en-pdf-merged-header-v1` / `en-pdf-two-column-sidebar-v1`: PDF layouts where employer and job title
  are separate visual columns, plus a real sidebar. Employer and title must not be merged or swapped.

## No real personal data

Every name, employer, certificate and date is invented for this repository. No content was copied
from a real CV, a user upload, a recruitment document or a third-party dataset. There are no names of
real people, no contact details, no national identifiers and no photographs. Documents are not stored
as binaries: `scripts/cv-fixture-generator.mjs` builds each PDF/DOCX deterministically from the
declarative `content` blocks, so the repository holds text and coordinates only.

## Layout of a scenario

| Field | Meaning |
|---|---|
| `id` | Stable fixture id. Versioned by the corpus file name (`corpus.v1.json`). |
| `format` | `pdf` (positioned Latin text) or `docx` (real ZIP with paragraphs, bullets, tables). |
| `language` | `en`, `ar` or `ar-en` (mixed). |
| `layout` | `single-column`, `two-column`, `table`, `bullets`, `negative`, … |
| `content` | Declarative blocks: `line`, `line` with `\t` for a right-hand column, `columns`, `table`, `bullet`, `heading`. |
| `expected` | Ground truth: `skills` (dictionary ids), `experiences`, `certifications`, `courses`. |
| `must_not_extract` | Known false positives that must not appear (negative controls). |

PDF fixtures may only contain ASCII because they use the standard Helvetica font. Arabic and mixed
documents are DOCX fixtures, which carry real Unicode text.

## How it is evaluated

`scripts/evaluate-cv-parser-local.mjs` asserts the corpus is structurally valid (unique ids, ≥10
scenarios, at least one negative fixture, no empty expectation sets), generates each document, and
uploads it to the disposable local Supabase stack. Documents go through the real `parse-cv` Edge
Function and the persisted `cv_suggestions` rows are compared field by field. Ground truth is never
adjusted from parser output.

The evaluator reports true positives, false positives, false negatives, precision, recall and F1 per
field category, per fixture and in aggregate, and fails when a gate is missed:

| Field | Minimum precision | Minimum recall |
|---|---:|---:|
| Skills | 95% | 95% |
| Experience fields | 90% | 90% |
| Certification fields | 95% | 95% |
| Course fields | 95% | 95% |

**Limitation:** a curated synthetic corpus is not a representative real-CV corpus. Passing these gates
does not establish accuracy on real-world CVs. Issue #24 stays open until an owner-approved, consented
and anonymized corpus is supplied and evaluated. OCR for scanned/image-only PDFs remains out of scope.

## Additional regression coverage

The current main baseline passes the original Arabic attached-skill and two-column sidebar fixtures.
This extension adds Arabic month names with Arabic-Indic digits, `YYYY-MM` dates, alternate
Arabic/English headings, and an ambiguous employer/title negative control. Ambiguous two-part headers
without a recognized role token are intentionally left unassigned.

A second positioned PDF regression now separates the role and employer into opposite columns on the same baseline. The layout reconstruction pairs them only when the left fragment resembles a known role and the right fragment carries a conservative organization marker; ordinary sidebar skill labels remain in the sidebar stream.
