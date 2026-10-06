// Build-time patch of the vendored @agentmemory/agentmemory worker dist.
//
// WHY: the engine's health evaluation (src/health/thresholds.ts, bundled into
// dist/*.mjs) flags `critical` when heapUsed/heapTotal exceeds
// memoryCriticalPercent (default 95) while RSS is above memoryRssFloorBytes
// (default 512 MiB). V8 legitimately spikes that ratio during GC cycles under
// the LLM-compress allocation bursts, and at `critical` the
// /agentmemory/health route answers 503 (fail-closed) while reads and writes
// keep working. Clients treat any non-2xx health as "server down", so a
// healthy NAS saw random "agentmemory isn't responding" failures mid-session.
// Upstream ships no override: evaluateHealth() is always called with no config
// argument, so the defaults cannot be changed from env or config.
//
// The patch raises the floor to 1.5 GiB RSS (target host has 32 GB, container
// carries no memory limit) and critical to 98%, so the alert fires only near
// genuine memory exhaustion. `degraded` (warn 80%) is cosmetic and stays
// untouched: clients already treat degraded as operational.
//
// Upstream version bumps re-vendor fresh dist files at build time, so the
// patch re-applies on every build. The guard below fails the build loudly if
// the shipped dist no longer contains the patterns, making a silent
// unpatched release impossible.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const DIST = "/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist";
const PATCHES = [
  [/memoryCriticalPercent:\s*95\b/g, "memoryCriticalPercent: 98"],
  [/memoryRssFloorBytes:\s*512 \* 1024 \* 1024\b/g, "memoryRssFloorBytes: 1536 * 1024 * 1024"],
];

const counts = new Map(PATCHES.map(([, replacement]) => [replacement, 0]));
for (const entry of readdirSync(DIST)) {
  if (!entry.endsWith(".mjs")) continue;
  const path = join(DIST, entry);
  let source = readFileSync(path, "utf8");
  for (const [pattern, replacement] of PATCHES) {
    source = source.replace(pattern, () => {
      counts.set(replacement, counts.get(replacement) + 1);
      return replacement;
    });
  }
  writeFileSync(path, source);
}

const missed = [...counts].filter(([, n]) => n === 0).map(([replacement]) => replacement);
if (missed.length > 0) {
  console.error(`health-thresholds patch: pattern(s) not found in ${DIST}: ${missed.join(", ")}`);
  process.exit(1);
}
console.log("health-thresholds patch applied:", [...counts].map(([to, n]) => `${to} x${n}`).join(", "));
