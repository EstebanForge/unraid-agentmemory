# Migration: move an agentmemory store into this Unraid container

This guide moves an existing agentmemory memory store from any machine (a dev laptop, a server) into the Unraid container built from this repo. It preserves all sessions, observations, memories, summaries, semantic/procedural stores, and the knowledge graph.

The move is a one-time cutover with a brief downtime window. agentmemory has a single-writer invariant: only one engine may own the store at a time. Running the source and the NAS against separate copies diverges them.

## What migrates and what does not

| Item | Location on source | Migrates? |
|---|---|---|
| KV store (sessions, observations, memories, summaries, semantic, procedural, graph) | `~/.agentmemory/data/state_store.db` | yes |
| Streams / queue | `~/.agentmemory/data/stream_store` | yes |
| HMAC secret | `~/.agentmemory/.hmac` | no (regenerated on the NAS; old bearer tokens invalidated, harmless) |
| Configuration | `~/.agentmemory/.env` | no (re-enter as container env vars) |
| Standalone-shim memories | `~/.agentmemory/standalone.json` | no (separate store; re-save by hand, see step 10) |

The standalone-shim split exists because the `@agentmemory/mcp` stdio shim keeps its own fallback store when it cannot reach the server. Anything saved while the server was down lives there and is invisible to the main store's search. Re-save those entries after cutover.

## Prerequisites

- The Unraid container is installed from the template and the image pulls successfully (GHCR package set to public).
- Shell access on the source machine and on the NAS.
- The container on the NAS is stopped (or not yet started). The data must land before first boot so the engine hydrates from it instead of starting empty.

## Procedure

### 1. Prepare the NAS appdata directory

```bash
# on the NAS
mkdir -p /mnt/user/appdata/agentmemory/data
```

Keep this on the cache pool, not the array. The KV store does random IO and array spinners make recalls slow. The default template path is already cache-only.

### 2. Stop the source instance

Stop the agentmemory daemon on the source so the store is quiescent.

```bash
# on the source (native install)
agentmemory stop
# or, if launched via launchd / systemd, stop and disable the unit
```

Confirm it is fully stopped: `ps aux | grep -E 'iii|agentmemory' | grep -v grep` should show nothing.

### 3. Package the data

```bash
# on the source
tar czf agentmemory-data.tgz -C ~/.agentmemory/data .
```

This captures `state_store.db` and `stream_store`. Inspect it if you want confidence:

```bash
tar tzf agentmemory-data.tgz | head
```

### 4. Transfer to the NAS

```bash
# from the source
scp agentmemory-data.tgz root@<nas-ip>:/mnt/user/appdata/agentmemory/
```

### 5. Extract into the appdata directory

```bash
# on the NAS
tar xzf /mnt/user/appdata/agentmemory/agentmemory-data.tgz \
  -C /mnt/user/appdata/agentmemory/data
```

No manual `chown` is needed. The container entrypoint runs as root and re-owns `/data` to its runtime user on every boot. The files end up owned by UID 1000 (the `node` user inside the image), which is expected for appdata.

### 6. Set the container environment

In the Unraid template, before first start:

- `GEMINI_API_KEY` (required). Powers embeddings, compression, consolidation, graph extraction. Without it the container runs BM25-only and LLM features are dead.
- `AGENTMEMORY_SECRET`: a long random string you control. The entrypoint seeds `/data/.hmac` from this value on first boot. Use the same value on every client.
- `VIEWER_ALLOWED_HOSTS` (optional). Set to the address you will browse the viewer from (e.g. `whitebox:3113`) to make the web UI LAN-reachable. Leave blank to keep the viewer local-only.
- Tuning vars (`GEMINI_MODEL`, `CONSOLIDATION_ENABLED`, etc.): see the root README env table.

### 7. Start the container

Start it from the Unraid Docker tab. The healthcheck polls `/agentmemory/livez`. Expect green within ~30 seconds. The first boot hydrates the in-memory indexes from the migrated `state_store` snapshots, which takes ~9 to 10 seconds.

Check the log for `iii-engine is ready` and no reconnect storm.

### 8. Verify the migration

```bash
# REST health
curl -s http://<nas-ip>:3111/agentmemory/livez
```

Open the viewer at `http://<nas-ip>:3113` (only if you set `VIEWER_ALLOWED_HOSTS` to that address; otherwise the viewer stays loopback-only and this step is skipped). The migrated sessions and memories should appear. The viewer shows a login modal that asks for `AGENTMEMORY_SECRET`; paste it.

### 9. Repoint every client at the NAS

On each machine that runs an agent client (pi, construct-cli, Claude Code, etc.), set in the agent or MCP config:

```
AGENTMEMORY_URL=http://<nas-ip>:3111
AGENTMEMORY_SECRET=<same value as the container>
```

Restart the client so the MCP shim picks up the new target. See [operations.md](operations.md) for per-client examples.

### 10. Re-save the standalone-shim memories

For each entry in the source `~/.agentmemory/standalone.json`, run `memory_save` from a client now pointed at the NAS. Use the same `type`, `content`, and `title` fields. These are typically a small number of entries (a handful at most).

### 11. Decommission the source

Stop and disable the source agentmemory service so it cannot start again and compete. Keep `~/.agentmemory/` as a cold backup for a week until you trust the NAS run, then remove it.

## Verification checklist

- [ ] `livez` returns ok
- [ ] viewer shows the migrated sessions
- [ ] a `memory_save` from a client appears in the viewer within a few seconds
- [ ] a `memory_recall` / `memory_smart_search` returns results
- [ ] source instance is stopped and disabled

## Rollback

If the NAS run is wrong and you need the source back:

1. Stop the NAS container.
2. On each client, revert `AGENTMEMORY_URL` to the source (or unset it for localhost).
3. Restart the source agentmemory instance.

The source store was frozen, not destroyed, so this is lossless as long as you have not run both simultaneously. If you did run both, the source is still authoritative for everything saved before cutover; pick the instance with the newer data and discard the other.

## Gotchas

- **Never run source and NAS at once.** Two writers against two stores diverge silently. There is no merge.
- **The container image cannot do local embeddings** (`--omit=optional` drops the transformers dependency). If `GEMINI_API_KEY` is missing or invalid, recall silently degrades to BM25-only and consolidation, graph extraction, and LLM compression all fail. Set the key before first start.
- **`.hmac` regeneration invalidates old bearer tokens.** Any client caching an old token re-authenticates with `AGENTMEMORY_SECRET`. Harmless.
- **Ownership.** The entrypoint re-owns `/data` to UID 1000 on boot. On Unraid this is fine because appdata is not SMB-exported. If you later export the share, expect the container-owned files to differ from the share default.
