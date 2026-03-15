import { NextResponse } from "next/server";
import {
  documentToReports,
  isMeshExportDocument,
} from "@/lib/services/meshExportImport";

/**
 * POST body: full JSON `{ export: { id, createdAt, crs, featureCollection } }`
 * Returns normalized MeshReport[] for client to persist + optional story generation.
 */
export async function POST(req: Request) {
  try {
    const body = await req.json();
    if (!isMeshExportDocument(body)) {
      return NextResponse.json(
        {
          ok: false,
          error:
            "Invalid export document. Expected { export: { id, featureCollection } }.",
        },
        { status: 400 }
      );
    }
    const reports = documentToReports(body);
    return NextResponse.json({
      ok: true,
      exportId: body.export.id,
      crs: body.export.crs,
      featureCount: reports.length,
      reports,
    });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: String(e) },
      { status: 400 }
    );
  }
}
