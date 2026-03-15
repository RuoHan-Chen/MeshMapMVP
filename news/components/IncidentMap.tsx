"use client";

import type { NewsStoryMapIncidents } from "@/lib/types";
import { useEffect, useRef } from "react";

import "leaflet/dist/leaflet.css";

export default function IncidentMap({ data }: { data: NewsStoryMapIncidents }) {
  const ref = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("leaflet").Map | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const L = (await import("leaflet")).default;
      if (cancelled || !ref.current) return;
      if (mapRef.current) {
        mapRef.current.remove();
        mapRef.current = null;
      }
      const points: [number, number][] = [
        [data.sos.latitude, data.sos.longitude],
        ...data.events.map((e) => [e.latitude, e.longitude] as [number, number]),
      ];
      const map = L.map(ref.current);
      mapRef.current = map;
      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: "&copy; OpenStreetMap",
      }).addTo(map);

      const bounds = L.latLngBounds(points);
      map.fitBounds(bounds.pad(0.25));

      const red = L.divIcon({
        className: "",
        html: `<div style="width:14px;height:14px;background:#b91c1c;border:2px solid #fff;border-radius:50%;box-shadow:0 1px 4px rgba(0,0,0,.4)"></div>`,
        iconSize: [14, 14],
        iconAnchor: [7, 7],
      });
      const blue = L.divIcon({
        className: "",
        html: `<div style="width:12px;height:12px;background:#1d4ed8;border:2px solid #fff;border-radius:50%;box-shadow:0 1px 4px rgba(0,0,0,.4)"></div>`,
        iconSize: [12, 12],
        iconAnchor: [6, 6],
      });

      L.marker([data.sos.latitude, data.sos.longitude], { icon: red })
        .addTo(map)
        .bindPopup(
          `<strong>SOS</strong><br/>${escapeHtml(data.sos.title)}<br/><small>${escapeHtml(data.sos.description).slice(0, 300)}</small>`
        );

      data.events.forEach((e) => {
        let popup = `<strong>${escapeHtml(e.title)}</strong><br/><small>${escapeHtml(e.description).slice(0, 280)}</small>`;
        if (e.image?.data && e.image?.mime_type) {
          const src = `data:${e.image.mime_type};base64,${e.image.data}`;
          popup += `<br/><img src="${src.replace(/"/g, "&quot;")}" alt="" style="max-width:220px;max-height:160px;margin-top:6px;border-radius:6px;" />`;
        }
        L.marker([e.latitude, e.longitude], { icon: blue })
          .addTo(map)
          .bindPopup(popup);
      });
    })();
    return () => {
      cancelled = true;
      if (mapRef.current) {
        mapRef.current.remove();
        mapRef.current = null;
      }
    };
  }, [data]);

  return (
    <div
      ref={ref}
      className="h-[min(420px,55vh)] w-full rounded border border-neutral-200 bg-neutral-100"
    />
  );
}

function escapeHtml(s: string) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}
