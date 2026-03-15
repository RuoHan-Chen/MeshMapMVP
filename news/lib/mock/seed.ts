import type { MeshReport, NewsStory } from "@/lib/types";

export function seedReports(): MeshReport[] {
  const t = new Date().toISOString();
  return [
    {
      id: "seed-r1",
      sourcePeerId: "mesh-node-7a",
      timestamp: t,
      latitude: 37.7749,
      longitude: -122.4194,
      placeName: "Downtown, SF",
      eventType: "power_outage",
      description: "Block reported dark; traffic lights may be out on 4th.",
      imageUrls: [],
      imageDescriptors: ["Night street scene described by peer (mock)."],
      trustScore: 0.72,
      status: "received",
    },
    {
      id: "seed-r2",
      sourcePeerId: "mesh-node-2c",
      timestamp: t,
      latitude: 37.7755,
      longitude: -122.418,
      placeName: "Downtown, SF",
      eventType: "power_outage",
      description: "Same area — flickering then out. Unconfirmed extent.",
      imageUrls: [],
      imageDescriptors: [],
      trustScore: 0.55,
      status: "received",
    },
  ];
}

export function seedStoryFromReport(r: MeshReport): NewsStory {
  return {
    id: "seed-s1",
    newsId: "seed-s1",
    title: `Local report: ${r.eventType} near ${r.placeName}`,
    dek: "Seeded demo story · unverified",
    summary: r.description,
    articleBody: `**Reported:** ${r.description}\n\n**Unverified** mesh data.`,
    eventType: r.eventType,
    latitude: r.latitude,
    longitude: r.longitude,
    areaHash: `${r.latitude.toFixed(2)},${r.longitude.toFixed(2)}`,
    createdAt: r.timestamp,
    sourceReportIds: [r.id],
    imageUrls: r.imageUrls ?? [],
    imageDescriptors: r.imageDescriptors,
    canonicalTags: [r.eventType, "seed"],
    severity: "medium",
    duplicateOf: null,
    sourceCount: 1,
    actionables: [
      "Monitor official power-utility status.",
      "Avoid unlit intersections; treat as four-way stop.",
      "Keep flashlights and batteries ready.",
    ],
    dontDos: [
      "Do not assume grid restoration time from rumors.",
      "Do not use generators indoors.",
      "Do not call 911 for non-emergencies.",
    ],
  };
}
