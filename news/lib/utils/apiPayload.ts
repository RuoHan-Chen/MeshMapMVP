import type { MeshReport, NewsStory } from "@/lib/types";

/** Max length of a single data: URL we send to the API (vision). ~1.2MB keeps under Vercel limits. */
const MAX_DATA_URL_LEN = 1_200_000;

/** Drop huge data: URLs; keep https always; keep small uploads for Claude vision. */
export function meshReportForGenerateApi(r: MeshReport): MeshReport {
  const imageUrls = r.imageUrls.filter((u) => {
    if (!u.startsWith("data:")) return true;
    return u.length <= MAX_DATA_URL_LEN;
  });
  const droppedData = r.imageUrls.some(
    (u) => u.startsWith("data:") && u.length > MAX_DATA_URL_LEN
  );
  let imageDescriptors = [...r.imageDescriptors];
  if (droppedData)
    imageDescriptors.unshift(
      "Large photo omitted from AI (use a smaller image or an https image URL)."
    );
  else if (imageUrls.some((u) => u.startsWith("data:")))
    imageDescriptors = [
      "Photo sent to model for description.",
      ...imageDescriptors,
    ];
  return { ...r, imageUrls, imageDescriptors };
}

export function storiesForGenerateApi(stories: NewsStory[]): NewsStory[] {
  return stories.map((s) => ({ ...s, imageUrls: [] }));
}

/** data: URLs for generate incidents — max 4, max size each (Vercel/LLM limits) */
export function filterIncidentDataImages(urls: unknown[]): string[] {
  const out: string[] = [];
  for (const u of urls) {
    if (out.length >= 4) break;
    if (typeof u !== "string" || !u.startsWith("data:image/")) continue;
    if (u.length > MAX_DATA_URL_LEN) continue;
    out.push(u);
  }
  return out;
}

/** Build data URLs from events[].image { data, mime_type }; max 4, size-capped */
export function imageDataUrlsFromEvents(
  events: Array<{ image?: { data?: string; mime_type?: string } }>
): string[] {
  const out: string[] = [];
  for (const e of events) {
    if (out.length >= 4) break;
    const img = e.image;
    if (!img?.data || typeof img.data !== "string") continue;
    const mime = (img.mime_type || "image/jpeg").trim() || "image/jpeg";
    const dataUrl = `data:${mime};base64,${img.data}`;
    if (dataUrl.length > MAX_DATA_URL_LEN) continue;
    out.push(dataUrl);
  }
  return out;
}
