#!/usr/bin/env bash
#
# start-spark-cluster.sh
#
# Starts the Spark standalone master, worker(s), and Zeppelin daemons on a
# node that has already been provisioned by setup-spark-standalone-s1.sh.
# Does NOT reinstall anything — assumes SPARK_HOME and ZEPPELIN_HOME are
# already in place with their conf/ directories fully written.
#
# Re-running is safe: existing daemons are stopped cleanly before starting
# fresh ones, so the running state always converges to the current config.
#
# Usage:
#   sudo ./start-spark-cluster.sh
#   sudo NUM_WORKERS=4 ./start-spark-cluster.sh
#
set -euo pipefail

# ============================== CONFIGURATION ==============================
# Mirror the values used in setup-spark-standalone-s1.sh. Override via env
# vars if the cluster shape was customised at setup time.

SPARK_HOME="${SPARK_HOME:-/opt/spark}"
ZEPPELIN_HOME="${ZEPPELIN_HOME:-/opt/zeppelin}"

MASTER_PORT="${MASTER_PORT:-7077}"
MASTER_WEBUI_PORT="${MASTER_WEBUI_PORT:-8080}"
WORKER_WEBUI_PORT_BASE="${WORKER_WEBUI_PORT_BASE:-8081}"
ZEPPELIN_PORT="${ZEPPELIN_PORT:-8890}"

# NUM_WORKERS is read from spark-env.sh (SPARK_WORKER_INSTANCES) at runtime
# by start-worker.sh. Override here only if you want to launch a different
# number without editing spark-env.sh.
NUM_WORKERS="${NUM_WORKERS:-}"

# =============================================================================

# ── Preflight checks ─────────────────────────────────────────────────────────

if [ ! -f "${SPARK_HOME}/bin/spark-submit" ]; then
  echo "ERROR: Spark not found at ${SPARK_HOME}." >&2
  echo "Run setup-spark-standalone-s1.sh first." >&2
  exit 1
fi

if [ ! -f "${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" ]; then
  echo "ERROR: Zeppelin not found at ${ZEPPELIN_HOME}." >&2
  echo "Run setup-spark-standalone-s1.sh first." >&2
  exit 1
fi

# ── Load environment ──────────────────────────────────────────────────────────

if [ -f /etc/profile.d/spark.sh ]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/spark.sh
fi

# If the caller supplied NUM_WORKERS, write it into spark-env.sh so
# start-worker.sh (which reads SPARK_WORKER_INSTANCES from that file) picks
# it up.  Sed-in-place avoids a full rewrite of the file.
if [ -n "${NUM_WORKERS}" ]; then
  sed -i "s/^export SPARK_WORKER_INSTANCES=.*/export SPARK_WORKER_INSTANCES=${NUM_WORKERS}/" \
    "${SPARK_HOME}/conf/spark-env.sh"
fi

# Resolve the actual instance count from spark-env.sh for the summary banner.
ACTUAL_WORKERS="$(
  # shellcheck disable=SC1091
  source "${SPARK_HOME}/conf/spark-env.sh" 2>/dev/null
  echo "${SPARK_WORKER_INSTANCES:-1}"
)"

LOCAL_IP="$(hostname -I | awk '{print $1}')"

# ── Stop any existing daemons ─────────────────────────────────────────────────

echo "==> [1/3] Stopping existing Spark and Zeppelin daemons (if any)"
"${SPARK_HOME}/sbin/stop-worker.sh"  2>/dev/null || true
"${SPARK_HOME}/sbin/stop-master.sh"  2>/dev/null || true
"${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" stop 2>/dev/null || true
sleep 2

# ── Start Spark master ────────────────────────────────────────────────────────

echo "==> [2/3] Starting Spark master and ${ACTUAL_WORKERS} worker instance(s)"
"${SPARK_HOME}/sbin/start-master.sh"

# start-worker.sh honours SPARK_WORKER_INSTANCES from spark-env.sh and
# launches that many worker JVMs, each with an auto-incremented UI port.
"${SPARK_HOME}/sbin/start-worker.sh" "spark://localhost:${MASTER_PORT}"

# ── Start Zeppelin ────────────────────────────────────────────────────────────

echo "==> [3/3] Starting Zeppelin"
"${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" start

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo " Spark standalone cluster + Zeppelin is up."
echo ""
echo "   Spark master UI:  http://${LOCAL_IP}:${MASTER_WEBUI_PORT}"
echo "   Connect string:   spark://localhost:${MASTER_PORT}"
for i in $(seq 1 "${ACTUAL_WORKERS}"); do
  echo "   Worker ${i} UI:      http://${LOCAL_IP}:$((WORKER_WEBUI_PORT_BASE + i - 1))"
done
echo "   Zeppelin UI:      http://${LOCAL_IP}:${ZEPPELIN_PORT}"
echo "================================================================"
