#!/usr/bin/env bash
# Run the Vector unit tests in tests/vector/ against every Vector config
# Purl ships, so the three copies of the level-detection VRL cannot drift:
#   chart     - chart/templates/vector-configmap.yaml, rendered by helm
#   deploy    - deploy/vector/vector.toml (docker-compose collector)
#   install   - the agent config install.sh writes, expanded by bash exactly
#               as install.sh does (catches `$` in VRL eaten by the heredoc)
#
# Uses a local `vector` binary when present, otherwise the chart's Vector
# image through docker. Usage: tests/vector/run.sh [repo-root]
set -euo pipefail

ROOT="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"
CASES="$ROOT/tests/vector/level-detection.toml"

VECTOR_TAG="$(awk '/^vector:/{v=1} v && /^    tag:/{gsub(/"/,"",$2); print $2; exit}' "$ROOT/chart/values.yaml")"
VECTOR_IMAGE="timberio/vector:${VECTOR_TAG:?could not read vector.image.tag from chart/values.yaml}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/purl-vector-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- drift guard -------------------------------------------------------------
# The level-detection block is copied into three files. Compare them first so
# a fix applied to one copy only fails here, not in production.
block() {  # print the BEGIN..END block of $1, indentation and \$ escapes removed
  awk '/# BEGIN purl-level-detection/{on=1} on{print} /# END purl-level-detection/{exit}' "$1" \
    | sed -e 's/^[[:space:]]*//' -e 's/\\\$/$/g'
}
block "$ROOT/chart/templates/vector-configmap.yaml" > "$WORK/block.chart"
block "$ROOT/deploy/vector/vector.toml"             > "$WORK/block.deploy"
block "$ROOT/install.sh"                            > "$WORK/block.install"
[ -s "$WORK/block.chart" ] || { echo "tests/vector: no purl-level-detection block in the chart" >&2; exit 1; }
for copy in deploy install; do
  if ! diff -u "$WORK/block.chart" "$WORK/block.$copy" >&2; then
    echo "FAIL: the purl-level-detection block in $copy differs from the chart's copy" >&2
    exit 1
  fi
done

# --- chart -------------------------------------------------------------------
helm template purl "$ROOT/chart" --set purl.autoGenerateSecrets=true \
    --show-only templates/vector-configmap.yaml \
  | awk '/^  vector.toml: \|/{on=1; next} on && /^[^ ]/{exit} on{sub(/^    /,""); print}' \
  > "$WORK/chart.toml"

# --- deploy ------------------------------------------------------------------
cp "$ROOT/deploy/vector/vector.toml" "$WORK/deploy.toml"

# --- install.sh --------------------------------------------------------------
# Take the heredoc that writes [transforms.parsed] and let bash expand it with
# stand-in values, the same way install.sh does on a real host.
awk '
  /cat >> \/etc\/vector\/vector.toml << EOF$/ {buf=""; on=1; next}
  on && /^EOF$/ {on=0; if (buf ~ /\[transforms\.parsed\]/) {printf "%s", buf; exit}; next}
  on {buf = buf $0 "\n"}
' "$ROOT/install.sh" > "$WORK/install.body"
grep -q '^\[transforms\.parsed\]' "$WORK/install.body" \
  || { echo "tests/vector: could not find the [transforms.parsed] heredoc in install.sh" >&2; exit 1; }
{
  printf '[sources.docker_logs]\ntype = "demo_logs"\nformat = "shuffle"\nlines = ["x"]\n'
  inputs='["docker_logs"]' hostname_label=test-host purl_url=http://purl.invalid:3000 \
    bash -c "cat <<EOF
$(cat "$WORK/install.body")
EOF"
} > "$WORK/install.toml"

# --- run -----------------------------------------------------------------------
run_vector() {
  if command -v vector >/dev/null 2>&1; then
    (cd "$WORK" && PURL_API_KEY=test PURL_URL=http://purl.invalid:3000 vector test "$@")
  else
    docker run --rm -e PURL_API_KEY=test -e PURL_URL=http://purl.invalid:3000 \
      -v "$WORK":/work -w /work "$VECTOR_IMAGE" test "$@"
  fi
}

fail=0
for target in chart:parsed deploy:parse install:parsed; do
  name="${target%%:*}"
  transform="${target#*:}"
  sed "s/@TRANSFORM@/$transform/g" "$CASES" > "$WORK/$name-tests.toml"
  echo "==> vector test: $name ($transform)"
  if ! run_vector "$name.toml" "$name-tests.toml"; then
    echo "FAIL: $name" >&2
    fail=1
  fi
done
exit "$fail"
