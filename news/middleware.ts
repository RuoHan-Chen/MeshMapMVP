import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

/**
 * CORS for /api/* so other sites (or mesh clients) can POST JSON from the browser.
 * Preflight: OPTIONS. Allow-Origin: * — no cookies/credentials from foreign origins.
 */
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Requested-With",
  "Access-Control-Max-Age": "86400",
};

export function middleware(request: NextRequest) {
  if (!request.nextUrl.pathname.startsWith("/api/")) {
    return NextResponse.next();
  }

  if (request.method === "OPTIONS") {
    return new NextResponse(null, { status: 204, headers: { ...CORS_HEADERS } });
  }

  const response = NextResponse.next();
  Object.entries(CORS_HEADERS).forEach(([k, v]) => {
    if (k !== "Access-Control-Max-Age") response.headers.set(k, v);
  });
  return response;
}

export const config = {
  matcher: "/api/:path*",
};
