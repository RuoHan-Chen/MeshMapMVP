"use client";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  exportSnapshot,
  importSnapshot,
  type MeshNewsSnapshot,
} from "@/lib/storage/indexeddb";

const TABLE = "meshnews_demo";

/** Prefer publishable key (sb_publishable_…); legacy JWT anon still works */
function supabasePublicKey(): string {
  return (
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim() ||
    ""
  );
}

export function cloudSyncConfigured(): boolean {
  return Boolean(
    process.env.NEXT_PUBLIC_SUPABASE_URL?.trim() && supabasePublicKey()
  );
}

function client(): SupabaseClient | null {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const key = supabasePublicKey();
  if (!url || !key) return null;
  return createClient(url, key);
}

/** Shared document id — same room = same data across browsers */
export function syncRoomId(): string {
  if (typeof window === "undefined") return "demo";
  return localStorage.getItem("meshnews-sync-room") || "demo";
}

export function setSyncRoomId(id: string) {
  const s = id.trim().slice(0, 64) || "demo";
  localStorage.setItem("meshnews-sync-room", s);
}

export async function pullFromCloud(): Promise<MeshNewsSnapshot | null> {
  const supa = client();
  const room = syncRoomId();
  if (!supa) return null;
  const { data, error } = await supa
    .from(TABLE)
    .select("payload, updated_at")
    .eq("id", room)
    .maybeSingle();
  if (error) {
    console.warn("[MeshNews sync] pull", error.message);
    return null;
  }
  if (!data?.payload) return null;
  const p = data.payload as MeshNewsSnapshot;
  return {
    reports: p.reports || [],
    stories: p.stories || [],
    recommendations: p.recommendations || [],
    escalations: p.escalations || [],
    updatedAt: data.updated_at as string,
  };
}

export async function pushToCloud(): Promise<boolean> {
  const supa = client();
  const room = syncRoomId();
  if (!supa) return false;
  const snapshot = await exportSnapshot();
  const payload = {
    reports: snapshot.reports,
    stories: snapshot.stories,
    recommendations: snapshot.recommendations,
    escalations: snapshot.escalations,
  };
  const { error } = await supa.from(TABLE).upsert(
    {
      id: room,
      payload,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "id" }
  );
  if (error) {
    console.warn("[MeshNews sync] push", error.message);
    return false;
  }
  return true;
}

let pushTimer: ReturnType<typeof setTimeout> | null = null;
export function schedulePushToCloud(debounceMs = 1200) {
  if (!cloudSyncConfigured()) return;
  if (pushTimer) clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    pushTimer = null;
    void pushToCloud();
  }, debounceMs);
}
