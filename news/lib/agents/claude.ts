import type { MeshReport, NewsStory, UrgencyLevel, AuthorityType } from "@/lib/types";
import type {
  ArticleDraft,
  EscalationDraftContent,
  LLMProvider,
  RecommendationDraft,
} from "@/lib/agents/types";

const MODEL = process.env.CLAUDE_MODEL || "claude-haiku-4-5-20251001";

function parseJSON<T>(text: string): T {
  let t = text.trim();
  if (t.startsWith("```")) {
    const start = t.indexOf("\n") + 1;
    const end = t.lastIndexOf("```");
    t = (end > start ? t.slice(start, end) : t).trim();
  }
  return JSON.parse(t) as T;
}

type ContentBlock =
  | { type: "text"; text: string }
  | {
      type: "image";
      source:
        | { type: "url"; url: string }
        | { type: "base64"; media_type: string; data: string };
    };

function dataUrlToImageBlock(dataUrl: string): ContentBlock | null {
  const m = dataUrl.match(/^data:([^;]+);base64,(.+)$/i);
  if (!m) return null;
  const media_type = m[1].toLowerCase();
  if (!/^image\/(jpeg|png|gif|webp)$/i.test(media_type)) return null;
  return {
    type: "image",
    source: { type: "base64", media_type, data: m[2] },
  };
}

async function messagesJSON<T>(
  system: string,
  content: ContentBlock[]
): Promise<T> {
  const key = process.env.CLAUDE_API_KEY;
  if (!key) throw new Error("CLAUDE_API_KEY not set");

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 4096,
      system: `${system}\n\nReply with valid JSON only, no markdown outside the JSON object.`,
      messages: [{ role: "user", content }],
    }),
  });
  if (!res.ok) {
    const err = await res.text();
    console.error("[MeshNews Claude] API error", res.status, err);
    throw new Error(`Claude API error: ${res.status} ${err}`);
  }
  const data = (await res.json()) as {
    content: Array<{ type: string; text?: string }>;
    usage?: unknown;
    stop_reason?: string;
    model?: string;
  };
  const text =
    data.content?.find((b) => b.type === "text")?.text?.trim() || "{}";

  /* Log full assistant reply in terminal (npm run dev). Set MESHNEWS_LOG_LLM=0 to disable. */
  if (process.env.MESHNEWS_LOG_LLM !== "0") {
    const max = Number(process.env.MESHNEWS_LOG_LLM_MAX_CHARS) || 12000;
    const slice = text.length > max ? `${text.slice(0, max)}\n… [truncated ${text.length - max} chars]` : text;
    console.log("\n========== [MeshNews Claude] response ==========");
    console.log("model:", data.model ?? MODEL, "stop_reason:", data.stop_reason);
    console.log("usage:", JSON.stringify(data.usage ?? {}));
    console.log("--- assistant text ---\n", slice, "\n--- end ---\n");
  }

  return parseJSON<T>(text);
}

async function chatJSON<T>(system: string, user: string): Promise<T> {
  return messagesJSON<T>(system, [{ type: "text", text: user }]);
}

export function createClaudeProvider(): LLMProvider {
  return {
    async generateSosAuthoritySms(input: {
      latitude: number;
      longitude: number;
      mapsUrl: string;
      sosCategory: string;
      sosDescription: string;
      placeName: string;
      peerId: string;
      timestamp: string;
      nearbyIncidents: import("@/lib/agents/types").SosNearbyEvent[];
    }): Promise<{ smsBody: string }> {
      return messagesJSON<{ smsBody: string }>(
        `One SMS to authorities: location (lat,lng + maps URL), SOS category, situation text, reporter peer id, time. Add nearby mesh incidents (shooting, earthquake, fire, etc.) as context—mark unverified. Max 1500 chars. JSON only: {"smsBody":"..."}`,
        [{ type: "text", text: JSON.stringify(input) }]
      );
    },

    async generateArticleFromIncidents(input: {
      newsId: string;
      sos: import("@/lib/types").MapIncidentSos;
      events: import("@/lib/types").MapIncidentEvent[];
      imageDataUrls?: string[];
    }): Promise<ArticleDraft> {
      const meta = JSON.stringify({
        newsId: input.newsId,
        sos: input.sos,
        events: input.events,
      });
      const content: ContentBlock[] = [
        {
          type: "text",
          text: `${meta}\n\nAttached images (if any) are unverified scene photos. Describe only what is visible. JSON: title, dek, summary, articleBody, canonicalTags[], severity, imageDescriptors[] (one caption per image in order), actionables[3], dontDos[3].`,
        },
      ];
      for (const url of input.imageDataUrls || []) {
        if (content.length >= 6) break;
        const block = dataUrlToImageBlock(url);
        if (block) content.push(block);
      }
      const out = await messagesJSON<{
        title: string;
        dek: string;
        summary: string;
        articleBody: string;
        canonicalTags: string[];
        severity: ArticleDraft["severity"];
        imageDescriptors: string[];
        actionables: [string, string, string];
        dontDos: [string, string, string];
      }>(
        `You write factual, neutral local crisis news from SOS + map events.`,
        content
      );
      return {
        title: out.title,
        dek: out.dek,
        summary: out.summary,
        articleBody: out.articleBody,
        canonicalTags: out.canonicalTags,
        severity: out.severity,
        imageDescriptors: out.imageDescriptors || [],
        unverifiedNote:
          "Sourced from submitted SOS and map events; not independently verified.",
        actionables: out.actionables,
        dontDos: out.dontDos,
      };
    },

    async generateArticle(reports: MeshReport[]): Promise<ArticleDraft> {
      const meta = JSON.stringify(
        reports.map((r) => ({
          placeName: r.placeName,
          eventType: r.eventType,
          description: r.description,
          timestamp: r.timestamp,
          trustScore: r.trustScore,
        }))
      );

      const content: ContentBlock[] = [
        {
          type: "text",
          text: `Mesh crisis report metadata (JSON):\n${meta}\n\nUse any attached images only as unverified visual context. Describe what you see neutrally; do not invent facts not visible or in metadata. JSON shape: {"title","dek","summary","articleBody","canonicalTags","severity","imageDescriptors"} — imageDescriptors must include short factual captions for each image (what is visible). severity: low|medium|high|critical.`,
        },
      ];

      const seen = new Set<string>();
      for (const r of reports) {
        for (const url of r.imageUrls) {
          if (seen.size >= 4) break;
          if (seen.has(url)) continue;
          seen.add(url);
          if (url.startsWith("https://") || url.startsWith("http://")) {
            content.push({
              type: "image",
              source: { type: "url", url },
            });
          } else if (url.startsWith("data:")) {
            const block = dataUrlToImageBlock(url);
            if (block) content.push(block);
          }
        }
      }

      const out = await messagesJSON<{
        title: string;
        dek: string;
        summary: string;
        articleBody: string;
        canonicalTags: string[];
        severity: ArticleDraft["severity"];
        imageDescriptors: string[];
      }>(
        `You write factual, neutral local news from mesh crisis reports.`,
        content
      );
      return {
        ...out,
        unverifiedNote:
          "Sourced from community mesh reports and any submitted images; not independently verified.",
      };
    },

    async generateRecommendations(input: {
      stories: NewsStory[];
      areaLabel: string;
      mockExternal: boolean;
    }): Promise<RecommendationDraft> {
      const user = JSON.stringify({
        area: input.areaLabel,
        stories: input.stories.map((s) => ({
          title: s.title,
          summary: s.summary,
          severity: s.severity,
          tags: s.canonicalTags,
        })),
        mockExternal: input.mockExternal,
      });
      return chatJSON<RecommendationDraft>(
        `JSON only: {"actionable":[string,string,string],"avoid":[string,string,string],"rationale","confidence":"low"|"medium"|"high","externalSourceLabels":[strings]}. Actionable = safe routes, aid. Avoid = rumors, dangerous zones.`,
        user
      );
    },

    async generateEscalation(input: {
      storySummary: string;
      eventType: string;
      urgency: UrgencyLevel;
      incidentLat: number;
      incidentLng: number;
      placeName: string;
      helpType: string;
    }): Promise<EscalationDraftContent> {
      return chatJSON<EscalationDraftContent>(
        `Demo escalation only — not real 911. JSON: {"phoneScript","textMessage","authorityType"} authorityType one of police|fire|ems|municipal|utilities.`,
        JSON.stringify(input)
      );
    },
  };
}
