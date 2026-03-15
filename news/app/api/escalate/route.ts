import { NextResponse } from "next/server";
import { buildEscalationDraft } from "@/lib/services/escalation";
import { sendTwilioSms } from "@/lib/services/twilio";
import type { NewsStory, UrgencyLevel } from "@/lib/types";

/**
 * Builds AI escalation draft. Optional: send SMS via Twilio (server env only).
 *
 * Body: story?, urgency, callerLat/Lng, helpType
 * Optional: sendSms: true, smsTo: "+1..." — sends draft.textMessage (AI-generated alert text).
 *
 * NOT a substitute for calling emergency services where required by law.
 */
export async function POST(req: Request) {
  try {
    const body = (await req.json()) as {
      story?: NewsStory | null;
      reportId?: string | null;
      urgency?: UrgencyLevel;
      callerLat?: number;
      callerLng?: number;
      callerLabel?: string;
      helpType?: string;
      sendSms?: boolean;
      smsTo?: string;
    };
    const draft = await buildEscalationDraft({
      story: body.story ?? null,
      reportId: body.reportId ?? null,
      urgency: body.urgency || "routine",
      callerLat: Number(body.callerLat) || 0,
      callerLng: Number(body.callerLng) || 0,
      callerLabel: body.callerLabel,
      helpType: body.helpType || "situation update",
    });

    let sms: { sent: boolean; sid?: string; error?: string } = { sent: false };
    if (body.sendSms && body.smsTo) {
      const out = await sendTwilioSms(body.smsTo, draft.textMessage);
      if (out.ok) {
        sms = { sent: true, sid: out.sid };
        console.log("[MeshNews Twilio] SMS sent sid=", out.sid, "to=", body.smsTo.replace(/\d{4}$/, "****"));
      } else {
        sms = { sent: false, error: out.error };
        console.warn("[MeshNews Twilio] SMS failed:", out.error);
      }
    }

    return NextResponse.json({
      ok: true,
      draft,
      sms,
      _warning:
        "Use only where legally appropriate. Trial Twilio only reaches verified numbers.",
    });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: String(e) },
      { status: 500 }
    );
  }
}
