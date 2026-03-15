/**
 * Server-only: append a generated story (and optional recommendation brief) to the
 * Supabase meshnews_demo payload so the web app sees it on next pull (e.g. from iOS publish).
 */
import { createClient } from "@supabase/supabase-js";
import type { NewsStory, RecommendationBrief } from "@/lib/types";

const TABLE = "meshnews_demo";
const DEFAULT_ROOM = "demo";

function serverSupabase() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const key =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim();
  if (!url || !key) return null;
  return createClient(url, key);
}

type Payload = {
  reports?: unknown[];
  stories?: NewsStory[];
  recommendations?: RecommendationBrief[];
  escalations?: unknown[];
};

export async function appendStoryToCloud(
  story: NewsStory,
  recommendationBrief?: RecommendationBrief,
  roomId: string = DEFAULT_ROOM
): Promise<boolean> {
  const supa = serverSupabase();
  if (!supa) return false;

  const { data: row, error: fetchErr } = await supa
    .from(TABLE)
    .select("payload")
    .eq("id", roomId)
    .maybeSingle();

  if (fetchErr) {
    console.warn("[MeshNews supabaseServer] fetch", fetchErr.message);
    return false;
  }

  const payload: Payload = (row?.payload as Payload) || {};
  const stories = [...(payload.stories || [])];
  const existingIndex = stories.findIndex((s) => s.id === story.id);
  if (existingIndex >= 0) {
    stories[existingIndex] = story;
  } else {
    stories.push(story);
  }
  payload.stories = stories;

  if (recommendationBrief) {
    const recs = [...(payload.recommendations || [])];
    const recIndex = recs.findIndex((r) => r.id === recommendationBrief.id);
    if (recIndex >= 0) {
      recs[recIndex] = recommendationBrief;
    } else {
      recs.push(recommendationBrief);
    }
    payload.recommendations = recs;
  }

  const { error: upsertErr } = await supa.from(TABLE).upsert(
    {
      id: roomId,
      payload,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "id" }
  );

  if (upsertErr) {
    console.warn("[MeshNews supabaseServer] upsert", upsertErr.message);
    return false;
  }
  return true;
}
