#!/usr/bin/env bash

# Literal transcription of the chrome-tests job of .github/workflows/ci.yml at
# 499c713ae7256c4322dc3f760f223ead2afcb0a3, matrix entry chrome-headless on
# ubuntu-latest, with its two shards run in sequence.

# GitHub runs every `run:` block under `bash -e`.
set -euo pipefail
STAGE="${1:?stage required: build | test | clean}"

cd /workspace

# Every stage runs all of its commands and exits with the first non-zero code,
# so one failing command never truncates the workload of the others.
STAGE_EXIT=0
run_step() {
  local label="$1"; shift
  local rc
  echo "=== ${label}: start $(date -u +%FT%TZ) ==="
  set +e
  "$@"
  rc=$?
  set -e
  echo "=== ${label}: end $(date -u +%FT%TZ) exit=${rc} ==="
  if [ "$rc" -ne 0 ] && [ "$STAGE_EXIT" -eq 0 ]; then
    STAGE_EXIT="$rc"
  fi
  return 0
}

case "$STAGE" in

  # Setup for the build stage, run by run_pipeline.sh outside the measured
  # window: drops every build output and the wireit cache, so the measured
  # command compiles as the job does on a cache miss. `npm run clean` is the
  # upstream script (tools/clean.mjs, git clean -X per workspace).
  clean)
    npm run clean
    rm -rf .wireit
    find . -path ./node_modules -prune -o -type d -name .wireit -print0 | xargs -0 rm -rf
    ;;

  build)
    # :128-129
    run_step "npm run build --workspace @puppeteer-test/test" \
      npm run build --workspace @puppeteer-test/test
    ;;

  test)
    # :143-145, both matrix shards in sequence; github.event_name is push on
    # the measured cell.
    run_step "test shard 1-2" \
      xvfb-run --auto-servernum npm run test -- --shard '1-2' --test-suite chrome-headless --save-stats-to /tmp/artifacts/push_INSERTID.json
    run_step "test shard 2-2" \
      xvfb-run --auto-servernum npm run test -- --shard '2-2' --test-suite chrome-headless --save-stats-to /tmp/artifacts/push_INSERTID.json
    ;;

  *)
    echo "unknown stage: $STAGE" >&2
    exit 2
    ;;

esac

echo "=== stage ${STAGE}: aggregate exit=${STAGE_EXIT} ==="
exit "$STAGE_EXIT"
