# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/).

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
