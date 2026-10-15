# Release runbook: image chain, rebuild order, verification

Three images form a chain — each one bakes the previous at BUILD time:

```
hermes-agent (:latest)  →  hermes-webui fork (:latest / :sha-*)  →  hermes-cloud-image (:latest / :sha-*)
        ↑ agent repo CI                  ↑ webui fork CI                    ↑ this repo CI
```

A fix is only live in production when it has traveled the WHOLE chain:
agent push green → cloud-image rebuilt AFTER that → Coolify actually pulled
the new digest. Skipping any hop replays stale code with zero errors at
deploy time (this exact failure happened 2026-10-12: two rebuilds raced an
agent fix and the container kept dying with the old error).

## Rules

1. **Agent CI green ⇒ immediately dispatch a cloud-image build.**
   `workflow_dispatch` exists for this. The cloud build pins `AGENT_IMAGE`
   by tag (`:latest`), so whatever is current at build start is what gets
   baked. A cloud build that starts before the agent manifest moves embeds
   the old agent — silently.
2. **Verify by digest, never by tag name.** Rebuilding on the same commit
   reuses the same `:sha-*` tag name with a NEW digest. Tag equality proves
   nothing.
3. **Coolify Redeploy reuses local layers.** After an image update, delete +
   recreate the service (same name, same volume — data is untouched) so the
   daemon pulls the new digest. A plain redeploy keeps running the old bytes.
4. **Same-volume redeploys rely on runtime migration, not re-seeding.**
   `stage2` only seeds MISSING files; existing `config.yaml` files are migrated
   by the in-agent `ensure_*` backfills on first use (look for the
   `backfilled ...` line in container logs as proof). If a fix changes the
   canonical config shape, the backfill — not the template — is what heals
   old volumes. New volumes get the shape from the template directly.

## Verification checklist (after any chain change)

On any machine with docker (no prod access needed):

```bash
# 1. agent layer fresh?
docker pull ghcr.io/johnsonbuilds/hermes-agent:latest
docker run --rm --entrypoint /bin/grep <img> -n "<marker of the fix>" /opt/hermes/<file>

# 2. cloud layer embedded the fresh agent?
docker pull ghcr.io/johnsonbuilds/hermes-cloud-image:<tag>
docker run --rm --entrypoint /bin/grep <img> -n "<same marker>" /opt/hermes/<file>

# 3. prod container == registry digest?
# on the Docker host:
docker inspect <cid> --format '{{.Image}}'
docker buildx imagetools inspect ghcr.io/johnsonbuilds/hermes-cloud-image:<tag> | grep -i digest
# equal => live; different => delete + recreate the service
```

## Future automation (not yet built)

- Cloud workflow follows agent releases automatically (scheduled digest check
  or `repository_dispatch` from the agent repo) instead of manual dispatch.
- Backend `/deploy-webui` pins an explicit image digest per release instead of
  a floating tag, closing the race structurally.
