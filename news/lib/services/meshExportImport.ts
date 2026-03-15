import type { MeshReport } from "@/lib/types";
import type {
  MeshExportDocument,
  MeshExportEnvelope,
  MeshExportPointFeature,
} from "@/lib/types/meshExport";

export function isMeshExportDocument(v: unknown): v is MeshExportDocument {
  if (!v || typeof v !== "object") return false;
  const exp = (v as { export?: unknown }).export;
  if (!exp || typeof exp !== "object") return false;
  const e = exp as MeshExportEnvelope;
  if (typeof e.id !== "string" || !e.featureCollection) return false;
  const fc = e.featureCollection;
  return (
    fc.type === "FeatureCollection" && Array.isArray(fc.features)
  );
}

/**
 * One map feature → one MeshReport (ingest-compatible).
 */
export function featureToMeshReport(
  feature: MeshExportPointFeature,
  exportId: string
): MeshReport {
  const [lng, lat] = feature.geometry.coordinates;
  const p = feature.properties;
  const id =
    typeof feature.id === "string" && feature.id
      ? `exp-${exportId}-${feature.id}`
      : `exp-${exportId}-${Math.random().toString(36).slice(2, 10)}`;

  const imageUrls: string[] = [];
  if (p.image?.present && p.image.url && typeof p.image.url === "string") {
    imageUrls.push(p.image.url);
  }

  const trust =
    typeof p.confidence === "number"
      ? Math.min(1, Math.max(0, p.confidence))
      : 0.5;

  const title = p.title ?? p.category ?? "report";
  const descriptors: string[] = [];
  if (p.image?.present) {
    descriptors.push(
      p.image.width && p.image.height
        ? `Image ${p.image.width}×${p.image.height}${p.image.mimeType ? ` (${p.image.mimeType})` : ""}`
        : "Image attached in export."
    );
  }
  if (!descriptors.length && imageUrls.length)
    descriptors.push("Image URL from export.");

  return {
    id,
    sourcePeerId: p.senderId || p.senderName || "mesh-export",
    timestamp: p.createdAt || new Date().toISOString(),
    latitude: lat,
    longitude: lng,
    placeName: title,
    eventType: p.category || p.kind || "incident",
    description: [p.title, p.description].filter(Boolean).join(" — ") || "",
    imageUrls,
    imageDescriptors: descriptors,
    trustScore: trust,
    status: "received",
    rawPayload: {
      exportId,
      featureId: feature.id,
      upVotes: p.upVotes,
      downVotes: p.downVotes,
      kind: p.kind,
    },
  };
}

export function documentToReports(doc: MeshExportDocument): MeshReport[] {
  const exp = doc.export;
  return exp.featureCollection.features.map((f) =>
    featureToMeshReport(f, exp.id)
  );
}
