import { NextResponse } from "next/server";
import { isTwilioConfigured, sendTwilioSms } from "@/lib/services/twilio";

/**
 * POST { to: "+1...", body: "..." } — send SMS (Twilio env required).
 * For testing / integrations. Prefer /api/escalate with sendSms for AI-composed text.
 */
export async function POST(req: Request) {
  if (!isTwilioConfigured()) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Twilio not configured. Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER",
      },
      { status: 503 }
    );
  }
  try {
    const body = (await req.json()) as { to?: string; body?: string };
    const out = await sendTwilioSms(body.to || "", body.body || "");
    if (!out.ok) {
      return NextResponse.json(
        { ok: false, error: out.error, code: out.code },
        { status: 400 }
      );
    }
    console.log("[MeshNews Twilio] /api/twilio/sms sid=", out.sid);
    return NextResponse.json({ ok: true, sid: out.sid });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: String(e) },
      { status: 500 }
    );
  }
}
