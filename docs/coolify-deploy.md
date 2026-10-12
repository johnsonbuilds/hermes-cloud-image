# Coolify deployment notes (verified 2026-10-11)

How to deploy this image from the Coolify dashboard, and the one
ownership pitfall that crash-loops both gateway and WebUI.

## Service settings (manual dashboard flow)

| Item | Value |
|---|---|
| Image | `ghcr.io/johnsonbuilds/hermes-cloud-image:<tag>` (`:latest` for trials, `:sha-*`/`:v*` for production) |
| Port mapping | host-port `→` **8787 only** (`8642` stays container-internal; the WebUI reaches it over loopback) |
| Volume | host dir (bind) `→` `/opt/data`, read-write |
| Resources | 1 CPU / 2560m RAM / pids 512 (same as the agent-only baseline, +headroom for the WebUI process) |
| User / docker options | leave empty (image defaults are correct; Docker's default capabilities already cover `s6-setuidgid`) |

Required env (all three, plus the two UIDs below):

| Variable | Value | If missing |
|---|---|---|
| `HERMES_WEBUI_PASSWORD` | per-tenant password | WebUI exposed on `0.0.0.0` with no auth |
| `API_SERVER_KEY` | 16+ random chars | gateway `8642` listener never binds; Tasks panel shows gateway unreachable (chat still works) |
| `HERMES_WEBUI_GATEWAY_API_KEY` | same value as `API_SERVER_KEY` | WebUI health probe fails auth, same symptom as above |
| `HERMES_UID` | `1000` | **see ownership pitfall** |
| `HERMES_GID` | `1000` | **see ownership pitfall** |

Do NOT rely on the auto-generated `API_SERVER_KEY`: on a first boot
without the env var, stage2 writes a generated key into `/opt/data/.env`,
which then shadows the env value at runtime (`override=True`) and is
invisible to the orchestrator. Always set it explicitly and keep
`HERMES_WEBUI_GATEWAY_API_KEY` identical
(verify: `grep -E "^API_SERVER_KEY" /opt/data/.env`).

## Ownership pitfall: Coolify resets the data dir to 1000:1000

Coolify (re)deploy resets the application data dir to `1000:1000`
(`deploy:deploy` owns the parents, the leaf and all contents become
`1000:1000`). The image default runtime user is `hermes` (`10000:10000`),
so after **every redeploy** both processes lose write access to
`/opt/data`:

- gateway crash-loops: `PermissionError: /opt/data/platforms/pairing`
  (plus `backups/`, `skills/`, `plugins/`, stale `gateway.pid` cleanup);
- WebUI dies at import: `RuntimeError: Could not create or access any
  usable workspace directory`, s6 slot reports `down`, `/health`
  connection-reset;
- even `s6-log` fails with `mkdir: Permission denied`.

Host-side `chown -R 10000:10000` only fixes it until the next redeploy,
which reverts the tree to `1000:1000` again. The durable fix is the
image-native remap (`HERMES_UID=1000`, `HERMES_GID=1000`, applied via
usermod + targeted chown at stage2): user and directory converge on
`1000:1000` and redeploys stop breaking. Backend automation therefore
needs no host SSH/provision-time chown — just the two env vars
(see `deploy_jobs.py` hermes env list).

## Verification (run on the Docker host, then in the browser)

```bash
CID=$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | grep -i cloud | awk '{print $1}' | head -n1)
docker logs $CID 2>&1 | grep -c "Traceback"       # must stop growing
docker logs $CID 2>&1 | grep -c "PermissionError" # must stop growing
docker exec $CID /command/s6-svstat /run/service/webui   # want: up
docker exec --user hermes $CID touch /opt/data/platforms/.w /opt/data/skills/.w /opt/data/backups/.w \
  && echo WRITE-OK && docker exec $CID rm /opt/data/platforms/.w /opt/data/skills/.w /opt/data/backups/.w
curl -fsS http://127.0.0.1:<host-port>/health; echo   # {"status":"ok",...}
```

Browser: password login → send one chat turn (proves session writes
under `/opt/data/webui`) → Tasks panel gateway pill green (proves
`8642` + key pair). If `Traceback` keeps growing after a fix, check
whether Coolify recreated the container (`docker inspect` `Created`)
and re-verify ownership on both sides:

```bash
P=<host data dir>
ls -ldn $P $P/platforms $P/skills $P/backups          # host view
docker exec $CID ls -ldn /opt/data /opt/data/platforms # container view (must agree; no userns remap here)
docker exec $CID cat /proc/self/uid_map                # 0 0 4294967295 = no remap
```
