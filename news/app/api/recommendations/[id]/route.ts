import { NextResponse } from "next/server";
import { getRecommendationBrief } from "@/lib/storage/briefStore";

/** GET — return saved actionables / full brief by id (from POST /api/recommendations) */
export async function GET(
  _req: Request,
  ctx: { params: Promise<{ id: string }> }
) {
  const { id } = await ctx.params;
  if (!id) {
    return NextResponse.json({ ok: false, error: "Missing id" }, { status: 400 });
  }
  const brief = await getRecommendationBrief(decodeURIComponent(id));
  if (!brief) {
    if (process.env.MESHNEWS_LOG_LLM !== "0") {
      console.log("[MeshNews] GET /api/recommendations/" + id + " → 404 (not in store)");
    }
    return NextResponse.json(
      { ok: false, error: "Brief not found or expired (use Upstash for multi-instance)" },
      { status: 404 }
    );
  }
  if (process.env.MESHNEWS_LOG_LLM !== "0") {
    console.log("[MeshNews] GET /api/recommendations/" + id + " → hit", {
      actionables: brief.actionableRecommendations,
    });
  }
  return NextResponse.json({
    ok: true,
    id: brief.id,
    actionableRecommendations: brief.actionableRecommendations,
    avoidRecommendations: brief.avoidRecommendations,
    rationale: brief.rationale,
    confidence: brief.confidence,
    area: brief.area,
    generatedAt: brief.generatedAt,
    basedOnStoryIds: brief.basedOnStoryIds,
    brief,
  });
}
