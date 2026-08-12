# unraid-agentmemory

Unraid template + self-contained Docker image for [agentmemory](https://www.agent-memory.dev/), the cross-session memory layer for coding agents.

This repo produces two artifacts:

1. A **multi-arch Docker image** at `ghcr.io/estebanforge/agentmemory` (amd64 + arm64), built from this Dockerfile. The image bundles the [iii engine](https://hub.docker.com/r/iiidev/iii) (v0.11.2, pinned) and the `@agentmemory/agentmemory` worker (pulled from npm at build time).
2. An **Unraid Community Applications template** at `template/agentmemory.xml`.

No fork of upstream is required. The Dockerfile is vendored from `rohitg00/agentmemory/deploy/fly/` with three justified deviations (see `entrypoint.sh` header).

## Why this exists

agentmemory's only distribution channel is npm. There is no official Docker image, and Unraid templates pull images, not npm packages. This repo closes that gap: it builds the image and ships the template that points at it.

## How the image is built

Two-stage build:

- Stage 1 copies the prebuilt `iii` engine binary out of `iiidev/iii:0.11.2`.
- Stage 2 is `node:24-slim` (Active LTS), installs `@agentmemory/agentmemory@<version>` into a dedicated prefix whose `package.json` `overrides` pin `iii-sdk` to 0.11.2 (npm `install -g` ignores overrides, and the caret range `^0.11.2` would otherwise resolve to 0.11.6, which breaks agentmemory).

`--omit=optional` drops `@huggingface/transformers`. Consequence: **this image cannot run local embeddings.** A cloud embedding provider (Gemini, OpenAI, Voyage, Cohere, or OpenRouter) is mandatory. This is deliberate, it keeps the image small and makes CPU-weak hosts (Intel Celeron NAS, etc.) viable by forcing embeddings off-host.

The single persistent path is `/data` (`state_store.db`, `stream_store`, `.hmac`). Back it up via Unraid's Appdata Backup.

## Build and release

CI (`.github/workflows/release.yml`) builds both architectures and pushes to GHCR **only when you push a version tag (e.g. `1.0.0`)** (plus manual dispatch). Commits to `main` do not trigger a build.

Two version concepts:

- **Release version** (this repo's semver, e.g. `1.0.0`): taken from the git tag. Drives the image tags and the CHANGELOG.
- **Bundled agentmemory version** (e.g. `0.9.28`): read from [`agentmemory.version`](agentmemory.version). A build detail (which upstream agentmemory release is baked in).

To cut a release:

1. Update `CHANGELOG.md`.
2. Set the `<Repository>` tag in `template/agentmemory.xml` to the new release (e.g. `ghcr.io/estebanforge/agentmemory:1.1.0`).
3. Commit to `main`.
4. `git tag 1.1.0 && git push --tags`. CI builds and publishes `:1.1.0`, `:1.1.0-am<bundled>`, and `:latest`.
5. In Unraid, the Apps tab shows an update; click Update. `/data` persists.

To bump only the bundled agentmemory version: edit `agentmemory.version`, then cut a release as above.

After the first CI run, set the package visibility to **Public** at `github.com/users/EstebanForge/packages/container/agentmemory/settings` so Unraid can pull it without registry auth.

## Install on Unraid

1. Enable **Template Authoring Mode**: Docker tab, stop the docker service, Advanced View, enable authoring mode, restart the service.
2. Copy `template/agentmemory.xml` to `/boot/config/plugins/dockerMan/templates-user/agentmemory.xml` on the NAS.
3. Apps tab, the `agentmemory` template appears under your user templates. Install it.
4. Set **at least one LLM provider key** (Gemini, OpenAI, Anthropic, MiniMax, or OpenRouter; or an OpenAI-compatible endpoint via `OPENAI_API_KEY` + `OPENAI_BASE_URL`). Set `AGENTMEMORY_SECRET` (recommended, a long random string you control) and, to open the viewer from a browser, `VIEWER_ALLOWED_HOSTS` (e.g. `whitebox:3113`).
5. Keep `Appdata` on the cache pool (default). Do not put it on the array, the KV store does random IO.
6. Start. Healthcheck hits `/agentmemory/livez`; container goes healthy in ~30s.

## Point your clients at the NAS

On every machine that runs an agent client (pi, construct-cli, Claude Code, etc.), set in the MCP/agent config:

```
AGENTMEMORY_URL=http://<nas-ip>:3111
AGENTMEMORY_SECRET=<same value as the container>
```

The `@agentmemory/mcp` stdio shim proxies all tools to that URL over HTTP.

**Then decommission the local agentmemory instance** on each client (stop the `iii` service, remove it from auto-start). Running two writers against two stores diverges them.

## Migrate an existing store

Stop the source instance, then:

```bash
# on the source machine
tar czf agentmemory-data.tgz -C ~/.agentmemory/data .

# on the NAS, before first start
mkdir -p /mnt/user/appdata/agentmemory/data
tar xzf agentmemory-data.tgz -C /mnt/user/appdata/agentmemory/data
```

The `.hmac` file regenerates on first boot if absent, invalidating old bearer tokens (harmless, clients re-auth with `AGENTMEMORY_SECRET`).

Memories saved via the standalone MCP shim live in a separate file (`~/.agentmemory/standalone.json`) and do **not** migrate. Re-save them with `memory_save` after repointing clients.

## Environment reference

The template exposes the full config surface (47 fields). The values below are the ones that matter for most setups; advanced tuning (search weights, chunk sizing, snapshots, team mode) lives in the template's advanced view, and the complete variable list is [upstream's `.env.example`](https://github.com/rohitg00/agentmemory/blob/main/.env.example).

**Pick one LLM provider** (if several keys are set, detection order is OpenAI > MiniMax > Anthropic > Gemini > OpenRouter):

| Provider | Keys / vars | Embeddings too? |
|---|---|---|
| Gemini (default) | `GEMINI_API_KEY` (+ `GEMINI_MODEL`) | yes |
| OpenAI | `OPENAI_API_KEY` | yes |
| OpenAI-compatible (DeepSeek, Z.ai GLM, SiliconFlow, vLLM, Ollama) | `OPENAI_API_KEY` + `OPENAI_BASE_URL` | yes (if the endpoint exposes `/v1/embeddings`) |
| Anthropic | `ANTHROPIC_API_KEY` (+ `ANTHROPIC_MODEL`) | no (pair with an embedding provider) |
| MiniMax | `MINIMAX_API_KEY` (+ `MINIMAX_MODEL`) | no (pair with an embedding provider) |
| OpenRouter | `OPENROUTER_API_KEY` (+ `OPENROUTER_MODEL`) | yes (one key, many models) |

**Embeddings** (`EMBEDDING_PROVIDER`, auto-detected if blank): `gemini`, `openai`, `voyage`, `cohere`, `openrouter`. Local is unavailable in this image.

**Auth and viewer**: `AGENTMEMORY_SECRET` (bearer auth, REST + viewer), `VIEWER_ALLOWED_HOSTS` (set to the browse address to make the viewer LAN-reachable).

**Defaults baked into the template** (all overrideable): auto-compress on, context injection on, consolidation on (14-day decay), graph extraction on, 200 obs/session, `GEMINI_MODEL=gemini-2.5-flash-lite`, tool surface `core`.

## Known caveats

- **iii is pinned to 0.11.2.** v0.11.6 introduces a sandbox worker model the agentmemory CLI is not refactored for. Do not bump `III_VERSION` without upstream changes.
- **Cold start ~9 to 10 seconds** (index hydration from `state_store` snapshots). The healthcheck `start_period` covers this.
- **`AGENTMEMORY_SECRET` is the only auth** on the REST + viewer ports. On a trusted home LAN this is fine; on any other network put the container behind a reverse proxy with TLS or restrict the published ports.
- **Observability is disabled** in the generated iii config. Re-enabling it at sampling 1.0 triggers a log feedback loop (issue #519). If you need traces, set a low sampling ratio and watch disk usage.

## Ports

| Port | Service | Exposed by template |
|---|---|---|
| 3111 | REST + MCP HTTP | yes |
| 3113 | Viewer WebUI | yes (bearer-authorized) |
| 3112 | iii-stream WS | no (internal) |
| 49134 | engine bridge WS | no (internal, container-local) |

## License

agentmemory is upstream's. This packaging is MIT.
