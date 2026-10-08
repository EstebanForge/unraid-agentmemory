# Architecture and maintainer notes

This document is for anyone changing the Dockerfile, entrypoint, or build pipeline. Read it before editing those files.

## Why this repo exists

agentmemory's only distribution channel is npm. There is no official Docker image. Unraid templates pull images, not npm packages. This repo closes the gap by building a self-contained image and shipping the Unraid template that points at it. No fork of upstream is required.

## The image build

The Dockerfile is vendored from `rohitg00/agentmemory/deploy/fly/Dockerfile` (the documented variant; the coolify one is identical minus an explanatory comment). Two stages:

1. `FROM iiidev/iii:0.22.1 AS iii-image` to grab the prebuilt iii engine binary.
2. `FROM node:24-slim`, copy the engine binary in, install `@agentmemory/agentmemory` from npm.

### The iii-sdk overrides pin (lockstep guard)

The engine binary in stage 1 and the worker's `iii-sdk` dependency must stay on the same version. Mismatch history: agentmemory 0.9.28/0.9.29 declared `iii-sdk: ^0.11.2`, a caret range that drifted to 0.11.6, which introduced a sandbox-everything worker model the agentmemory CLI was not refactored for. Running against 0.11.6 surfaced as EPIPE reconnect loops and empty search-after-save. The pin lifted in 1.0.3: agentmemory 0.9.30 pins `iii-sdk` to exactly 0.22.1 and pairs with engine 0.22.1.

The Dockerfile keeps the guard by installing agentmemory into a dedicated prefix (`/opt/agentmemory`) whose `package.json` sets `"overrides": {"iii-sdk": "<III_SDK_VERSION>"}`. npm respects `overrides` only for local installs, not `install -g`, which is why the prefix exists. With an exact upstream pin the override is a lockstep guard rather than a workaround, but it still fails the build loudly if `III_SDK_VERSION` is ever set to a version agentmemory cannot accept. If you change the install method, preserve the override.

Verify the pairing before any engine bump: `npm view @agentmemory/agentmemory@<version> dependencies.iii-sdk`.

### The embedding constraint

The Dockerfile installs with `--omit=optional`, which drops `@huggingface/transformers`. Consequence: **this image cannot run local MiniLM embeddings.** A cloud embedding provider (Gemini via `GEMINI_API_KEY`) is mandatory.

This is deliberate. It keeps the image small and makes CPU-weak hosts viable by forcing embeddings off-host. The target NAS (see below) is a Celeron; local embeddings on it would be 5 to 10 times slower than the dev machine it replaces.

## Three deviations from upstream's entrypoint

The entrypoint is vendored from upstream with three justified changes. Each is commented in `entrypoint.sh`.

1. **Observability disabled in the generated iii config.** Upstream enables it at `sampling_ratio: 1.0`. Under sustained load the log subscriber falls behind, the engine disconnects, and the worker enters a reconnect backoff loop. Full sampling also drove a log feedback loop that wrote 137 GB to `daemon.log.new` (issue #519). Disabling is the conservative, proven-safe choice.

2. **The HMAC secret honors an env-supplied `AGENTMEMORY_SECRET`.** Upstream always generates a random secret and prints it once. For a LAN-exposed container you want to control the bearer secret so clients can match it without scraping logs. The entrypoint seeds `/data/.hmac` from `AGENTMEMORY_SECRET` when set, and falls back to random generation when absent.

3. **The viewer opts into `0.0.0.0` only when `VIEWER_ALLOWED_HOSTS` is set.** Upstream only does the non-loopback bind inside Fly. agentmemory refuses to start a non-loopback viewer unless both `VIEWER_ALLOWED_HOSTS` (exact Host-header match, anti-DNS-rebind) and `AGENTMEMORY_SECRET` (bearer auth) are set; without them `startViewerServer` throws an uncaught `ViewerConfigError` and the whole process exits. The entrypoint therefore binds wide only when the operator supplies `VIEWER_ALLOWED_HOSTS` (the address they will browse), and leaves the safe loopback bind otherwise. The viewer frontend has a built-in login modal that asks for `AGENTMEMORY_SECRET`, so browser access is open URL, paste secret, use it, with no SSH tunnel.

## A fourth deviation from upstream's worker: health thresholds

The npm worker is patched at build time (`patches/health-thresholds.mjs`) because the engine's health evaluation has no override hook: `evaluateHealth()` is always called with no config argument, so its hardcoded defaults (`memoryCriticalPercent: 95`, `memoryRssFloorBytes: 512 MiB`) are unreachable from env or config.

Those defaults misfire on a healthy NAS. The engine flags `critical` when `heapUsed / heapTotal` crosses 95% while RSS is above the floor, and V8 legitimately spikes that ratio during GC cycles under the LLM-compress allocation bursts. At `critical` the `/agentmemory/health` route answers 503 (fail-closed) while reads and writes keep serving, and clients treat any non-2xx health as "server down". Observed live: 20/20 health probes returned 503 across several seconds while searches kept completing in the same window.

The patch raises the floor to 1.5 GiB RSS and critical to 98%, so the alert fires only near genuine memory exhaustion. The target host has 32 GB and the container carries no memory limit, so 1.5 GiB RSS is a real signal rather than a baseline. `degraded` (warn 80%) is untouched and stays cosmetic. The build fails if a bundled-version bump changes the dist shape and the patterns stop matching, so the patch cannot be silently lost.

## Build and release pipeline

`.github/workflows/release.yml` runs only on version tags (e.g. `1.0.0`) and manual dispatch. Commits to `main` do not build. It:

- reads the version from `agentmemory.version`,
- builds both architectures (`linux/amd64`, `linux/arm64`) with buildx,
- pushes to `ghcr.io/<owner>/agentmemory` with three tags: the version, the version with the iii pin suffix, and `latest`.

Both base images (`iiidev/iii:0.22.1`, `node:24-slim`) are multi-arch, so the result runs on x86_64 and ARM Unraid hosts.

After the first CI run, the GHCR package visibility defaults to private. Set it to public at `github.com/users/<owner>/packages/container/agentmemory/settings` so Unraid can pull anonymously. (Alternatively configure registry auth on Unraid, but public is simpler for personal use.)

## Target hardware

The intended host is a Celeron-class NAS:

- Intel Celeron N5105, 4 cores, no hyperthreading, no AVX2.
- 32 GB RAM.
- SSD cache pool, appdata is cache-only.

The Celeron is the only constraint and it is bypassed by the cloud-embeddings rule: embeddings, compression, consolidation, and graph extraction all run on your configured LLM/embedding provider (Gemini by default; any supported provider works). The NAS only does orchestration and in-memory BM25 search, both light.

Contention risk is real but bounded. The host already runs Plex (transcodes), a chromium container, and an arr stack. agentmemory's background timers (consolidation, graph) are LLM-bound and wait on the provider, so the local spike is a few seconds. If contention shows up, pin the container CPU (`--cpus=1.5`) in the Unraid advanced settings.

## Release procedure

Releases are tag-driven. Two version concepts: the **release version** (this repo's semver, from the git tag) and the **bundled agentmemory version** (from `agentmemory.version`, a build detail).

To cut a release:

1. Update `CHANGELOG.md`.
2. Set the `<Repository>` tag in `template/agentmemory.xml` to the new release (e.g. `ghcr.io/estebanforge/agentmemory:1.1.0`).
3. Commit to `main`.
4. `git tag 1.1.0 && git push --tags`. CI builds `:1.1.0`, `:1.1.0-am<bundled>`, and `:latest`.
5. Click Update in the Unraid Apps tab. `/data` persists.

To bump only the bundled agentmemory version: edit `agentmemory.version`, then cut a release.

Bump `III_VERSION` and `III_SDK_VERSION` together, set to the exact `iii-sdk` version agentmemory itself pins (verify: `npm view @agentmemory/agentmemory@<version> dependencies.iii-sdk`). Lockstep failure signature: EPIPE reconnect loops and empty search-after-save.

To re-vendor from upstream (when `deploy/fly/Dockerfile` or `entrypoint.sh` change upstream):

1. Diff the upstream files against the vendored copies.
2. Pull the changes that matter.
3. Re-apply the three deviations above. They are the point of the fork.

## Decisions log

- **Image source: GHCR under the repo owner, personal scope.** Not submitted to the Community Applications store. The template is community-ready (proper metadata, raw `TemplateURL`-shaped paths) so submission is a later option with no rework.
- **Image tag pinned to the release version.** The template pins `:<release>` (e.g. `:1.0.0`) for controlled upgrades. `:latest` exists for convenience but is not what the template references.
- **Tag-driven CI, not per-commit.** The workflow runs only on version tags (`X.Y.Z`) so commits to `main` do not rebuild. The release version is taken from the tag; the bundled agentmemory version from `agentmemory.version`.
- **Multi-provider template surface.** The template exposes every LLM and embedding provider agentmemory supports (Gemini, OpenAI, OpenAI-compatible, Anthropic, MiniMax, OpenRouter, Voyage, Cohere), so users pick their provider at install without hand-editing. Cloud embeddings are mandatory (local omitted).
- **PNG tile icon, not SVG.** Unraid tile rendering historically prefers PNG. The tile icon is `logo.png`, rendered at 256x256 from upstream's `assets/logo.svg`. Self-hosted in `assets/` so the tile does not depend on upstream.
- **Bundled agentmemory 0.9.30** (npm `latest` dist-tag). The repo's own version is independent semver (1.0.3) from the git tag.

## Known risks

- The `GEMINI_MODEL` tag (`gemini-3.5-flash-lite`) is set by the template, carried from release 1.0.1. `gemini-2.5-flash-lite` is retired by Google (404 for new API users) and must not be used. The upstream code default (0.9.29) is `gemini-3.7-flash`; the template overrides it with the non-thinking lite tier to avoid burst stream drops. If Google renames or withdraws the tag again, compression fails with 404s; verify the tag resolves before relying on it.
- `AGENTMEMORY_SECRET` is the only auth on `:3111` and `:3113`. Fine on a trusted home LAN. On any other network, put the container behind a reverse proxy with TLS or restrict the published ports.
- Cold start is ~9 to 10 seconds while indexes hydrate. The healthcheck `start_period` of 30 seconds covers it.
