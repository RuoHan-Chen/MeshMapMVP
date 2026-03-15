import { getLLMProvider } from "@/lib/agents";
import { areaHashFromCoords } from "@/lib/dedup/area";
import type {
  MapIncidentEvent,
  MapIncidentSos,
  NewsStory,
  StoryGenerateResult,
} from "@/lib/types";
import { normalizeImageDescriptors } from "@/lib/utils/imageDescriptors";

function pad3(
  a: string[] | undefined,
  label: string
): [string, string, string] {
  const x = a?.filter(Boolean) || [];
  return [
    x[0] || `${label} 1`,
    x[1] || `${label} 2`,
    x[2] || `${label} 3`,
  ] as [string, string, string];
}

export async function generateStoryFromIncidents(params: {
  newsId: string;
  sos: MapIncidentSos;
  events: MapIncidentEvent[];
  imageDataUrls?: string[];
}): Promise<StoryGenerateResult> {
  const llm = getLLMProvider();
  const draft = await llm.generateArticleFromIncidents({
    newsId: params.newsId,
    sos: params.sos,
    events: params.events,
    imageDataUrls: params.imageDataUrls,
  });

  const actionables = pad3(draft.actionables, "Stay informed");
  const dontDos = pad3(draft.dontDos, "Avoid unsafe behavior");

  const story: NewsStory = {
    id: params.newsId,
    newsId: params.newsId,
    title: draft.title,
    dek: draft.dek,
    articleBody: draft.articleBody,
    summary: draft.summary,
    eventType: "sos",
    latitude: params.sos.latitude,
    longitude: params.sos.longitude,
    areaHash: areaHashFromCoords(params.sos.latitude, params.sos.longitude),
    createdAt: new Date().toISOString(),
    sourceReportIds: [params.newsId],
    imageUrls: [...(params.imageDataUrls || [])],
    imageDescriptors: normalizeImageDescriptors(
      draft.imageDescriptors as unknown[]
    ),
    canonicalTags: draft.canonicalTags,
    severity: draft.severity,
    duplicateOf: null,
    sourceCount: 1 + params.events.length,
    unverifiedNote: draft.unverifiedNote,
    sosSubmitted: true,
    sosLocation: {
      latitude: params.sos.latitude,
      longitude: params.sos.longitude,
      placeName: params.sos.title,
    },
    mapIncidents: { sos: params.sos, events: params.events },
    actionables,
    dontDos,
  };

  return { story, merged: false };
}
