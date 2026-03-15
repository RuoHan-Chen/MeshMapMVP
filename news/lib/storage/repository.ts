import type {
  EscalationDraft,
  MeshReport,
  NewsStory,
  RecommendationBrief,
} from "@/lib/types";

/** Client-side persistence contract; swap for Supabase later */
export interface MeshNewsRepository {
  putReport(r: MeshReport): Promise<void>;
  listReports(): Promise<MeshReport[]>;
  putStory(s: NewsStory): Promise<void>;
  listStories(): Promise<NewsStory[]>;
  putRecommendation(b: RecommendationBrief): Promise<void>;
  listRecommendations(): Promise<RecommendationBrief[]>;
  putEscalation(e: EscalationDraft): Promise<void>;
  listEscalations(): Promise<EscalationDraft[]>;
  seedIfEmpty?(): Promise<void>;
}
