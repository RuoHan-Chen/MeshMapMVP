"use client";

import { useCallback, useEffect, useState } from "react";
import { createIndexedDBRepository } from "@/lib/storage/indexeddb";
import type {
  EscalationDraft,
  MeshReport,
  NewsStory,
  RecommendationBrief,
} from "@/lib/types";
import { seedReports, seedStoryFromReport } from "@/lib/mock/seed";
import { normalizeIngestBody } from "@/lib/services/reportIngest";
import {
  meshReportForGenerateApi,
  storiesForGenerateApi,
} from "@/lib/utils/apiPayload";
import Link from "next/link";
import { useCloudSync } from "@/components/CloudSyncProvider";
import { setSyncRoomId } from "@/lib/storage/cloudSync";
import { fileToVisionSafeDataUrl } from "@/lib/utils/imageCompress";
import { normalizeImageDescriptor } from "@/lib/utils/imageDescriptors";

const repo = createIndexedDBRepository();
const MODE_KEY = "meshnews-mode";

type Mode = "consumer" | "developer";
type DevTab =
  | "ingest"
  | "import"
  | "reports"
  | "stories"
  | "recommendations"
  | "escalation";

function formatTime(iso: string) {
  try {
    return new Date(iso).toLocaleString(undefined, {
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

export default function MeshNewsDashboard() {
  const [mode, setMode] = useState<Mode>("consumer");
  const [devTab, setDevTab] = useState<DevTab>("ingest");
  const [reports, setReports] = useState<MeshReport[]>([]);
  const [stories, setStories] = useState<NewsStory[]>([]);
  const [briefs, setBriefs] = useState<RecommendationBrief[]>([]);
  const [escalations, setEscalations] = useState<EscalationDraft[]>([]);
  const [loading, setLoading] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [selectedStory, setSelectedStory] = useState<NewsStory | null>(null);
  const [smsTo, setSmsTo] = useState("+61452581119");
  const sync = useCloudSync();
  const bumpCloud = () => sync?.notifyLocalChange();

  useEffect(() => {
    const saved = localStorage.getItem(MODE_KEY) as Mode | null;
    if (saved === "developer" || saved === "consumer") setMode(saved);
  }, []);

  const setModePersist = (m: Mode) => {
    setMode(m);
    localStorage.setItem(MODE_KEY, m);
    setMsg(null);
  };

  const refresh = useCallback(async () => {
    const [r, s, b, e] = await Promise.all([
      repo.listReports(),
      repo.listStories(),
      repo.listRecommendations(),
      repo.listEscalations(),
    ]);
    setReports(r.sort((a, b) => b.timestamp.localeCompare(a.timestamp)));
    setStories(s.sort((a, b) => b.createdAt.localeCompare(a.createdAt)));
    setBriefs(b.sort((a, b) => b.generatedAt.localeCompare(a.generatedAt)));
    setEscalations(e.sort((a, b) => b.createdAt.localeCompare(a.createdAt)));
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    const onPull = () => void refresh();
    window.addEventListener("meshnews-sync-pull", onPull);
    return () => window.removeEventListener("meshnews-sync-pull", onPull);
  }, [refresh]);

  async function seedDemo() {
    setLoading(true);
    for (const r of seedReports()) await repo.putReport(r);
    await repo.putStory(seedStoryFromReport(seedReports()[0]));
    setMsg("Sample data added.");
    await refresh();
    bumpCloud();
    setLoading(false);
  }

  const DEFAULT_GENERATE = `{
  "news_id": "550e8400-e29b-41d4-a716-446655440000",
  "sos": {
    "title": "Medical emergency — need ambulance",
    "description": "Caller reports chest pain; conscious; street corner.",
    "latitude": -33.9173,
    "longitude": 151.2276
  },
  "events": [
    {
      "title": "Road closure",
      "description": "Local mesh: King St blocked both directions.",
      "latitude": -33.918,
      "longitude": 151.228,
      "image": { "data": "<base64 string>", "mime_type": "image/jpeg" }
    },
    {
      "title": "Power flicker",
      "description": "Reports of brief outage two blocks east.",
      "latitude": -33.9165,
      "longitude": 151.226
    }
  ],
  "send_sos_sms": false
}`;

  async function submitGenerateJson(raw: string) {
    setLoading(true);
    setMsg(null);
    try {
      const body = JSON.parse(raw) as {
        news_id: string;
        sos: {
          title: string;
          description: string;
          latitude: number;
          longitude: number;
        };
        events?: Array<{
          title: string;
          description: string;
          latitude: number;
          longitude: number;
          image?: { data: string; mime_type?: string };
        }>;
        send_sos_sms?: boolean;
        authoritySmsTo?: string;
        images?: string[];
      };
      const fileInput = document.getElementById(
        "generate-images"
      ) as HTMLInputElement | null;
      const files = fileInput?.files;
      if (files?.length) {
        const urls: string[] = [];
        for (let i = 0; i < Math.min(files.length, 4); i++) {
          const f = files[i];
          if (!f.type.startsWith("image/")) continue;
          urls.push(await fileToVisionSafeDataUrl(f));
        }
        body.images = [...(body.images || []), ...urls].slice(0, 4);
      }
      const gen = await fetch("/api/stories/generate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const genData = await gen.json();
      if (genData.ok && genData.story) {
        await repo.putStory(genData.story as NewsStory);
        bumpCloud();
        let tail = `Story ${genData.story.id}. GET actionables: ${genData.recommendations_url || "/api/recommendations/" + genData.story.newsId}`;
        const sms = genData.authoritySms as
          | { sent?: boolean; error?: string; sid?: string }
          | undefined;
        if (body.send_sos_sms) {
          if (sms?.sent) tail += ` · SMS sent ${sms.sid?.slice(0, 10)}…`;
          else if (sms?.error) tail += ` · SMS: ${sms.error}`;
        }
        setMsg(tail);
      } else {
        setMsg(genData.error || "Generate failed");
      }
    } catch (e) {
      setMsg(String(e));
    }
    await refresh();
    setLoading(false);
  }

  async function importMeshExportJson(raw: string) {
    setLoading(true);
    setMsg(null);
    try {
      const res = await fetch("/api/import/export", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: raw,
      });
      const data = await res.json();
      if (!data.ok || !Array.isArray(data.reports)) {
        setMsg(data.error || "Import failed.");
        setLoading(false);
        return;
      }
      let storiesCreated = 0;
      for (const report of data.reports as MeshReport[]) {
        await repo.putReport(report);
        bumpCloud();
        const existing = await repo.listStories();
        const gen = await fetch("/api/stories/generate", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            reports: [meshReportForGenerateApi(report)],
            existingStories: storiesForGenerateApi(existing),
          }),
        });
        const genData = await gen.json();
        if (genData.ok && genData.story) {
          const story: NewsStory = genData.story;
          story.imageUrls = [
            ...new Set([...(story.imageUrls ?? []), ...report.imageUrls]),
          ];
          await repo.putStory(story);
          bumpCloud();
          storiesCreated++;
        }
      }
      setMsg(
        `Imported ${data.reports.length} feature(s), ${storiesCreated} story update(s). Export: ${data.exportId}`
      );
      await refresh();
    } catch (e) {
      setMsg(String(e));
    }
    setLoading(false);
  }

  async function runRecommendations() {
    setLoading(true);
    const s = await repo.listStories();
    const res = await fetch("/api/recommendations", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        stories: storiesForGenerateApi(s),
        mockExternal: true,
      }),
    });
    const data = await res.json();
    if (data.ok && data.brief) {
      await repo.putRecommendation(data.brief);
      bumpCloud();
      setMsg(
        `Safety brief saved. id=${data.id} — GET /api/recommendations/${data.id}`
      );
    } else setMsg(data.error || "Failed.");
    await refresh();
    setLoading(false);
  }

  async function runEscalation(sendSms?: boolean) {
    if (!selectedStory) {
      setMsg("Select a story first.");
      return;
    }
    if (sendSms && !/^(\+|04)\d{8,}$/.test(smsTo.replace(/\s/g, ""))) {
      setMsg("SMS To: E.164 (+61452581119) or 0452581119");
      return;
    }
    setLoading(true);
    const res = await fetch("/api/escalate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        story: { ...selectedStory, imageUrls: [] },
        urgency: "urgent",
        callerLat: selectedStory.latitude,
        callerLng: selectedStory.longitude,
        helpType: "welfare check / situation update",
        sendSms: !!sendSms,
        smsTo: sendSms ? smsTo.replace(/\s/g, "").trim() : undefined,
      }),
    });
    const data = await res.json();
    if (data.ok && data.draft) {
      await repo.putEscalation(data.draft);
      bumpCloud();
    }
    await refresh();
    setLoading(false);
    if (data.sms?.sent) setMsg(`Draft saved. SMS sent. Twilio sid=${data.sms.sid}`);
    else if (data.sms?.error && sendSms)
      setMsg(`Draft saved. SMS failed: ${data.sms.error}`);
    else setMsg("Draft saved.");
  }

  const inputClass =
    "mt-1 w-full border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 focus:border-neutral-500 focus:outline-none focus:ring-1 focus:ring-neutral-400";

  /* ——— Consumer: news-style home ——— */
  if (mode === "consumer") {
    return (
      <div className="min-h-screen bg-white text-neutral-900">
        <header className="border-b border-neutral-200 bg-white">
          <div className="mx-auto max-w-3xl px-4 py-4 sm:px-6">
            <div className="flex flex-wrap items-baseline justify-between gap-3 border-b border-neutral-900 pb-3">
              <div>
                <h1 className="text-2xl font-bold tracking-tight text-neutral-900 sm:text-3xl">
                  MeshNews
                </h1>
              </div>
              <button
                type="button"
                onClick={() => setModePersist("developer")}
                className="text-xs text-neutral-500 underline decoration-neutral-300 underline-offset-2 hover:text-neutral-800"
              >
                Developer
              </button>
            </div>
          </div>
        </header>

        <main className="mx-auto max-w-3xl px-4 py-8 sm:px-6">
          {msg && (
            <p className="mb-6 border-l-4 border-[#c8102e] bg-neutral-50 py-2 pl-3 text-sm text-neutral-700">
              {msg}
            </p>
          )}

          <section className="mb-12">
            <h2 className="mb-4 text-xs font-semibold uppercase tracking-wider text-neutral-500">
              Latest
            </h2>
            {stories.length === 0 ? (
              <p className="text-sm text-neutral-600">
                No stories yet. Switch to Developer mode to add sample data or
                submit a report.
              </p>
            ) : (
              <ul className="divide-y divide-neutral-200 border-t border-neutral-200">
                {stories.map((s) => (
                  <li key={s.id}>
                    <Link
                      href={`/story/${encodeURIComponent(s.id)}`}
                      className="flex gap-4 py-4 text-left hover:bg-neutral-50"
                    >
                      {(s.imageUrls?.[0] ?? "").length > 0 && (
                        <div className="h-20 w-28 shrink-0 overflow-hidden border border-neutral-200 bg-neutral-100">
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img
                            src={(s.imageUrls ?? [])[0].slice(0, 6_000_000)}
                            alt=""
                            className="h-full w-full object-cover"
                          />
                        </div>
                      )}
                      <div className="min-w-0 flex-1">
                        <span className="text-xs text-neutral-500">
                          {formatTime(s.createdAt)}
                        </span>
                        <h3 className="mt-1 text-lg font-semibold leading-snug text-neutral-900">
                          {s.title}
                        </h3>
                        <p className="mt-1 line-clamp-2 text-sm text-neutral-600">
                          {s.summary}
                        </p>
                      </div>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </main>
      </div>
    );
  }

  /* ——— Developer: plain tools, no flashy UI ——— */
  return (
    <div className="min-h-screen bg-neutral-50 text-neutral-900">
      <header className="border-b border-neutral-200 bg-white">
        <div className="mx-auto flex max-w-4xl flex-wrap items-center justify-between gap-3 px-4 py-3">
          <div>
            <span className="text-lg font-bold">MeshNews</span>
            <span className="ml-2 text-xs text-neutral-500">Developer</span>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <button
              type="button"
              onClick={() => setModePersist("consumer")}
              className="text-sm text-neutral-600 underline"
            >
              Consumer view
            </button>
            <button
              type="button"
              onClick={seedDemo}
              disabled={loading}
              className="text-sm text-neutral-700 disabled:opacity-50"
            >
              Load sample data
            </button>
            <button
              type="button"
              onClick={refresh}
              className="text-sm text-neutral-700"
            >
              Refresh
            </button>
          </div>
        </div>
        <nav className="mx-auto flex max-w-4xl gap-0 border-t border-neutral-100 bg-white px-4 text-sm">
          {(
            [
              ["ingest", "Generate news"],
              ["import", "Import export"],
              ["reports", "Raw reports"],
              ["stories", "Stories"],
              ["recommendations", "Safety brief"],
              ["escalation", "Escalation demo"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              type="button"
              onClick={() => setDevTab(id)}
              className={`border-b-2 px-3 py-2 ${
                devTab === id
                  ? "border-[#c8102e] font-medium text-neutral-900"
                  : "border-transparent text-neutral-600 hover:text-neutral-900"
              }`}
            >
              {label}
            </button>
          ))}
        </nav>
        {sync?.syncOn && (
          <div className="mx-auto flex max-w-4xl flex-wrap items-center gap-2 border-t border-sky-100 bg-sky-50 px-4 py-2 text-xs text-sky-900">
            <strong>Shared demo</strong>
            <span>Room</span>
            <input
              defaultValue={sync.room}
              className="w-28 rounded border border-sky-200 px-1 font-mono"
              onBlur={(e) => {
                setSyncRoomId(e.target.value);
                window.dispatchEvent(new Event("meshnews-sync-room"));
                void sync.pullNow();
              }}
            />
            <button
              type="button"
              className="rounded bg-sky-700 px-2 py-0.5 text-white"
              onClick={() => void sync.pullNow().then(() => refresh())}
            >
              Pull now
            </button>
            <span className="text-sky-700">
              Auto sync ~10s · same room = same data in every browser
            </span>
          </div>
        )}
      </header>

      <main className="mx-auto max-w-4xl px-4 py-6">
        {msg && (
          <p className="mb-4 border-l-4 border-neutral-400 bg-white py-2 pl-3 text-sm">
            {msg}
          </p>
        )}

        {devTab === "ingest" && (
          <section className="rounded border border-neutral-200 bg-white p-6">
            <h2 className="mb-1 text-base font-semibold">Generate news</h2>
            <p className="mb-4 text-xs text-neutral-500">
              <code className="rounded bg-neutral-100 px-1">news_id</code> (UUID)
              = story id and{" "}
              <code className="rounded bg-neutral-100 px-1">
                GET /api/recommendations/[news_id]
              </code>
              . One <strong>sos</strong> (title, description, location) → one SMS
              when <code className="rounded bg-neutral-100 px-1">send_sos_sms</code>
              . Many <strong>events</strong> → map pins only. Article includes 3
              actionables + 3 don&apos;ts. Per-event photos:{" "}
              <code className="rounded bg-neutral-100 px-1">events[].image</code>{" "}
              = <code className="rounded bg-neutral-100 px-1">{`{ "data": "<base64>", "mime_type": "image/jpeg" }`}</code>
              . Or use file picker to add top-level <code className="rounded bg-neutral-100 px-1">images</code> (data URLs).
            </p>
            <label className="mb-3 block text-xs font-medium text-neutral-700">
              Or attach photos here (top-level <code className="rounded bg-neutral-100 px-1">images</code>)
              <input
                id="generate-images"
                type="file"
                accept="image/*"
                multiple
                className="mt-1 block w-full text-xs"
              />
            </label>
            <textarea
              id="generate-json"
              rows={22}
              className="w-full border border-neutral-300 bg-white p-3 font-mono text-xs"
              defaultValue={DEFAULT_GENERATE}
            />
            <div className="mt-3 flex flex-wrap gap-2">
              <button
                type="button"
                disabled={loading}
                className="bg-neutral-900 px-4 py-2 text-sm text-white disabled:opacity-50"
                onClick={async () => {
                  const el = document.getElementById(
                    "generate-json"
                  ) as HTMLTextAreaElement | null;
                  await submitGenerateJson(el?.value || "{}");
                }}
              >
                {loading ? "…" : "Generate & save story"}
              </button>
              <a
                className="border border-neutral-300 px-4 py-2 text-sm hover:bg-neutral-50"
                href="/api/twilio/status"
                target="_blank"
                rel="noreferrer"
              >
                Twilio status
              </a>
            </div>
          </section>
        )}

        {devTab === "import" && (
          <section className="rounded border border-neutral-200 bg-white p-6">
            <h2 className="mb-1 text-base font-semibold">Import mesh export</h2>
            <p className="mb-4 text-xs text-neutral-500">
              Paste JSON matching{" "}
              <code className="rounded bg-neutral-100 px-1">
                {"{ export: { id, crs, featureCollection } }"}
              </code>
              . Each Point feature becomes a report and triggers story generation
              (images use <code className="rounded bg-neutral-100 px-1">properties.image.url</code> when present).
            </p>
            <textarea
              id="mesh-export-json"
              rows={14}
              className="w-full border border-neutral-300 bg-white p-3 font-mono text-xs"
              placeholder='{ "export": { "id": "...", "createdAt": "...", "crs": "EPSG:4326", "featureCollection": { "type": "FeatureCollection", "features": [] } } }'
              defaultValue=""
            />
            <div className="mt-3 flex flex-wrap gap-2">
              <button
                type="button"
                disabled={loading}
                className="bg-neutral-900 px-4 py-2 text-sm text-white disabled:opacity-50"
                onClick={async () => {
                  const el = document.getElementById(
                    "mesh-export-json"
                  ) as HTMLTextAreaElement | null;
                  await importMeshExportJson(el?.value?.trim() || "{}");
                }}
              >
                Import &amp; build stories
              </button>
              <label className="cursor-pointer border border-neutral-300 bg-white px-4 py-2 text-sm hover:bg-neutral-50">
                Choose JSON file
                <input
                  type="file"
                  accept=".json,application/json"
                  className="hidden"
                  onChange={async (e) => {
                    const f = e.target.files?.[0];
                    if (!f) return;
                    const text = await f.text();
                    const el = document.getElementById(
                      "mesh-export-json"
                    ) as HTMLTextAreaElement | null;
                    if (el) el.value = text;
                  }}
                />
              </label>
            </div>
          </section>
        )}

        {devTab === "reports" && (
          <section>
            <h2 className="mb-3 text-base font-semibold">Raw reports</h2>
            <div className="space-y-3">
              {reports.map((r) => (
                <div
                  key={r.id}
                  className="border border-neutral-200 bg-white p-4 text-sm"
                >
                  {r.imageUrls[0] && (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={r.imageUrls[0].slice(0, 5000)}
                      alt=""
                      className="mb-2 h-24 w-full max-w-xs object-cover"
                    />
                  )}
                  <p className="font-medium">{r.eventType}</p>
                  <p className="text-neutral-600">{r.description}</p>
                  <p className="mt-1 text-xs text-neutral-500">
                    {r.placeName} · {r.sourcePeerId} · trust{" "}
                    {(r.trustScore * 100).toFixed(0)}%
                  </p>
                  <p className="text-xs text-neutral-400">{r.timestamp}</p>
                </div>
              ))}
            </div>
            {reports.length === 0 && (
              <p className="text-sm text-neutral-500">No reports.</p>
            )}
          </section>
        )}

        {devTab === "stories" && (
          <section>
            <h2 className="mb-3 text-base font-semibold">Stories</h2>
            <ul className="space-y-2">
              {stories.map((s) => (
                <li key={s.id}>
                  <button
                    type="button"
                    onClick={() => setSelectedStory(s)}
                    className={`flex w-full gap-3 border p-3 text-left text-sm ${
                      selectedStory?.id === s.id
                        ? "border-neutral-900 bg-neutral-100"
                        : "border-neutral-200 bg-white hover:bg-neutral-50"
                    }`}
                  >
                    {(s.imageUrls?.[0] ?? "").length > 0 && (
                      <div className="h-16 w-24 shrink-0 overflow-hidden border border-neutral-200 bg-neutral-100">
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img
                          src={(s.imageUrls ?? [])[0].slice(0, 6_000_000)}
                          alt=""
                          className="h-full w-full object-cover"
                        />
                      </div>
                    )}
                    <div className="min-w-0 flex-1">
                      <span className="text-xs text-neutral-500">
                        {s.severity} · {s.sourceCount} sources · {s.areaHash}
                      </span>
                      <p className="font-medium">{s.title}</p>
                      <p className="text-neutral-600">{s.dek}</p>
                      <Link
                        href={`/story/${encodeURIComponent(s.id)}`}
                        className="mt-1 inline-block text-xs underline"
                        onClick={(e) => e.stopPropagation()}
                      >
                        Open article page
                      </Link>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
            {selectedStory && (
              <div className="mt-4 border border-neutral-200 bg-white p-4 text-sm">
                <h3 className="font-semibold">{selectedStory.title}</h3>
                {(selectedStory.imageUrls ?? []).map((src, i) => (
                  <div key={i} className="mt-3 max-w-md border border-neutral-200">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img
                      src={src.slice(0, 6_000_000)}
                      alt=""
                      className="max-h-48 w-full object-contain"
                    />
                  </div>
                ))}
                <p className="mt-2 text-neutral-700">{selectedStory.summary}</p>
                <pre className="mt-3 max-h-48 overflow-auto whitespace-pre-wrap text-xs text-neutral-600">
                  {selectedStory.articleBody}
                </pre>
                <p className="mt-2 text-xs text-neutral-500">
                  Tags: {selectedStory.canonicalTags.join(", ")}
                </p>
              </div>
            )}
            {stories.length === 0 && (
              <p className="text-sm text-neutral-500">No stories.</p>
            )}
          </section>
        )}

        {devTab === "recommendations" && (
          <section className="space-y-4">
            <div className="flex items-center gap-3">
              <button
                type="button"
                onClick={runRecommendations}
                disabled={loading}
                className="bg-neutral-900 px-3 py-2 text-sm text-white disabled:opacity-50"
              >
                Generate safety brief
              </button>
              <span className="text-xs text-neutral-500">
                From current stories (mock external OK)
              </span>
            </div>
            {briefs.map((b) => (
              <div
                key={b.id}
                className="border border-neutral-200 bg-white p-4 text-sm"
              >
                <p className="text-xs text-neutral-500">
                  {b.area} · confidence: {b.confidence}
                </p>
                <p className="mt-2">{b.rationale}</p>
                <div className="mt-4 grid gap-4 sm:grid-cols-2">
                  <div>
                    <p className="text-xs font-semibold uppercase text-neutral-500">
                      Actionable
                    </p>
                    <ol className="mt-1 list-decimal pl-4">
                      {b.actionableRecommendations.map((x, i) => (
                        <li key={i}>{x}</li>
                      ))}
                    </ol>
                  </div>
                  <div>
                    <p className="text-xs font-semibold uppercase text-neutral-500">
                      Avoid
                    </p>
                    <ol className="mt-1 list-decimal pl-4">
                      {b.avoidRecommendations.map((x, i) => (
                        <li key={i}>{x}</li>
                      ))}
                    </ol>
                  </div>
                </div>
              </div>
            ))}
            {briefs.length === 0 && (
              <p className="text-sm text-neutral-500">No briefs yet.</p>
            )}
          </section>
        )}

        {devTab === "escalation" && (
          <section className="space-y-4">
            <p className="border border-amber-200 bg-amber-50 p-3 text-xs text-neutral-800">
              <strong>Twilio:</strong> set{" "}
              <code className="rounded bg-white px-1">TWILIO_ACCOUNT_SID</code>,{" "}
              <code className="rounded bg-white px-1">TWILIO_AUTH_TOKEN</code> (or{" "}
              <code className="rounded bg-white px-1">TWILIO_SECRET_KEY</code>),{" "}
              <code className="rounded bg-white px-1">TWILIO_PHONE_NUMBER</code>.
              Trial accounts only SMS <strong>verified</strong> numbers. Use only
              where legal.
            </p>
            <label className="block text-xs font-medium text-neutral-700">
              SMS To (E.164)
              <input
                value={smsTo}
                onChange={(e) => setSmsTo(e.target.value)}
                placeholder="+61452581119 or 0452581119"
                className={inputClass}
              />
            </label>
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                onClick={() => runEscalation(false)}
                disabled={loading || !selectedStory}
                className="bg-neutral-200 px-3 py-2 text-sm disabled:opacity-40"
              >
                Draft only
              </button>
              <button
                type="button"
                onClick={() => runEscalation(true)}
                disabled={loading || !selectedStory}
                className="bg-neutral-900 px-3 py-2 text-sm text-white disabled:opacity-40"
              >
                Draft + send SMS (AI text)
              </button>
            </div>
            <p className="text-xs text-neutral-500">
              Select a story first. SMS body = AI-generated escalation text.
            </p>
            {escalations.map((e) => (
              <div
                key={e.id}
                className="border border-neutral-200 bg-white p-4 text-xs"
              >
                <p>
                  {e.authorityType} · {e.urgencyLevel}
                </p>
                <p className="mt-2 font-medium">SMS</p>
                <p className="text-neutral-700">{e.textMessage}</p>
                <p className="mt-2 font-medium">Call script</p>
                <p className="text-neutral-700">{e.phoneScript}</p>
              </div>
            ))}
          </section>
        )}
      </main>
    </div>
  );
}
