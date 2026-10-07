#!/usr/bin/env bash
# usage (all of Mathlib at three releases through `litedoc4 build --versions`):
#   mv-l-run.sh setup                 build litedoc4, clone Mathlib's three tags
#   mv-l-run.sh run <label> <versions> one `build --versions` into the shared --out
#   mv-l-run.sh render-alone          `store render` of the first 1, 2 and 3 versions, timed apart
#   mv-l-run.sh report                sizes of the store and the site
#
# Environment: MV_L_WORK (default $RUNNER_TEMP/mv-l or /private/tmp/lean-doc-relay/mv-l),
# MV_L_JOBS (default 4).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${MV_L_WORK:-${RUNNER_TEMP:-/private/tmp/lean-doc-relay}/mv-l}"
LOGS="$WORK/logs"
MATHLIB="$WORK/mathlib"
OUT="$WORK/out"
JOBS="${MV_L_JOBS:-4}"
TAGS=(v4.32.2 v4.33.0 v4.33.1)
LITEDOC4="$ROOT/.lake/build/bin/litedoc4"
mkdir -p "$LOGS"

time_cmd() {
  if [ -x /usr/bin/time ] && /usr/bin/time -v true >/dev/null 2>&1; then
    echo /usr/bin/time -v
  else
    echo /usr/bin/time -l
  fi
}

sample() {
  while true; do
    printf '%s %s %s\n' "$(date -u +%H:%M:%S)" \
      "$(df -k "$WORK" | awk 'NR == 2 { print int($4 / 1048576) "GiB-free" }')" \
      "$( (awk '/MemAvailable/ { print int($2 / 1024) "MiB-avail" }' /proc/meminfo 2>/dev/null) || echo -)"
    sleep 15
  done
}

case "${1:-}" in
  setup)
    "$ROOT/tools/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" >"$LOGS/litedoc4-build.log" 2>&1
    [ -x "$LITEDOC4" ] || { echo "no $LITEDOC4" >&2; exit 1; }
    sha256sum "$LITEDOC4" | tee "$LOGS/litedoc4.sha256"
    rm -rf "$MATHLIB"
    mkdir -p "$MATHLIB"
    git -C "$MATHLIB" init -q
    git -C "$MATHLIB" remote add origin https://github.com/leanprover-community/mathlib4
    for tag in "${TAGS[@]}"; do
      git -C "$MATHLIB" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    done
    git -C "$MATHLIB" -c advice.detachedHead=false checkout -q "refs/tags/${TAGS[${#TAGS[@]}-1]}"
    printf 'no_equations_under = ["Mathlib.Tactic", "Mathlib.Meta"]\n' >"$MATHLIB/litedoc4.toml"
    for tag in "${TAGS[@]}"; do
      echo "$tag $(git -C "$MATHLIB" rev-parse "refs/tags/${tag}^{commit}")"
    done | tee "$LOGS/tags.txt"
    ;;
  run)
    label="$2"
    versions="$3"
    sample >"$LOGS/$label-sampler.txt" &
    sampler=$!
    status=0
    # shellcheck disable=SC2046  # the time command is two words on purpose
    $(time_cmd) "$LITEDOC4" build --root "$MATHLIB" --lib Mathlib --out "$OUT" \
      --versions "$versions" --jobs "$JOBS" >"$LOGS/$label.out" 2>"$LOGS/$label.err" || status=$?
    kill "$sampler" 2>/dev/null || true
    echo "exit $status" >>"$LOGS/$label.out"
    if [ -d "$OUT/site" ]; then
      (cd "$OUT/site" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$LOGS/$label-site.sha256"
    fi
    grep -E '^(phase|versions extracted|version |put |build )' "$LOGS/$label.out" || true
    tail -n 25 "$LOGS/$label.err"
    exit "$status"
    ;;
  render-alone)
    list=""
    for tag in "${TAGS[@]}"; do
      list="${list:+$list,}$tag"
      n="$(echo "$list" | tr ',' '\n' | wc -l | tr -d ' ')"
      rm -rf "$WORK/render-$n"
      status=0
      # shellcheck disable=SC2046
      $(time_cmd) "$LITEDOC4" store render --store "$OUT/store" --versions "$list" \
        --out "$WORK/render-$n" >"$LOGS/render-$n.out" 2>"$LOGS/render-$n.err" || status=$?
      echo "$n version(s): exit $status; $(grep -E 'Elapsed|Maximum resident' "$LOGS/render-$n.err" | tr -s ' \t' ' ' | tr '\n' ';')"
      rm -rf "$WORK/render-$n"
      [ "$status" -eq 0 ] || exit "$status"
    done
    ;;
  report)
    {
      echo "store entries (bytes):"
      find "$OUT/store" -type f -exec ls -l {} + | awk '{ print $5, $9 }' | sed "s#$OUT/##"
      echo "site: $(find "$OUT/site" -type f | wc -l | tr -d ' ') files, $(du -sk "$OUT/site" | awk '{ print $1 }') KiB"
      for d in "$OUT/site"/*/; do
        echo "  $(basename "$d"): $(find "$d" -type f | wc -l | tr -d ' ') files, $(du -sk "$d" | awk '{ print $1 }') KiB"
      done
      for pair in "a b" "b c"; do
        set -- $pair
        if [ -f "$LOGS/$1-site.sha256" ] && [ -f "$LOGS/$2-site.sha256" ]; then
          if cmp -s "$LOGS/$1-site.sha256" "$LOGS/$2-site.sha256"; then
            echo "site $1 = site $2, byte for byte"
          else
            echo "site $1 != site $2: $(/usr/bin/diff "$LOGS/$1-site.sha256" "$LOGS/$2-site.sha256" | grep -c '^[<>]') line(s) differ"
          fi
        fi
      done
      df -h "$WORK"
    } | tee "$LOGS/report.txt"
    ;;
  *)
    sed -n '2,9p' "$0" >&2
    exit 2
    ;;
esac
