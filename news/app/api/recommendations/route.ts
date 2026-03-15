import { NextResponse } from "next/server";
import { buildRecommendationBrief } from "@/lib/services/recommendations";
import { saveRecommendationBrief } from "@/lib/storage/briefStore";
import type { NewsStory } from "@/lib/types";

/** Body: { stories: NewsStory[], areaLabel?, mockExternal? } — saves brief by id for GET /api/recommendations/[id] */
export async function POST(req: Request) {
  try {
    const body = (await req.json()) as {
      stories?: NewsStory[];
      areaLabel?: string;
      mockExternal?: boolean;
    };
    const stories = body.stories || [];
    const area =
      body.areaLabel ||
      (stories[0]
        ? `${stories[0].latitude.toFixed(2)},${stories[0].longitude.toFixed(2)}`
        : "unknown");
    const brief = await buildRecommendationBrief(
      stories,
      area,
      body.mockExternal !== false
    );
    await saveRecommendationBrief(brief);

    if (process.env.MESHNEWS_LOG_LLM !== "0") {
      console.log("\n========== [MeshNews] recommendation brief saved ==========");
      console.log("id:", brief.id);
      console.log("actionables:", brief.actionableRecommendations);
      console.log("avoid:", brief.avoidRecommendations);
      console.log("confidence:", brief.confidence, "area:", brief.area);
      console.log("full brief:", JSON.stringify(brief, null, 2).slice(0, 4000));
      console.log("--- query later: GET /api/recommendations/" + brief.id + " ---\n");
    }

    return NextResponse.json({
      ok: true,
      brief,
      /** Use this id to fetch actionables again without regenerating */
      id: brief.id,
    });
  } catch (e) {
    console.error("[MeshNews] POST /api/recommendations", e);
    return NextResponse.json(
      { ok: false, error: String(e) },
      { status: 500 }
    );
  }
}
