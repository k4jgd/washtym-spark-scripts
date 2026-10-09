#!/usr/bin/env bash
#
# sqlserver-metastore-support.sh
#
# Configures Spark's Hive metastore (schema/table metadata — the thing
# that was disappearing on every interpreter restart) to persist in an
# existing SQL Server instance, rather than the default in-memory or
# embedded-Derby catalog.
#
# What this does:
#   1. Downloads the Microsoft JDBC driver for SQL Server into Spark's
#      jars directory.
#   2. Generates hive-site.xml with the SQL Server connection details.
#   3. Sets spark.sql.catalogImplementation=hive in spark-defaults.conf,
#      so this metastore is actually used without any per-notebook code.
#
# Standard Spark binary distributions already bundle Hive metastore
# client support (spark-hive, hive-exec, hive-metastore, DataNucleus) —
# nothing extra needed there, only the SQL Server driver.
#
# PREREQUISITE: the SQL Server login you provide needs permission to
# CREATE TABLE in the target database. On first connection, DataNucleus
# (Hive's ORM layer) auto-creates the ~50 metastore schema tables itself
# — there's no separate schema-init step to run manually.
#
# Assumes setup-spark-standalone.sh has already been run.
#
# Usage:
#   sudo SQLSERVER_HOST=myhost.internal \
#        SQLSERVER_DB=hive_metastore \
#        SQLSERVER_USER=hive_user \
#        SQLSERVER_PASSWORD='...' \
#        ./sqlserver-metastore-support.sh
#
# Optional:
#   SQLSERVER_PORT (default 1433)
#   SQLSERVER_ENCRYPT (default true)
#   SQLSERVER_TRUST_SERVER_CERT (default true — common for a dev
#     instance without a CA-signed cert; set to false for anything
#     beyond dev)
#
set -euo pipefail

SPARK_HOME="${SPARK_HOME:-/opt/spark}"
MAVEN_CENTRAL="https://repo1.maven.org/maven2"
MSSQL_JDBC_VERSION="${MSSQL_JDBC_VERSION:-12.8.1.jre11}"

SQLSERVER_HOST="${SQLSERVER_HOST:-}"
SQLSERVER_PORT="${SQLSERVER_PORT:-1433}"
SQLSERVER_DB="${SQLSERVER_DB:-}"
SQLSERVER_USER="${SQLSERVER_USER:-}"
SQLSERVER_PASSWORD="${SQLSERVER_PASSWORD:-}"
SQLSERVER_ENCRYPT="${SQLSERVER_ENCRYPT:-true}"
SQLSERVER_TRUST_SERVER_CERT="${SQLSERVER_TRUST_SERVER_CERT:-true}"

MISSING=()
[ -z "${SQLSERVER_HOST}" ] && MISSING+=("SQLSERVER_HOST")
[ -z "${SQLSERVER_DB}" ] && MISSING+=("SQLSERVER_DB")
[ -z "${SQLSERVER_USER}" ] && MISSING+=("SQLSERVER_USER")
[ -z "${SQLSERVER_PASSWORD}" ] && MISSING+=("SQLSERVER_PASSWORD")

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: missing required variable(s): ${MISSING[*]}" >&2
  echo "" >&2
  echo "Usage:" >&2
  echo "  sudo SQLSERVER_HOST=myhost SQLSERVER_DB=hive_metastore \\" >&2
  echo "       SQLSERVER_USER=hive_user SQLSERVER_PASSWORD='...' \\" >&2
  echo "       ./sqlserver-metastore-support.sh" >&2
  exit 1
fi

if [ ! -d "${SPARK_HOME}/conf" ]; then
  echo "ERROR: ${SPARK_HOME}/conf not found. Is SPARK_HOME correct, and" >&2
  echo "       has setup-spark-standalone.sh already been run?" >&2
  exit 1
fi

echo "==> [1/3] Downloading the SQL Server JDBC driver"
MSSQL_JAR="mssql-jdbc-${MSSQL_JDBC_VERSION}.jar"

if [ -f "${SPARK_HOME}/jars/${MSSQL_JAR}" ]; then
  echo "    ${MSSQL_JAR} already present — skipping."
else
  DOWNLOAD_DIR="$(mktemp -d)"
  trap 'rm -rf "${DOWNLOAD_DIR}"' EXIT
  wget -q -O "${DOWNLOAD_DIR}/${MSSQL_JAR}" \
    "${MAVEN_CENTRAL}/com/microsoft/sqlserver/mssql-jdbc/${MSSQL_JDBC_VERSION}/${MSSQL_JAR}"
  mv "${DOWNLOAD_DIR}/${MSSQL_JAR}" "${SPARK_HOME}/jars/${MSSQL_JAR}"
fi

# Remove any stale driver jar from a previous run with a different
# MSSQL_JDBC_VERSION, so only one version is ever on the classpath.
find "${SPARK_HOME}/jars" -maxdepth 1 -name 'mssql-jdbc-*.jar' ! -name "${MSSQL_JAR}" -delete

echo "==> [2/3] Generating hive-site.xml"
HIVE_SITE_XML="${SPARK_HOME}/conf/hive-site.xml"
JDBC_URL="jdbc:sqlserver://${SQLSERVER_HOST}:${SQLSERVER_PORT};databaseName=${SQLSERVER_DB};encrypt=${SQLSERVER_ENCRYPT};trustServerCertificate=${SQLSERVER_TRUST_SERVER_CERT}"

cat > "${HIVE_SITE_XML}" <<EOF
<?xml version="1.0"?>
<configuration>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>${JDBC_URL}</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>com.microsoft.sqlserver.jdbc.SQLServerDriver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>${SQLSERVER_USER}</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>${SQLSERVER_PASSWORD}</value>
  </property>
  <property>
    <!-- Lets DataNucleus create the ~50 metastore schema tables itself
         on first connection, rather than requiring the Hive schematool
         to be run manually first. -->
    <name>datanucleus.schema.autoCreateAll</name>
    <value>true</value>
  </property>
  <property>
    <name>hive.metastore.schema.verification</name>
    <value>false</value>
  </property>
</configuration>
EOF
chmod 600 "${HIVE_SITE_XML}"  # contains a plaintext DB password — owner-only
echo "    Written to ${HIVE_SITE_XML} (permissions set to 600)"
echo "    Connection: ${JDBC_URL}"

echo "==> [3/3] Setting spark.sql.catalogImplementation=hive"
SPARK_DEFAULTS="${SPARK_HOME}/conf/spark-defaults.conf"
touch "${SPARK_DEFAULTS}"
sed -i '/^spark\.sql\.catalogImplementation/d' "${SPARK_DEFAULTS}"
echo "spark.sql.catalogImplementation     hive" >> "${SPARK_DEFAULTS}"

echo ""
echo "==> Done."
echo ""
echo "IMPORTANT: the Zeppelin Spark interpreter is a separate process"
echo "and does NOT pick up this change on its own — force it to restart:"
echo ""
echo "  pgrep -fl RemoteInterpreterServer"
echo "  sudo pkill -f RemoteInterpreterServer"
echo ""
echo "Then test with a fresh paragraph:"
echo ""
echo "  %spark"
echo "  spark.sql(\"CREATE SCHEMA IF NOT EXISTS sls\")"
echo "  spark.sql(\"\"\"CREATE TABLE IF NOT EXISTS sls.ale2s USING delta"
echo "    LOCATION 's3a://your-bucket/hello-world-test/tables-2-sls-delta'\"\"\")"
echo "  spark.sql(\"SHOW TABLES IN sls\").show()"
echo ""
echo "Then restart the interpreter AGAIN and re-run only the last line —"
echo "if 'sls.ale2s' still shows up without recreating it, the metadata"
echo "is now genuinely persisted in SQL Server, not in-memory."
