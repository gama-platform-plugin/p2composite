#!/bin/bash
set -e

ORG="${GITHUB_ORG:-gama-plugin}"
VPS_HOST="152.228.133.219"

# Derive version from branch name: GAMA_YYYY-MM → YYYY.MM
BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
if [[ "$BRANCH" =~ GAMA_([0-9]{4}-[0-9]{2}) ]]; then
    GAMA_VERSION="${BASH_REMATCH[1]//-/.}"   # 2025-06 → 2025.06
    echo "Branch ${BRANCH} → version=${GAMA_VERSION}"
else
    echo "ERROR: branch '${BRANCH}' does not match GAMA_YYYY-MM"
    exit 1
fi

BASE_URL="https://updates.gama-platform.org/plugin/${GAMA_VERSION}"
VPS_DIR="/var/www/gama_updates/plugin/${GAMA_VERSION}"

echo "=== Fetching plugin repos from org: ${ORG} ==="

# Include all non-archived repos EXCEPT those tagged "template" or "no-p2".
# To opt a repo out of the composite, add the "no-p2" topic to it.
# Infrastructure repos (plugin-template, p2composite) should carry the "template" topic.
REPOS=$(gh api "orgs/${ORG}/repos" \
    --paginate \
    --jq '.[] | select(.archived == false) | select(.topics | (contains(["template"]) or contains(["no-p2"])) | not) | .name')

REPO_COUNT=$(echo "$REPOS" | grep -c . || true)
echo "Found ${REPO_COUNT} plugin repos"

TIMESTAMP=$(date +%s)000

# --- compositeContent.xml ---
CHILDREN_CONTENT=""
CHILDREN_ARTIFACTS=""
for REPO in $REPOS; do
    URL="${BASE_URL}/${REPO}/"
    CHILDREN_CONTENT="${CHILDREN_CONTENT}    <child location='${URL}'/>\n"
    CHILDREN_ARTIFACTS="${CHILDREN_ARTIFACTS}    <child location='${URL}'/>\n"
    echo "  + ${REPO}"
done

cat > compositeContent.xml <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<?compositeMetadataRepository version='1.0.0'?>
<repository name='GAMA plugin Plugins'
  type='org.eclipse.equinox.internal.p2.metadata.repository.CompositeMetadataRepository'
  version='1.0.0'>
  <properties size='1'>
    <property name='p2.timestamp' value='${TIMESTAMP}'/>
  </properties>
  <children size='${REPO_COUNT}'>
$(echo -e "$CHILDREN_CONTENT" | sed '/^$/d')
  </children>
</repository>
EOF

# --- compositeArtifacts.xml ---
cat > compositeArtifacts.xml <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<?compositeArtifactRepository version='1.0.0'?>
<repository name='GAMA plugin Plugins'
  type='org.eclipse.equinox.internal.p2.artifact.repository.CompositeArtifactRepository'
  version='1.0.0'>
  <properties size='1'>
    <property name='p2.timestamp' value='${TIMESTAMP}'/>
  </properties>
  <children size='${REPO_COUNT}'>
$(echo -e "$CHILDREN_ARTIFACTS" | sed '/^$/d')
  </children>
</repository>
EOF

echo "=== Deploying composite XMLs to VPS ==="
scp compositeContent.xml compositeArtifacts.xml \
    "${GAMA_SERVER_USERNAME}@${VPS_HOST}:${VPS_DIR}/"

echo "=== Done. Composite updated with ${REPO_COUNT} children ==="
