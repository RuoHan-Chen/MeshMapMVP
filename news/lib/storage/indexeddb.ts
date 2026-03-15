"use client";

import { openDB, type DBSchema, type IDBPDatabase } from "idb";
import type {
  EscalationDraft,
  MeshReport,
  NewsStory,
  RecommendationBrief,
} from "@/lib/types";
import type { MeshNewsRepository } from "@/lib/storage/repository";

interface MeshDB extends DBSchema {
  reports: { key: string; value: MeshReport };
  stories: { key: string; value: NewsStory };
  recommendations: { key: string; value: RecommendationBrief };
  escalations: { key: string; value: EscalationDraft };
}

const DB_NAME = "meshnews-v1";
const VERSION = 1;

let dbPromise: Promise<IDBPDatabase<MeshDB>> | null = null;

function getDb(): Promise<IDBPDatabase<MeshDB>> {
  if (!dbPromise) {
    dbPromise = openDB<MeshDB>(DB_NAME, VERSION, {
      upgrade(db) {
        db.createObjectStore("reports", { keyPath: "id" });
        db.createObjectStore("stories", { keyPath: "id" });
        db.createObjectStore("recommendations", { keyPath: "id" });
        db.createObjectStore("escalations", { keyPath: "id" });
      },
    });
  }
  return dbPromise;
}

export interface MeshNewsSnapshot {
  reports: MeshReport[];
  stories: NewsStory[];
  recommendations: RecommendationBrief[];
  escalations: EscalationDraft[];
  updatedAt?: string;
}

export async function exportSnapshot(): Promise<MeshNewsSnapshot> {
  const db = await getDb();
  const [reports, stories, recommendations, escalations] = await Promise.all([
    db.getAll("reports"),
    db.getAll("stories"),
    db.getAll("recommendations"),
    db.getAll("escalations"),
  ]);
  return {
    reports,
    stories,
    recommendations,
    escalations,
    updatedAt: new Date().toISOString(),
  };
}

/** Replace all stores (used after cloud pull). */
export async function importSnapshot(s: MeshNewsSnapshot): Promise<void> {
  const db = await getDb();
  const tx = db.transaction(
    ["reports", "stories", "recommendations", "escalations"],
    "readwrite"
  );
  await Promise.all([
    tx.objectStore("reports").clear(),
    tx.objectStore("stories").clear(),
    tx.objectStore("recommendations").clear(),
    tx.objectStore("escalations").clear(),
  ]);
  for (const r of s.reports || []) await tx.objectStore("reports").put(r);
  for (const x of s.stories || []) await tx.objectStore("stories").put(x);
  for (const b of s.recommendations || [])
    await tx.objectStore("recommendations").put(b);
  for (const e of s.escalations || [])
    await tx.objectStore("escalations").put(e);
  await tx.done;
}

export function createIndexedDBRepository(): MeshNewsRepository {
  return {
    async putReport(r: MeshReport) {
      const db = await getDb();
      await db.put("reports", r);
    },
    async listReports() {
      const db = await getDb();
      return db.getAll("reports");
    },
    async putStory(s: NewsStory) {
      const db = await getDb();
      await db.put("stories", s);
    },
    async listStories() {
      const db = await getDb();
      return db.getAll("stories");
    },
    async putRecommendation(b: RecommendationBrief) {
      const db = await getDb();
      await db.put("recommendations", b);
    },
    async listRecommendations() {
      const db = await getDb();
      return db.getAll("recommendations");
    },
    async putEscalation(e: EscalationDraft) {
      const db = await getDb();
      await db.put("escalations", e);
    },
    async listEscalations() {
      const db = await getDb();
      return db.getAll("escalations");
    },
  };
}
