# MeshNews

Hackathon-friendly web app: **mesh / P2P crisis reports** → **local news-style stories**, **area recommendations**, and **mock authority escalation** (demo only).

- **Stack:** Next.js App Router, TypeScript, Tailwind CSS, Vercel serverless route handlers  
- **Storage (demo):** IndexedDB in the browser (local-first)  
- **LLM:** Mock by default; **Claude** when `CLAUDE_API_KEY` is set (optional OpenAI fallback)

## APIs you need (optional)

| Variable | Required? | Purpose |
|----------|-----------|---------|
| `CLAUDE_API_KEY` | No | Anthropic — article / recommendations / escalation |
| `CLAUDE_MODEL` | No | Default `claude-haiku-4-5-20251001` (override in Anthropic console if needed) |
| `OPENAI_API_KEY` | No | Only if Claude unset; GPT instead |
| Supabase URL + key | No | Future: swap repository for hosted persistence |
| Twilio | No | **Implemented** — see below |

**Demo mode works with zero env vars.**

## Setup

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Env vars

Create `.env.local`:

```env
CLAUDE_API_KEY=sk-ant-...
# CLAUDE_MODEL=claude-haiku-4-5-20251001
```

On Vercel, add `CLAUDE_API_KEY` (and optional `CLAUDE_MODEL`) under Environment Variables. For SOS SMS: `TWILIO_*`, **`SOS_AUTHORITY_SMS_TO`** (E.164 who receives the alert).

**LLM logs:** While `npm run dev` runs, every Claude reply is printed in that terminal (`[MeshNews Claude] response`, raw text + usage). Disable with `MESHNEWS_LOG_LLM=0`. Optional `MESHNEWS_LOG_LLM_MAX_CHARS` (default 12000) truncates huge JSON.

**Saved recommendations:** `POST /api/recommendations` stores the brief in memory (and optionally **Upstash Redis**). Later: `GET https://your-app.vercel.app/api/recommendations/{id}` returns the same actionables without calling Claude again. On Vercel without Redis, briefs survive only within the same warm instance—set `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` for reliable IDs in production.

## Articles & images

- Each story has its own URL: **`/story/{id}`** (opens full article with images).
- **Image uploads** stay in the browser (IndexedDB). For **Claude**, uploads are **resized/JPEG** so the API can send them as vision input (caption + article). **HTTPS image URLs** in reports/imports are also sent to the model. Very large originals are compressed first; if still over ~1.2MB base64, vision is skipped for that image.

## Local demo

**Consumer mode** (default): simple news-style list and articles, plus “Local safety” (no ingest or technical labels).  
**Developer mode**: submit reports, raw data, stories, safety brief generator, escalation demo. Toggle via **Developer** / **Consumer view** (saved in `localStorage`).

1. Open **Developer** → **Load sample data** (reports + one story), or **Generate news** with JSON (`news_id`, `sos`, `events[]`).  
2. **Consumer view** to read like a news site; article shows **incident map** (Leaflet) + **3 actionables** + **3 don’ts**. **GET /api/recommendations/{news_id}** matches generate’s `news_id`.

## Vercel deploy

1. Push repo to GitHub.  
2. Import project in Vercel (Next.js).  
3. Add `CLAUDE_API_KEY` (and optional `CLAUDE_MODEL`) in Vercel → Environment Variables.  
4. Deploy.  

IndexedDB is **per browser** by default. For a **shared demo** across browsers (no API code to host), set **`NEXT_PUBLIC_SUPABASE_URL`** + **`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`** (Supabase → API Keys → Publishable; `sb_publishable_…`). Legacy JWT anon via **`NEXT_PUBLIC_SUPABASE_ANON_KEY`** still works. and run **`supabase/meshnews_demo.sql`** once. The app then **pulls ~every 10s** and **pushes** after local changes (same **room** id = same dataset).

## CORS (cross-origin API calls)

`/api/*` sends **`Access-Control-Allow-Origin: *`** and answers **`OPTIONS`** preflight, so any origin can call your APIs with `fetch(..., { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(...) })`.

To **lock down** later, set `Access-Control-Allow-Origin` to your mesh app origin(s) only (and avoid `*` if you use cookies).

## Mesh export schema (GeoJSON)

Imports use **`{ export: { id, createdAt, crs, featureCollection } }`** (CRS `EPSG:4326`, coordinates `[lng, lat]`).

- Types: `lib/types/meshExport.ts`
- Mapper: `lib/services/meshExportImport.ts` → `MeshReport[]`
- **POST `/api/import/export`** — body = full JSON → `{ ok, reports, exportId, featureCount }`
- Developer → **Import export** — paste JSON or load a file. Sample: `/samples/mesh-export.sample.json`

| Feature property | MeshReport |
|------------------|------------|
| `geometry.coordinates` | longitude, latitude |
| `properties.title` / `category` | placeName / eventType |
| `properties.description` | description |
| `properties.senderId` | sourcePeerId |
| `properties.confidence` | trustScore |
| `properties.image.url` | imageUrls |

## API routes

| Route | Method | Body | Description |
|-------|--------|------|-------------|
| `/api/reports` | POST | ingest fields | Normalize mesh report (client saves to IndexedDB) |
| `/api/stories/generate` | POST | **`news_id`** (UUID), **`sos`** `{ title, description, latitude, longitude }`, **`events[]`** same fields per pin, **`send_sos_sms?`**, **`authoritySmsTo?`** | One story id = `news_id`; one SMS if `send_sos_sms`; saves brief under **`news_id`**; article + map + 3 actionables + 3 don’ts. Legacy: `reports[]` still works. |
| `/api/recommendations` | POST | `stories[]`, … | Optional extra briefs (generate already persists by `news_id`) |
| `/api/recommendations/[id]` | GET | — | **`id` = `news_id`** from generate → **actionableRecommendations** + **avoidRecommendations** |
| `/api/escalate` | POST | same + optional `sendSms`, `smsTo` | Draft + optional real SMS |
| `/api/twilio/sms` | POST | `{ to, body }` | Direct SMS (Twilio env) |
| `/api/import/export` | POST | Mesh export JSON | Normalize to `reports[]` |

## Swapping mock → real

1. **LLM:** `lib/agents/index.ts` — `CLAUDE_API_KEY` → Claude, else `OPENAI_API_KEY` → GPT, else mock. Providers in `lib/agents/claude.ts`, `openai.ts`.  
2. **Mesh ingest:** Replace client calls to `/api/reports` with your P2P transport; keep `normalizeIngestBody` shape.  
3. **Online sources:** Extend `lib/services/recommendations.ts` / mock provider to call RSS, OEM APIs, or search.  
4. **Escalation + Twilio:** `POST /api/escalate` with `sendSms: true`, `smsTo: "+1..."` sends the AI `textMessage` via Twilio. Or `POST /api/twilio/sms` with `{ to, body }`. Env: **`TWILIO_ACCOUNT_SID` = AC…** (not SK…), **`TWILIO_AUTH_TOKEN`**, **`TWILIO_PHONE_NUMBER`** (Twilio From), **`SOS_AUTHORITY_SMS_TO`** (recipient). **`GET /api/twilio/status`** — quick check (no secrets). Trial accounts: verify recipient in Twilio Console. Restart dev server after editing `.env`.  

## Project structure

```
app/
  api/reports/route.ts
  api/stories/generate/route.ts
  api/recommendations/route.ts
  api/escalate/route.ts
  layout.tsx
  page.tsx
components/
  MeshNewsDashboard.tsx
lib/
  types/index.ts
  dedup/area.ts, nearby.ts
  agents/mock.ts, claude.ts, openai.ts, index.ts
  services/reportIngest.ts, storyGenerate.ts, recommendations.ts, escalation.ts
  storage/repository.ts, indexeddb.ts
  mock/seed.ts
  types/meshExport.ts
  services/meshExportImport.ts
  api/import/export/route.ts
```

## Safety

All generated content is labeled **unverified** where appropriate. Escalation is **mock only** — see code comments in `app/api/escalate/route.ts` and `lib/services/escalation.ts`.
