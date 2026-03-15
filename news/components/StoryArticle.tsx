"use client";

import dynamic from "next/dynamic";
import Link from "next/link";
import { use, useCallback, useEffect, useState } from "react";
import { createIndexedDBRepository } from "@/lib/storage/indexeddb";
import type { NewsStory } from "@/lib/types";
import { normalizeImageDescriptor } from "@/lib/utils/imageDescriptors";

const IncidentMap = dynamic(() => import("@/components/IncidentMap"), {
  ssr: false,
  loading: () => (
    <div className="flex h-[320px] items-center justify-center rounded border border-neutral-200 bg-neutral-50 text-sm text-neutral-500">
      Loading map…
    </div>
  ),
});

const repo = createIndexedDBRepository();

function formatTime(iso: string) {
  try {
    return new Date(iso).toLocaleString(undefined, {
      day: "numeric",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

export default function StoryArticle({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const [story, setStory] = useState<NewsStory | null>(null);
  const [ready, setReady] = useState(false);

  const loadStory = useCallback(async () => {
    const stories = await repo.listStories();
    const s = stories.find((x) => x.id === id) ?? null;
    setStory(s);
    setReady(true);
  }, [id]);

  useEffect(() => {
    void loadStory();
  }, [loadStory]);

  useEffect(() => {
    const onPull = () => void loadStory();
    window.addEventListener("meshnews-sync-pull", onPull);
    return () => window.removeEventListener("meshnews-sync-pull", onPull);
  }, [loadStory]);

  if (!ready) {
    return (
      <div className="min-h-screen bg-white px-4 py-12 text-center text-neutral-600">
        Loading…
      </div>
    );
  }

  if (!story) {
    return (
      <div className="min-h-screen bg-white px-4 py-12 text-center">
        <p className="text-neutral-600">Story not found.</p>
        <Link href="/" className="mt-4 inline-block text-sm underline">
          Home
        </Link>
      </div>
    );
  }

  const images = story.imageUrls?.length ? story.imageUrls : [];
  const newsId = story.newsId || story.id;
  const actionables = story.actionables || [
    "Follow official alerts for your area.",
    "Help others only when safe.",
    "Keep devices charged for updates.",
  ];
  const dontDos = story.dontDos || [
    "Do not spread unverified rumors.",
    "Do not enter unsafe zones.",
    "Do not misuse emergency numbers.",
  ];

  return (
    <div className="min-h-screen bg-white text-neutral-900">
      <header className="border-b border-neutral-200 px-4 py-4 sm:px-6">
        <div className="mx-auto max-w-2xl">
          <Link
            href="/"
            className="text-sm text-neutral-600 underline underline-offset-2 hover:text-neutral-900"
          >
            ← Latest
          </Link>
          <h1 className="mt-3 text-2xl font-bold leading-tight sm:text-3xl">
            MeshNews
          </h1>
        </div>
      </header>

      <article className="mx-auto max-w-2xl px-4 py-8 sm:px-6">
        <p className="text-xs text-neutral-500">{formatTime(story.createdAt)}</p>
        <p className="mt-1 font-mono text-xs text-neutral-400">
          news_id · {newsId}
        </p>
        <h2 className="mt-2 text-2xl font-bold leading-tight text-neutral-900 sm:text-3xl">
          {story.title}
        </h2>
        <p className="mt-2 text-base text-neutral-600">{story.dek}</p>

        {story.mapIncidents && (
          <section className="mt-8">
            <h3 className="text-xs font-semibold uppercase tracking-wider text-neutral-500">
              Incident map
            </h3>
            <p className="mt-1 text-xs text-neutral-500">
              Red = SOS (one message to authorities). Blue = other reported
              events.
            </p>
            <div className="mt-3">
              <IncidentMap data={story.mapIncidents} />
            </div>
          </section>
        )}

        {story.sosSubmitted && story.sosLocation && !story.mapIncidents && (
          <div
            className="mt-4 rounded border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-950"
            role="status"
          >
            <p className="font-semibold">SOS</p>
            <p className="mt-1 font-mono text-red-900">
              {story.sosLocation.latitude.toFixed(5)},{" "}
              {story.sosLocation.longitude.toFixed(5)}
            </p>
            <a
              className="mt-2 inline-block text-red-800 underline"
              href={`https://www.google.com/maps?q=${story.sosLocation.latitude},${story.sosLocation.longitude}`}
              target="_blank"
              rel="noreferrer"
            >
              Maps
            </a>
          </div>
        )}

        <section className="mt-8 grid gap-6 sm:grid-cols-2">
          <div className="rounded border border-emerald-200 bg-emerald-50 p-4">
            <h3 className="text-sm font-semibold text-emerald-900">
              What to do (3)
            </h3>
            <ol className="mt-2 list-decimal space-y-2 pl-4 text-sm text-emerald-950">
              {actionables.map((a, i) => (
                <li key={i}>{a}</li>
              ))}
            </ol>
          </div>
          <div className="rounded border border-amber-200 bg-amber-50 p-4">
            <h3 className="text-sm font-semibold text-amber-950">
              What not to do (3)
            </h3>
            <ol className="mt-2 list-decimal space-y-2 pl-4 text-sm text-amber-950">
              {dontDos.map((a, i) => (
                <li key={i}>{a}</li>
              ))}
            </ol>
          </div>
        </section>

        {images.length > 0 && (
          <div className="mt-8 space-y-4">
            {images.map((src, i) => (
              <figure
                key={i}
                className="overflow-hidden border border-neutral-200 bg-neutral-50"
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={src.slice(0, 6_000_000)}
                  alt=""
                  className="max-h-[480px] w-full object-contain"
                />
                {normalizeImageDescriptor(story.imageDescriptors[i]) && (
                  <figcaption className="border-t border-neutral-200 px-3 py-2 text-xs text-neutral-600">
                    {normalizeImageDescriptor(story.imageDescriptors[i])}
                  </figcaption>
                )}
              </figure>
            ))}
          </div>
        )}

        <div className="prose prose-neutral mt-8 max-w-none text-base leading-relaxed text-neutral-800 prose-p:my-4">
          {String(story.articleBody ?? "")
            .split("\n\n")
            .filter(Boolean)
            .map((p, i) => (
              <p key={i}>{p.replace(/\*\*/g, "")}</p>
            ))}
        </div>
      </article>
    </div>
  );
}
