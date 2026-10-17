#!/usr/bin/env bash
# Mathlib's documentation site, built and published as hosting/mathlib/README.md
# describes it: every public release, the store kept between runs in a bucket
# the site does not serve, the site uploaded to the bucket the domain serves.
#
# usage: tools/mathlib-site.sh <step>
#   versions  hosting/mathlib/versions.sh into <work>/versions.txt
#   setup     build litedoc4; fetch Mathlib's release tags; check out the newest
#   restore   the store bucket into <work>/out/store (an empty bucket is a build from nothing)
#   build     `litedoc4 build --versions`, up to three attempts on the same store
#   save      <work>/out/store into the store bucket, then checked there; nothing is deleted
#   local     tools/served-gate.sh over <work>/out/site served on 127.0.0.1
#   deploy    <work>/out/site into the site bucket: every file but the entry points, then
#             the entry points, then (only with MATHLIB_SITE_PRUNE=1) deleting what the
#             site no longer has, then every file of the site checked in the bucket
#   live      tools/served-gate.sh, then tools/live-smoke-gate.sh, against MATHLIB_SITE_URL
#
# Environment: MATHLIB_SITE_WORK (default $RUNNER_TEMP/mathlib-site), MATHLIB_SITE_URL
# (default https://mathlib.fuji.land), MATHLIB_SITE_JOBS (default 4), R2_ACCOUNT_ID,
# R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY for restore, save and deploy; `gh`
# authenticated for versions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${MATHLIB_SITE_WORK:-${RUNNER_TEMP:-/private/tmp/lean-doc-relay}/mathlib-site}"
OUT="$WORK/out"
MATHLIB="$WORK/mathlib"
SITE_URL="${MATHLIB_SITE_URL:-https://mathlib.fuji.land}"
JOBS="${MATHLIB_SITE_JOBS:-4}"
LITEDOC4="$ROOT/.lake/build/bin/litedoc4"
SITE_BUCKET=mathlib-docs
STORE_BUCKET=mathlib-docs-store
ENTRY_POINTS=(--exclude /versions.json --exclude /index.html --exclude /404.html)
mkdir -p "$WORK"

versions () {
  [ -s "$WORK/versions.txt" ] || { echo "no $WORK/versions.txt; run the versions step first" >&2; exit 1; }
  cat "$WORK/versions.txt"
}

r2 () {
  : "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"
  RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
    RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
    rclone "$@" --checksum --fast-list --transfers 64 --checkers 64 --stats 60s --stats-one-line
}

case "${1:-}" in
  versions)
    "$ROOT/hosting/mathlib/versions.sh" >"$WORK/versions.txt"
    cat "$WORK/versions.txt"
    ;;
  setup)
    "$ROOT/tools/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro"
    [ -x "$LITEDOC4" ] || { echo "no $LITEDOC4" >&2; exit 1; }
    IFS=, read -r -a tags <<<"$(versions)"
    rm -rf "$MATHLIB"
    mkdir -p "$MATHLIB"
    git -C "$MATHLIB" init -q
    git -C "$MATHLIB" remote add origin https://github.com/leanprover-community/mathlib4
    refspecs=()
    for tag in "${tags[@]}"; do refspecs+=("refs/tags/$tag:refs/tags/$tag"); done
    git -C "$MATHLIB" -c maintenance.auto=false -c gc.auto=0 fetch -q --depth 1 origin "${refspecs[@]}"
    git -C "$MATHLIB" -c advice.detachedHead=false checkout -q "refs/tags/${tags[${#tags[@]}-1]}"
    for tag in "${tags[@]}"; do
      echo "$tag $(git -C "$MATHLIB" rev-parse "refs/tags/${tag}^{commit}") $(git -C "$MATHLIB" show "refs/tags/${tag}:lean-toolchain")"
    done
    ;;
  restore)
    mkdir -p "$OUT/store"
    r2 copy "r2:$STORE_BUCKET/store" "$OUT/store"
    echo "restored: $(find "$OUT/store" -type f | wc -l) files, $(du -sk "$OUT/store" | cut -f1) KiB"
    ;;
  build)
    status=1
    for attempt in 1 2 3; do
      set +e
      "$LITEDOC4" build --root "$MATHLIB" --lib Mathlib --out "$OUT" --versions "$(versions)" \
        --jobs "$JOBS" --config "$ROOT/hosting/mathlib/litedoc4.toml" --lake "$(command -v lake)"
      status=$?
      set -e
      if [ "$status" = 0 ]; then break; fi
      echo "attempt $attempt exited $status; the store keeps every version already put" >&2
      if [ "$attempt" -lt 3 ]; then sleep 60; fi
    done
    echo "build: $attempt attempt(s), exit $status"
    exit "$status"
    ;;
  save)
    [ -d "$OUT/store" ] || { echo "no $OUT/store" >&2; exit 1; }
    r2 copy "$OUT/store" "r2:$STORE_BUCKET/store"
    echo "store: $(find "$OUT/store" -type f | wc -l) files, $(du -sk "$OUT/store" | cut -f1) KiB"
    r2 check "$OUT/store" "r2:$STORE_BUCKET/store" --one-way
    ;;
  local)
    [ -d "$OUT/site" ] || { echo "no $OUT/site" >&2; exit 1; }
    port=8942
    python3 -m http.server --bind 127.0.0.1 --directory "$OUT/site" "$port" >"$WORK/httpd.log" 2>&1 &
    httpd=$!
    for _ in $(seq 30); do
      if curl -fsS -o /dev/null "http://127.0.0.1:$port/versions.json" 2>/dev/null; then break; fi
      sleep 1
    done
    set +e
    "$ROOT/tools/served-gate.sh" --declared "$(versions)" --out "$OUT" --url "http://127.0.0.1:$port"
    status=$?
    set -e
    kill "$httpd" 2>/dev/null || true
    exit "$status"
    ;;
  deploy)
    [ -d "$OUT/site" ] || { echo "no $OUT/site" >&2; exit 1; }
    r2 copy "$OUT/site" "r2:$SITE_BUCKET" "${ENTRY_POINTS[@]}"
    r2 copy "$OUT/site" "r2:$SITE_BUCKET"
    if [ "${MATHLIB_SITE_PRUNE:-0}" = 1 ]; then
      r2 sync "$OUT/site" "r2:$SITE_BUCKET"
    fi
    echo "site: $(find "$OUT/site" -type f | wc -l) files, $(du -sk "$OUT/site" | cut -f1) KiB"
    r2 check "$OUT/site" "r2:$SITE_BUCKET" --one-way
    ;;
  live)
    "$ROOT/tools/served-gate.sh" --declared "$(versions)" --out "$OUT" --url "$SITE_URL"
    "$ROOT/tools/live-smoke-gate.sh" --url "$SITE_URL"
    ;;
  *)
    sed -n '2,/^set -/p' "$0" | sed '$d'
    exit 2
    ;;
esac
