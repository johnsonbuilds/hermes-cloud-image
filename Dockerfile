# Hermes Cloud Image — single-container gateway + WebUI for hosted deployment.
#
# This repo owns NO upstream code. It assembles two released images:
#   1. the hermes-agent image (s6-overlay PID 1, gateway as main program,
#      sealed /opt/hermes/.venv) — the base;
#   2. the hermes-webui image — only its source tree (/apptoo) is copied in.
#
# Syncing upstream never merges here: bump versions.env and rebuild.
# See README.md for the Coolify contract and the sync procedure.

ARG AGENT_IMAGE=ghcr.io/johnsonbuilds/hermes-agent:latest
ARG WEBUI_IMAGE=ghcr.io/nesquena/hermes-webui:latest

FROM ${WEBUI_IMAGE} AS webui

FROM ${AGENT_IMAGE} AS runtime

# WebUI source only. The WebUI's own venv/entrypoint (docker_init.bash) is
# intentionally NOT used: server.py runs on the agent's sealed venv, which
# already carries every heavy agent dependency. We add just the WebUI's own
# two hard deps (requirements.txt: pyyaml + cryptography).
COPY --from=webui --chmod=a+rX,go-w /apptoo /opt/webui

# s6-overlay service slot for the WebUI (mirrors the dashboard service:
# longrun + env-gated run/finish pair). Registration is additive — a new
# bundle member file, never an edit to an upstream service.
COPY --chmod=0755 s6-rc.d/webui/run s6-rc.d/webui/finish /etc/s6-overlay/s6-rc.d/webui/
COPY s6-rc.d/webui/type /etc/s6-overlay/s6-rc.d/webui/
COPY s6-rc.d/webui/dependencies.d/base /etc/s6-overlay/s6-rc.d/webui/dependencies.d/
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/webui

RUN /opt/hermes/.venv/bin/pip install --no-cache-dir "pyyaml>=6.0" "cryptography>=42.0"

# WebUI wiring. HERMES_HOME=/opt/data already comes from the agent base.
# The gateway runs as the container main program (main-wrapper.sh default);
# the WebUI reaches it over loopback — no second exposed port needed.
ENV HERMES_WEBUI_ENABLED=1 \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_WEBUI_PORT=8787 \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    HERMES_WEBUI_STATE_DIR=/opt/data/webui \
    HERMES_API_URL=http://127.0.0.1:8642

EXPOSE 8787

# The WebUI is the per-tenant entrypoint Coolify health-checks.
HEALTHCHECK --interval=30s --timeout=8s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8787/health >/dev/null || exit 1

# ENTRYPOINT/CMD intentionally inherited from the agent base (s6 /init +
# gateway main program). Do not override.
