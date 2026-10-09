#!/usr/bin/env bash
#
# delta-support.sh
#
# Adds Delta Lake support to a box already provisioned by
# setup-spark-standalone.sh. Standalone and separate by design — run
# this any time %spark paragraphs fail with:
#
#   [DATA_SOURCE_NOT_FOUND] Failed to find the data source: delta.
#
# Root cause: .format("delta") requires the Delta Lake package to be
# registered with Spark. This is never bundled with a base Spark
# install — it must be added explicitly, which this script does
# permanently (via spark-defaults.conf) rather than requiring a
# %spark.conf paragraph in every notebook.
#
# Version pinning: Delta Lake 4.1.0 is the release that added full,
# explicit support for the Spark 4.1.x line (compiled and tested
# against it), via a new Spark-version-suffixed Maven artifact
# (delta-spark_4.1_2.13) introduced specifically to make this pairing
# unambiguous. Delta 4.2.0's published package metadata currently
# excludes Spark 4.1.2 specifically (a known, acknowledged upstream
# packaging bug as of this writing) — reason enough to deliberately
# stay on 4.1.0 rather than grabbing "latest".
#
# Assumes setup-spark-standalone.sh has already been run (Spark
# installed under /opt/spark by default, on the 4.1.x line).
#
# Usage:
#   sudo ./delta-support.sh
#
set -euo pipefail

SPARK_HOME="${SPARK_HOME:-/opt/spark}"
DELTA_VERSION="${DELTA_VERSION:-4.1.0}"
DELTA_SPARK_ARTIFACT="${DELTA_SPARK_ARTIFACT:-delta-spark_4.1_2.13}"

if [ ! -d "${SPARK_HOME}/conf" ]; then
  echo "ERROR: ${SPARK_HOME}/conf not found. Is SPARK_HOME correct, and" >&2
  echo "       has setup-spark-standalone.sh already been run?" >&2
  exit 1
fi

echo "==> [1/2] Configuring spark-defaults.conf for Delta Lake"
echo "    Package: io.delta:${DELTA_SPARK_ARTIFACT}:${DELTA_VERSION}"

SPARK_DEFAULTS="${SPARK_HOME}/conf/spark-defaults.conf"
touch "${SPARK_DEFAULTS}"

# Remove any previous Delta-related lines this script added, so
# re-running with a different DELTA_VERSION/DELTA_SPARK_ARTIFACT
# replaces rather than duplicates them.
sed -i '/^spark\.jars\.packages.*io\.delta/d' "${SPARK_DEFAULTS}"
sed -i '/^spark\.sql\.extensions/d' "${SPARK_DEFAULTS}"
sed -i '/^spark\.sql\.catalog\.spark_catalog/d' "${SPARK_DEFAULTS}"

{
  echo "spark.jars.packages                 io.delta:${DELTA_SPARK_ARTIFACT}:${DELTA_VERSION}"
  echo "spark.sql.extensions                io.delta.sql.DeltaSparkSessionExtension"
  echo "spark.sql.catalog.spark_catalog     org.apache.spark.sql.delta.catalog.DeltaCatalog"
} >> "${SPARK_DEFAULTS}"

echo "    Written to ${SPARK_DEFAULTS}"
echo ""
echo "NOTE: spark.jars.packages resolves via Ivy at Spark startup (not a"
echo "      pre-downloaded jar, unlike how s3-support.sh handles hadoop-aws)."
echo "      The first paragraph run after this WILL be slower — Spark"
echo "      downloads Delta and its transitive dependencies from Maven"
echo "      Central the first time, then caches them under ~/.ivy2 for"
echo "      every run after that."

echo "==> [2/2] Done"
echo ""
echo "IMPORTANT: the Zeppelin Spark interpreter is a separate process"
echo "that does NOT pick up spark-defaults.conf changes on its own or"
echo "reliably via the UI's 'restart' button — force it directly:"
echo ""
echo "  pgrep -fl RemoteInterpreterServer"
echo "  sudo pkill -f RemoteInterpreterServer"
echo ""
echo "Then run a fresh paragraph (a new interpreter process spawns"
echo "automatically, resolving Delta via Ivy on this first run) and test:"
echo ""
echo "  %spark"
echo "  spark.range(5).write.format(\"delta\").mode(\"overwrite\")"
echo "    .save(\"s3a://your-bucket/delta-hello-world/\")"
echo "  spark.read.format(\"delta\").load(\"s3a://your-bucket/delta-hello-world/\").show()"
