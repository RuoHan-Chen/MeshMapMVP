import type { RecommendationBrief } from "@/lib/types";

const PREFIX = "meshnews:brief:";

declare global {
  // eslint-disable-next-line no-var
  var __meshnewsBriefStore: Map<string, RecommendationBrief> | undefined;
}

function memory(): Map<string, RecommendationBrief> {
  if (!globalThis.__meshnewsBriefStore) {
    globalThis.__meshnewsBriefStore = new Map();
  }
  return globalThis.__meshnewsBriefStore;
}

async function upstashSet(key: string, value: string): Promise<void> {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return;
  const ttl = Number(process.env.MESHNEWS_BRIEF_TTL_SEC) || 604800; // 7d
  const u = `${url.replace(/\/$/, "")}/set/${encodeURIComponent(key)}?EX=${ttl}`;
  await fetch(u, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(value),
  });
}

async function upstashGet(key: string): Promise<string | null> {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return null;
  const res = await fetch(`${url}/get/${encodeURIComponent(key)}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = (await res.json()) as { result: string | null };
  return data.result ?? null;
}

export async function saveRecommendationBrief(
  brief: RecommendationBrief
): Promise<void> {
  const key = PREFIX + brief.id;
  memory().set(brief.id, brief);
  const raw = JSON.stringify(brief);
  try {
    await upstashSet(key, raw);
  } catch (e) {
    console.warn("[MeshNews briefStore] Upstash set failed (using memory only)", e);
  }
}

export async function getRecommendationBrief(
  id: string
): Promise<RecommendationBrief | null> {
  const mem = memory().get(id);
  if (mem) return mem;
  try {
    const raw = await upstashGet(PREFIX + id);
    if (!raw) return null;
    return JSON.parse(raw) as RecommendationBrief;
  } catch {
    return null;
  }
}
