#!/bin/bash
################################################################################
# ECR Discovery Script - Part 1 (Summary View)
#
# Purpose: List all repositories with tag counts (quick inventory)
# Usage: ./ecr-discovery.sh
################################################################################

set -euo pipefail

# Configuration
readonly AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-7}"
readonly REPO_PREFIX="project/"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

check_dependencies() {
    if ! command -v aws &> /dev/null || ! command -v jq &> /dev/null; then
        log_error "Missing aws-cli or jq"
        exit 1
    fi
}

get_all_aos_repositories() {
    aws ecr describe-repositories \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null | \
        jq -r --arg prefix "${REPO_PREFIX}" \
            '.repositories[] |
             select(.repositoryName | startswith($prefix)) |
             .repositoryName' | \
        sort
}

analyze_repository() {
    local repo="$1"

    # Get all images
    local images_json=$(aws ecr describe-images \
        --repository-name "${repo}" \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null || echo '{"imageDetails":[]}')

    local total_images=$(echo "${images_json}" | jq '.imageDetails | length')

    if [ "${total_images}" -eq 0 ]; then
        printf "%-50s | %5s | %8s | %7s | %7s | %9s\n" "${repo}" "0" "0" "0" "0" "0"
        return 0
    fi

    # Categorize and count tags using jq
    local counts=$(echo "${images_json}" | jq -r '
        .imageDetails[] |
        if .imageTags == null or .imageTags == [] then
            "untagged"
        else
            .imageTags[] |
            if . == "latest" then
                "latest"
            elif test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9]+)?$") then
                "release"
            elif test("^[0-9a-f]{8}$") then
                "commit"
            else
                "other"
            end
        end' | sort | uniq -c | awk '{print $2":"$1}')

    # Initialize counts
    local release_count=0
    local commit_count=0
    local latest_count=0
    local other_count=0
    local untagged_count=0

    # Parse counts
    while IFS=: read -r type count; do
        case "$type" in
            release) release_count=$count ;;
            commit) commit_count=$count ;;
            latest) latest_count=$count ;;
            other) other_count=$count ;;
            untagged) untagged_count=$count ;;
        esac
    done <<< "$counts"

    # Print row
    printf "%-50s | %5d | %8d | %7d | %7d | %9d\n" \
        "${repo}" \
        "${total_images}" \
        "${release_count}" \
        "${commit_count}" \
        "${latest_count}" \
        "${untagged_count}"
}

main() {
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                  ECR DISCOVERY - SUMMARY VIEW (PART 1)                   ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Region: ${AWS_REGION}"
    echo "Prefix: ${REPO_PREFIX}"
    echo ""

    check_dependencies

    log_info "Fetching repositories from ${AWS_REGION}..."

    # Get all repositories (sorted)
    local repositories=()
    while IFS= read -r repo; do
        [ -n "${repo}" ] && repositories+=("${repo}")
    done < <(get_all_aos_repositories)

    local repo_count=${#repositories[@]}

    if [ ${repo_count} -eq 0 ]; then
        log_error "No repositories found with prefix '${REPO_PREFIX}' in ${AWS_REGION}"
        exit 1
    fi

    log_success "Found ${repo_count} repositories"
    echo ""

    # Print table header
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-50s | %5s | %8s | %7s | %7s | %9s\n" "REPOSITORY" "TOTAL" "RELEASE" "COMMIT" "LATEST" "UNTAGGED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Track totals
    local grand_total=0
    local grand_release=0
    local grand_commit=0
    local grand_latest=0
    local grand_untagged=0

    # Analyze each repository
    for repo in "${repositories[@]}"; do
        # Get counts from analyze_repository output
        local output=$(analyze_repository "${repo}")
        echo "$output"

        # Extract numbers for totals
        local total=$(echo "$output" | awk -F'|' '{print $2}' | xargs)
        local release=$(echo "$output" | awk -F'|' '{print $3}' | xargs)
        local commit=$(echo "$output" | awk -F'|' '{print $4}' | xargs)
        local latest=$(echo "$output" | awk -F'|' '{print $5}' | xargs)
        local untagged=$(echo "$output" | awk -F'|' '{print $6}' | xargs)

        grand_total=$((grand_total + total))
        grand_release=$((grand_release + release))
        grand_commit=$((grand_commit + commit))
        grand_latest=$((grand_latest + latest))
        grand_untagged=$((grand_untagged + untagged))
    done

    # Print footer with totals
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-50s | %5d | %8d | %7d | %7d | %9d\n" \
        "TOTAL (${repo_count} repositories)" \
        "${grand_total}" \
        "${grand_release}" \
        "${grand_commit}" \
        "${grand_latest}" \
        "${grand_untagged}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_success "Discovery complete!"
    echo ""
}

main "$@"
exit 0
