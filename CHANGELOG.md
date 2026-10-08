# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.3] - 2026-10-08

### Fixed

- Unbounded engine memory growth. The 0.11.x engine's file-based KV store kept every scope (graph provenance, audit log, vector index, viewer stream backlog) resident in engine RAM with no cap; on a store that had grown to 3.4 GB, the engine idled at 5.8 GB RSS with the whole index and history in heap. Matches upstream issues #964, #1389, #1443 and #1153. agentmemory 0.9.30 moves the engine pin from 0.11.2 to 0.22.1 and bounds all four stores: graph provenance capped at 32 observation ids per record with boot-time compaction (`AGENTMEMORY_GRAPH_COMPACT_ON_BOOT`), audit log moved to monthly scopes with `AGENTMEMORY_AUDIT_RETENTION_MONTHS`, the vector index persisted in buckets (`AGENTMEMORY_VECTOR_BUCKET_SIZE`), and the viewer stream backlog capped (`AGENTMEMORY_VIEWER_STREAM_MAX`). BM25 is no longer persisted; it is rebuilt at boot.
- Engine crash on boot with 0.22.1. The worker CLI rewrites the generated iii config into a runtime file at startup, and its transform mangled the block-style `cors.allowed_origins` list in our vendored entrypoint heredoc into invalid YAML. The heredoc now mirrors upstream 0.9.30's bundled config shape (inline flow array, `save_interval_ms`, new `iii-exec` worker) with the repo deviations re-applied: `0.0.0.0` binds on the HTTP and stream workers, `/data` store paths, observability disabled.

### Changed

- Bundled agentmemory 0.9.29 → 0.9.30 and iii engine / iii-sdk 0.11.2 → 0.22.1, upstream's validated pairing. The 0.11.x pin (v0.11.6 required a worker model the CLI was not refactored for: EPIPE reconnect loops, empty search-after-save) is lifted because the refactor shipped with the 0.9.30 pairing. The `overrides` pin stays as a lockstep guard: bump `III_VERSION` and `III_SDK_VERSION` together, always matching agentmemory's own `iii-sdk` requirement.
- Dockerfile default `ARG AGENTMEMORY_VERSION` now tracks `agentmemory.version` (0.9.30); it had lagged at 0.9.28 since 1.0.0, so a build without the build-arg silently shipped an older worker.
- The health-threshold patch (deviation #4) still applies on the new dist; the build fails loudly if the dist shape changes.
- Verified E2E before tagging: livez health, save → BM25 search → viewer reachable on the new pairing, no EPIPE reconnect loops in logs.

Bundled versions: agentmemory 0.9.30, iii engine 0.22.1, Node 24.

## [1.0.2] - 2026-09-06

### Fixed

- Random "agentmemory isn't responding" failures mid-session. Root cause: the engine's health route answers 503 (fail-closed) whenever its internal status reaches `critical`, and `critical` fired spuriously. The status is driven by `heapUsed / heapTotal > 95%` above a 512 MiB RSS floor, both hardcoded defaults with no env or config override, and V8 legitimately spikes that ratio during GC cycles under the LLM-compress allocation bursts. Observed live: 20/20 health probes returned 503 while searches kept completing in the same window. A docker restart cleared it until the working set crept back.
- New build-time patch (`patches/health-thresholds.mjs`, deviation #4) raises the vendored worker's `memoryRssFloorBytes` to 1.5 GiB and `memoryCriticalPercent` to 98, so the critical state means "actually near memory exhaustion". `degraded` (warn 80%) is untouched; clients treat degraded as operational. The build fails if a bundled-version bump changes the dist shape, so the patch cannot be silently lost.

Bundled versions: agentmemory 0.9.29, iii engine 0.11.2, Node 24.

## [1.0.1] - 2026-08-26

### Changed
- Bundled agentmemory 0.9.28 → 0.9.29. The iii engine stays pinned at 0.11.2 (upstream pins `iii-sdk` to exactly 0.11.2 in both releases). Highlights relevant to this image: hybrid ranking (BM25 + vector + graph) reaches the primary `mem::search` recall path (it was keyword-only in 0.9.28), provider default models bumped to current generations (Gemini default `gemini-3.7-flash`), MCP protocol version negotiation fixed, superseded memory versions no longer surface in recall.
- `GEMINI_MODEL` template default `gemini-2.5-flash-lite` → `gemini-3.5-flash-lite`. Google retired 2.5-flash-lite for new API users, so every LLM call (compression, summarisation, consolidation, graph extraction) returned 404 until the model was overridden. Verified live: compression succeeds on `gemini-3.5-flash-lite`.

Bundled versions: agentmemory 0.9.29, iii engine 0.11.2, Node 24.

## [1.0.0] - 2026-08-12

First release. Packaging of upstream [agentmemory](https://www.agent-memory.dev/) for Unraid.

### Added
- Self-contained multi-arch Docker image (`linux/amd64` + `linux/arm64`) bundling the iii engine v0.11.2 and the `@agentmemory/agentmemory` worker on Node 24 (Active LTS).
- Unraid Community Applications template (`template/agentmemory.xml`) with 47 configurable fields covering providers, models, search, behaviour, snapshots, and team sharing.
- Multi-provider LLM support: Gemini, OpenAI, any OpenAI-compatible API (DeepSeek, Z.ai GLM, SiliconFlow, vLLM, LM Studio, Ollama via `OPENAI_BASE_URL`), Anthropic, MiniMax, OpenRouter, plus a `FALLBACK_PROVIDERS` chain.
- Multi-provider embeddings: Gemini, OpenAI (+ compatible), Voyage AI, Cohere, OpenRouter. Local embeddings omitted, so a cloud provider is mandatory.
- Bearer-token auth (`AGENTMEMORY_SECRET`) for the REST API and the viewer.
- Viewer web UI with a built-in login modal, gated by `VIEWER_ALLOWED_HOSTS` (loopback-safe by default; LAN-reachable when set).
- Memory pipeline: 4-tier consolidation (working, episodic, semantic, procedural) with Ebbinghaus decay, knowledge-graph extraction, context injection, LLM auto-compression, and optional reflection.
- Search tuning: BM25 / vector / graph weights, context token budget, chunked summarisation.
- Operational features: periodic snapshots, team sharing (`TEAM_MODE`), MCP tool surface toggle (`core` / `all`).
- Healthcheck on `/agentmemory/livez`, `tini` as PID 1, `gosu` privilege drop.
- Tag-driven GitHub Actions CI: multi-arch buildx build pushing to GHCR; release version derived from the tag.
- Documentation: README, `docs/migration.md`, `docs/operations.md`, `docs/architecture.md`.

### Decisions carried into 1.0.0
- iii engine pinned to v0.11.2 (v0.11.6 breaks agentmemory's worker model).
- Observability disabled in the generated iii config (issue #519 log feedback loop).
- `--omit=optional` keeps the image small and forces off-host embeddings, which makes CPU-weak NAS hosts viable.
- Viewer binds `0.0.0.0` only when `VIEWER_ALLOWED_HOSTS` is set, preventing an uncaught `ViewerConfigError` crash.

Bundled versions: agentmemory 0.9.28, iii engine 0.11.2, Node 24.
