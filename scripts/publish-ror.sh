#!/usr/bin/env bash
# Upload a new StockPiler zip to the Return of Reckoning addon site.
# The token is read from the ROR_TOKEN environment variable. Do not enable
# xtrace: curl receives the bearer token on its command line.
set +x
set -euo pipefail

cd "$(dirname "$0")/.."

: "${VERSION:?VERSION is required}"
: "${ZIP:?ZIP is required}"
: "${CHANGELOG:?CHANGELOG is required}"

VERSION=${VERSION//$'\r'/}
VERSION=${VERSION//[[:space:]]/}

python3 - <<'PY'
import os, re, sys
version = os.environ["VERSION"]
semver = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
if not semver.fullmatch(version):
    sys.exit(f"Refusing to upload non-semver version {version!r}")
PY

python3 scripts/verify-addon-zip.py "$ZIP"

if [[ ! -s "$CHANGELOG" ]]; then
  echo "Changelog section is empty: ${CHANGELOG}" >&2
  exit 1
fi

api_base="https://addons.returnofreckoning.com/api/v1/addons/stockpiler/releases"
version_enc=$(VERSION="$VERSION" python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["VERSION"], safe=""))')
release_url="${api_base}/${version_enc}"
status_prefix="${release_url}/status"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

exist_body="${tmp}/exist.json"
exist_err="${tmp}/exist.err"
set +e
exist_code=$(curl -sS --fail-with-body --proto '=https' --max-redirs 2 --retry 3 --retry-delay 2 \
  --connect-timeout 20 --max-time 60 \
  -o "$exist_body" -w "%{http_code}" "$release_url" 2>"$exist_err")
exist_rc=$?
set -e

if [[ "$exist_rc" -eq 0 && "$exist_code" == "200" ]]; then
  if python3 scripts/ror-response.py public-release "$exist_body" "$VERSION"; then
    echo "::notice title=RoR upload::Release ${VERSION} already exists on the addon site; skipping upload"
    exit 0
  fi
  echo "Existence check returned HTTP 200 but not release ${VERSION}" >&2
  cat "$exist_body" >&2
  exit 1
fi

if [[ "$exist_code" != "404" ]]; then
  echo "Existence check for ${VERSION} returned HTTP ${exist_code} (curl ${exist_rc})" >&2
  cat "$exist_err" >&2
  cat "$exist_body" >&2
  exit 1
fi

echo "Addon site has no ${VERSION} release yet."

dry_run() {
  echo "Dry run: would POST ${api_base}"
  echo "Fields: version=${VERSION} package=@${ZIP} changelog_md=@${CHANGELOG}"
  echo "Authorization: Bearer token from ROR_TOKEN (not printed)."
}

if [[ "${ROR_DRY_RUN:-}" == "1" ]]; then
  dry_run
  exit 0
fi

if [[ -z "${ROR_TOKEN:-}" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "ROR_TOKEN is empty; refusing to upload" >&2
    exit 1
  fi
  dry_run
  exit 0
fi

upload_body="${tmp}/upload.json"
upload_hdr="${tmp}/upload.hdr"
upload_err="${tmp}/upload.err"
set +e
upload_code=$(curl -sS --fail-with-body --proto '=https' --max-redirs 0 \
  --connect-timeout 20 --max-time 120 \
  -H "Authorization: Bearer ${ROR_TOKEN}" \
  -F "version=${VERSION}" \
  -F "package=@${ZIP};type=application/zip" \
  -F "changelog_md=@${CHANGELOG};type=text/markdown" \
  -D "$upload_hdr" \
  -o "$upload_body" \
  -w "%{http_code}" \
  "$api_base" 2>"$upload_err")
upload_rc=$?
set -e

if [[ "$upload_code" == "409" ]]; then
  echo "::notice title=RoR upload::Release ${VERSION} already exists on the addon site; skipping upload"
  exit 0
fi

if [[ "$upload_code" == "422" ]] && python3 scripts/ror-response.py already-exists "$upload_body"; then
  echo "::notice title=RoR upload::Release ${VERSION} already exists on the addon site; skipping upload"
  exit 0
fi

if [[ "$upload_rc" -ne 0 || "$upload_code" != "202" ]]; then
  echo "Upload of ${VERSION} failed (HTTP ${upload_code}, curl ${upload_rc})" >&2
  cat "$upload_err" >&2
  cat "$upload_body" >&2
  exit 1
fi

status_url=$(python3 scripts/ror-response.py status-url "$upload_body" "$upload_hdr" "$VERSION")
if [[ "$status_url" != "$status_prefix" ]]; then
  echo "Refusing to poll unexpected status URL" >&2
  exit 1
fi

echo "Addon site accepted ${VERSION} (HTTP ${upload_code}). Polling pipeline status."

deadline=$((SECONDS + 300))
while true; do
  status_body="${tmp}/status.json"
  status_err="${tmp}/status.err"
  set +e
  status_code=$(curl -sS --fail-with-body --proto '=https' --max-redirs 0 --retry 5 --retry-delay 2 \
    --connect-timeout 20 --max-time 60 \
    -H "Authorization: Bearer ${ROR_TOKEN}" \
    -o "$status_body" \
    -w "%{http_code}" \
    "$status_url" 2>"$status_err")
  status_rc=$?
  set -e
  if [[ "$status_rc" -ne 0 ]]; then
    echo "Status check failed (HTTP ${status_code}, curl ${status_rc})" >&2
    cat "$status_err" >&2
    cat "$status_body" >&2
    exit 1
  fi

  result=$(python3 scripts/ror-response.py poll "$status_body")
  kind=${result%%:*}
  detail=${result#*:}
  case "$kind" in
    wait)
      echo "RoR pipeline for ${VERSION}: ${detail}"
      ;;
    ok)
      echo "RoR release ${VERSION} passed checks (${detail})."
      exit 0
      ;;
    moderation)
      echo "::notice title=RoR upload::Release ${VERSION} is awaiting moderation (${detail}). Not failing the job."
      exit 0
      ;;
    fail)
      echo "RoR release checks failed for ${VERSION}: ${detail}" >&2
      cat "$status_body" >&2
      exit 1
      ;;
    *)
      echo "Unexpected poll result: ${result}" >&2
      exit 1
      ;;
  esac

  if (( SECONDS >= deadline )); then
    echo "Timed out after 5 minutes waiting for RoR release ${VERSION} (${detail})" >&2
    cat "$status_body" >&2
    exit 1
  fi
  sleep 15
done
