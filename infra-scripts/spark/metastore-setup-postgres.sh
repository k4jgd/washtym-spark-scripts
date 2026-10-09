
#!/usr/bin/env bash
#
# postgresql-metastore-support.sh
#
# Configures Spark's Hive metastore to persist in an existing
# PostgreSQL instance. Same purpose as sqlserver-metastore-support.sh —
# use whichever matches the database you actually have. Running this
# after the SQL Server version simply overwrites hive-site.xml to point
# at Postgres instead; only one metastore backend is active at a time.
#
# What this does:
#   1. Downloads the PostgreSQL JDBC driver into Spark's jars directory.
#   2. Generates hive-site.xml with the Postgres connection details.
#   3. Sets spark.sql.catalogImplementation=hive in spark-defaults.conf.
#
# PREREQUISITE: the Postgres role you provide needs permission to
# CREATE TABLE in the target database — DataNucleus (Hive's ORM layer)
# auto-creates the ~50 metastore schema tables itself on first
# connection, no manual schema-init step required.
#
# SCHEMA ISOLATION: if reusing an existing database rather than a
# dedicated one and you don't want Hive's internal tables mixed into
# "public" alongside other tables, set the role's search_path once
# (run as whichever admin role you'd normally use):
#
#   CREATE SCHEMA hive_meta AUTHORIZATION hive_user;
#   ALTER ROLE hive_user SET search_path TO hive_meta;
#
# Everything DataNucleus creates afterward lands under hive_meta —
# no change needed here or in hive-site.xml for that.
#
# Assumes setup-spark-standalone.sh has already been run.
#
# Usage:
#   sudo POSTGRES_HOST=devpg.internal.corp \
#        POSTGRES_DB=hive_metastore \
#        POSTGRES_USER=hive_user \
#        POSTGRES_PASSWORD='...' \
#        ./postgresql-metastore-support.sh
#
# Optional:
#   POSTGRES_PORT (default 5432)
#   POSTGRES_SSLMODE (default "prefer" — attempts SSL, falls back to
#     plaintext if unavailable; a reasonable dev default. Set to
#     "require" or "verify-full" for anything beyond dev.)
#
set -euo pipefail

SPARK_HOME="${SPARK_HOME:-/opt/spark}"
MAVEN_CENTRAL="https://repo1.maven.org/maven2"
POSTGRES_JDBC_VERSION="${POSTGRES_JDBC_VERSION:-42.7.4}"

POSTGRES_HOST=localvm1.zilcherratum.com #"${POSTGRES_HOST:-}"
POSTGRES_PORT=5432 #"${POSTGRES_PORT:-5432}"
POSTGRES_DB=hive_metastore #"${POSTGRES_DB:-}"
POSTGRES_USER=hive_user #"${POSTGRES_USER:-}"
POSTGRES_PASSWORD=HiveMeta2026! #"${POSTGRES_PASSWORD:-}"
POSTGRES_SSLMODE=disable #"${POSTGRES_SSLMODE:-prefer}"

MISSING=()
[ -z "${POSTGRES_HOST}" ] && MISSING+=("POSTGRES_HOST")
[ -z "${POSTGRES_DB}" ] && MISSING+=("POSTGRES_DB")
[ -z "${POSTGRES_USER}" ] && MISSING+=("POSTGRES_USER")
[ -z "${POSTGRES_PASSWORD}" ] && MISSING+=("POSTGRES_PASSWORD")

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: missing required variable(s): ${MISSING[*]}" >&2
  echo "" >&2
  echo "Usage:" >&2
  echo "  sudo POSTGRES_HOST=devpg POSTGRES_DB=hive_metastore \\" >&2
  echo "       POSTGRES_USER=hive_user POSTGRES_PASSWORD='...' \\" >&2
  echo "       ./postgresql-metastore-support.sh" >&2
  exit 1
fi

if [ ! -d "${SPARK_HOME}/conf" ]; then
  echo "ERROR: ${SPARK_HOME}/conf not found. Is SPARK_HOME correct, and" >&2
  echo "       has setup-spark-standalone.sh already been run?" >&2
  exit 1
fi

echo "==> [1/3] Downloading the PostgreSQL JDBC driver"
POSTGRES_JAR="postgresql-${POSTGRES_JDBC_VERSION}.jar"

if [ -f "${SPARK_HOME}/jars/${POSTGRES_JAR}" ]; then
  echo "    ${POSTGRES_JAR} already present — skipping."
else
  DOWNLOAD_DIR="$(mktemp -d)"
  trap 'rm -rf "${DOWNLOAD_DIR}"' EXIT
  DOWNLOAD_URL="${MAVEN_CENTRAL}/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/${POSTGRES_JAR}"
  if ! wget -O "${DOWNLOAD_DIR}/${POSTGRES_JAR}" "${DOWNLOAD_URL}"; then
    echo "" >&2
    echo "ERROR: Failed to download the PostgreSQL JDBC driver from:" >&2
    echo "  ${DOWNLOAD_URL}" >&2
    echo "" >&2
    echo "Common causes:" >&2
    echo "  - No network access to repo1.maven.org from this machine" >&2
    echo "    (test with: curl -I https://repo1.maven.org)" >&2
    echo "  - A firewall/proxy blocking outbound HTTPS" >&2
    echo "  - POSTGRES_JDBC_VERSION=${POSTGRES_JDBC_VERSION} does not exist" >&2
    echo "    (check available versions at:" >&2
    echo "    https://repo1.maven.org/maven2/org/postgresql/postgresql/)" >&2
    exit 1
  fi
  mv "${DOWNLOAD_DIR}/${POSTGRES_JAR}" "${SPARK_HOME}/jars/${POSTGRES_JAR}"
fi

# Remove any stale driver jar from a previous run with a different
# POSTGRES_JDBC_VERSION, so only one version is ever on the classpath.
find "${SPARK_HOME}/jars" -maxdepth 1 -name 'postgresql-*.jar' ! -name "${POSTGRES_JAR}" -delete

# If a SQL Server driver jar is present from sqlserver-metastore-support.sh,
# it's harmless to leave (unused, since hive-site.xml below points
# exclusively at Postgres) but is dead weight now — remove it for
# tidiness rather than leaving two metastore drivers on the classpath.
if ls "${SPARK_HOME}"/jars/mssql-jdbc-*.jar > /dev/null 2>&1; then
  echo "    Removing unused mssql-jdbc jar (switching metastore backend to Postgres)"
  rm -f "${SPARK_HOME}"/jars/mssql-jdbc-*.jar
fi

echo "==> [2/3] Generating hive-site.xml"
HIVE_SITE_XML="${SPARK_HOME}/conf/hive-site.xml"
JDBC_URL="jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=${POSTGRES_SSLMODE}"

cat > "${HIVE_SITE_XML}" <<EOF
<?xml version="1.0"?>
<configuration>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>${JDBC_URL}</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>org.postgresql.Driver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>${POSTGRES_USER}</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>${POSTGRES_PASSWORD}</value>
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
  <property>
    <!-- Without this, DataNucleus can leave metastore write transactions
         (e.g. INSERT INTO TABLE_PARAMS during CREATE TABLE) open
         indefinitely instead of auto-committing, permanently holding a
         lock and silently blocking every subsequent metastore operation
         behind it — the paragraph "hangs forever with no error" symptom. -->
    <name>datanucleus.connectionPool.testOnBorrow</name>
    <value>true</value>
  </property>
  <property>
    <name>datanucleus.transactionIsolation</name>
    <value>read-committed</value>
  </property>
  <property>
    <name>datanucleus.connectionPoolingType</name>
    <value>HikariCP</value>
  </property>
  <property>
    <name>datanucleus.connectionPool.maxPoolSize</name>
    <value>10</value>
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
echo "is now genuinely persisted in Postgres, not in-memory."
