# unraid-agentmemory docs

Reference documentation for this repo. Split by audience.

## For end users (people running the container)

- [migration.md](migration.md): move an existing agentmemory store from another machine into this Unraid container, step by step.
- [operations.md](operations.md): day-to-day ops (point clients at the NAS, update, back up, troubleshoot).

The repo root [README.md](../README.md) is the quick-start landing page (install, build, env table).

## For maintainers (us)

- [architecture.md](architecture.md): design decisions, the three deviations from upstream, the build pipeline, target hardware, and the release procedure. Read before changing the Dockerfile or entrypoint.
