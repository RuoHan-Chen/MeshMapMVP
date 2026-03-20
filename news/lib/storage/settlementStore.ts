type Json = unknown;

declare global {
  // eslint-disable-next-line no-var
  var __meshchatSettlementStore: Map<string, string> | undefined;
}

function memory(): Map<string, string> {
  if (!globalThis.__meshchatSettlementStore) {
    globalThis.__meshchatSettlementStore = new Map();
  }
  return globalThis.__meshchatSettlementStore;
}

function upstashEnabled(): boolean {
  return Boolean(process.env.UPSTASH_REDIS_REST_URL && process.env.UPSTASH_REDIS_REST_TOKEN);
}

async function upstashSet(key: string, value: string): Promise<void> {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return;
  const ttl = Number(process.env.MESHCHAT_SETTLEMENT_TTL_SEC) || 60 * 60 * 24 * 30; // 30d
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

export async function setJson<T extends Json>(key: string, value: T): Promise<void> {
  const raw = JSON.stringify(value);
  memory().set(key, raw);
  if (!upstashEnabled()) return;
  try {
    await upstashSet(key, raw);
  } catch {
    // If Redis fails, fall back to in-memory.
  }
}

export async function getJson<T>(key: string): Promise<T | null> {
  const mem = memory().get(key);
  if (mem) return JSON.parse(mem) as T;
  if (!upstashEnabled()) return null;
  try {
    const raw = await upstashGet(key);
    if (!raw) return null;
    memory().set(key, raw);
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

