#!/usr/bin/env bash
# majorBumpRepoPlugin.sh — Create a new GAMA version branch across all plugin repos and bump version strings.
#
# Batch mode (local, iterates all repos):
#   ./majorBumpRepoPlugin.sh --branch GAMA_2026-04 [--eclipse 2025-06] [--from GAMA_2025-06] [--dry-run]
#
# Single-repo mode (used by the GitHub Action — repo already checked out):
#   ./majorBumpRepoPlugin.sh --repo-dir <path> --branch GAMA_2026-04 [--eclipse 2025-06] [--is-template] [--dry-run]
#
# Options:
#   --branch         REQUIRED. New branch name, e.g. GAMA_2026-04
#   --repo-dir       Process only this directory (skips fetch/base-checkout; for CI use)
#   --is-template    Also bump 1.0.0.qualifier placeholder versions (template repo only)
#   --from           Base branch to branch from (batch mode; defaults to current branch)
#   --eclipse        Eclipse release string for the p2 repo URL (default: 2025-03)
#   --deps-to-add    Comma-separated org.gama artifactIds to add to <dependencies>
#   --deps-to-remove Comma-separated org.gama artifactIds to remove from <dependencies>
#   --dry-run        Print what would happen without making any git or API calls

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# MAVEN DEPENDENCY CHANGES  (org.gama artifacts in the <dependencies> block)
# Edit these arrays before each release if the set of Maven deps needs to change.
# Use --dry-run first to confirm the diff looks right.
# ═══════════════════════════════════════════════════════════════════════════════

# artifactIds to ADD  (groupId=org.gama, version=${gama.version} are implicit):
DEPS_TO_ADD=(
    # "gama.api"
)

# artifactIds to REMOVE:
DEPS_TO_REMOVE=(
    # "gama.core"
)

# ═══════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ═══════════════════════════════════════════════════════════════════════════════

NEW_BRANCH=""
FROM_BRANCH=""
ECLIPSE_RELEASE="2025-03"
REPO_DIR=""
IS_TEMPLATE=false
DRY_RUN=false
TYCHO_VERSION=""
JDK_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)         NEW_BRANCH="$2";      shift 2 ;;
        --from)           FROM_BRANCH="$2";   shift 2 ;;
        --eclipse)        ECLIPSE_RELEASE="$2"; shift 2 ;;
        --repo-dir)       REPO_DIR="$2";      shift 2 ;;
        --is-template)    IS_TEMPLATE=true;   shift   ;;
        --dry-run)        DRY_RUN=true;       shift   ;;
        --tycho-version)  TYCHO_VERSION="$2"; shift 2 ;;
        --jdk-version)    JDK_VERSION="$2";   shift 2 ;;
        --deps-to-add)
            IFS=',' read -ra _tmp <<< "$2"
            DEPS_TO_ADD+=( "${_tmp[@]}" )
            shift 2 ;;
        --deps-to-remove)
            IFS=',' read -ra _tmp <<< "$2"
            DEPS_TO_REMOVE+=( "${_tmp[@]}" )
            shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1  ;;
    esac
done

if [[ -z "$NEW_BRANCH" ]]; then
    echo "Error: --branch is required  (e.g. --branch GAMA_2026-04)" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Version derivation
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$NEW_BRANCH" =~ ^GAMA_([0-9]{4})-([0-9]{2})$ ]]; then
    YEAR="${BASH_REMATCH[1]}"
    MONTH_PADDED="${BASH_REMATCH[2]}"
    [[ "$MONTH_PADDED" == "0"* ]] && MONTH="${MONTH_PADDED#0}" || MONTH="$MONTH_PADDED"
else
    echo "Error: branch '${NEW_BRANCH}' does not match GAMA_YYYY-MM" >&2
    exit 1
fi

GAMA_P2_VERSION="${YEAR}.${MONTH_PADDED}"            # 2026.04
GAMA_MAVEN_VERSION="${YEAR}.${MONTH}.0-SNAPSHOT"     # 2026.4.0-SNAPSHOT
GAMA_FEATURE_VERSION="${YEAR}.${MONTH}.0.qualifier"  # 2026.4.0.qualifier

printf '\n%-22s %s\n' "New branch:"      "$NEW_BRANCH"
printf   '%-22s %s\n' "P2 version:"      "$GAMA_P2_VERSION"
printf   '%-22s %s\n' "Maven version:"   "$GAMA_MAVEN_VERSION"
printf   '%-22s %s\n' "Feature version:" "$GAMA_FEATURE_VERSION"
printf   '%-22s %s\n' "Eclipse release:" "$ECLIPSE_RELEASE"
[[ "$DRY_RUN" == true ]] && printf '%-22s %s\n\n' "Mode:" "DRY RUN (no commits / pushes / API calls)"

# ═══════════════════════════════════════════════════════════════════════════════
# Repo layout
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$(dirname "$SCRIPT_DIR")"

# Local directory name → GitHub repo name (only needed where they differ)
declare -A GITHUB_REPO_NAME=(
    [gama.plugin.template]="plugin-template"
    # All other repos: local name == GitHub name
)
github_name() { echo "${GITHUB_REPO_NAME[$1]:-$1}"; }

# All repos to bump in batch mode (local dir names).
# p2composite is included; its pom/feature helpers are no-ops since those files
# don't exist there, so it just gets a branch + empty commit.
PLUGIN_REPOS=(
    gama.graphical.modeling
    gama.plugin.across-lab
    gama.plugin.femtost
    gama.plugin.genstar
    gama.plugin.inrae
    gama.plugin.irit
    gama.plugin.legacy
    gama.plugin.mcp
    gama.plugin.template   # is_template=true, handled below
    p2composite
)

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}


bump_p2site_pom() {
    local pom="$1"
    [[ -f "$pom" ]] || return 0
    echo "  pom (p2site):    $pom"
    run sed -i -E \
        's|<version>[0-9]+\.[0-9]+\.0-SNAPSHOT</version>|<version>'"${GAMA_MAVEN_VERSION}"'</version>|g' \
        "$pom"
}

bump_feature_xml() {
    local xml="$1"
    local is_template="${2:-false}"
    [[ -f "$xml" ]] || return 0
    echo "  feature.xml:     $xml"
    if [[ "$is_template" == true ]]; then
        run sed -i -E \
            's|version="1\.0\.0\.qualifier"|version="'"${GAMA_FEATURE_VERSION}"'"|g' \
            "$xml"
    fi
    run sed -i -E \
        's|version="20[0-9][0-9]\.[0-9]+\.0\.qualifier"|version="'"${GAMA_FEATURE_VERSION}"'"|g' \
        "$xml"
}

bump_category_xml() {
    local xml="$1"
    local is_template="${2:-false}"
    [[ -f "$xml" ]] || return 0
    echo "  category.xml:    $xml"
    if [[ "$is_template" == true ]]; then
        run sed -i -E \
            's|_1\.0\.0\.qualifier\.jar|_'"${GAMA_FEATURE_VERSION}"'.jar|g' \
            "$xml"
        run sed -i -E \
            's|version="1\.0\.0\.qualifier"|version="'"${GAMA_FEATURE_VERSION}"'"|g' \
            "$xml"
    fi
    run sed -i -E \
        's|_20[0-9][0-9]\.[0-9]+\.0\.qualifier\.jar|_'"${GAMA_FEATURE_VERSION}"'.jar|g' \
        "$xml"
    run sed -i -E \
        's|version="20[0-9][0-9]\.[0-9]+\.0\.qualifier"|version="'"${GAMA_FEATURE_VERSION}"'"|g' \
        "$xml"
}

apply_dep_changes() {
    local pom="$1"
    [[ -f "$pom" ]] || return 0

    # Maven pom.xml carries a default namespace — all XPath must use the mvn: prefix
    local NS="mvn=http://maven.apache.org/POM/4.0.0"
    local XPATH_DEP="//mvn:dependencies/mvn:dependency[mvn:artifactId"

    dep_exists() {
        [[ -n "$(xmlstarlet sel -N "$NS" -t \
            -v "${XPATH_DEP}='${1}']/mvn:artifactId" "$pom" 2>/dev/null)" ]]
    }

    for artifact in "${DEPS_TO_REMOVE[@]+"${DEPS_TO_REMOVE[@]}"}"; do
        if ! dep_exists "$artifact"; then
            echo "  dep remove: SKIP — ${artifact} not found in $pom" >&2
            continue
        fi
        echo "  dep remove:      $artifact"
        run xmlstarlet ed -L -N "$NS" \
            -d "${XPATH_DEP}='${artifact}']" \
            "$pom"
    done

    for artifact in "${DEPS_TO_ADD[@]+"${DEPS_TO_ADD[@]}"}"; do
        if dep_exists "$artifact"; then
            echo "  dep add: SKIP — ${artifact} already present in $pom" >&2
            continue
        fi
        echo "  dep add:         $artifact"
        run xmlstarlet ed -L -N "$NS" \
            -s "//mvn:dependencies" -t elem -n "dependency" \
            -s "//mvn:dependencies/dependency" -t elem -n "groupId"    -v "org.gama" \
            -s "//mvn:dependencies/dependency" -t elem -n "artifactId" -v "${artifact}" \
            -s "//mvn:dependencies/dependency" -t elem -n "version"    -v '${gama.version}' \
            "$pom"
    done
}

bump_gama_parent_properties() {
    local pom="$1"
    [[ -f "$pom" ]] || return 0
    echo "  pom (parent):    $pom"
    local NS="mvn=http://maven.apache.org/POM/4.0.0"

    run xmlstarlet ed -L -N "$NS" \
        -u "//mvn:version[contains(., '.0-SNAPSHOT')]" -v "$GAMA_MAVEN_VERSION" \
        "$pom"
    run xmlstarlet ed -L -N "$NS" \
        -u "//mvn:properties/mvn:gama.p2.version" -v "$GAMA_P2_VERSION" \
        "$pom"
    run xmlstarlet ed -L -N "$NS" \
        -u "//mvn:properties/mvn:gama.version" -v "[0,)" \
        "$pom"
    local eclipse_url
    eclipse_url=$(xmlstarlet sel -N "$NS" -t \
        -v "//mvn:url[contains(., 'download.eclipse.org/releases/')]" \
        "$pom" 2>/dev/null || true)
    if [[ "$eclipse_url" == *'${eclipse.p2.version}'* ]]; then
        # Already using the property — just bump its value
        echo "    eclipse.p2.version → $ECLIPSE_RELEASE"
        run xmlstarlet ed -L -N "$NS" \
            -u "//mvn:properties/mvn:eclipse.p2.version" -v "$ECLIPSE_RELEASE" \
            "$pom"
    elif [[ -n "$eclipse_url" ]]; then
        # Hardcoded URL — migrate to property, then set the property value
        echo "    eclipse URL: migrating to \${eclipse.p2.version} = $ECLIPSE_RELEASE"
        run xmlstarlet ed -L -N "$NS" \
            -u "//mvn:url[contains(., 'download.eclipse.org/releases/')]" \
            -v 'https://download.eclipse.org/releases/${eclipse.p2.version}' \
            "$pom"
        local prop_exists
        prop_exists=$(xmlstarlet sel -N "$NS" -t \
            -v "//mvn:properties/mvn:eclipse.p2.version" \
            "$pom" 2>/dev/null || true)
        if [[ -n "$prop_exists" ]]; then
            run xmlstarlet ed -L -N "$NS" \
                -u "//mvn:properties/mvn:eclipse.p2.version" -v "$ECLIPSE_RELEASE" \
                "$pom"
        else
            run xmlstarlet ed -L -N "$NS" \
                -s "//mvn:properties" -t elem -n "eclipse.p2.version" -v "$ECLIPSE_RELEASE" \
                "$pom"
        fi
    fi

    if [[ -n "$TYCHO_VERSION" ]]; then
        echo "    tycho.version → $TYCHO_VERSION"
        run xmlstarlet ed -L -N "$NS" \
            -u "//mvn:properties/mvn:tycho.version" -v "$TYCHO_VERSION" \
            "$pom"
    fi
    if [[ -n "$JDK_VERSION" ]]; then
        echo "    jdk.version → $JDK_VERSION"
        run xmlstarlet ed -L -N "$NS" \
            -u "//mvn:properties/mvn:jdk.version" -v "$JDK_VERSION" \
            "$pom"
    fi
}

bump_submodule_poms() {
    local repo_dir="$1"
    local NS="mvn=http://maven.apache.org/POM/4.0.0"
    while IFS= read -r -d '' pom; do
        local match
        match=$(xmlstarlet sel -N "$NS" -t \
            -v "//mvn:parent[mvn:artifactId='gama.plugin.parent']/mvn:version" \
            "$pom" 2>/dev/null || true)
        [[ -z "$match" ]] && continue
        echo "  pom (module):    $pom"
        run xmlstarlet ed -L -N "$NS" \
            -u "//mvn:parent[mvn:artifactId='gama.plugin.parent']/mvn:version" \
            -v "$GAMA_MAVEN_VERSION" \
            "$pom"
    done < <(find "$repo_dir" -name "pom.xml" \
        -not -path "*/target/*" \
        -not -path "*/gama.plugin.parent/*" \
        -not -path "*/gama.plugin.p2updatesite/*" \
        -print0)
}

bump_workflow_jdk() {
    local repo_dir="$1"
    [[ -n "$JDK_VERSION" ]] || return 0
    local workflows_dir="${repo_dir}/.github/workflows"
    [[ -d "$workflows_dir" ]] || return 0

    while IFS= read -r -d '' yml; do
        echo "  workflow:        $yml"
        run sed -i -E \
            's/(java-version:[[:space:]]*")[0-9]+(")/\1'"${JDK_VERSION}"'\2/' \
            "$yml"
        run sed -i -E \
            's/(Set up Java )[0-9]+/\1'"${JDK_VERSION}"'/' \
            "$yml"
    done < <(find "$workflows_dir" -name "*.yml" -print0)

    while IFS= read -r -d '' mf; do
        echo "  MANIFEST.MF:     $mf"
        run sed -i -E \
            's/(Bundle-RequiredExecutionEnvironment: JavaSE-)[0-9]+/\1'"${JDK_VERSION}"'/' \
            "$mf"
    done < <(find "$repo_dir" -name "MANIFEST.MF" -not -path "*/target/*" -print0)
}

# ═══════════════════════════════════════════════════════════════════════════════
# bump_repo  —  the single entry point for processing one repo
#
# $1  repo_dir     : path to the repo
# $2  is_template  : true → also bump 1.0.0.qualifier placeholders
# $3  fetch_base   : true (default) → fetch + checkout base before branching
#                    false → repo is already on the correct base (CI/--repo-dir)
# ═══════════════════════════════════════════════════════════════════════════════
bump_repo() {
    local repo_dir="$1"
    local is_template="${2:-false}"
    local fetch_base="${3:-true}"
    local repo_name
    repo_name="$(basename "$repo_dir")"

    printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '  %s\n'  "$repo_name"
    printf '%s\n'    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ! -d "$repo_dir/.git" ]]; then
        echo "  ✗ Not a git repo — skipping"
        return
    fi

    if [[ "$fetch_base" == true ]]; then
        local base
        if [[ -n "$FROM_BRANCH" ]]; then
            base="$FROM_BRANCH"
        else
            base="$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null)" || \
            base="$(gh api "repos/gama-platform-plugin/$(github_name "$repo_name")" \
                       --jq '.default_branch' 2>/dev/null)" || \
            base="main"
        fi
        echo "  Base branch: $base"
        run git -C "$repo_dir" fetch --quiet origin
        run git -C "$repo_dir" checkout "$base"
    fi

    run git -C "$repo_dir" checkout -b "$NEW_BRANCH"

    bump_gama_parent_properties "${repo_dir}/gama.plugin.parent/pom.xml"
    bump_p2site_pom             "${repo_dir}/gama.plugin.p2updatesite/pom.xml"
    bump_submodule_poms         "$repo_dir"
    bump_workflow_jdk           "$repo_dir"

    while IFS= read -r -d '' fxml; do
        bump_feature_xml "$fxml" "$is_template"
    done < <(find "$repo_dir" -name "feature.xml" -not -path "*/target/*" -print0)

    bump_category_xml "${repo_dir}/gama.plugin.p2updatesite/category.xml" "$is_template"
    apply_dep_changes    "${repo_dir}/gama.plugin.parent/pom.xml"

    if [[ "$DRY_RUN" == false ]]; then
        if git -C "$repo_dir" diff --quiet HEAD; then
            git -C "$repo_dir" commit --allow-empty -m "chore: bump to ${NEW_BRANCH}"
        else
            # Stage everything except the bump-tools directory
            git -C "$repo_dir" add -A -- ':!bump-tools'
            git -C "$repo_dir" commit -m "chore: bump to ${NEW_BRANCH}"
        fi
        git -C "$repo_dir" push -u origin "$NEW_BRANCH"
        echo "  ✓ pushed ${NEW_BRANCH}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

# ── Single-repo mode (--repo-dir) ─────────────────────────────────────────────
if [[ -n "$REPO_DIR" ]]; then
    bump_repo "$(cd "$REPO_DIR" && pwd)" "$IS_TEMPLATE" false
    printf '\n✓ Done!  New branch: %s  (%s)\n\n' "$NEW_BRANCH" "$GAMA_MAVEN_VERSION"
    exit 0
fi

# ── Batch mode ────────────────────────────────────────────────────────────────
for repo in "${PLUGIN_REPOS[@]}"; do
    is_tmpl=false
    [[ "$repo" == "gama.plugin.template" ]] && is_tmpl=true
    bump_repo "${PLUGINS_DIR}/${repo}" "$is_tmpl"
done

if [[ "$DRY_RUN" == false ]]; then
    printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '  Setting default branches on GitHub\n'
    printf '%s\n'   "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for repo in "${PLUGIN_REPOS[@]}"; do
        gh_name="$(github_name "$repo")"
        echo "  gama-platform-plugin/${gh_name} → ${NEW_BRANCH}"
        gh api --method PATCH "repos/gama-platform-plugin/${gh_name}" \
            -f "default_branch=${NEW_BRANCH}"
    done
fi

printf '\n✓ Done!  New branch: %s  (%s)\n\n' "$NEW_BRANCH" "$GAMA_MAVEN_VERSION"
