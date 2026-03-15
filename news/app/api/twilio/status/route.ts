import { NextResponse } from "next/server";
import { isTwilioConfigured } from "@/lib/services/twilio";

/**
 * GET — safe diagnostics (no secrets). Use when SMS doesn’t send.
 */
export async function GET() {
  const sid =
    process.env.TWILIO_ACCOUNT_SID || process.env.TWILLIO_ACCOUNT_SID || "";
  const trimmed = sid.trim();
  let accountSidHint: "missing" | "ok_ac" | "wrong_sk" = "missing";
  if (trimmed.startsWith("AC")) accountSidHint = "ok_ac";
  else if (trimmed.startsWith("SK")) accountSidHint = "wrong_sk";

  const hasToken = Boolean(
    process.env.TWILIO_AUTH_TOKEN ||
      process.env.TWILLIO_AUTH_TOKEN ||
      process.env.TWILIO_SECRET_KEY
  );
  const hasFrom = Boolean(
    process.env.TWILIO_PHONE_NUMBER || process.env.TWILLIO_PHONE_NUMBER
  );
  const hasSosTo = Boolean(
    process.env.SOS_AUTHORITY_SMS_TO || process.env.SOS_ALERT_TO
  );

  return NextResponse.json({
    twilioReady: isTwilioConfigured(),
    accountSidHint,
    hasAuthToken: hasToken,
    hasTwilioFromNumber: hasFrom,
    hasSosAuthorityTo: hasSosTo,
    hints: [
      !isTwilioConfigured() &&
        accountSidHint === "wrong_sk" &&
        "Replace SK… with Account SID AC… from console.twilio.com",
      !hasToken && "Set TWILIO_AUTH_TOKEN",
      !hasFrom && "Set TWILIO_PHONE_NUMBER (your Twilio SMS number)",
      !hasSosTo &&
        "Set SOS_AUTHORITY_SMS_TO in .env, or use Submit report → SMS to (optional) when SOS is checked",
    ].filter(Boolean),
  });
}
