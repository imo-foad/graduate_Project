// Image validation for Social Feed media. Pure functions only: no network, no Storage, no Deno APIs.
//
// The client-declared Content-Type is never trusted. The real container signature is read from the
// bytes and the dimensions are parsed from the container header, so a renamed HTML/SVG/executable file
// cannot enter the post image pipeline. The database repeats the size/dimension/MIME checks and binds
// the storage path to the authenticated uploader, so a bypass of this module still cannot attach media.

export const SOCIAL_MEDIA_BUCKET = "social-media";
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export const MAX_IMAGE_DIMENSION = 8000;
export const MAX_IMAGE_PIXELS = 40_000_000;
export const MAX_IMAGES_PER_POST = 10;
export const MAX_POST_MEDIA_BYTES = 25 * 1024 * 1024;
export const ALLOWED_IMAGE_MIME = ["image/jpeg", "image/png", "image/webp"] as const;

export type AllowedImageMime = (typeof ALLOWED_IMAGE_MIME)[number];

export type ImageVerdict =
  | { ok: true; mime: AllowedImageMime; extension: "jpg" | "png" | "webp"; width: number; height: number; size: number }
  | { ok: false; error: string };

const fail = (error: string): ImageVerdict => ({ ok: false, error });

const isPng = (b: Uint8Array) =>
  b.length >= 24 &&
  b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
  b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a;

const isJpeg = (b: Uint8Array) => b.length >= 4 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;

const isWebp = (b: Uint8Array) =>
  b.length >= 30 &&
  b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
  b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50;

const u16be = (b: Uint8Array, i: number) => (b[i] << 8) | b[i + 1];
const u32be = (b: Uint8Array, i: number) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
const u24le = (b: Uint8Array, i: number) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);

function pngSize(b: Uint8Array): { width: number; height: number } | null {
  // IHDR must be the first chunk: 4 length + "IHDR" + 32-bit width/height.
  if (b[12] !== 0x49 || b[13] !== 0x48 || b[14] !== 0x44 || b[15] !== 0x52) return null;
  return { width: u32be(b, 16), height: u32be(b, 20) };
}

function jpegSize(b: Uint8Array): { width: number; height: number } | null {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) { i++; continue; }
    const marker = b[i + 1];
    // Standalone markers carry no length field.
    if (marker === 0xd8 || marker === 0xd9 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
    const length = u16be(b, i + 2);
    if (length < 2) return null;
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      if (i + 8 >= b.length) return null;
      return { height: u16be(b, i + 5), width: u16be(b, i + 7) };
    }
    i += 2 + length;
  }
  return null;
}

function webpSize(b: Uint8Array): { width: number; height: number } | null {
  const chunk = String.fromCharCode(b[12], b[13], b[14], b[15]);
  if (chunk === "VP8X" && b.length >= 30) {
    return { width: u24le(b, 24) + 1, height: u24le(b, 27) + 1 };
  }
  if (chunk === "VP8L" && b.length >= 25 && b[20] === 0x2f) {
    const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 };
  }
  if (chunk === "VP8 " && b.length >= 30) {
    if (b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return null;
    return { width: u16be(b, 26) & 0x3fff, height: u16be(b, 28) & 0x3fff };
  }
  return null;
}

/**
 * Validate bytes as a supported raster image. `declaredMime` is only compared against the real
 * signature: it can never widen what is accepted.
 */
export function validateSocialImage(bytes: Uint8Array, declaredMime?: string | null): ImageVerdict {
  if (!bytes || bytes.length === 0) return fail("SOCIAL_MEDIA_INVALID");
  if (bytes.length > MAX_IMAGE_BYTES) return fail("SOCIAL_MEDIA_TOO_LARGE");

  let mime: AllowedImageMime;
  let extension: "jpg" | "png" | "webp";
  let dims: { width: number; height: number } | null = null;

  if (isPng(bytes)) {
    mime = "image/png"; extension = "png"; dims = pngSize(bytes);
  } else if (isJpeg(bytes)) {
    mime = "image/jpeg"; extension = "jpg"; dims = jpegSize(bytes);
  } else if (isWebp(bytes)) {
    mime = "image/webp"; extension = "webp"; dims = webpSize(bytes);
  } else {
    return fail("SOCIAL_MEDIA_INVALID");
  }

  if (!dims || !Number.isFinite(dims.width) || !Number.isFinite(dims.height) ||
      dims.width < 1 || dims.height < 1) {
    return fail("SOCIAL_MEDIA_INVALID");
  }
  if (dims.width > MAX_IMAGE_DIMENSION || dims.height > MAX_IMAGE_DIMENSION ||
      dims.width * dims.height > MAX_IMAGE_PIXELS) {
    return fail("SOCIAL_MEDIA_INVALID");
  }
  if (declaredMime && declaredMime.toLowerCase() !== mime) return fail("SOCIAL_MEDIA_INVALID");

  return { ok: true, mime, extension, width: dims.width, height: dims.height, size: bytes.length };
}

/** Total-size guard for a post's attached images; the database enforces the same limit. */
export function validatePostMediaBudget(sizes: number[]): { ok: boolean; error?: string } {
  if (sizes.length > MAX_IMAGES_PER_POST) return { ok: false, error: "SOCIAL_MEDIA_LIMIT_EXCEEDED" };
  const total = sizes.reduce((sum, value) => sum + (Number.isFinite(value) && value > 0 ? value : 0), 0);
  if (total > MAX_POST_MEDIA_BYTES) return { ok: false, error: "SOCIAL_MEDIA_TOO_LARGE" };
  return { ok: true };
}
