import type { MeshReport, NewsStory } from "@/lib/types";
import {
  areaHashFromCoords,
  haversineKm,
  hoursBetween,
  jaccard,
  tokenSet,
} from "@/lib/dedup/area";

export interface DedupConfig {
  maxDistanceKm: number;
  maxHoursApart: number;
  minDescriptionJaccard: number;
}

const DEFAULTS: DedupConfig = {
  maxDistanceKm: 3,
  maxHoursApart: 4,
  minDescriptionJaccard: 0.15,
};

/**
 * Find an existing story in the same area that likely describes the same incident.
 */
export function findDuplicateStory(
  report: MeshReport,
  existingStories: NewsStory[],
  config: Partial<DedupConfig> = {}
): NewsStory | null {
  const c = { ...DEFAULTS, ...config };
  const reportTokens = tokenSet(report.description);
  const reportArea = areaHashFromCoords(report.latitude, report.longitude);

  for (const story of existingStories) {
    if (story.mergedIntoStoryId) continue;
    const dist = haversineKm(
      report.latitude,
      report.longitude,
      story.latitude,
      story.longitude
    );
    if (dist > c.maxDistanceKm) continue;
    if (story.eventType !== report.eventType) continue;
    const storyTokens = tokenSet(story.summary + " " + story.articleBody);
    const sim = jaccard(reportTokens, storyTokens);
    const reportTime = report.timestamp;
    const storyTime = story.createdAt;
    if (hoursBetween(reportTime, storyTime) > c.maxHoursApart && sim < 0.25)
      continue;
    if (sim >= c.minDescriptionJaccard || story.sourceReportIds.includes(report.id))
      return story;
    // Same area + same event type + close in time → merge
    if (hoursBetween(reportTime, storyTime) <= 2) return story;
  }

  // Fallback: exact area bucket + same event type
  for (const story of existingStories) {
    if (story.mergedIntoStoryId) continue;
    if (story.areaHash === reportArea && story.eventType === report.eventType) {
      const dist = haversineKm(
        report.latitude,
        report.longitude,
        story.latitude,
        story.longitude
      );
      if (dist <= c.maxDistanceKm) return story;
    }
  }

  return null;
}
