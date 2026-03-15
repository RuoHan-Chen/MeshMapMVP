# Deploy on Vercel

## Build (local)

```bash
npm install
npm run build
```

This repo **builds cleanly** with the default Next.js settings—no `vercel.json` required.

## Deploy

1. Push the repo to GitHub/GitLab/Bitbucket.
2. [Vercel](https://vercel.com) → **Add New…** → **Project** → import the repo.
3. Framework: **Next.js** (auto-detected). Root: repo root. Build: `npm run build`, Output: default.
4. **Environment variables** (Production + Preview as needed):

   | Variable | Required | Notes |
   |----------|----------|--------|
   | `CLAUDE_API_KEY` | For real articles / SOS SMS text | Omit = mock LLM |
   | `TWILIO_ACCOUNT_SID` | SMS | Must start with `AC` |
   | `TWILIO_AUTH_TOKEN` | SMS | |
   | `TWILIO_PHONE_NUMBER` | SMS | Twilio **From** (E.164) |
   | `SOS_AUTHORITY_SMS_TO` | SMS | Recipient (E.164 or AU `04…`) |
   | `UPSTASH_REDIS_REST_URL` | Optional | Persist `GET /api/recommendations/[id]` across instances |
   | `UPSTASH_REDIS_REST_TOKEN` | Optional | |
   | `NEXT_PUBLIC_SUPABASE_URL` | Optional | Shared demo state across browsers |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Optional | `sb_publishable_…` (preferred over legacy anon) |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Optional | Legacy JWT anon if publishable unset |

5. Deploy. First deploy runs `npm run build` on Vercel’s builders.

## Notes

- **Middleware warning** in build logs is from Next 16 deprecation notice; deploy still works.
- **IndexedDB** is per-browser; serverless has no shared disk—briefs need **Upstash** (or similar) if you rely on `GET /api/recommendations/{id}` after cold starts.
- Do **not** commit `.env`; set secrets only in Vercel → Settings → Environment Variables.
