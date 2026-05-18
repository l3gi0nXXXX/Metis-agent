#!/usr/bin/env node

import { readFile } from "node:fs/promises";

function parseArgs(argv) {
  const out = {
    input: "",
    maxPages: 20,
    maxPixels: 4_000_000,
    minTextChars: 200,
    pageNumbers: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) {
        throw new Error(`Missing value for ${arg}`);
      }
      i += 1;
      return argv[i];
    };
    if (arg === "--input") {
      out.input = next();
    } else if (arg === "--max-pages") {
      out.maxPages = Math.max(1, Number.parseInt(next(), 10));
    } else if (arg === "--max-pixels") {
      out.maxPixels = Math.max(1, Number.parseInt(next(), 10));
    } else if (arg === "--min-text-chars") {
      out.minTextChars = Math.max(0, Number.parseInt(next(), 10));
    } else if (arg === "--pages") {
      out.pageNumbers = next()
        .split(",")
        .map((item) => Number.parseInt(item.trim(), 10))
        .filter((item) => Number.isFinite(item) && item >= 1);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!out.input) {
    throw new Error("--input is required");
  }
  return out;
}

async function loadPdfJs() {
  try {
    return await import("pdfjs-dist/legacy/build/pdf.mjs");
  } catch (err) {
    throw new Error(`Optional dependency pdfjs-dist is required for PDF extraction: ${String(err)}`);
  }
}

async function loadCanvas() {
  try {
    return await import("@napi-rs/canvas");
  } catch (err) {
    throw new Error(`Optional dependency @napi-rs/canvas is required for PDF image extraction: ${String(err)}`);
  }
}

function pageSelection(pdf, maxPages, requestedPages) {
  if (requestedPages.length > 0) {
    return requestedPages.filter((page) => page >= 1 && page <= pdf.numPages).slice(0, maxPages);
  }
  const count = Math.min(pdf.numPages, maxPages);
  return Array.from({ length: count }, (_unused, index) => index + 1);
}

async function extractText(pdf, selectedPages) {
  const textParts = [];
  for (const pageNumber of selectedPages) {
    const page = await pdf.getPage(pageNumber);
    const textContent = await page.getTextContent();
    const text = textContent.items
      .map((item) => (typeof item.str === "string" ? item.str : ""))
      .filter(Boolean)
      .join(" ")
      .trim();
    if (text) {
      textParts.push(text);
    }
  }
  return textParts.join("\n\n");
}

async function renderImages(pdf, selectedPages, maxPixels) {
  const { createCanvas } = await loadCanvas();
  const images = [];
  const pixelBudget = Math.max(1, maxPixels);
  for (const pageNumber of selectedPages) {
    const page = await pdf.getPage(pageNumber);
    const viewport = page.getViewport({ scale: 1 });
    const pagePixels = Math.max(1, viewport.width * viewport.height);
    const scale = Math.max(0.1, Math.min(1, Math.sqrt(pixelBudget / pagePixels)));
    const scaled = page.getViewport({ scale });
    const canvas = createCanvas(Math.ceil(scaled.width), Math.ceil(scaled.height));
    const canvasContext = canvas.getContext("2d");
    await page.render({ canvasContext, viewport: scaled }).promise;
    images.push({
      mimeType: "image/png",
      data: canvas.toBuffer("image/png").toString("base64"),
    });
  }
  return images;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { getDocument } = await loadPdfJs();
  const buffer = await readFile(args.input);
  const pdf = await getDocument({ data: new Uint8Array(buffer), disableWorker: true }).promise;
  const selectedPages = pageSelection(pdf, args.maxPages, args.pageNumbers);
  const text = await extractText(pdf, selectedPages);
  const warnings = [];
  let images = [];
  if (text.trim().length < args.minTextChars) {
    try {
      images = await renderImages(pdf, selectedPages, args.maxPixels);
    } catch (err) {
      warnings.push(String(err));
    }
  }
  process.stdout.write(
    JSON.stringify({
      ok: true,
      status: "ok",
      text,
      images,
      pageCount: pdf.numPages,
      selectedPages,
      warnings,
    }),
  );
}

main().catch((err) => {
  process.stdout.write(
    JSON.stringify({
      ok: false,
      status: "extractor_failed",
      message: String(err && err.message ? err.message : err),
      text: "",
      images: [],
      pageCount: 0,
      selectedPages: [],
      warnings: [],
    }),
  );
  process.exitCode = 1;
});
