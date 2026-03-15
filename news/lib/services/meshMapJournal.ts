/** Legacy mesh export parse only — not part of generate schema */
export interface MeshMapJournal {
  exportDate?: string;
  exporter?: string;
  members: Array<{ id?: string; name: string; latitude: number; longitude: number }>;
  events: Array<{
    id?: string; name?: string; category?: string; description?: string;
    date?: string; latitude: number; longitude: number;
    thumbnailDataURI?: string; icon?: string;
  }>;
}

/** Decode meshmap HTML line: var b = "eyJ..."; → JSON */
export function parseMeshMapBase64Payload(b64url: string): unknown {
  const s = b64url.trim().replace(/-/g, "+").replace(/_/g, "/");
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const json = Buffer.from(s + pad, "base64").toString("utf8");
  return JSON.parse(json);
}

/** Pull `b = "..."` from meshmap-export HTML */
export function extractBase64FromMeshMapHtml(html: string): string | null {
  const m = html.match(/var\s+b\s*=\s*"([^"]+)"/);
  return m ? m[1] : null;
}

export function normalizeMeshMapData(raw: unknown): MeshMapJournal | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const members: MeshMapJournal["members"] = [];
  const events: MeshMapJournal["events"] = [];

  if (Array.isArray(o.members)) {
    for (const m of o.members) {
      if (!m || typeof m !== "object") continue;
      const x = m as Record<string, unknown>;
      const lat = Number(x.latitude);
      const lng = Number(x.longitude);
      if (Number.isNaN(lat) || Number.isNaN(lng)) continue;
      members.push({
        id: typeof x.id === "string" ? x.id : undefined,
        name: String(x.name || "Member"),
        latitude: lat,
        longitude: lng,
      });
    }
  }

  if (Array.isArray(o.events)) {
    for (const e of o.events) {
      if (!e || typeof e !== "object") continue;
      const x = e as Record<string, unknown>;
      const lat = Number(x.latitude);
      const lng = Number(x.longitude);
      if (Number.isNaN(lat) || Number.isNaN(lng)) continue;
      const thumb = x.thumbnailDataURI;
      events.push({
        id: typeof x.id === "string" ? x.id : undefined,
        name: typeof x.name === "string" ? x.name : undefined,
        category: typeof x.category === "string" ? x.category : undefined,
        description: typeof x.description === "string" ? x.description : undefined,
        date: typeof x.date === "string" ? x.date : undefined,
        latitude: lat,
        longitude: lng,
        thumbnailDataURI:
          typeof thumb === "string" && thumb.startsWith("data:") ? thumb : undefined,
        icon: typeof x.icon === "string" ? x.icon : undefined,
      });
    }
  }

  if (!members.length && !events.length) return null;
  return {
    exportDate: typeof o.exportDate === "string" ? o.exportDate : undefined,
    exporter: typeof o.exporter === "string" ? o.exporter : undefined,
    members,
    events,
  };
}

/** Accept: raw JSON object | base64url string | full HTML export */
export function parseMeshMapJournalInput(
  input: string | Record<string, unknown>
): MeshMapJournal | null {
  if (typeof input === "object") return normalizeMeshMapData(input);
  const t = input.trim();
  if (!t) return null;
  if (t.includes("var b =") || t.includes("<html")) {
    const b = extractBase64FromMeshMapHtml(t);
    if (!b) return null;
    try {
      return normalizeMeshMapData(parseMeshMapBase64Payload(b));
    } catch {
      return null;
    }
  }
  try {
    if (t.startsWith("{")) return normalizeMeshMapData(JSON.parse(t));
    return normalizeMeshMapData(parseMeshMapBase64Payload(t));
  } catch {
    return null;
  }
}
