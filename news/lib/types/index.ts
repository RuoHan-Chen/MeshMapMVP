/** MeshReport — legacy ingest; optional for imports */
export type MeshReportStatus = "received" | "merged" | "rejected";

export interface MeshReport {
  id: string;
  sourcePeerId: string;
  timestamp: string;
  latitude: number;
  longitude: number;
  placeName: string;
  eventType: string;
  description: string;
  imageUrls: string[];
  imageDescriptors: string[];
  trustScore: number;
  status: MeshReportStatus;
  isSos?: boolean;
  rawPayload?: Record<string, unknown>;
}

/** Single SOS point — one SMS, one primary location */
export interface MapIncidentSos {
  title: string;
  description: string;
  latitude: number;
  longitude: number;
}

/** Inline image: base64 + mime (e.g. event photo) */
export interface MapIncidentImage {
  data: string;
  mime_type: string;
}

/** Map pin — optional image per event */
export interface MapIncidentEvent {
  title: string;
  description: string;
  latitude: number;
  longitude: number;
  image?: MapIncidentImage;
}

export interface NewsStoryMapIncidents {
  sos: MapIncidentSos;
  events: MapIncidentEvent[];
}

/** NewsStory — article + map + actionables; id === newsId (UUID) for GET /api/recommendations/[news_id] */
export interface NewsStory {
  id: string;
  /** UUID for GET /api/recommendations/[newsId]; defaults to id when missing */
  newsId?: string;
  title: string;
  dek: string;
  articleBody: string;
  summary: string;
  eventType: string;
  latitude: number;
  longitude: number;
  areaHash: string;
  createdAt: string;
  sourceReportIds: string[];
  imageUrls: string[];
  imageDescriptors: string[];
  canonicalTags: string[];
  severity: "low" | "medium" | "high" | "critical";
  duplicateOf: string | null;
  mergedIntoStoryId?: string | null;
  sourceCount: number;
  unverifiedNote?: string;
  sosSubmitted?: boolean;
  sosLocation?: { latitude: number; longitude: number; placeName?: string };
  /** SOS + event pins shown on in-app map */
  mapIncidents?: NewsStoryMapIncidents;
  /** Exactly 3 — what to do now */
  actionables?: [string, string, string];
  /** Exactly 3 — what not to do */
  dontDos?: [string, string, string];
}

export interface RecommendationBrief {
  id: string;
  basedOnStoryIds: string[];
  basedOnExternalSources: string[];
  generatedAt: string;
  actionableRecommendations: [string, string, string];
  avoidRecommendations: [string, string, string];
  rationale: string;
  area: string;
  confidence: "low" | "medium" | "high";
}

export type UrgencyLevel = "routine" | "urgent" | "emergency";
export type AuthorityType = "police" | "fire" | "ems" | "municipal" | "utilities";

export interface EscalationDraft {
  id: string;
  storyId: string | null;
  reportId: string | null;
  urgencyLevel: UrgencyLevel;
  authorityType: AuthorityType;
  phoneScript: string;
  textMessage: string;
  structuredContext: Record<string, string | number | boolean>;
  callerLocation: { lat: number; lng: number; label?: string };
  incidentLocation: { lat: number; lng: number; label?: string };
  createdAt: string;
}

export interface StoryGenerateResult {
  story: NewsStory | null;
  merged: boolean;
  duplicateStoryId?: string;
  attachedReportId?: string;
  message?: string;
  authoritySms?: {
    sent: boolean;
    sid?: string;
    error?: string;
    body?: string;
  };
}
