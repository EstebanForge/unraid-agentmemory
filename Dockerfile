# Self-contained agentmemory image for Unraid.
# Vendored from rohitg00/agentmemory deploy/fly/Dockerfile (the documented variant).
# Engine (iii) is copied from the official iiidev/iii image; the worker
# (@agentmemory/agentmemory) is pulled from npm at build time. No upstream
# fork required.
#
# Multi-arch: linux/amd64 + linux/arm64 (both base images are multi-arch).

ARG III_VERSION=0.11.2

# Stage 1: grab the prebuilt iii engine binary.
FROM iiidev/iii:${III_VERSION} AS iii-image

# Stage 2: node runtime + engine + worker. Node 24 is the current Active LTS
# and is in upstream agentmemory's CI matrix (20/22/24/26), so it is tested.
FROM node:24-slim

ARG AGENTMEMORY_VERSION=0.9.28
ARG III_VERSION=0.11.2
ARG III_SDK_VERSION=0.11.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates tini gosu curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=iii-image /app/iii /usr/local/bin/iii

# Install agentmemory into a dedicated prefix so the local package.json's
# `overrides` field pins iii-sdk down to match the engine (agentmemory's
# caret range `^0.11.2` otherwise resolves to 0.11.6, the version that
# requires the new sandbox-everything worker model the agentmemory CLI
# is not refactored for yet). `npm install -g` ignores overrides, hence
# the local prefix.
#
# --omit=optional drops @huggingface/transformers, so local MiniLM
# embeddings are UNAVAILABLE in this image. A cloud embedding provider
# (Gemini via GEMINI_API_KEY) is mandatory. This is deliberate: it keeps
# the image small and makes CPU-weak hosts (e.g. Intel Celeron NAS)
# viable by forcing embeddings off-host.
WORKDIR /opt/agentmemory
RUN printf '{"name":"agentmemory-deploy","version":"1.0.0","private":true,"overrides":{"iii-sdk":"%s"}}\n' "${III_SDK_VERSION}" > package.json \
 && npm install "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" --omit=optional --no-fund --no-audit \
 && ln -s /opt/agentmemory/node_modules/.bin/agentmemory /usr/local/bin/agentmemory

ENV AGENTMEMORY_III_VERSION=${III_VERSION} \
    TINI_SUBREAPER=1

COPY --chmod=0755 entrypoint.sh /usr/local/bin/agentmemory-entrypoint.sh

EXPOSE 3111 3113

# livez healthcheck, same as upstream deploy/coolify.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3111/agentmemory/livez || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentmemory-entrypoint.sh"]
