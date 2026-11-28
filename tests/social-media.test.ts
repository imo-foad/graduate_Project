// Pure-unit coverage for the social image validator used by the upload Edge Function.
// Real container headers are built byte by byte; no network, Storage or database is involved.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MAX_IMAGE_BYTES,
  MAX_IMAGE_DIMENSION,
  MAX_IMAGES_PER_POST,
  MAX_POST_MEDIA_BYTES,
  validatePostMediaBudget,
  validateSocialImage,
} from "../supabase/functions/_shared/social-media.ts";

function png(width: number, height: number, extra = 0): Uint8Array {
  const bytes = new Uint8Array(33 + extra);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  bytes.set([0, 0, 0, 13], 8);
  bytes.set([0x49, 0x48, 0x44, 0x52], 12);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  return bytes;
}

function jpeg(width: number, height: number): Uint8Array {
  // SOI, APP0 (length 16, payload), then SOF0 with the real dimensions.
  const bytes = new Uint8Array(2 + 18 + 19);
  bytes.set([0xff, 0xd8], 0);
  bytes.set([0xff, 0xe0, 0x00, 0x10], 2);
  bytes.set([0x4a, 0x46, 0x49, 0x46, 0x00], 6);
  let i = 20;
  bytes.set([0xff, 0xc0, 0x00, 0x11, 0x08], i);
  const view = new DataView(bytes.buffer);
  view.setUint16(i + 5, height);
  view.setUint16(i + 7, width);
  bytes.set([0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01], i + 9);
  return bytes;
}

function webpExtended(width: number, height: number): Uint8Array {
  const bytes = new Uint8Array(30);
  bytes.set([0x52, 0x49, 0x46, 0x46], 0);
  bytes.set([0x57, 0x45, 0x42, 0x50], 8);
  bytes.set([0x56, 0x50, 0x38, 0x58], 12);
  bytes.set([10, 0, 0, 0], 16);
  const store24 = (offset: number, value: number) => {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
    bytes[offset + 2] = (value >> 16) & 0xff;
  };
  store24(24, width - 1);
  store24(27, height - 1);
  return bytes;
}

test("accepts a real PNG signature and reads its dimensions", () => {
  const verdict = validateSocialImage(png(800, 600), "image/png");
  assert.deepEqual(verdict, { ok: true, mime: "image/png", extension: "png", width: 800, height: 600, size: 33 });
});

test("accepts a real JPEG signature and reads the SOF dimensions", () => {
  const verdict = validateSocialImage(jpeg(1920, 1080), "image/jpeg");
  assert.equal(verdict.ok, true);
  if (verdict.ok) {
    assert.equal(verdict.mime, "image/jpeg");
    assert.equal(verdict.width, 1920);
    assert.equal(verdict.height, 1080);
  }
});

test("accepts a real WebP signature and reads the VP8X dimensions", () => {
  const verdict = validateSocialImage(webpExtended(1024, 768), "image/webp");
  assert.equal(verdict.ok, true);
  if (verdict.ok) {
    assert.equal(verdict.mime, "image/webp");
    assert.equal(verdict.width, 1024);
    assert.equal(verdict.height, 768);
  }
});

test("rejects an empty byte stream", () => {
  assert.deepEqual(validateSocialImage(new Uint8Array(), "image/png"), { ok: false, error: "SOCIAL_MEDIA_INVALID" });
});

test("rejects a file whose declared MIME does not match its signature", () => {
  assert.deepEqual(validateSocialImage(png(10, 10), "image/jpeg"), { ok: false, error: "SOCIAL_MEDIA_INVALID" });
});

test("rejects SVG, HTML and executable payloads even when labelled as an image", () => {
  const svg = new TextEncoder().encode("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>");
  assert.equal(validateSocialImage(svg, "image/png").ok, false);
  const html = new TextEncoder().encode("<!doctype html><html></html>");
  assert.equal(validateSocialImage(html, "image/jpeg").ok, false);
  const elf = new Uint8Array([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0]);
  assert.equal(validateSocialImage(elf, "image/webp").ok, false);
});

test("rejects a truncated PNG that has no IHDR dimensions", () => {
  const truncated = png(10, 10).slice(0, 16);
  assert.deepEqual(validateSocialImage(truncated, "image/png"), { ok: false, error: "SOCIAL_MEDIA_INVALID" });
});

test("enforces the 5 MB per-image ceiling before sniffing", () => {
  const oversized = new Uint8Array(MAX_IMAGE_BYTES + 1);
  oversized.set(png(10, 10), 0);
  assert.deepEqual(validateSocialImage(oversized, "image/png"), { ok: false, error: "SOCIAL_MEDIA_TOO_LARGE" });
});

test("rejects excessive dimensions and the pixel budget", () => {
  assert.equal(validateSocialImage(png(MAX_IMAGE_DIMENSION + 1, 10), "image/png").ok, false);
  assert.equal(validateSocialImage(png(MAX_IMAGE_DIMENSION, MAX_IMAGE_DIMENSION), "image/png").ok, false);
});

test("a zero dimension is rejected", () => {
  assert.equal(validateSocialImage(png(0, 10), "image/png").ok, false);
});

test("post media budget caps image count and total bytes", () => {
  assert.deepEqual(validatePostMediaBudget(new Array(MAX_IMAGES_PER_POST).fill(1024)), { ok: true });
  assert.deepEqual(validatePostMediaBudget(new Array(MAX_IMAGES_PER_POST + 1).fill(1)),
    { ok: false, error: "SOCIAL_MEDIA_LIMIT_EXCEEDED" });
  assert.deepEqual(validatePostMediaBudget([MAX_POST_MEDIA_BYTES / 2, MAX_POST_MEDIA_BYTES / 2 + 1]),
    { ok: false, error: "SOCIAL_MEDIA_TOO_LARGE" });
});

test("ignores a null declared MIME but still validates the real container", () => {
  assert.equal(validateSocialImage(png(4, 4), null).ok, true);
  assert.equal(validateSocialImage(new TextEncoder().encode("not an image"), null).ok, false);
});
