import type { MeshReport, NewsStory } from "@/lib/types";
import type { MapIncidentEvent, MapIncidentSos } from "@/lib/types";

export interface ArticleDraft {
  title: string;
  dek: string;
  summary: string;
  articleBody: string;
  canonicalTags: string[];
  severity: NewsStory["severity"];
  imageDescriptors: string[];
  unverifiedNote: string;
  /** Filled when generating from SOS + events */
  actionables?: [string, string, string];
  dontDos?: [string, string, string];
}

export interface RecommendationDraft {
  actionable: [string, string, string];
  avoid: [string, string, string];
  rationale: string;
  confidence: "low" | "medium" | "high";
  externalSourceLabels: string[];
}

export interface EscalationDraftContent {
  phoneScript: string;
  textMessage: string;
  authorityType: import("@/lib/types").AuthorityType;
}

export interface SosNearbyEvent {
  latitude: number;
  longitude: number;
  category?: string;
  name?: string;
  description?: string;
  distanceKm?: number;
}

export interface LLMProvider {
  generateArticle(reports: MeshReport[]): Promise<ArticleDraft>;
  /** Primary path: one SOS + many events → article + 3 actionables + 3 dontDos */
  generateArticleFromIncidents(input: {
    newsId: string;
    sos: MapIncidentSos;
    events: MapIncidentEvent[];
    /** data:image/...;base64,... for vision (optional) */
    imageDataUrls?: string[];
  }): Promise<ArticleDraft>;
  generateSosAuthoritySms(input: {
    latitude: number;
    longitude: number;
    mapsUrl: string;
    sosCategory: string;
    sosDescription: string;
    placeName: string;
    peerId: string;
    timestamp: string;
    nearbyIncidents: SosNearbyEvent[];
  }): Promise<{ smsBody: string }>;
  generateRecommendations(input: {
    stories: NewsStory[];
    areaLabel: string;
    mockExternal: boolean;
  }): Promise<RecommendationDraft>;
  generateEscalation(input: {
    storySummary: string;
    eventType: string;
    urgency: import("@/lib/types").UrgencyLevel;
    incidentLat: number;
    incidentLng: number;
    placeName: string;
    helpType: string;
  }): Promise<EscalationDraftContent>;
}
