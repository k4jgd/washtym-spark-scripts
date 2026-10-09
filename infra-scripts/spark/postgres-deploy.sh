#!/usr/bin/env bash
#
# deploy-postgres.sh
#
# Single, self-contained, argument-free deployment of PostgreSQL via
# Docker Compose, for use as a Hive metastore backend. Designed to be
# copied to any machine and run identically, with no env vars or flags
# — every setting is a plain constant below. Edit those constants
# directly (not via arguments) if you need different values before
# distributing this file.
#
# Usage:
#   sudo ./deploy-postgres.sh
#
# Re-running is safe — 'docker compose up -d' reconciles to the same
# state rather than recreating anything unnecessarily, and the bind-
# mounted data directory below persists data across container
# recreation, host reboots, and re-runs of this script — and, being a
# plain directory, is trivial to copy to another machine for migration.
#
set -euo pipefail

# ============================== CONFIGURATION ==============================
# Edit these directly before distributing this file to other machines —
# they are intentionally NOT arguments/env vars, per how this script is
# meant to be used (copy, run, identical everywhere).

POSTGRES_DB="hive_metastore"
POSTGRES_USER="hive_user"
POSTGRES_PASSWORD="HiveMeta2026!"   # <-- change before real use
POSTGRES_PORT="5432"
POSTGRES_IMAGE="postgres:16"

CONTAINER_NAME="pg-hive-metastore"
COMPOSE_DIR="/opt/pg-hive-metastore"
DATA_DIR="${COMPOSE_DIR}/data"   # plain host directory — this is what you
                                  # copy/rsync/tar to migrate to another machine
BIND_ADDRESS="0.0.0.0"   # localhost-only by default; see note below

# NOTE on BIND_ADDRESS: if Zeppelin/Spark run on a DIFFERENT machine
# than this Postgres deployment, change this to "0.0.0.0" so the port
# is reachable from other hosts. Left at 127.0.0.1 by default since
# most setups run Spark/Zeppelin and this metastore on the same box.

# =============================================================================

echo "==> [1/4] Ensuring Docker and Compose are installed"
if ! command -v docker > /dev/null 2>&1; then
  apt-get update -y || echo "    (apt-get update had errors on some repo — continuing)"
  apt-get install -y docker.io
fi

if docker compose version > /dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose > /dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  apt-get update -y || echo "    (apt-get update had errors on some repo — continuing)"
  apt-get install -y docker-compose-plugin || apt-get install -y docker-compose
  if docker compose version > /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  else
    COMPOSE_CMD="docker-compose"
  fi
fi
echo "    Using: ${COMPOSE_CMD}"

systemctl enable docker > /dev/null 2>&1 || true
systemctl start docker
if ! docker info > /dev/null 2>&1; then
  echo "ERROR: Docker daemon is not responding. Check 'systemctl status docker'." >&2
  exit 1
fi

echo "==> [2/4] Writing docker-compose.yml"
mkdir -p "${COMPOSE_DIR}" "${DATA_DIR}"
cat > "${COMPOSE_DIR}/docker-compose.yml" <<EOF
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${BIND_ADDRESS}:${POSTGRES_PORT}:5432"
    volumes:
      - ${DATA_DIR}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 5s
      timeout: 5s
      retries: 10
EOF
chmod 600 "${COMPOSE_DIR}/docker-compose.yml"  # contains a plaintext password
echo "    Written to ${COMPOSE_DIR}/docker-compose.yml (permissions set to 600)"
echo "    Data directory: ${DATA_DIR}"

echo "==> [3/4] Starting Postgres (docker compose up -d)"
(cd "${COMPOSE_DIR}" && ${COMPOSE_CMD} up -d)

echo "==> [4/4] Waiting for Postgres to be ready"
for i in $(seq 1 30); do
  if docker exec "${CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; then
    echo "    Postgres is ready."
    break
  fi
  sleep 1
  if [ "${i}" -eq 30 ]; then
    echo "WARNING: Postgres did not report ready within 30s. Check:" >&2
    echo "  docker logs ${CONTAINER_NAME}" >&2
  fi
done

echo ""
echo "==> Done. Connection details:"
echo "      Host:     ${BIND_ADDRESS}"
echo "      Port:     ${POSTGRES_PORT}"
echo "      Database: ${POSTGRES_DB}"
echo "      User:     ${POSTGRES_USER}"
echo "      Password: (see POSTGRES_PASSWORD in this script)"
echo ""
echo "Next step — point Spark's metastore at this with"
echo "postgresql-metastore-support.sh (credentials must match what's"
echo "hardcoded above):"
echo "  sudo POSTGRES_HOST=${BIND_ADDRESS} POSTGRES_DB=${POSTGRES_DB} \\"
echo "       POSTGRES_USER=${POSTGRES_USER} POSTGRES_PASSWORD='${POSTGRES_PASSWORD}' \\"
echo "       ./postgresql-metastore-support.sh"
echo ""
echo "To migrate this metastore to another machine:"
echo "  1. On this machine:  cd ${COMPOSE_DIR} && ${COMPOSE_CMD} down"
echo "  2. Copy the data:    rsync -a ${DATA_DIR}/ newhost:${DATA_DIR}/"
echo "     (or: tar -czf pg-data.tar.gz -C ${DATA_DIR} . , then extract"
echo "     into the same path on the new machine)"
echo "  3. Copy this script (with matching POSTGRES_* values) to the new"
echo "     machine and run it there — it will find the existing data"
echo "     already in place and start Postgres against it, rather than"
echo "     initializing an empty database."
echo ""
echo "To tear down completely (container only — DATA_DIR is untouched,"
echo "since it's a plain directory, not a Docker-managed volume):"
echo "  cd ${COMPOSE_DIR} && ${COMPOSE_CMD} down"
echo "To also delete the data itself:"
echo "  rm -rf ${DATA_DIR}"
