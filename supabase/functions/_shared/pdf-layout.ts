// Layout-aware reconstruction of PDF text (issue #24).
//
// PDF.js returns text items in content-stream order with a transform matrix, not in reading order.
// Concatenating them flattens columns: an employer on the left and its job title on the right become
// one sentence, and a date can attach to the wrong entry. This module rebuilds visual lines from the
// item coordinates, separates visually distinct columns, and keeps a large horizontal gap inside one
// line as an explicit " | " boundary instead of a space.
//
// It is intentionally small and dependency-free. It does not attempt a general PDF layout engine:
// when a layout cannot be classified with confidence it keeps normal line order ("lower confidence"
// but transparent) rather than inventing structure.

export interface PdfTextItem {
  str: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface PdfLayoutOptions {
  /** Baseline distance (points) within which items belong to the same visual line. */
  lineTolerance?: number;
  /** Horizontal gap (points) treated as a column/segment boundary. */
  gapThreshold?: number;
}

interface Line {
  y: number;
  height: number;
  items: PdfTextItem[];
}

interface Segment {
  text: string;
  start: number;
  end: number;
}

function median(values: number[], fallback: number): number {
  if (values.length === 0) return fallback;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function groupLines(items: PdfTextItem[], tolerance: number): Line[] {
  const ordered = [...items]
    .filter((item) => item.str.trim() !== "" && Number.isFinite(item.x) && Number.isFinite(item.y))
    .sort((a, b) => (b.y - a.y) || (a.x - b.x));
  const lines: Line[] = [];
  for (const item of ordered) {
    const current = lines[lines.length - 1];
    if (current && Math.abs(current.y - item.y) <= tolerance) {
      current.items.push(item);
      current.height = Math.max(current.height, item.height);
    } else {
      lines.push({ y: item.y, height: item.height, items: [item] });
    }
  }
  for (const line of lines) line.items.sort((a, b) => a.x - b.x);
  return lines;
}

function joinItems(items: PdfTextItem[]): string {
  let text = "";
  let previousEnd: number | null = null;
  for (const item of items) {
    const value = item.str;
    if (!value) continue;
    if (
      text !== "" && previousEnd !== null &&
      item.x - previousEnd > 0.6 &&
      !/\s$/.test(text) && !/^\s/.test(value)
    ) {
      text += " ";
    }
    text += value;
    previousEnd = item.x + Math.max(0, item.width);
  }
  return text.replace(/[\t ]+/g, " ").trim();
}

function toSegments(line: Line, gapThreshold: number): Segment[] {
  const segments: Segment[] = [];
  let current: PdfTextItem[] = [];
  let currentStart = 0;
  let currentEnd = 0;
  const flush = () => {
    if (current.length === 0) return;
    const text = joinItems(current);
    if (text) segments.push({ text, start: currentStart, end: currentEnd });
    current = [];
  };
  for (const item of line.items) {
    const start = item.x;
    const end = item.x + Math.max(0, item.width);
    if (current.length > 0 && start - currentEnd > gapThreshold) {
      flush();
      currentStart = start;
    }
    if (current.length === 0) currentStart = start;
    current.push(item);
    currentEnd = Math.max(currentEnd, end);
  }
  flush();
  return segments;
}

/** Short right-aligned tokens (dates, durations) are metadata for the same entry, not a real column. */
function isInlineMetadata(text: string): boolean {
  if (text.length > 40) return false;
  if (/(?:19|20)\d{2}/.test(text)) return true;
  return /\b(?:present|current|now|ongoing)\b/i.test(text) ||
    /\b\d+\s*(?:days?|weeks?|months?|years?|hours?|hrs?)\b/i.test(text);
}

function detectColumnSplit(segmented: Segment[][], gapThreshold: number): number | null {
  const multi = segmented.filter((segments) => segments.length >= 2);
  if (multi.length < 3) return null;
  const candidates = new Set<number>();
  for (const segments of multi) {
    for (let index = 1; index < segments.length; index++) {
      const previous = segments[index - 1];
      const next = segments[index];
      if (next.start - previous.end > gapThreshold) {
        candidates.add(Math.round((previous.end + next.start) / 2));
      }
    }
  }
  let best: { split: number; lines: number } | null = null;
  for (const split of candidates) {
    let supported = 0;
    for (const segments of multi) {
      const left = segments.filter((segment) => segment.end <= split + 3);
      const right = segments.filter((segment) => segment.start >= split - 3);
      if (left.length > 0 && right.length > 0 && left.length + right.length === segments.length) supported++;
    }
    if (!best || supported > best.lines || (supported === best.lines && split < best.split)) {
      best = { split, lines: supported };
    }
  }
  if (!best) return null;
  if (best.lines < Math.max(3, Math.ceil(multi.length * 0.6))) return null;

  let rightSegments = 0;
  let metadataSegments = 0;
  for (const segments of multi) {
    for (const segment of segments) {
      if (segment.start < best.split - 3) continue;
      rightSegments++;
      if (isInlineMetadata(segment.text)) metadataSegments++;
    }
  }
  // A right-aligned date/status column belongs to the same entry line; splitting it out would detach
  // dates from their job titles. Keep those lines intact with " | " separators instead.
  if (rightSegments > 0 && metadataSegments / rightSegments >= 0.8) return null;
  return best.split;
}

const JOB_TITLE = /(?:^|[^\p{L}])(?:developer|engineer|analyst|designer|intern|manager|consultant|administrator|specialist|architect|lead|officer|technician|tester|qa|scientist|researcher|coordinator|accountant|teacher|مدير|مهندس|محلل|مصمم|متدرب|مطور|باحث|فني|محاسب|معلم)(?=$|[^\p{L}])/iu;
const ORGANIZATION_SUFFIX = /(?:\b(?:systems?|analytics|labs?|group|limited|ltd|inc|corp(?:oration)?|technologies|technology|studio|services|solutions|university|hospital|bank|agency|company)\b|^شركة\s|^مؤسسة\s|^جامعة\s)/i;

/** Pair cross-column employer/title fragments only when both sides carry strong lexical cues. */
function pairedExperienceHeader(left: string, right: string): boolean {
  return JOB_TITLE.test(left) && !left.includes("|") &&
    !JOB_TITLE.test(right) && ORGANIZATION_SUFFIX.test(right);
}

/**
 * Rebuild readable text from positioned PDF text items for one page.
 * Single-column pages keep line order; large intra-line gaps become " | ".
 * A stable two-column page is emitted column by column so entries are never merged.
 */
export function layoutPdfText(items: PdfTextItem[], options: PdfLayoutOptions = {}): string {
  const heights = items.map((item) => item.height).filter((height) => height > 0);
  const typicalHeight = median(heights, 10);
  const tolerance = options.lineTolerance ?? Math.max(1.5, Math.min(6, typicalHeight * 0.4));
  const gapThreshold = options.gapThreshold ?? Math.max(10, typicalHeight * 1.3);

  const lines = groupLines(items, tolerance);
  if (lines.length === 0) return "";
  const segmented = lines.map((line) => toSegments(line, gapThreshold));
  const split = detectColumnSplit(segmented, gapThreshold);

  if (split === null) {
    return segmented
      .map((segments) => segments.map((segment) => segment.text).join(" | "))
      .filter((line) => line !== "")
      .join("\n");
  }

  const columns: { left: string[]; right: string[] } = { left: [], right: [] };
  for (const segments of segmented) {
    if (segments.length === 0) continue;
    const left = segments.filter((segment) => segment.start < split - 3).map((segment) => segment.text);
    const right = segments.filter((segment) => segment.start >= split - 3).map((segment) => segment.text);
    if (left.length > 0 && right.length > 0 &&
        left.length === 1 && right.length === 1 && pairedExperienceHeader(left[0], right[0])) {
      // The two columns contain complementary fragments of one experience header. Keep the
      // combined header in the left-column reading stream and do not duplicate the employer.
      columns.left.push(left[0] + " | " + right[0]);
      continue;
    }
    if (left.length > 0) columns.left.push(left.join(" | "));
    if (right.length > 0) columns.right.push(right.join(" | "));
  }
  return [...columns.left, ...columns.right].filter((line) => line !== "").join("\n");
}
