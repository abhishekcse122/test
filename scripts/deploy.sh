#!/usr/bin/env bash
set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-/var/www/app}"
USE_DOCKER="${USE_DOCKER:-false}"
SERVICE_NAME="${SERVICE_NAME:-}"

cd "${DEPLOY_PATH}"

if [[ "${USE_DOCKER}" == "true" ]]; then
  if command -v docker >/dev/null 2>&1; then
    if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f compose.yml ] || [ -f compose.yaml ]; then
      (docker compose pull || docker-compose pull) || true
      (docker compose up -d --build || docker-compose up -d --build)
    else
      echo "No docker compose file found; skipping docker deployment."
    fi
  else
    echo "Docker not installed on remote host."
    exit 1
  fi
else
  if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
    npm ci --omit=dev || npm ci || true
    if npm run | grep -q " build"; then
      npm run build || true
    fi
  fi

  if [ -f requirements.txt ] && command -v python3 >/dev/null 2>&1; then
    python3 -m venv .venv || true
    # shellcheck disable=SC1091
    source .venv/bin/activate || true
    pip install --upgrade pip || true
    pip install -r requirements.txt || true
    deactivate || true
  fi

  if [ -n "${SERVICE_NAME}" ]; then
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl daemon-reload || true
      sudo systemctl restart "${SERVICE_NAME}"
      sudo systemctl status --no-pager -n 20 "${SERVICE_NAME}" || true
    else
      echo "systemctl not found; cannot restart ${SERVICE_NAME}"
      exit 1
    fi
  else
    echo "SERVICE_NAME not set; skipped service restart."
  fi
fi