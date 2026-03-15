import { NextResponse } from "next/server";
import { normalizeIngestBody } from "@/lib/services/reportIngest";

/** Simulates mesh ingest — normalize only; client persists to IndexedDB */
export async function POST(req: Request) {
  try {
    const body = (await req.json()) as Record<string, unknown>;
    const report = normalizeIngestBody(body);
    return NextResponse.json({ ok: true, report });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: String(e) },
      { status: 400 }
    );
  }
}

export async function GET() {
  return NextResponse.json({
    message: "POST JSON body: sourcePeerId, latitude, longitude, placeName, eventType, description, timestamp?, imageUrl | imageUrls[], trustScore?",
  });
}
