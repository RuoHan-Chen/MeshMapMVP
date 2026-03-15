import { getLLMProvider } from "@/lib/agents";
import { haversineKm } from "@/lib/dedup/area";
import type { MeshReport } from "@/lib/types";
import type { SosNearbyEvent } from "@/lib/agents/types";
import {
  isE164,
  isTwilioConfigured,
  normalizeToE164,
  sendTwilioSms,
} from "@/lib/services/twilio";

export interface NearbyEventInput {
  latitude: number;
  longitude: number;
  category?: string;
  name?: string;
  description?: string;
}

/** Build nearby list with distances from SOS point; cap count */
export function buildNearbyIncidents(
  sosLat: number,
  sosLng: number,
  nearbyEvents: NearbyEventInput[],
  maxKm = 30,
  maxItems = 12
): SosNearbyEvent[] {
  const out: SosNearbyEvent[] = [];
  for (const e of nearbyEvents) {
    const lat = Number(e.latitude);
    const lng = Number(e.longitude);
    if (Number.isNaN(lat) || Number.isNaN(lng)) continue;
    const km = haversineKm(sosLat, sosLng, lat, lng);
    if (km > maxKm) continue;
    out.push({
      latitude: lat,
      longitude: lng,
      category: e.category,
      name: e.name,
      description: e.description,
      distanceKm: Math.round(km * 10) / 10,
    });
  }
  out.sort((a, b) => (a.distanceKm ?? 0) - (b.distanceKm ?? 0));
  return out.slice(0, maxItems);
}

export async function runSosAuthorityNotify(params: {
  primary: MeshReport;
  nearbyEvents: NearbyEventInput[];
  authoritySmsTo?: string;
}): Promise<{ sent: boolean; sid?: string; error?: string; body: string }> {
  const to =
    params.authoritySmsTo?.trim() ||
    process.env.SOS_AUTHORITY_SMS_TO ||
    process.env.SOS_ALERT_TO ||
    "";
  const mapsUrl = `https://www.google.com/maps?q=${params.primary.latitude},${params.primary.longitude}`;

  const nearbyIncidents = buildNearbyIncidents(
    params.primary.latitude,
    params.primary.longitude,
    params.nearbyEvents
  );

  const llm = getLLMProvider();
  const { smsBody } = await llm.generateSosAuthoritySms({
    latitude: params.primary.latitude,
    longitude: params.primary.longitude,
    mapsUrl,
    sosCategory: params.primary.eventType || "sos",
    sosDescription:
      [params.primary.placeName, params.primary.description]
        .filter(Boolean)
        .join(" — ") || "SOS",
    placeName: params.primary.placeName,
    peerId: params.primary.sourcePeerId,
    timestamp: params.primary.timestamp,
    nearbyIncidents,
  });

  if (process.env.MESHNEWS_LOG_LLM !== "0") {
    console.log("[MeshNews SOS] authority SMS draft length", smsBody.length);
  }

  if (!to) {
    return {
      sent: false,
      error:
        "No destination: set SOS_AUTHORITY_SMS_TO in .env (e.g. +61452581119) or pass authoritySmsTo in the API body.",
      body: smsBody,
    };
  }

  if (!isTwilioConfigured()) {
    return {
      sent: false,
      error:
        "Twilio not configured on server (TWILIO_ACCOUNT_SID=AC…, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER). SMS was not sent.",
      body: smsBody,
    };
  }

  const e164 = normalizeToE164(to);
  if (!isE164(e164)) {
    return {
      sent: false,
      error: `Invalid SOS_AUTHORITY_SMS_TO "${to}". Use E.164 (+61452581119) or AU mobile 04xxxxxxxx.`,
      body: smsBody,
    };
  }

  const out = await sendTwilioSms(e164, smsBody);
  if (out.ok)
    return { sent: true, sid: out.sid, body: smsBody };
  return { sent: false, error: out.error, body: smsBody };
}
