#!/usr/bin/env bash
# Send one SMS using .env (TWILIO_* and SOS_AUTHORITY_SMS_TO).
# Usage: ./scripts/send-sms-curl.sh [BASE_URL]
# Example: ./scripts/send-sms-curl.sh
#          ./scripts/send-sms-curl.sh https://news-jade-nine.vercel.app

set -e
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

TO="${SOS_AUTHORITY_SMS_TO:-}"
if [ -z "$TO" ]; then
  echo "SOS_AUTHORITY_SMS_TO not set in .env"
  exit 1
fi

BASE_URL="${1:-http://localhost:3000}"
BODY='Earthquake 6.7 at UNSW Sydney. Injured person (possible broken leg) near -33.91784,151.23059. in white shirt. Structural damage and ground cracks reported. Immediate assistance needed.'

# Build JSON safely (server truncates body to 150 chars)
PAYLOAD=$(node -e "console.log(JSON.stringify({to: process.env.TO, body: process.env.BODY}))" TO="$TO" BODY="$BODY")

curl -s -X POST "${BASE_URL}/api/twilio/sms" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"
echo ""
