import { getLLMProvider } from "@/lib/agents";
import type {
  EscalationDraft,
  NewsStory,
  UrgencyLevel,
} from "@/lib/types";

/**
 * DEMO ONLY — prepares mock SMS/call script. Do not use as substitute for emergency services.
 */
export async function buildEscalationDraft(input: {
  story: NewsStory | null;
  reportId: string | null;
  urgency: UrgencyLevel;
  callerLat: number;
  callerLng: number;
  callerLabel?: string;
  helpType: string;
}): Promise<EscalationDraft> {
  const llm = getLLMProvider();
  const story = input.story;
  const placeName =
    story?.canonicalTags?.[0] ||
    `${story?.latitude ?? input.callerLat},${story?.longitude ?? input.callerLng}`;
  const content = await llm.generateEscalation({
    storySummary: story?.summary || "Mesh report only",
    eventType: story?.eventType || "incident",
    urgency: input.urgency,
    incidentLat: story?.latitude ?? input.callerLat,
    incidentLng: story?.longitude ?? input.callerLng,
    placeName,
    helpType: input.helpType,
  });

  return {
    id: `esc-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`,
    storyId: story?.id ?? null,
    reportId: input.reportId,
    urgencyLevel: input.urgency,
    authorityType: content.authorityType,
    phoneScript: content.phoneScript,
    textMessage: content.textMessage,
    structuredContext: {
      eventType: story?.eventType || "",
      severity: story?.severity || "low",
      sourceCount: story?.sourceCount ?? 0,
      demoOnly: true,
    },
    callerLocation: {
      lat: input.callerLat,
      lng: input.callerLng,
      label: input.callerLabel,
    },
    incidentLocation: {
      lat: story?.latitude ?? input.callerLat,
      lng: story?.longitude ?? input.callerLng,
      label: story?.title,
    },
    createdAt: new Date().toISOString(),
  };
}
