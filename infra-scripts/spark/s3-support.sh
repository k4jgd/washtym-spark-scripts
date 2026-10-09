#!/usr/bin/env bash
#
# s3-support.sh
#
# Adds AWS S3 (s3a://) support to a box already provisioned by
# setup-spark-standalone.sh. Standalone and separate by design.
#
# What this does:
#   1. Detects the exact Hadoop client version bundled inside your
#      installed Spark (rather than guessing), to avoid the classic
#      hadoop-aws / hadoop-client version-mismatch failures.
#   2. Downloads the matching hadoop-aws jar (the connector that
#      implements the s3a:// filesystem) and the AWS SDK bundle it
#      depends on, into Spark's jars directory.
#   3. Configures spark-defaults.conf with the s3a filesystem and a
#      sensible default credentials provider chain.
#   4. Restarts Spark so new Spark contexts pick up the new jars/config.
#
# Assumes setup-spark-standalone.sh has already been run (Spark
# installed under /opt/spark by default).
#
# Usage:
#   sudo ./s3-support.sh
#
#   # With explicit static credentials (writes them into spark-defaults.conf):
#   sudo AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... ./s3-support.sh
#
#   # Without credentials (default — see the credentials section below):
#   sudo ./s3-support.sh
#
set -euo pipefail

SPARK_HOME="${SPARK_HOME:-/opt/spark}"
MAVEN_CENTRAL="https://repo1.maven.org/maven2"

if [ ! -d "${SPARK_HOME}/jars" ]; then
  echo "ERROR: ${SPARK_HOME}/jars not found. Is SPARK_HOME correct, and" >&2
  echo "       has setup-spark-standalone.sh already been run?" >&2
  exit 1
fi

echo "==> [1/5] Detecting Hadoop client version bundled with this Spark install"
DETECTED_JAR="$(ls "${SPARK_HOME}/jars/" | grep -E '^hadoop-client-api-[0-9].*\.jar$' | head -n1 || true)"

if [ -z "${DETECTED_JAR}" ]; then
  echo "ERROR: Could not find a hadoop-client-api-*.jar in ${SPARK_HOME}/jars." >&2
  echo "       This script expects a Spark build with the modern shaded" >&2
  echo "       Hadoop client jars (Spark 3.x+ '-bin-hadoop3' distributions)." >&2
  echo "       Set HADOOP_AWS_VERSION explicitly and re-run if you know the" >&2
  echo "       version you need, e.g.:" >&2
  echo "         sudo HADOOP_AWS_VERSION=3.4.1 ./s3-support.sh" >&2
  if [ -z "${HADOOP_AWS_VERSION:-}" ]; then
    exit 1
  fi
fi

HADOOP_AWS_VERSION="${HADOOP_AWS_VERSION:-$(echo "${DETECTED_JAR}" | sed -E 's/^hadoop-client-api-([0-9.]+)\.jar$/\1/')}"
echo "    Using hadoop-aws version: ${HADOOP_AWS_VERSION}"

# --- AWS SDK coordinates ---------------------------------------------------
# Hadoop 3.4.x migrated S3A from AWS SDK v1 (com.amazonaws, artifact
# "aws-java-sdk-bundle") to AWS SDK v2 (software.amazon.awssdk, artifact
# "bundle") — a breaking change (HADOOP-18073). Using the wrong SDK
# entirely, or a v2 bundle version hadoop-aws wasn't built against, both
# fail at runtime with a ClassNotFoundException, not at download time.
#
# Rather than hardcoding a guessed version (which is what caused the
# previous failure), this reads the EXACT version hadoop-aws's own Maven
# POM declares for this dependency — resolving through a parent-POM
# property reference if needed, the same way Maven itself would.
echo "==> [2/5] Resolving the exact AWS SDK v2 bundle version hadoop-aws ${HADOOP_AWS_VERSION} depends on"

DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "${DOWNLOAD_DIR}"' EXIT

AWS_SDK_BUNDLE_VERSION="${AWS_SDK_BUNDLE_VERSION:-}"
if [ -z "${AWS_SDK_BUNDLE_VERSION}" ]; then
  AWS_SDK_BUNDLE_VERSION="$(python3 - "${HADOOP_AWS_VERSION}" "${MAVEN_CENTRAL}" <<'PYEOF'
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

NS = {"m": "http://maven.apache.org/POM/4.0.0"}
TARGET_GROUP, TARGET_ARTIFACT = "software.amazon.awssdk", "bundle"


def pom_url(maven_central, group_id, artifact_id, version):
    path = group_id.replace(".", "/")
    return f"{maven_central}/{path}/{artifact_id}/{version}/{artifact_id}-{version}.pom"


def fetch(url):
    with urllib.request.urlopen(url) as resp:
        return resp.read().decode("utf-8")


def get_parent(root):
    p = root.find("m:parent", NS)
    if p is None:
        return None
    return {tag: p.find(f"m:{tag}", NS).text for tag in ("groupId", "artifactId", "version")}


def find_dep_in_dependencies(root, group_id, artifact_id):
    """Version text, '' if matched with no <version> tag (inherited), None if unmatched."""
    for dep in root.findall(".//m:dependencies/m:dependency", NS):
        g, a = dep.find("m:groupId", NS), dep.find("m:artifactId", NS)
        if g is not None and a is not None and g.text == group_id and a.text == artifact_id:
            v = dep.find("m:version", NS)
            return v.text if v is not None else ""
    return None


def find_dep_in_dep_mgmt(root, group_id, artifact_id):
    for dep in root.findall(".//m:dependencyManagement/m:dependencies/m:dependency", NS):
        g, a = dep.find("m:groupId", NS), dep.find("m:artifactId", NS)
        if g is not None and a is not None and g.text == group_id and a.text == artifact_id:
            v = dep.find("m:version", NS)
            return v.text if v is not None else ""
    return None


def find_property(root, prop_name):
    props = root.find("m:properties", NS)
    if props is None:
        return None
    el = props.find(f"m:{prop_name}", NS)
    return el.text if el is not None else None


def main():
    hadoop_aws_version, maven_central = sys.argv[1], sys.argv[2]

    coords = {"groupId": "org.apache.hadoop", "artifactId": "hadoop-aws", "version": hadoop_aws_version}
    chain_roots = []
    version_raw = None
    is_leaf = True
    max_depth = 6

    for _ in range(max_depth):
        text = fetch(pom_url(maven_central, coords["groupId"], coords["artifactId"], coords["version"]))
        root = ET.fromstring(text)
        chain_roots.append(root)

        # Only the leaf POM's own <dependencies> list is relevant — a
        # parent's plain <dependencies> (not dependencyManagement) isn't
        # inherited by children in Maven, so we don't check it there.
        if is_leaf:
            found = find_dep_in_dependencies(root, TARGET_GROUP, TARGET_ARTIFACT)
            if found is not None:
                version_raw = found
            is_leaf = False

        # dependencyManagement, by contrast, IS inherited — check every
        # level of the chain until found.
        if not version_raw:
            found_mgmt = find_dep_in_dep_mgmt(root, TARGET_GROUP, TARGET_ARTIFACT)
            if found_mgmt:
                version_raw = found_mgmt

        if version_raw:
            break

        parent = get_parent(root)
        if parent is None:
            break
        coords = parent

    if not version_raw:
        print(
            f"ERROR: {TARGET_GROUP}:{TARGET_ARTIFACT} not found in hadoop-aws "
            f"{hadoop_aws_version}'s dependencies or its parent chain "
            f"(searched {len(chain_roots)} POM(s)).",
            file=sys.stderr,
        )
        sys.exit(1)

    m = re.match(r"^\$\{(.+)\}$", version_raw)
    if not m:
        print(version_raw)
        return

    # Property indirection — search every POM already fetched, then keep
    # walking further up the parent chain if still unresolved.
    prop_name = m.group(1)
    for root in chain_roots:
        val = find_property(root, prop_name)
        if val is not None:
            print(val)
            return

    coords = get_parent(chain_roots[-1])
    while coords and len(chain_roots) < max_depth:
        text = fetch(pom_url(maven_central, coords["groupId"], coords["artifactId"], coords["version"]))
        root = ET.fromstring(text)
        chain_roots.append(root)
        val = find_property(root, prop_name)
        if val is not None:
            print(val)
            return
        coords = get_parent(root)

    print(f"ERROR: property {prop_name} not resolved anywhere in the parent chain.", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
PYEOF
)" || {
    echo "ERROR: Could not resolve the AWS SDK v2 bundle version automatically." >&2
    echo "       Set it explicitly and re-run, e.g.:" >&2
    echo "         sudo AWS_SDK_BUNDLE_VERSION=2.29.52 ./s3-support.sh" >&2
    exit 1
  }
fi
echo "    Resolved software.amazon.awssdk:bundle version: ${AWS_SDK_BUNDLE_VERSION}"

echo "==> [3/5] Downloading hadoop-aws and the AWS SDK v2 bundle"
HADOOP_AWS_JAR="hadoop-aws-${HADOOP_AWS_VERSION}.jar"
AWS_SDK_JAR="bundle-${AWS_SDK_BUNDLE_VERSION}.jar"

# Any stale v1 SDK jar from a previous run of this script (before this
# fix) will silently coexist on the classpath and isn't harmful by
# itself, but serves no purpose now — remove it to avoid confusion.
rm -f "${SPARK_HOME}"/jars/aws-java-sdk-bundle-*.jar

if [ -f "${SPARK_HOME}/jars/${HADOOP_AWS_JAR}" ]; then
  echo "    ${HADOOP_AWS_JAR} already present — skipping."
else
  wget -q -O "${DOWNLOAD_DIR}/${HADOOP_AWS_JAR}" \
    "${MAVEN_CENTRAL}/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/${HADOOP_AWS_JAR}"
  mv "${DOWNLOAD_DIR}/${HADOOP_AWS_JAR}" "${SPARK_HOME}/jars/${HADOOP_AWS_JAR}"
fi

if [ -f "${SPARK_HOME}/jars/${AWS_SDK_JAR}" ]; then
  echo "    ${AWS_SDK_JAR} already present — skipping."
else
  wget -q -O "${DOWNLOAD_DIR}/${AWS_SDK_JAR}" \
    "${MAVEN_CENTRAL}/software/amazon/awssdk/bundle/${AWS_SDK_BUNDLE_VERSION}/${AWS_SDK_JAR}"
  mv "${DOWNLOAD_DIR}/${AWS_SDK_JAR}" "${SPARK_HOME}/jars/${AWS_SDK_JAR}"
fi

echo "==> [4/5] Configuring spark-defaults.conf for s3a://"
SPARK_DEFAULTS="${SPARK_HOME}/conf/spark-defaults.conf"
touch "${SPARK_DEFAULTS}"

# Remove any previous S3-related lines this script added, so re-running
# with different credentials/settings replaces rather than duplicates them.
sed -i '/^spark\.hadoop\.fs\.s3a\./d' "${SPARK_DEFAULTS}"

{
  echo "spark.hadoop.fs.s3a.impl                      org.apache.hadoop.fs.s3a.S3AFileSystem"
  echo "spark.hadoop.fs.s3a.endpoint                  s3.amazonaws.com"
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    # Explicit static credentials were provided — use them directly.
    echo "spark.hadoop.fs.s3a.aws.credentials.provider  org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider"
    echo "spark.hadoop.fs.s3a.access.key                ${AWS_ACCESS_KEY_ID}"
    echo "spark.hadoop.fs.s3a.secret.key                ${AWS_SECRET_ACCESS_KEY}"
  else
    # No static credentials given — use the standard AWS SDK v2 default
    # chain: environment variables, ~/.aws/credentials, EC2/ECS instance
    # role, in that order. This is the SDK v2 equivalent of the v1
    # DefaultAWSCredentialsProviderChain class; using the v1 class name
    # here would fail, since the v1 SDK jar is no longer on the classpath
    # (see the SDK v2 migration note above).
    echo "spark.hadoop.fs.s3a.aws.credentials.provider  software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider"
  fi
} >> "${SPARK_DEFAULTS}"

if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  chmod 600 "${SPARK_DEFAULTS}"
  echo "    Static credentials written to ${SPARK_DEFAULTS} (permissions set to 600)."
  echo "    Consider using an IAM role or environment variables instead of"
  echo "    static keys for anything beyond local experimentation."
else
  echo "    No static credentials given — configured to use the AWS default"
  echo "    credentials chain (env vars / ~/.aws/credentials / instance role)."
fi

echo "==> [5/5] Restarting Spark so new contexts pick up the new jars/config"
"${SPARK_HOME}/sbin/stop-worker.sh" 2>/dev/null || true
"${SPARK_HOME}/sbin/stop-master.sh" 2>/dev/null || true
sleep 2
"${SPARK_HOME}/sbin/start-master.sh"
"${SPARK_HOME}/sbin/start-worker.sh" "spark://localhost:7077"

echo ""
echo "==> Done. IMPORTANT: the Zeppelin Spark interpreter is a separate"
echo "    process from the Spark daemons just restarted above, and it"
echo "    does NOT pick up new jars on its own. The UI's 'restart' button"
echo "    is not always sufficient — force it directly:"
echo ""
echo "      pgrep -fl RemoteInterpreterServer"
echo "      sudo pkill -f RemoteInterpreterServer"
echo ""
echo "    Then run a fresh paragraph (a new interpreter process spawns"
echo "    automatically) and test with:"
echo ""
echo "      %spark"
echo "      spark.read.text(\"s3a://your-bucket/some-file.txt\").show()"
echo ""
echo "If this fails with a 403 or credentials error, verify your AWS"
echo "credentials are visible to the account running Spark (run"
echo "'aws sts get-caller-identity' as that same user/role to confirm)."
