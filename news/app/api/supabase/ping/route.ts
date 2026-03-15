import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

/**
 * GET — checks Supabase + meshnews_demo table (no secrets in response)
 */
export async function GET() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const key =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim();

  if (!url || !key) {
    return NextResponse.json({
      ok: false,
      configured: false,
      hint: "Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY (or legacy ANON)",
    });
  }

  const supa = createClient(url, key);
  const { data, error } = await supa
    .from("meshnews_demo")
    .select("id")
    .limit(1);

  if (error) {
    return NextResponse.json({
      ok: false,
      configured: true,
      connected: false,
      error: error.message,
      hint:
        error.message.includes("relation") || error.code === "42P01"
          ? "Run supabase/meshnews_demo.sql in SQL Editor"
          : error.message.includes("JWT") || error.message.includes("Invalid API key")
            ? "Check publishable key (sb_publishable_…) or legacy anon"
            : undefined,
    });
  }

  return NextResponse.json({
    ok: true,
    configured: true,
    connected: true,
    table: "meshnews_demo",
    rowsSampled: Array.isArray(data) ? data.length : 0,
  });
}
