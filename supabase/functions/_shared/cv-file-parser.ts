import DOMMatrixPolyfill from "npm:@thednp/dommatrix@2.0.12";
import { unzipSync } from "npm:fflate@0.8.3";

export class CvFileError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "CvFileError";
  }
}

const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_DOCX_XML_BYTES = 2 * 1024 * 1024;
const MAX_TEXT_CHARS = 100_000;
const MAX_PDF_PAGES = 40;

function normalizeText(value: string): string {
  return value
    .replace(/\u0000/g, " ")
    .replace(/[\u0001-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, " ")
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t]+/g, " ")
    .replace(/\n[ \t]+/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .slice(0, MAX_TEXT_CHARS)
    .trim();
}

function decodeXmlText(value: string): string {
  return value
    .replace(/&#x([0-9a-f]+);/gi, (_all, hex: string) => {
      const point = Number.parseInt(hex, 16);
      return point >= 0 && point <= 0x10ffff ? String.fromCodePoint(point) : " ";
    })
    .replace(/&#([0-9]+);/g, (_all, decimal: string) => {
      const point = Number.parseInt(decimal, 10);
      return point >= 0 && point <= 0x10ffff ? String.fromCodePoint(point) : " ";
    })
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function extractDocxText(bytes: Uint8Array): string {
  try {
    if (bytes[0] !== 0x50 || bytes[1] !== 0x4b) {
      throw new CvFileError("CV_FILE_TYPE_MISMATCH");
    }

    const files = unzipSync(bytes, {
      filter(file) {
        return file.name === "word/document.xml"
          && file.originalSize > 0
          && file.originalSize <= MAX_DOCX_XML_BYTES;
      },
    });
    const documentXml = files["word/document.xml"];
    if (!documentXml) throw new CvFileError("CV_INVALID_FILE");

    const xml = new TextDecoder("utf-8", { fatal: true }).decode(documentXml);
    const tokens = /<w:t\b[^>]*>([\s\S]*?)<\/w:t>|<w:tab\b[^>]*\/>|<w:br\b[^>]*\/>|<\/w:p>/g;
    let result = "";
    for (const match of xml.matchAll(tokens)) {
      if (match[1] !== undefined) result += decodeXmlText(match[1]);
      else if (match[0].startsWith("<w:tab")) result += "\t";
      else result += "\n";
      if (result.length >= MAX_TEXT_CHARS) break;
    }
    const text = normalizeText(result);
    if (!text) throw new CvFileError("CV_NO_TEXT_FOUND");
    return text;
  } catch (error) {
    if (error instanceof CvFileError) throw error;
    throw new CvFileError("CV_INVALID_FILE");
  }
}

async function extractPdfText(bytes: Uint8Array): Promise<string> {
  const header = new TextDecoder("latin1").decode(bytes.subarray(0, Math.min(bytes.length, 1024)));
  if (!header.includes("%PDF-")) throw new CvFileError("CV_FILE_TYPE_MISMATCH");

  const runtime = globalThis as typeof globalThis & { process?: unknown; DOMMatrix?: unknown };
  const hadProcess = "process" in runtime;
  const previousProcess = runtime.process;
  const previousPlatform = typeof navigator !== "undefined" ? navigator.platform : undefined;

  try {
    runtime.DOMMatrix ??= DOMMatrixPolyfill as unknown as typeof DOMMatrix;
    if (hadProcess) Object.defineProperty(runtime, "process", { value: undefined, configurable: true });
    if (typeof navigator !== "undefined" && previousPlatform !== "Linux") {
      try {
        Object.defineProperty(navigator, "platform", { value: "Linux", configurable: true });
      } catch {
        // The Edge runtime may expose a non-configurable navigator; PDF text parsing does not need this hint.
      }
    }

    const pdfjs = await import("npm:pdfjs-dist@5.4.149");
    pdfjs.GlobalWorkerOptions.workerSrc = import.meta.resolve("npm:pdfjs-dist@5.4.149/build/pdf.worker.mjs");
    const loadingTask = pdfjs.getDocument({
      data: bytes,
      isEvalSupported: false,
      useSystemFonts: false,
      stopAtErrors: true,
    });

    try {
      const document = await loadingTask.promise;
      if (document.numPages > MAX_PDF_PAGES) throw new CvFileError("CV_TOO_MANY_PAGES");
      let result = "";
      for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber++) {
        const page = await document.getPage(pageNumber);
        const content = await page.getTextContent();
        for (const item of content.items) {
          if ("str" in item && typeof item.str === "string") {
            result += item.str + ("hasEOL" in item && item.hasEOL ? "\n" : " ");
            if (result.length >= MAX_TEXT_CHARS) break;
          }
        }
        page.cleanup();
        if (result.length >= MAX_TEXT_CHARS) break;
      }
      const text = normalizeText(result);
      if (!text) throw new CvFileError("CV_NO_TEXT_FOUND");
      return text;
    } finally {
      await loadingTask.destroy();
    }
  } catch (error) {
    if (error instanceof CvFileError) throw error;
    throw new CvFileError("CV_INVALID_FILE");
  } finally {
    if (hadProcess) Object.defineProperty(runtime, "process", { value: previousProcess, configurable: true });
    if (typeof navigator !== "undefined" && previousPlatform !== undefined) {
      try {
        Object.defineProperty(navigator, "platform", { value: previousPlatform, configurable: true });
      } catch {
        // Ignore read-only navigator implementations.
      }
    }
  }
}

export async function extractCvText(bytes: Uint8Array, fileType: "pdf" | "docx"): Promise<string> {
  if (!(bytes instanceof Uint8Array) || bytes.length < 8) throw new CvFileError("CV_INVALID_FILE");
  if (bytes.length > MAX_FILE_BYTES) throw new CvFileError("CV_DOCUMENT_TOO_LARGE");
  if (fileType === "pdf") return await extractPdfText(bytes);
  if (fileType === "docx") return extractDocxText(bytes);
  throw new CvFileError("CV_FILE_TYPE_MISMATCH");
}
