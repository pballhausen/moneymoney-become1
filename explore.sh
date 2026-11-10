#!/usr/bin/env bash
# Optionaler Helfer, um die private become.1-GraphQL-API direkt per curl zu erkunden.
# Für den Betrieb der Extension nicht nötig.
#
#   cp .env.example .env   und BECOME1_REFRESH_TOKEN eintragen
#   ./explore.sh '{ queryB1CardUserTransactions { id reference side amount { value currency } } }'
#   ./explore.sh '{ getOwnB1CardUsers { id cardStatus } }'

set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${BECOME1_REFRESH_TOKEN:?BECOME1_REFRESH_TOKEN fehlt — .env anlegen (siehe .env.example)}"
FIREBASE_API_KEY="${FIREBASE_API_KEY:-AIzaSyCQmxu5BULN61MH-r2qCpryqas0rXkUVjE}"

QUERY="${1:-{ getOwnB1CardUsers { id cardStatus } }}"

ID_TOKEN="$(curl -sS -X POST \
  "https://securetoken.googleapis.com/v1/token?key=${FIREBASE_API_KEY}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=refresh_token' \
  --data-urlencode "refresh_token=${BECOME1_REFRESH_TOKEN}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id_token",""))')"

if [[ -z "$ID_TOKEN" ]]; then
  echo "Token-Refresh fehlgeschlagen — Refresh-Token abgelaufen oder zurückgezogen?" >&2
  exit 1
fi

curl -sS -X POST https://api.become1.de/graphql \
  -H 'Content-Type: application/json' \
  -H "Authorization: ${ID_TOKEN}" \
  --data "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$QUERY")" \
  | python3 -m json.tool
