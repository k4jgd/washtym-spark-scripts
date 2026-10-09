#!/usr/bin/env bash
#
# pyspark-support.sh
#
# Adds PySpark support to a box already provisioned by
# setup-spark-standalone.sh. Standalone and separate by design — run
# this any time PySpark notebooks fail with:
#
#   Cannot run program "python" (in directory "."): error=2, No such
#   file or directory
#
# Root cause: Ubuntu deliberately ships only a "python3" binary, not a
# plain "python" one, but Zeppelin's Python/PySpark interpreter shells
# out to the literal command "python". This script installs the
# standard Debian/Ubuntu package that provides that symlink, then
# restarts Zeppelin so the interpreter picks it up.
#
# Assumes setup-spark-standalone.sh has already been run (Spark and
# Zeppelin installed under /opt/spark and /opt/zeppelin by default).
#
# Usage:
#   sudo ./pyspark-support.sh
#
set -euo pipefail

ZEPPELIN_HOME="${ZEPPELIN_HOME:-/opt/zeppelin}"

echo "==> [1/2] Installing python-is-python3"
apt-get update -y
apt-get install -y python-is-python3

echo "    Verifying 'python' now resolves:"
if command -v python > /dev/null 2>&1; then
  echo "    $(python --version) -> $(command -v python)"
else
  echo "ERROR: 'python' still not found on PATH after install." >&2
  echo "       Check that /usr/bin/python-is-python3's symlink was created:" >&2
  echo "         ls -l /usr/bin/python" >&2
  exit 1
fi

ZEPPELIN_DAEMON="${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh"
if [ -x "${ZEPPELIN_DAEMON}" ]; then
  echo "==> [2/2] Restarting Zeppelin so the PySpark interpreter picks this up"
  "${ZEPPELIN_DAEMON}" restart
else
  echo "WARNING: ${ZEPPELIN_DAEMON} not found or not executable — could not" >&2
  echo "         restart Zeppelin automatically. Restart it manually:" >&2
  echo "           sudo ${ZEPPELIN_DAEMON} restart" >&2
  echo "         (or restart just the interpreter via Interpreter > spark" >&2
  echo "         > restart in the Zeppelin UI, which avoids a full server" >&2
  echo "         restart)." >&2
fi

echo ""
echo "==> Done. Test with a new paragraph:"
echo "      %spark.pyspark"
echo "      print(spark.version)"
