# hermes-cloud-image

Single-container image for hosted Hermes: **gateway + WebUI in one container**,
deployed per tenant via the Coolify API.

This repo owns no upstream code. It assembles two released images
(pinned in `versions.env`):

- agent base: `ghcr.io/johnsonbuilds/hermes-agent` — s6-overlay PID 1,
  gateway as the container main program, sealed `/opt/hermes/.venv`;
- WebUI source: `ghcr.io/nesquena/hermes-webui` (`/apptoo` tree only —
  its venv/entrypoint are not used; `server.py` runs on the agent venv).

## How it fits together

- `Dockerfile` copies the WebUI source to `/opt/webui`, adds `pyyaml` +
  `cryptography` to the agent venv, and registers one additive s6 service
  (`s6-rc.d/webui/`). Nothing in either base image is patched.
- At runtime the gateway stays the container main program
  (`main-wrapper.sh` default: `hermes gateway`); the WebUI runs as a
  supervised `longrun` service on port 8787 against the same `HERMES_HOME`.
- The WebUI reaches the in-container gateway over loopback
  (`HERMES_API_URL=http://127.0.0.1:8642`); only 8787 needs exposing.

## Coolify contract (per tenant)

| Item | Value |
|---|---|
| Image | `ghcr.io/johnsonbuilds/hermes-cloud-image:latest` (or a pinned `:v*` / `:sha-*`) |
| Exposed port | `8787` (WebUI) |
| Volume | one persistent volume mounted at `/opt/data` (`HERMES_HOME`: config, state, sessions, WebUI sidecars) |
| Health check | `GET /health` on 8787 (baked `HEALTHCHECK` matches) |

Required environment:

| Variable | Purpose |
|---|---|
| `HERMES_WEBUI_PASSWORD` | WebUI login (required whenever 8787 leaves loopback) |
| `API_SERVER_KEY` | gateway API key, 16+ chars (enables the 8642 listener the WebUI Tasks probe uses) |
| `HERMES_WEBUI_GATEWAY_API_KEY` | must equal `API_SERVER_KEY` so the WebUI probe can authenticate |

Optional environment:

| Variable | Default | Purpose |
|---|---|---|
| `HERMES_WEBUI_ENABLED` | `1` | set `0` to park the WebUI slot (gateway-only container) |
| `HERMES_DASHBOARD` | unset (off) | agent-base flag; unchanged by this image |
| `AGENT_GATEWAY_READY_NOTIFY_URL` | unset | agent-fork hook: gateway `GET`s this URL once ready (orchestrator callback) |

Each tenant gets its own container + own `/opt/data` volume: profiles,
sessions, and credentials never cross tenants. Never share one volume
across tenants.

## Local verification

```bash
# Build against the pins:
set -a; source versions.env; set +a
docker build --build-arg AGENT_IMAGE="$AGENT_IMAGE" \
             --build-arg WEBUI_IMAGE="$WEBUI_IMAGE" -t hermes-cloud:local .

# Run with throwaway state:
mkdir -p /tmp/cloud-data
docker run -d --name cloud-local -p 127.0.0.1:8787:8787 \
  -v /tmp/cloud-data:/opt/data \
  -e HERMES_WEBUI_PASSWORD=change-me \
  -e API_SERVER_KEY=$(openssl rand -hex 16) \
  -e HERMES_WEBUI_GATEWAY_API_KEY=$API_SERVER_KEY \
  hermes-cloud:local
curl -fsS http://127.0.0.1:8787/health
# Open http://127.0.0.1:8787, finish onboarding, send one chat turn,
# then check the Tasks panel gateway pill is green.
docker rm -f cloud-local
```

## Picking up upstream releases (conflict-free by construction)

1. Agent or WebUI cuts a release: edit the one line in `versions.env`.
2. Push to `main` (builds `:sha-<sha>`) or tag `v*` (builds `:v*` + `:latest`).
3. CI builds amd64+arm64, merges the manifest, and runs the `/health`
   smoke check.
4. Point the next tenant deploy (or rolling update) at the new tag.

Prefer version tags or digests over `:latest` in `versions.env` for
production so rebuilds are reproducible. Keep the agent and WebUI pins
moving together — the WebUI imports agent modules in-process, and mixed
new/old combinations are untested upstream.
