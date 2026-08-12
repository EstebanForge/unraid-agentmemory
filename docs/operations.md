# Operations

Day-to-day running of the agentmemory container on Unraid, after migration.

## Point clients at the NAS

Every agent client talks to the container through the `@agentmemory/mcp` stdio shim, which proxies all tools to the REST surface. Set two variables in each client's environment or MCP config:

```
AGENTMEMORY_URL=http://<nas-ip>:3111
AGENTMEMORY_SECRET=<same value as the container>
```

The client never connects to `:49134` (the engine bridge) or `:3112` (streams). Those stay internal to the container.

### Common clients

- **pi** (`~/.pi/agent/mcp.json` or the agent config): set the two env vars in the environment pi runs under. Restart pi.
- **construct-cli**: set them in the construct environment. Note the `ENT_` prefix quirk: use unprefixed names (`AGENTMEMORY_URL`, `AGENTMEMORY_SECRET`) so both the host and the construct environment resolve them.
- **Claude Code / other MCP hosts**: set the env vars in the shell that launches the host, or in the MCP server config if it forwards env.

Restart the client after changing the variables so the shim re-probes the server.

## Switching providers

The container supports any provider agentmemory supports. Change the provider key(s) in the container variables (Unraid: click the container, Edit, adjust the relevant `LLM:*` or `Embeddings:*` variable), restart, done. No image change needed.

- **Detection order** (if multiple keys are set): OpenAI > MiniMax > Anthropic > Gemini > OpenRouter for LLM; Gemini > OpenAI > Voyage > Cohere > OpenRouter for embeddings. Or force one with `EMBEDDING_PROVIDER`.
- **Anthropic and MiniMax are LLM-only** (no embeddings API). Pair them with a separate embedding provider key (Gemini, OpenAI, Voyage, Cohere, or OpenRouter).
- **OpenAI-compatible third parties** (DeepSeek, Z.ai GLM, SiliconFlow, vLLM, Ollama): set `OPENAI_API_KEY` to the third-party key and `OPENAI_BASE_URL` to the `/v1` endpoint. Works for both LLM and embeddings if the endpoint exposes them.
- **Easiest multi-model route**: OpenRouter (`OPENROUTER_API_KEY` + `OPENROUTER_MODEL`) reaches DeepSeek, GLM, Claude, GPT, and more behind one key.

If you switch provider, clients do not need to change `AGENTMEMORY_URL` or `AGENTMEMORY_SECRET`; only the server-side provider key changes.

## Updating

Releases are tag-driven. When the maintainer publishes a new release (an `X.Y.Z` tag), CI builds and pushes the new image tag, and Unraid shows an update.

1. Unraid Apps tab: the agentmemory container shows an update. Click Update.
2. `/data` persists across the image swap, so no data loss.

To publish a release yourself (maintainer), see the Build and release section in the root README.

Do not bump `III_VERSION` (the engine) past 0.11.2. See [architecture.md](architecture.md) for why.

## Backups

The single persistent path is `/mnt/user/appdata/agentmemory/data`. Back it up and the entire memory store is covered.

- **Appdata Backup plugin** (Community Applications): add the agentmemory container to the backup set. Schedule it. This is the recommended path on Unraid and covers the `.hmac` secret too.
- **Manual snapshot**: `tar czf agentmemory-$(date +%F).tgz -C /mnt/user/appdata/agentmemory/data .`

Restore is the reverse: stop the container, extract the tar into the appdata directory, start the container.

## Viewer

`http://<nas-ip>:3113` is the memory browser. It is only LAN-reachable if you set `VIEWER_ALLOWED_HOSTS` (template variable) to the address you browse from, for example `whitebox:3113`. Without it the viewer stays loopback-only and the published 3113 is unreachable from the LAN; the container is still healthy.

When reachable, the viewer is auth-gated by `AGENTMEMORY_SECRET`. Open the URL and the page shows a login modal that asks for the secret. Paste it; the token is held in the browser sessionStorage for the session.

The viewer is optional for operation. The container works fine with only `:3111` if you prefer not to expose the UI.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Container stuck unhealthy | `livez` failing, usually no provider key set or the key rejected | Check the container log; confirm at least one LLM provider key is set and valid |
| Recall returns nothing or scores look flat | BM25-only mode, embeddings not configured | Confirm a provider key is set and `EMBEDDING_PROVIDER` resolves (or leave it blank to auto-detect) |
| Container restart loop | Corrupt index or bad config | Check the log. As a recovery step, set `AGENTMEMORY_DROP_STALE_INDEX=true` once to rebuild indexes on boot |
| Mac client cannot connect | Wrong URL, secret mismatch, or firewall | Confirm `AGENTMEMORY_URL` reaches the NAS, `AGENTMEMORY_SECRET` matches the container, and the NAS allows the client's IP on `:3111` |
| Slow recall | Consolidation or graph extraction running in the background, or Gemini latency | Wait for the background pass to finish. Check Gemini status if it persists |
| Disk filling on cache | Graph snapshots or logs growing | Logs are capped (json-file, 10m by 3). Check graph snapshot count under `/data` and prune old ones |
| Old bearer tokens rejected after restart | `.hmac` rotated or regenerated | Re-issue clients with the current `AGENTMEMORY_SECRET` |

## Ports reference

| Port | Service | Published by template |
|---|---|---|
| 3111 | REST + MCP HTTP | yes |
| 3113 | Viewer WebUI | yes (bearer-authorized) |
| 3112 | iii-stream WebSocket | no (internal) |
| 49134 | engine bridge WebSocket | no (internal, container-local) |

Only `:3111` and `:3113` need to reach the LAN. The engine bridge stays inside the container.
