import type { MeshReport } from "@/lib/types";

export function normalizeIngestBody(body: Record<string, unknown>): MeshReport {
  const id =
    typeof body.id === "string" && body.id
      ? body.id
      : `r-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;

  const imageUrls: string[] = Array.isArray(body.imageUrls)
    ? (body.imageUrls as string[]).filter((u) => typeof u === "string")
    : body.imageUrl && typeof body.imageUrl === "string"
      ? [body.imageUrl]
      : [];

  const imageDescriptors: string[] = Array.isArray(body.imageDescriptors)
    ? (body.imageDescriptors as string[]).filter((s) => typeof s === "string")
    : imageUrls.length
      ? imageUrls.map((_, i) => `Image ${i + 1} from mesh (URL).`)
      : [];

  return {
    id,
    sourcePeerId: String(body.sourcePeerId || body.source_peer_id || "peer-unknown"),
    timestamp:
      typeof body.timestamp === "string"
        ? body.timestamp
        : new Date().toISOString(),
    latitude: Number(body.latitude) || 0,
    longitude: Number(body.longitude) || 0,
    placeName: String(body.placeName || body.place_name || ""),
    eventType: String(body.eventType || body.event_type || "incident"),
    description: String(body.description || ""),
    imageUrls,
    imageDescriptors,
    trustScore: Math.min(1, Math.max(0, Number(body.trustScore ?? 0.5) || 0.5)),
    status: "received",
    isSos: Boolean(body.isSos ?? body.sos),
    rawPayload: body as Record<string, unknown>,
  };
}
