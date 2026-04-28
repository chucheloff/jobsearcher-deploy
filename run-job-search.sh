#!/usr/bin/env bash
# run-job-search.sh — invoke the job-search skill with live progress.
# Usage: bash run-job-search.sh [extra openclaw args...]
#
# Streams three things to your terminal in parallel, prefixed:
#   [agent]   stdout of `openclaw agent` (skill narration, step bullets)
#   [gateway] gateway log lines for THIS run only
#   [mcp]     company-mcp / jobmcp / gmail-mcp request lines
#
# Stop with Ctrl-C; the streamers shut down with the agent.
set -euo pipefail

COMPOSE="docker compose -f $HOME/jobsearcher-deploy/compose.yml"
MSG="${MSG:-run job-search pass dry-run=true limit=1}"
TIMEOUT="${TIMEOUT:-600}"
THINKING="${THINKING:-medium}"
LOG_DIR="$HOME/jobsearcher-deploy/runs"
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
RUN_LOG="$LOG_DIR/run-$STAMP.log"

echo "==> writing all streams to $RUN_LOG"
echo "==> message: $MSG"
echo "==> thinking: $THINKING  timeout: ${TIMEOUT}s"
echo "==> -----------------------------------------------"

# Preflight: openclaw-cli shares gateway's netns via `network_mode: service:gateway`.
# When the gateway is recreated (image swap, model change, config reload), cli's
# bound netns becomes stale — DNS and 127.0.0.1:18789 stop working without any
# visible error. Recreate cli on every run to be safe (cheap: <5s).
echo "==> preflight: ensuring cli is bound to current gateway netns"
$COMPOSE up -d --force-recreate --no-deps openclaw-cli >/dev/null 2>&1
for i in $(seq 1 20); do
  if $COMPOSE exec -T openclaw-cli sh -c \
      'curl -fsS --max-time 2 http://127.0.0.1:18789/healthz >/dev/null 2>&1 \
       && getent hosts openrouter.ai >/dev/null 2>&1'; then
    echo "==> preflight ok (cli sees gateway + external DNS)"
    break
  fi
  sleep 1
  if [ "$i" = "20" ]; then
    echo "==> preflight FAILED (cli netns not healthy after 20s); aborting"
    exit 1
  fi
done

# Start log streamers (stop together via trap)
$COMPOSE logs -f --since 1s --tail 0 openclaw-gateway 2>&1 \
    | sed -u 's/^/[gateway] /' | tee -a "$RUN_LOG" &
GW_PID=$!
$COMPOSE logs -f --since 1s --tail 0 jobmcp company-mcp gmail-mcp slack-mcp 2>&1 \
    | sed -u 's/^/[mcp]     /' | tee -a "$RUN_LOG" &
MCP_PID=$!

cleanup() {
  echo
  echo "==> stopping streamers"
  kill $GW_PID $MCP_PID 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Run the agent with verbose, NO --json so step output streams live.
# Pass --thinking + --timeout from env.
$COMPOSE exec -T openclaw-cli openclaw agent \
    --agent main \
    --message "$MSG" \
    --thinking "$THINKING" \
    --timeout "$TIMEOUT" \
    --verbose on \
    "$@" 2>&1 \
    | sed -u 's/^/[agent]   /' | tee -a "$RUN_LOG"
AGENT_EXIT=${PIPESTATUS[0]}
echo "==> agent exited code $AGENT_EXIT"
exit $AGENT_EXIT
