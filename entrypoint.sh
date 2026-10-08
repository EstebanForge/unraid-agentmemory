#!/bin/sh
# agentmemory first-boot entrypoint.
#
# Runs as root so it can:
# 1. Overwrite the npm-bundled iii-config.yaml (which binds 127.0.0.1 and
#    uses relative ./data paths) with a deploy-tuned version that binds
#    0.0.0.0 and uses absolute /data paths.
# 2. chown the platform-mounted /data volume to the runtime user.
# 3. Seed the HMAC secret on first boot and persist it to /data/.hmac
#    (chmod 600) so it survives restarts.
#
# Then it starts the iii engine, waits for it without a timeout, and execs
# the agentmemory CLI under gosu as the unprivileged `node` user, attached
# to the already-running engine (see deviation #4 at the exec site).
#
# Deviations from upstream deploy/entrypoint.sh (justified):
# - Observability DISABLED in the generated config. Upstream enables it at
#   sampling_ratio 1.0; that triggers the log-subscriber feedback loop that
#   wrote 137 GB to daemon.log.new (issue #519). Proven-bad on sustained load.
# - Honors an env-supplied AGENTMEMORY_SECRET: if set AND the hmac file is
#   absent, seeds the file from env (no random generation, no log leak).
# - Viewer opts into a 0.0.0.0 bind only when VIEWER_ALLOWED_HOSTS is set.
#   Upstream only does the non-loopback bind inside Fly. agentmemory refuses
#   to start a non-loopback viewer unless VIEWER_ALLOWED_HOSTS (exact Host
#   header match, anti-DNS-rebind) and AGENTMEMORY_SECRET (bearer auth) are
#   both set, otherwise it throws an uncaught ViewerConfigError that kills
#   the whole process. Set VIEWER_ALLOWED_HOSTS to the address you will
#   browse (e.g. nas:3113) and the viewer is LAN-reachable and auth-gated by
#   AGENTMEMORY_SECRET (the frontend shows a login modal). Leave it blank and
#   the viewer stays loopback; the container still runs, only the published
#   3113 is unreachable from the LAN.

set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

mkdir -p "$DATA_DIR"
chown -R "$RUN_AS" "$DATA_DIR"

cat > "$III_CONFIG" <<'EOF'
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        # Inline flow array, matching upstream 0.9.30's bundled config
        # shape. The CLI rewrites this file into iii-config.runtime.yaml
        # at startup and its transform mangles block-style lists into
        # invalid YAML (engine crash on boot, found in 1.0.3 E2E).
        allowed_origins: ["http://localhost:3111", "http://localhost:3113", "http://127.0.0.1:3111", "http://127.0.0.1:3113"]
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          save_interval_ms: 2000
          file_path: /data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          save_interval_ms: 2000
          file_path: /data/stream_store
  # Observability intentionally DISABLED. With enabled=true the worker emits
  # spans/logs to ws://localhost:49134/otel; the subscriber falls behind under
  # sustained load, the engine disconnects, and the worker enters a reconnect
  # backoff loop. Full sampling also drove a log feedback loop that wrote
  # 137 GB to daemon.log.new (issue #519). Re-enable per-session via env only
  # if you need to trace a specific failure.
  - name: iii-observability
    config:
      enabled: false
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 0.1
      metrics_enabled: true
      logs_enabled: false
      logs_console_output: false
  - name: iii-exec
    config:
      watch:
        - src/**/*.ts
      exec:
        - node dist/index.mjs
EOF
chown "$RUN_AS" "$III_CONFIG"

# Seed the HMAC secret. Honor an env-supplied AGENTMEMORY_SECRET; generate a
# random one only when none is provided. The file persists across restarts.
if [ ! -s "$HMAC_FILE" ]; then
    if [ -n "${AGENTMEMORY_SECRET:-}" ]; then
        SECRET="$AGENTMEMORY_SECRET"
    else
        SECRET="$(openssl rand -hex 32)"
    fi
    umask 077
    printf '%s\n' "$SECRET" > "$HMAC_FILE"
    chmod 600 "$HMAC_FILE"
    chown "$RUN_AS" "$HMAC_FILE"
    if [ -z "${AGENTMEMORY_SECRET:-}" ]; then
        echo "================================================================"
        echo "agentmemory: generated HMAC secret on first boot"
        echo "AGENTMEMORY_SECRET=$SECRET"
        echo "Copy this value now. It will not be printed again."
        echo "Stored at: $HMAC_FILE (chmod 600)"
        echo "To rotate: delete $HMAC_FILE on the persistent volume and restart."
        echo "================================================================"
    fi
fi

AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
export AGENTMEMORY_SECRET

# Bind the viewer to 0.0.0.0 ONLY when the operator supplied
# VIEWER_ALLOWED_HOSTS. agentmemory requires both that (anti-DNS-rebind,
# exact Host-header match) and AGENTMEMORY_SECRET (always set above) for any
# non-loopback viewer bind; without them startViewerServer throws an uncaught
# ViewerConfigError and the whole process exits. Leaving VIEWER_ALLOWED_HOSTS
# unset keeps the safe loopback bind: the container stays healthy and the
# published 3113 is simply LAN-unreachable.
if [ -n "${VIEWER_ALLOWED_HOSTS:-}" ]; then
    : "${AGENTMEMORY_VIEWER_HOST:=0.0.0.0}"
    export AGENTMEMORY_VIEWER_HOST VIEWER_ALLOWED_HOSTS
fi

# Deviation #4: supervise the engine with an unbounded wait, then attach
# the worker. Upstream's CLI gives the engine 15 s to become ready
# (waitForEngine(15e3) is hardcoded in src/cli.ts and pinned by its tests;
# the AGENTMEMORY_READY_TIMEOUT_MS knob proposed in issue #634 does not
# exist in 0.9.30). Hydrating a multi-GB store takes longer than that
# (measured ~18 s at 3.4 GB, and the first boot after a version switch is
# slower), so the stock path aborts and the container dies. We start the
# engine here, wait for its API with no timeout, then attach the worker
# with --no-engine + III_ENGINE_URL, the CLI's supported attach mode.
#
# The engine log MUST live outside the config's directory: the engine's
# config watcher reloads on filesystem events in that directory, and its
# own log writes otherwise trigger a permanent ~500 ms reload loop
# (observed on engine 0.22.1; zero reloads once the log is elsewhere).
#
# MALLOC_ARENA_MAX=2 matches upstream's engine tuning on Linux (agentmemory
# #1457 / iii #2257: unbounded glibc arenas multiplied engine RSS several
# times on multi-GB stores).
export MALLOC_ARENA_MAX=2
ENG_CONF=/conf
ENG_LOG=/var/log/agentmemory
ENG_WORK=/var/lib/agentmemory
mkdir -p "$ENG_CONF" "$ENG_LOG" "$ENG_WORK"
cp "$III_CONFIG" "$ENG_CONF/iii.yaml"
chown -R "$RUN_AS" "$ENG_CONF" "$ENG_LOG" "$ENG_WORK"
# The engine creates ./config under its working directory; the dedicated
# ENG_WORK keeps that out of both / and the watched config dir.
gosu "$RUN_AS" sh -c "cd '$ENG_WORK' && exec iii --config '$ENG_CONF/iii.yaml' >> '$ENG_LOG/engine.log' 2>&1" &
ENG_PID=$!
i=0
until curl -s -o /dev/null -m 2 http://127.0.0.1:3111/; do
    if ! kill -0 "$ENG_PID" 2>/dev/null; then
        echo "agentmemory entrypoint: engine exited during startup" >&2
        tail -n 40 "$ENG_LOG/engine.log" >&2 || true
        exit 1
    fi
    i=$((i + 1))
    if [ "$i" -gt 360 ]; then
        echo "agentmemory entrypoint: engine not ready after 30 min" >&2
        exit 1
    fi
    sleep 5
done
echo "agentmemory entrypoint: engine ready, attaching worker"
III_ENGINE_URL='ws://127.0.0.1:49134'
export III_ENGINE_URL

exec gosu "$RUN_AS" agentmemory --no-engine "$@"
