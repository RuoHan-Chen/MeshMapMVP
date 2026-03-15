import { getLLMProvider } from "@/lib/agents";
import { areaHashFromCoords } from "@/lib/dedup/area";
import { findDuplicateStory } from "@/lib/dedup/nearby";
import type { MeshReport, NewsStory, StoryGenerateResult } from "@/lib/types";
import { normalizeImageDescriptors } from "@/lib/utils/imageDescriptors";

export async function generateStoryFromReports(
  reports: MeshReport[],
  existingStories: NewsStory[]
): Promise<StoryGenerateResult> {
  if (!reports.length) {
    return { story: null, merged: false, message: "No reports" };
  }

  const primary = reports[0];
  const dup = findDuplicateStory(primary, existingStories);

  const urlsFromReports = [
    ...new Set(reports.flatMap((r) => r.imageUrls).filter(Boolean)),
  ];

    if (dup) {
    const mergedUrls = [
      ...new Set([...(dup.imageUrls ?? []), ...urlsFromReports]),
    ];
    const updated: NewsStory = {
      ...dup,
      imageUrls: mergedUrls,
      sourceReportIds: [...new Set([...dup.sourceReportIds, ...reports.map((r) => r.id)])],
      sourceCount: dup.sourceCount + reports.length,
      summary:
        dup.summary +
        ` Additional mesh report(s) merged (${reports.length}); still unverified.`,
      ...(primary.isSos && {
        sosSubmitted: true,
        sosLocation: {
          latitude: primary.latitude,
          longitude: primary.longitude,
          placeName: primary.placeName || undefined,
        },
      }),
    };
    return {
      story: { ...updated },
      merged: true,
      duplicateStoryId: dup.id,
      attachedReportId: primary.id,
      message: "Merged into existing nearby story",
    };
  }

  const llm = getLLMProvider();
  const draft = await llm.generateArticle(reports);

  const sid = `s-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  const story: NewsStory = {
    id: sid,
    newsId: sid,
    title: draft.title,
    dek: draft.dek,
    articleBody: draft.articleBody,
    summary: draft.summary,
    eventType: primary.eventType,
    latitude: primary.latitude,
    longitude: primary.longitude,
    areaHash: areaHashFromCoords(primary.latitude, primary.longitude),
    createdAt: new Date().toISOString(),
    sourceReportIds: reports.map((r) => r.id),
    imageUrls: urlsFromReports,
    imageDescriptors: normalizeImageDescriptors(
      draft.imageDescriptors as unknown[]
    ),
    canonicalTags: draft.canonicalTags,
    severity: draft.severity,
    duplicateOf: null,
    sourceCount: reports.length,
    unverifiedNote: draft.unverifiedNote,
    ...(primary.isSos && {
      sosSubmitted: true,
      sosLocation: {
        latitude: primary.latitude,
        longitude: primary.longitude,
        placeName: primary.placeName || undefined,
      },
      severity:
        draft.severity === "low" ? "high" : draft.severity === "medium" ? "high" : draft.severity,
    }),
    actionables: [
      "Rely on verified official channels for the area.",
      "Avoid unnecessary travel near the reported zone.",
      "Document safely if you are not in danger.",
    ],
    dontDos: [
      "Do not spread unconfirmed casualty counts.",
      "Do not enter cordoned or hazardous areas.",
      "Do not overload emergency services with non-urgent calls.",
    ],
  };

  return { story, merged: false };
}
