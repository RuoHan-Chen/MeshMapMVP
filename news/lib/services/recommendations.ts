import { getLLMProvider } from "@/lib/agents";
import type { NewsStory, RecommendationBrief } from "@/lib/types";

export async function buildRecommendationBrief(
  stories: NewsStory[],
  areaLabel: string,
  mockExternal: boolean
): Promise<RecommendationBrief> {
  const llm = getLLMProvider();
  const draft = await llm.generateRecommendations({
    stories,
    areaLabel,
    mockExternal,
  });

  return {
    id: `rec-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`,
    basedOnStoryIds: stories.map((s) => s.id),
    basedOnExternalSources: draft.externalSourceLabels,
    generatedAt: new Date().toISOString(),
    actionableRecommendations: draft.actionable,
    avoidRecommendations: draft.avoid,
    rationale: draft.rationale,
    area: areaLabel,
    confidence: draft.confidence,
  };
}
