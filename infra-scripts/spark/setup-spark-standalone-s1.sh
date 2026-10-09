#!/usr/bin/env bash
#
# setup-spark-standalone.sh
#
# Fully self-contained, single-node Spark environment: Java 17, Apache
# Spark (standalone mode), and Apache Zeppelin, all installed and
# started on ONE Linux instance. No external inventory, no SSH to other
# hosts, no separate scripts — everything this environment needs is
# provisioned and launched by this file alone.
#
# Re-running this script is safe. Package installs and downloads are
# skipped if already present; the Spark and Zeppelin daemons are always
# stopped and restarted cleanly on each run, so the running state and
# open ports always match this file's current configuration (adjusting
# NUM_WORKERS, WORKER_CORES, etc. and re-running takes effect reliably).
#
# Usage:
#   sudo ./setup-spark-standalone.sh
#   sudo NUM_WORKERS=4 ./setup-spark-standalone.sh
#
set -euo pipefail

# ============================== CONFIGURATION ==============================
# Adjust these to change the shape of the cluster this script builds.

NUM_MASTERS="${NUM_MASTERS:-1}"      # Standalone Spark supports exactly ONE
                                      # active master without ZooKeeper-based
                                      # HA, which is a separate, more complex
                                      # topology outside this script's scope.
                                      # Leave at 1 — see validation below.

NUM_WORKERS="${NUM_WORKERS:-2}"      # Number of independent worker JVMs to
                                      # launch on this node, each bound to
                                      # its own port. Freely adjustable.

SPARK_VERSION="4.1.2"                # NOT on Zeppelin 0.12.1's internal
                                      # "officially supported" whitelist
                                      # (that list was built against the
                                      # 4.0.x line specifically). The
                                      # interpreter.json patch below
                                      # disables that version check so
                                      # 4.1.2 is allowed to open anyway.
HADOOP_VERSION="hadoop3"
ZEPPELIN_VERSION="0.12.1"            # Must be 0.12.1+ — earlier Zeppelin
                                      # releases (incl. 0.11.x) predate
                                      # official Spark 4.x support and fail
                                      # with "Spark major version '4' is
                                      # not supported yet" at interpreter
                                      # startup.

SPARK_HOME="/opt/spark"
ZEPPELIN_HOME="/opt/zeppelin"

MASTER_PORT=7077                     # Spark master's internal cluster port
MASTER_WEBUI_PORT=8080               # Spark master's web UI
WORKER_WEBUI_PORT_BASE=8081          # Worker instance i's UI listens on BASE + (i-1)
WORKER_CORES="${WORKER_CORES:-1}"    # CPU cores allotted to EACH worker instance
WORKER_MEMORY="${WORKER_MEMORY:-1g}" # RAM allotted to EACH worker instance
ZEPPELIN_PORT=8890                   # Zeppelin notebook web UI

# =============================================================================

if [ "${NUM_MASTERS}" -ne 1 ]; then
  echo "ERROR: NUM_MASTERS=${NUM_MASTERS} is not supported." >&2
  echo "Standalone Spark allows exactly one active master unless you add" >&2
  echo "ZooKeeper-based high availability, which this script does not set" >&2
  echo "up. Set NUM_MASTERS=1, or ask for the HA variant of this script." >&2
  exit 1
fi

LOCAL_IP="$(hostname -I | awk '{print $1}')"

echo "==> [1/6] Installing prerequisites (Java 17, Python 3.10+, wget)"
apt-get update -y
apt-get install -y openjdk-17-jdk-headless python3.10 python3-pip wget

echo "==> [2/6] Installing Spark ${SPARK_VERSION}"
if [ -f "${SPARK_HOME}/bin/spark-submit" ]; then
  echo "    Spark already installed at ${SPARK_HOME} — skipping."
else
  cd /tmp
  wget -q "https://dlcdn.apache.org/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-${HADOOP_VERSION}.tgz"
  mkdir -p "${SPARK_HOME}"
  tar -xzf "spark-${SPARK_VERSION}-bin-${HADOOP_VERSION}.tgz" -C "${SPARK_HOME}" --strip-components=1
  rm "spark-${SPARK_VERSION}-bin-${HADOOP_VERSION}.tgz"
fi

echo "==> [3/6] Installing Zeppelin ${ZEPPELIN_VERSION}"
if [ -f "${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" ]; then
  echo "    Zeppelin already installed at ${ZEPPELIN_HOME} — skipping."
else
  cd /tmp
  wget -q "https://dlcdn.apache.org/zeppelin/zeppelin-${ZEPPELIN_VERSION}/zeppelin-${ZEPPELIN_VERSION}-bin-all.tgz"
  mkdir -p "${ZEPPELIN_HOME}"
  tar -xzf "zeppelin-${ZEPPELIN_VERSION}-bin-all.tgz" -C "${ZEPPELIN_HOME}" --strip-components=1
  rm "zeppelin-${ZEPPELIN_VERSION}-bin-all.tgz"
fi

echo "==> [4/6] Configuring environment"
if [ ! -f /etc/profile.d/spark.sh ]; then
  cat > /etc/profile.d/spark.sh <<EOF
export SPARK_HOME=${SPARK_HOME}
export ZEPPELIN_HOME=${ZEPPELIN_HOME}
export PATH=\$SPARK_HOME/bin:\$SPARK_HOME/sbin:\$ZEPPELIN_HOME/bin:\$PATH
export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(which java))))
EOF
fi
# shellcheck disable=SC1091
source /etc/profile.d/spark.sh

# Configure Spark itself: SPARK_WORKER_INSTANCES tells start-worker.sh to
# launch NUM_WORKERS separate worker JVMs from a single invocation, each
# correctly numbered and each given its own web UI port automatically
# (base port + instance offset). This is the supported mechanism for
# multiple workers on one node — calling start-worker.sh repeatedly by
# hand causes a PID-file collision, since every invocation otherwise
# defaults to "instance 1".
cat > "${SPARK_HOME}/conf/spark-env.sh" <<EOF
export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(which java))))
export SPARK_MASTER_PORT=${MASTER_PORT}
export SPARK_MASTER_WEBUI_PORT=${MASTER_WEBUI_PORT}
export SPARK_WORKER_INSTANCES=${NUM_WORKERS}
export SPARK_WORKER_CORES=${WORKER_CORES}
export SPARK_WORKER_MEMORY=${WORKER_MEMORY}
export SPARK_WORKER_WEBUI_PORT=${WORKER_WEBUI_PORT_BASE}
EOF
chmod +x "${SPARK_HOME}/conf/spark-env.sh"

# Point Zeppelin's Spark interpreter at this node's own master, and pin
# its web UI to ZEPPELIN_PORT.
cat > "${ZEPPELIN_HOME}/conf/zeppelin-env.sh" <<EOF
export SPARK_HOME=${SPARK_HOME}
export MASTER=spark://localhost:${MASTER_PORT}
export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(which java))))
export ZEPPELIN_PORT=${ZEPPELIN_PORT}
export ZEPPELIN_ADDR=0.0.0.0
EOF

# Zeppelin 0.12.0+ enforces stricter WebSocket/REST origin validation
# (fixing CVE-2024-51775, a missing-origin-validation vulnerability in
# 0.11.1–0.12.0). Left at its unconfigured default, this can reject
# logins from any address other than exactly "localhost" with an
# "origin not allowed" error — which is why a browser reaching this box
# by its LAN IP needs that IP's origin explicitly permitted here.
ZEPPELIN_SITE_XML="${ZEPPELIN_HOME}/conf/zeppelin-site.xml"
if [ ! -f "${ZEPPELIN_SITE_XML}" ]; then
  cp "${ZEPPELIN_HOME}/conf/zeppelin-site.xml.template" "${ZEPPELIN_SITE_XML}"
fi
python3 - "${ZEPPELIN_SITE_XML}" "${LOCAL_IP}" "${ZEPPELIN_PORT}" <<'PYEOF'
import re
import sys

path, local_ip, port = sys.argv[1], sys.argv[2], sys.argv[3]
allowed_origins = f"http://localhost:{port},http://{local_ip}:{port}"

with open(path) as f:
    content = f.read()

pattern = re.compile(
    r"(<name>zeppelin\.server\.allowed\.origins</name>\s*<value>)[^<]*(</value>)"
)
new_content, count = pattern.subn(
    lambda m: m.group(1) + allowed_origins + m.group(2), content
)
if count == 0:
    raise SystemExit(
        "ERROR: zeppelin.server.allowed.origins property not found in "
        f"{path} — template format may have changed; edit it manually."
    )

with open(path, "w") as f:
    f.write(new_content)
PYEOF

echo "==> [5/6] Restarting Spark master and ${NUM_WORKERS} worker instance(s)"

# Always stop any existing daemons before starting fresh ones. This is
# deliberate, not optional: an idempotent "skip if already running" check
# cannot tell whether what's already running matches the CURRENT config
# (worker count, ports, memory/cores). A stale instance from an earlier
# run/config is exactly what produces Spark's "already running as process
# N. Stop it first." error. Stopping first guarantees convergence — what's
# running after this script finishes always matches what's configured
# above — at the cost of a few seconds of restart on every run.
"${SPARK_HOME}/sbin/stop-worker.sh" 2>/dev/null || true
"${SPARK_HOME}/sbin/stop-master.sh" 2>/dev/null || true
sleep 2

"${SPARK_HOME}/sbin/start-master.sh"
# A single start-worker.sh call, driven by SPARK_WORKER_INSTANCES in
# spark-env.sh (set above), launches all NUM_WORKERS instances with
# correct, non-colliding instance numbers and auto-incremented UI ports.
"${SPARK_HOME}/sbin/start-worker.sh" "spark://localhost:${MASTER_PORT}"

echo "==> [6/6] Restarting Zeppelin"
"${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" stop 2>/dev/null || true
sleep 2

# interpreter.json is generated by Zeppelin itself at first startup — it
# is NOT shipped in the distribution tarball, so it won't exist yet on a
# fresh install. If it's missing, start Zeppelin briefly just to have it
# generate the file, then stop it again before patching. On every run
# (fresh or not) we then set zeppelin.spark.enableSupportedVersionCheck
# to false in the spark interpreter's properties, since Spark 4.1.2 is
# newer than what Zeppelin 0.12.1's interpreter whitelist was built
# against and is otherwise rejected with "This is not officially
# supported spark version" at interpreter-open time.
ZEPPELIN_INTERPRETER_JSON="${ZEPPELIN_HOME}/conf/interpreter.json"
if [ ! -f "${ZEPPELIN_INTERPRETER_JSON}" ]; then
  echo "    Bootstrapping interpreter.json (first run only)"
  "${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" start
  for i in $(seq 1 30); do
    [ -f "${ZEPPELIN_INTERPRETER_JSON}" ] && break
    sleep 2
  done
  "${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" stop
  sleep 2
fi

if [ -f "${ZEPPELIN_INTERPRETER_JSON}" ]; then
  python3 - "${ZEPPELIN_INTERPRETER_JSON}" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

settings = data.get("interpreterSettings", {})
patched = False
for setting in settings.values():
    if setting.get("name") == "spark":
        props = setting.setdefault("properties", {})
        props["zeppelin.spark.enableSupportedVersionCheck"] = {
            "name": "zeppelin.spark.enableSupportedVersionCheck",
            "value": "false",
            "type": "checkbox",
        }
        patched = True

if patched:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
else:
    print(
        "WARNING: no 'spark' interpreter setting found in interpreter.json "
        "— enableSupportedVersionCheck was NOT set. Set it manually via "
        "Interpreter > spark in the Zeppelin UI if needed.",
        file=sys.stderr,
    )
PYEOF
else
  echo "WARNING: interpreter.json still not found after bootstrap attempt" >&2
  echo "         — could not disable the Spark version check automatically." >&2
  echo "         Set it manually via Interpreter > spark in the Zeppelin UI." >&2
fi

"${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh" start

echo ""
echo "================================================================"
echo " Standalone Spark + Zeppelin environment is up."
echo ""
echo "   Spark master UI:  http://${LOCAL_IP}:${MASTER_WEBUI_PORT}"
echo "   Connect string:   spark://localhost:${MASTER_PORT}"
for i in $(seq 1 "${NUM_WORKERS}"); do
  echo "   Worker ${i} UI:      http://${LOCAL_IP}:$((WORKER_WEBUI_PORT_BASE + i - 1))"
done
echo "   Zeppelin UI:       http://${LOCAL_IP}:${ZEPPELIN_PORT}"
echo "================================================================"
