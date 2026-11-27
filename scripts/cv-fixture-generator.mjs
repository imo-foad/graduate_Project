// Deterministic generator for the synthetic CV parser corpus (issue #24).
//
// Everything here is invented. The corpus contains no real personal data, no downloaded CV and no
// external service call: a document is built from a scenario's declarative blocks at evaluation time.
// PDF fixtures are positioned text runs (so multi-column layouts are real, not pre-flattened text);
// DOCX fixtures are real ZIP packages with paragraphs, bullets and tables.

const PAGE_WIDTH = 612;
const PAGE_HEIGHT = 792;

function escapePdfText(value) {
  return value.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function makeZip(entries) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const [name, value] of entries) {
    const nameBytes = Buffer.from(name, "utf8");
    const data = Buffer.from(value, "utf8");
    const crc = crc32(data);
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(0, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(0, 12);
    localHeader.writeUInt32LE(crc, 14);
    localHeader.writeUInt32LE(data.length, 18);
    localHeader.writeUInt32LE(data.length, 22);
    localHeader.writeUInt16LE(nameBytes.length, 26);
    localHeader.writeUInt16LE(0, 28);
    local.push(localHeader, nameBytes, data);
    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0, 8);
    centralHeader.writeUInt16LE(0, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(0, 14);
    centralHeader.writeUInt32LE(crc, 16);
    centralHeader.writeUInt32LE(data.length, 20);
    centralHeader.writeUInt32LE(data.length, 24);
    centralHeader.writeUInt16LE(nameBytes.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE(0, 38);
    centralHeader.writeUInt32LE(offset, 42);
    central.push(centralHeader, nameBytes);
    offset += localHeader.length + nameBytes.length + data.length;
  }
  const centralBytes = Buffer.concat(central);
  const centralOffset = offset;
  const localBytes = Buffer.concat(local);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(centralOffset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([localBytes, centralBytes, end]);
}

/** Convert declarative blocks into absolute PDF text runs: [{ y, x, text }]. */
function blocksToPdfRuns(blocks) {
  const runs = [];
  let y = 760;
  for (const block of blocks) {
    if (block.columns) {
      const left = block.columns.left ?? [];
      const right = block.columns.right ?? [];
      let leftY = y;
      let rightY = y;
      const rows = Math.max(left.length, right.length);
      for (let index = 0; index < rows; index++) {
        if (left[index] !== undefined) {
          runs.push({ x: 50, y: leftY, text: left[index] });
          leftY -= 16;
        }
        if (right[index] !== undefined) {
          runs.push({ x: 330, y: rightY, text: right[index] });
          rightY -= 16;
        }
      }
      y = Math.min(leftY, rightY) - 10;
      continue;
    }
    if (block.table) {
      for (const row of block.table) {
        row.forEach((cell, index) => runs.push({ x: 50 + index * 175, y, text: String(cell) }));
        y -= 16;
      }
      continue;
    }
    const line = String(block.line ?? "");
    if (line.includes("\t")) {
      const [left, ...rest] = line.split("\t");
      runs.push({ x: 50, y, text: left });
      runs.push({ x: 430, y, text: rest.join("\t") });
    } else {
      runs.push({ x: 50, y, text: line });
    }
    y -= 16;
  }
  return runs;
}

export function buildPdf(blocks) {
  const runs = blocksToPdfRuns(blocks);
  const nonAscii = runs.find((run) => /[^\x00-\x7F]/.test(run.text));
  if (nonAscii) {
    throw new Error("synthetic PDF fixtures use the standard Latin font; put non-ASCII text in a DOCX scenario");
  }
  // block y already uses PDF user space (origin bottom-left), decreasing per visual line.
  const commands = runs
    .map((run) => `BT\n/F1 11 Tf\n1 0 0 1 ${run.x} ${run.y} Tm\n(${escapePdfText(run.text)}) Tj\nET`)
    .join("\n");
  const stream = commands;
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    `3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PAGE_WIDTH} ${PAGE_HEIGHT}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n`,
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "5 0 obj\n<< /Length " + Buffer.byteLength(stream, "latin1") + " >>\nstream\n" + stream + "\nendstream\nendobj\n",
  ];
  let output = "%PDF-1.4\n% Synthetic CV parser evaluation fixture\n";
  const offsets = [0];
  for (const object of objects) {
    offsets.push(Buffer.byteLength(output, "latin1"));
    output += object;
  }
  const xref = Buffer.byteLength(output, "latin1");
  output += "xref\n0 6\n0000000000 65535 f \n";
  for (let index = 1; index < offsets.length; index++) {
    output += offsets[index].toString().padStart(10, "0") + " 00000 n \n";
  }
  output += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + xref + "\n%%EOF\n";
  return Buffer.from(output, "latin1");
}

function xmlEscape(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function paragraphXml(text, { bullet = false, style = null } = {}) {
  const properties = [];
  if (style) properties.push(`<w:pStyle w:val="${xmlEscape(style)}"/>`);
  if (bullet) properties.push('<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>');
  const pPr = properties.length > 0 ? `<w:pPr>${properties.join("")}</w:pPr>` : "";
  const visible = bullet ? "• " + text : text;
  return `<w:p>${pPr}<w:r><w:t xml:space="preserve">${xmlEscape(visible)}</w:t></w:r></w:p>`;
}

function tableXml(rows) {
  const body = rows.map((row) => "<w:tr>" + row.map((cell) =>
    `<w:tc><w:tcPr><w:tcW w:w="2400" w:type="dxa"/></w:tcPr>${paragraphXml(String(cell))}</w:tc>`,
  ).join("") + "</w:tr>").join("");
  return `<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>${body}</w:tbl>`;
}

export function buildDocxWithDocumentXml(documentXml, extraEntries = []) {
  const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>';
  const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>';
  return makeZip([
    ["[Content_Types].xml", contentTypes],
    ["_rels/.rels", rels],
    ["word/document.xml", documentXml],
    ...extraEntries,
  ]);
}

export function buildDocx(blocks) {
  const body = blocks.map((block) => {
    if (block.table) return tableXml(block.table);
    if (block.bullet) return paragraphXml(String(block.line ?? ""), { bullet: true });
    if (block.heading) return paragraphXml(String(block.line ?? ""), { style: "Heading1" });
    return paragraphXml(String(block.line ?? ""));
  }).join("");
  const document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
    body + '<w:sectPr/></w:body></w:document>';
  return buildDocxWithDocumentXml(document);
}

export const DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
export const PDF_MIME = "application/pdf";

export function buildFixture(scenario) {
  if (scenario.format === "pdf") return { bytes: buildPdf(scenario.content), mime: PDF_MIME };
  if (scenario.format === "docx") return { bytes: buildDocx(scenario.content), mime: DOCX_MIME };
  throw new Error("unsupported fixture format: " + scenario.format);
}
