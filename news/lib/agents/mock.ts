import type { MeshReport, NewsStory } from "@/lib/types";
import type {
  ArticleDraft,
  EscalationDraftContent,
  LLMProvider,
  RecommendationDraft,
} from "@/lib/agents/types";
function inferSeverity(eventType: string): ArticleDraft["severity"] {
  const e = eventType.toLowerCase();
  if (/fire|explosion|collapse|shooting|flood/i.test(e)) return "high";
  if (/injury|medical|gas|power/i.test(e)) return "medium";
  return "low";
}

export const mockProvider: LLMProvider = {
  async generateArticleFromIncidents(input: {
    newsId: string;
    sos: import("@/lib/types").MapIncidentSos;
    events: import("@/lib/types").MapIncidentEvent[];
    imageDataUrls?: string[];
  }): Promise<ArticleDraft> {
    const s = input.sos;
    const n = input.imageDataUrls?.length ?? 0;
    return {
      title: `SOS: ${s.title}`,
      dek: `${input.events.length} map event(s) · Unverified`,
      summary: `Primary SOS: ${s.description.slice(0, 200)}`,
      articleBody: [
        `**SOS (primary)**`,
        s.description,
        `Location: ${s.latitude.toFixed(5)}, ${s.longitude.toFixed(5)}`,
        ``,
        `**Other reported events**`,
        ...input.events.map(
          (e, i) =>
            `${i + 1}. **${e.title}** — ${e.description} _(${e.latitude.toFixed(4)}, ${e.longitude.toFixed(4)})_`
        ),
      ].join("\n\n"),
      canonicalTags: ["sos", "mesh", "unverified"],
      severity: "high",
      imageDescriptors:
        n > 0
          ? Array.from({ length: n }, (_, i) => `Submitted image ${i + 1} (mock: vision not run).`)
          : [],
      unverifiedNote: "Mock article from SOS + events.",
      actionables: [
        "Stay away from reported hazard zones until official all-clear.",
        "Use official channels for evacuation or shelter info.",
        "Check on neighbors only if safe to do so.",
      ],
      dontDos: [
        "Do not spread unconfirmed casualty or cause rumors.",
        "Do not enter cordoned or flooded areas.",
        "Do not overload emergency lines with non-urgent calls.",
      ],
    };
  },

  async generateArticle(reports: MeshReport[]): Promise<ArticleDraft> {
    const r = reports[0];
    const place = r.placeName || "the reported area";
    const type = r.eventType || "incident";
    const time = new Date(r.timestamp).toLocaleString();
    const descriptors =
      r.imageDescriptors.length > 0
        ? r.imageDescriptors
        : r.imageUrls.length > 0
          ? r.imageUrls.map((_, i) => `Submitted image ${i + 1} (URL provided; visual content not analyzed in mock mode).`)
          : ["No images attached."];

    return {
      title: `Local report: ${type} near ${place}`,
      dek: `Community-sourced update · ${time} · Unverified mesh report`,
      summary: `Multiple sources on the local mesh reported a ${type} near ${place}. Details below are compiled from submitted fields only; independent confirmation has not been established.`,
      articleBody: [
        `**What was reported**`,
        `At approximately ${time}, a mesh peer (${r.sourcePeerId}) filed a report classified as "${type}" near ${place} (coordinates approximately ${r.latitude.toFixed(4)}, ${r.longitude.toFixed(4)}).`,
        ``,
        `**Description (as submitted)**`,
        r.description || "(No description provided.)",
        ``,
        `**Confidence / trust**`,
        `Source trust score on file: ${(r.trustScore * 100).toFixed(0)}%. This does not imply factual accuracy.`,
        ``,
        `**Uncertain or unconfirmed**`,
        `Timing, extent, and cause should be treated as unverified until official or on-scene confirmation is available.`,
      ].join("\n\n"),
      canonicalTags: [type, place.split(",")[0] || place, "mesh-report", "unverified"],
      severity: inferSeverity(type),
      imageDescriptors: descriptors,
      unverifiedNote:
        "This article is generated from community mesh data. Do not treat as emergency services confirmation.",
    };
  },

  async generateSosAuthoritySms(input: {
    latitude: number;
    longitude: number;
    mapsUrl: string;
    sosCategory: string;
    sosDescription: string;
    placeName: string;
    peerId: string;
    timestamp: string;
    nearbyIncidents: import("@/lib/agents/types").SosNearbyEvent[];
  }): Promise<{ smsBody: string }> {
    const near = input.nearbyIncidents
      .map(
        (n) =>
          `${n.category || n.name || "incident"}${n.distanceKm != null ? ` ~${n.distanceKm.toFixed(1)}km` : ""}${n.description ? `: ${n.description.slice(0, 80)}` : ""}`
      )
      .join(" | ");
    const body = [
      `MESH SOS ${input.sosCategory.toUpperCase()}`,
      `Loc ${input.latitude.toFixed(5)},${input.longitude.toFixed(5)}`,
      input.mapsUrl,
      input.sosDescription.slice(0, 200) || input.placeName,
      `Peer ${input.peerId} ${input.timestamp}`,
      near ? `Nearby: ${near.slice(0, 400)}` : "",
    ]
      .filter(Boolean)
      .join("\n");
    return { smsBody: body.slice(0, 1580) };
  },

  async generateRecommendations(input: {
    stories: NewsStory[];
    areaLabel: string;
    mockExternal: boolean;
  }): Promise<RecommendationDraft> {
    const types = [...new Set(input.stories.map((s) => s.eventType))].join(", ") || "general";
    const external = input.mockExternal
      ? ["Mock: City OEM status page (simulated)", "Mock: Transit alert feed (simulated)"]
      : [];

    return {
      actionable: [
        `If moving on foot, favor well-lit main corridors away from reported ${types} clusters (mock routing hint).`,
        `Check in with designated community aid points if announced for this area (simulated).`,
        `Keep devices charged; prefer SMS/voice for low-bandwidth mesh handoff (demo recommendation).`,
      ],
      avoid: [
        `Avoid spreading location-precise rumors not tied to a verified story ID.`,
        `Avoid congested gathering points if crowding is reported for this event type.`,
        `Avoid secondary routes that parallel reported incident corridors until cleared.`,
      ],
      rationale: `Brief synthesized from ${input.stories.length} local story/stories in ${input.areaLabel}. External feeds: ${external.length ? "mock mode" : "not used"}.`,
      confidence: input.stories.length >= 2 ? "medium" : "low",
      externalSourceLabels: external,
    };
  },

  async generateEscalation(input: {
    storySummary: string;
    eventType: string;
    urgency: import("@/lib/types").UrgencyLevel;
    incidentLat: number;
    incidentLng: number;
    placeName: string;
    helpType: string;
  }): Promise<EscalationDraftContent> {
    const auth =
      /fire|smoke/i.test(input.eventType) ? "fire" : /medical|injury/i.test(input.eventType) ? "ems" : "police";
    return {
      authorityType: auth as EscalationDraftContent["authorityType"],
      textMessage: `[DEMO ONLY] ${input.urgency.toUpperCase()}: ${input.eventType} at ${input.placeName}. ${input.helpType}. Loc ~${input.incidentLat.toFixed(3)},${input.incidentLng.toFixed(3)}. Summary: ${input.storySummary.slice(0, 120)}...`,
      phoneScript: [
        `This is a demo script only. Do not use for real emergencies without verifying locally.`,
        `Say: "I'm calling about a reported ${input.eventType} near ${input.placeName}."`,
        `Say: "Requesting: ${input.helpType}. Urgency: ${input.urgency}."`,
        `Say: "Approximate location latitude ${input.incidentLat}, longitude ${input.incidentLng}."`,
        `Say: "Context: ${input.storySummary.slice(0, 200)}..."`,
      ].join(" "),
    };
  },
};
