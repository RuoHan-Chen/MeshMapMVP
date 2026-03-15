/**
 * Twilio SMS — server-side only. Never expose Account SID + Auth Token to the client.
 *
 * Legal / ops: Obtaining consent, local laws, and misuse of “alert police” flows are your
 * responsibility. Trial accounts only send to verified numbers.
 */

function twilioCreds(): {
  accountSid: string;
  authToken: string;
  from: string;
} | null {
  const accountSid =
    process.env.TWILIO_ACCOUNT_SID || process.env.TWILLIO_ACCOUNT_SID;
  const authToken =
    process.env.TWILIO_AUTH_TOKEN ||
    process.env.TWILLIO_AUTH_TOKEN ||
    process.env.TWILIO_SECRET_KEY ||
    process.env.TWILLIO_SECRET_KEY;
  const from =
    process.env.TWILIO_PHONE_NUMBER || process.env.TWILLIO_PHONE_NUMBER;
  const sid = accountSid?.trim();
  if (!sid || !authToken?.trim() || !from?.trim()) return null;
  // Console / API Key SIDs (SK…) cannot be used for Messages REST Basic auth
  if (!sid.startsWith("AC")) return null;
  return { accountSid: sid, authToken: authToken.trim(), from: from.trim() };
}

export function isTwilioConfigured(): boolean {
  return twilioCreds() !== null;
}

/** E.164 e.g. +15551234567 */
export function isE164(to: string): boolean {
  return /^\+[1-9]\d{6,14}$/.test(to.trim());
}

/**
 * Accept common AU mobile input: 0475267605 → +61475267605
 * Also strips spaces/dashes. Already-E.164 passes through.
 */
export function normalizeToE164(to: string): string {
  let s = to.replace(/[\s\-().]/g, "").trim();
  if (s.startsWith("+")) return s;
  // AU mobile: 04xx xxx xxx (10 digits, starts with 04)
  if (/^04\d{8}$/.test(s)) return "+61" + s.slice(1);
  // AU without leading 0 (rare)
  if (/^4\d{8}$/.test(s)) return "+61" + s;
  return s;
}

export async function sendTwilioSms(
  to: string,
  body: string
): Promise<{ ok: true; sid: string } | { ok: false; error: string; code?: number }> {
  const sid =
    process.env.TWILIO_ACCOUNT_SID || process.env.TWILLIO_ACCOUNT_SID || "";
  const creds = twilioCreds();
  if (!creds) {
    if (sid.trim() && !sid.trim().startsWith("AC")) {
      return {
        ok: false,
        error:
          "TWILIO_ACCOUNT_SID must start with AC (Account SID from console.twilio.com). Do not use an API Key SID (SK…).",
      };
    }
    return {
      ok: false,
      error:
        "Twilio not configured: set TWILIO_ACCOUNT_SID (AC…), TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER (+1… Twilio-owned From number).",
    };
  }
  const toNorm = normalizeToE164(to);
  if (!isE164(toNorm)) {
    return {
      ok: false,
      error:
        "Invalid number. AU mobile: 04xxxxxxxx or E.164 +61475267605 (drop the leading 0 after +61).",
    };
  }
  const text = body.slice(0, 1600);
  if (!text.length) return { ok: false, error: "Empty body" };

  const auth = Buffer.from(`${creds.accountSid}:${creds.authToken}`).toString(
    "base64"
  );
  const url = `https://api.twilio.com/2010-04-01/Accounts/${creds.accountSid}/Messages.json`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      To: toNorm,
      From: creds.from,
      Body: text,
    }),
  });
  const data = (await res.json()) as {
    sid?: string;
    message?: string;
    code?: number;
    more_info?: string;
  };
  if (!res.ok) {
    const code = data.code ?? res.status;
    const hint =
      code === 20003 || code === 401
        ? " Check Auth Token (not API Secret) and Account SID AC…"
        : code === 21608
          ? " Trial: add this number in Twilio → Phone Numbers → Verified, or upgrade."
          : code === 21266
            ? " From and To cannot be the same number."
            : code === 21659 || code === 21610
              ? " From must be your Twilio SMS-capable number (not a personal mobile)."
              : "";
    const msg = [data.message, hint].filter(Boolean).join("");
    return {
      ok: false,
      error: msg || res.statusText || "Twilio request failed",
      code: code as number,
    };
  }
  if (!data.sid) return { ok: false, error: "No Message SID in response" };
  return { ok: true, sid: data.sid };
}
