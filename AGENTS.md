# PROJECT KNOWLEDGE BASE

**Generated:** 2026-08-12 (updated for 1.0.0)

## OVERVIEW

Project: **unraid-agentmemory**
Stack: Docker (multi-arch `linux/amd64` + `linux/arm64`), tag-driven GitHub Actions CI, POSIX sh entrypoint, Unraid Community Applications XML template. Base image `node:24-slim` (Active LTS). No application source code is written here; this repo **packages** upstream `@agentmemory/agentmemory` (npm) + the `iii` engine (`iiidev/iii`) into a self-contained image and ships the Unraid template that points at it.

Two artifacts produced:
1. Image `ghcr.io/estebanforge/agentmemory:<release>` (also `:latest`).
2. Unraid template `template/agentmemory.xml`.

Upstream: [agentmemory](https://www.agent-memory.dev/) (npm only, no official image). No fork of upstream is required.

## VERSION MODEL (read this first)

Two independent versions:

- **Release version** (this repo's semver, e.g. `1.0.0`): comes from the git tag (`1.0.0`). Drives the image tags and `CHANGELOG.md`.
- **Bundled agentmemory version** (e.g. `0.9.28`): read from `agentmemory.version`. A build detail (which upstream agentmemory npm release is baked in).
- **iii engine**: pinned to `0.11.2` in the Dockerfile. Do not bump (see NOTES).

## STRUCTURE

```
.
├── Dockerfile              # 2-stage build: iii engine binary + agentmemory worker (npm) on node:24-slim
├── entrypoint.sh           # First-boot: generate iii config, seed HMAC, gate viewer, drop privs
├── agentmemory.version     # Bundled agentmemory version (0.9.28); single source for the build arg
├── CHANGELOG.md            # Release history (Keep a Changelog); current [1.0.0]
├── template/
│   └── agentmemory.xml     # Unraid CA template: 47 configurable fields (multi-provider)
├── .github/workflows/
│   └── release.yml         # buildx multi-arch build + GHCR push (TAG-DRIVEN: bare semver tags only)
├── docs/
│   ├── README.md           # Doc index (audience split: users vs maintainers)
│   ├── architecture.md     # Design decisions, deviations, release procedure
│   ├── operations.md       # Day-to-day: clients, switching providers, backup, troubleshoot
│   └── migration.md        # Move an existing store into this container
├── assets/
│   ├── logo.svg            # Source icon (canonical, from upstream)
│   └── logo.png            # 256x256 tile icon (what the template references)
├── .dockerignore
└── .gitignore
```

*   `Dockerfile`: Read with `docs/architecture.md`. The `overrides` iii-sdk pin and `--omit=optional` are load-bearing. Touch only with reason.
*   `entrypoint.sh`: Vendored from upstream with 3 justified deviations (documented in-file and in `docs/architecture.md`). Re-vendoring means re-applying those 3.
*   `agentmemory.version`: Bump here to bundle a newer upstream agentmemory, then cut a release.
*   `template/agentmemory.xml`: The `<Repository>` tag must match the release being shipped (e.g. `:1.0.0`). 47 fields, multi-provider.

## COMMANDS

This is a packaging repo. There is no test suite, linter, or build step run locally in normal flow; CI does the build. Local builds are for verification only.

| Action | Command |
|--------|---------|
| Local build (single arch, verify) | `docker build -t agentmemory:dev --build-arg AGENTMEMORY_VERSION=$(cat agentmemory.version) .` |
| Local build (multi-arch) | `docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/estebanforge/agentmemory:dev .` |
| Run locally | `docker run -p 3111:3111 -p 3113:3113 -v $(pwd)/data:/data -e GEMINI_API_KEY=... agentmemory:dev` |
| Healthcheck (manual) | `curl -fsS http://127.0.0.1:3111/agentmemory/livez` |
| Cut a release | `git tag X.Y.Z && git push --tags` (CI runs ONLY on tags; main commits do not build) |
| Upgrade bundled agentmemory | Edit `agentmemory.version`, then cut a release as above |

## CODING STANDARDS

*   **Shell (`entrypoint.sh`)**: POSIX `sh`. `set -eu`. Root does setup, then `exec gosu node:node` drops privileges. Comments explain the *why* (each deviation from upstream is justified inline).
*   **Dockerfile**: Multi-stage, pinned `ARG`s at top. `tini` as PID 1 (`TINI_SUBREAPER=1`). Explanatory comments before non-obvious steps.
*   **XML template**: Unraid CA schema v2. `Mask="true"` on secrets. `Display="advanced"` / `"advanced-hide"` for tuning vars. Provider-agnostic: any one of Gemini/OpenAI/Anthropic/MiniMax/OpenRouter (or OpenAI-compatible via `OPENAI_BASE_URL`) works.
*   **Docs**: Telegraphic, table-heavy, em-dash-free. Audience split: user docs (`operations.md`, `migration.md`) vs maintainer docs (`architecture.md`).
*   **Style rule**: Match the existing files. No drive-by reformatting. Every deviation from upstream needs a written justification.

## WHERE TO LOOK

*   **Build**: `Dockerfile`
*   **Runtime**: `entrypoint.sh`
*   **CI**: `.github/workflows/release.yml`
*   **Template**: `template/agentmemory.xml`
*   **Design rationale**: `docs/architecture.md` (read before editing Dockerfile/entrypoint)
*   **Ops + provider switching**: `docs/operations.md`
*   **Release version**: git tag (e.g. `1.0.0`); **bundled agentmemory version**: `agentmemory.version`
*   **Release history**: `CHANGELOG.md`

## NOTES (critical gotchas)

1.  **iii is pinned to 0.11.2.** `III_VERSION` and `III_SDK_VERSION` must not exceed 0.11.2. v0.11.6 adds a sandbox worker model the agentmemory CLI is not refactored for; it surfaces as EPIPE reconnect loops and empty search-after-save. The pin lifts only when upstream refactors.
2.  **The `overrides` pin is load-bearing.** `npm install -g` ignores `overrides`. agentmemory is installed into `/opt/agentmemory` (a local prefix) whose `package.json` pins `iii-sdk` to 0.11.2. Without it the caret range `^0.11.2` resolves to 0.11.6 and breaks. Do not change the install method without preserving this.
3.  **No local embeddings; multi-provider LLM.** `--omit=optional` drops `@huggingface/transformers`, so a cloud embedding provider is mandatory. LLM providers: Gemini, OpenAI, OpenAI-compatible (DeepSeek, Z.ai GLM, SiliconFlow, vLLM, Ollama via `OPENAI_BASE_URL`), Anthropic, MiniMax, OpenRouter. Embedding providers: Gemini, OpenAI, Voyage, Cohere, OpenRouter. Anthropic and MiniMax are LLM-only (no embeddings API) and must be paired with an embedding provider. Detection order if multiple keys set: OpenAI > MiniMax > Anthropic > Gemini > OpenRouter (LLM); Gemini > OpenAI > Voyage > Cohere > OpenRouter (embeddings).
4.  **Observability is disabled** in the generated iii config. Re-enabling at `sampling_ratio: 1.0` triggers a log feedback loop (issue #519, 137 GB to `daemon.log.new`). Re-enable per-session only, low sampling, watch disk.
5.  **Three deviations from upstream entrypoint** (the point of the fork): (a) observability off, (b) `AGENTMEMORY_SECRET` honored from env, (c) viewer binds `0.0.0.0` only when `VIEWER_ALLOWED_HOSTS` is set (without it, a non-loopback viewer throws an uncaught `ViewerConfigError` that kills the whole process). Re-vendoring requires re-applying all three. See `docs/architecture.md`.
6.  **GHCR visibility**: package is PUBLIC. Unraid pulls anonymously. (New packages default private; this one is already public.)
7.  **Release procedure** (tag-driven): (1) update `CHANGELOG.md`, (2) set `<Repository>` in `template/agentmemory.xml` to `:<release>`, (3) commit to main, (4) `git tag X.Y.Z && git push --tags`. CI builds `:<release>`, `:<release>-am<bundled>`, `:latest`. Main commits do NOT build. `/data` persists across image swaps.
8.  **Persistent path is `/data` only** (`state_store.db`, `stream_store`, `.hmac`). Cache pool only, not the array (random IO). `.hmac` regenerates if absent, invalidating old bearer tokens (clients re-auth with `AGENTMEMORY_SECRET`).
9.  **Cold start ~9-10s** (index hydration). Healthcheck `start-period: 30s` covers it.
10. **Auth model**: `AGENTMEMORY_SECRET` is the *only* auth on `:3111` and `:3113`. Fine on a trusted home LAN; elsewhere use a reverse proxy with TLS or restrict published ports.

## PORTS

| Port | Service | Published |
|------|---------|-----------|
| 3111 | REST + MCP HTTP | yes |
| 3113 | Viewer WebUI (bearer-gated, needs `VIEWER_ALLOWED_HOSTS` for LAN access) | yes |
| 3112 | iii-stream WS | no (internal) |
| 49134 | engine bridge WS | no (container-local) |
