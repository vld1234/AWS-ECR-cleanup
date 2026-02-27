#!/bin/bash
################################################################################
# ECR - Collect "latest" Tag Information
#
# Purpose: Analyze all images with "latest" tag across repositories
# Usage: ./ecr-latest-info.sh
################################################################################

set -euo pipefail

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-7}"
REPO_PREFIX="project/"

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║           AOS ECR - LATEST TAG INFORMATION                                   ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Region: ${AWS_REGION}"
echo "Prefix: ${REPO_PREFIX}"
echo ""
echo "Fetching repositories..."

# Get repositories
REPOS=$(aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --output json 2>/dev/null | \
    jq -r --arg prefix "${REPO_PREFIX}" \
        '.repositories[] | select(.repositoryName | startswith($prefix)) | .repositoryName' | \
    sort)

REPO_COUNT=$(echo "$REPOS" | wc -l)
echo "Found ${REPO_COUNT} repositories"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SCANNING FOR 'latest' TAGS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

COUNT=0
REPOS_WITH_LATEST=0
TOTAL_LATEST_SIZE=0

# Create temp file for summary
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Process each repository
echo "$REPOS" | while IFS= read -r REPO; do
    COUNT=$((COUNT + 1))

    echo "[$COUNT/$REPO_COUNT] $REPO"

    # Get images with "latest" tag
    LATEST_DATA=$(aws ecr describe-images \
        --repository-name "${REPO}" \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null | \
        jq -c '[.imageDetails[] |
                select(.imageTags != null and .imageTags != []) |
                select(.imageTags[] == "latest") |
                {
                    digest: .imageDigest,
                    pushed: .imagePushedAt,
                    epoch: (.imagePushedAt | gsub("\\.[0-9]+\\+"; "+") | gsub("\\+00:00"; "Z") | fromdateiso8601),
                    size: .imageSizeInBytes,
                    all_tags: .imageTags
                }
            ]')

    LATEST_COUNT=$(echo "$LATEST_DATA" | jq 'length')

    if [ "$LATEST_COUNT" -gt 0 ]; then
        REPOS_WITH_LATEST=$((REPOS_WITH_LATEST + 1))

        # Get the latest image info
        LATEST_INFO=$(echo "$LATEST_DATA" | jq -c '.[0]')

        IMAGE_SIZE=$(echo "$LATEST_INFO" | jq -r '.size')
        TOTAL_LATEST_SIZE=$((TOTAL_LATEST_SIZE + IMAGE_SIZE))

        SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $IMAGE_SIZE / 1024 / 1024}")
        SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $IMAGE_SIZE / 1024 / 1024 / 1024}")

        if (( $(awk "BEGIN {print ($SIZE_GB >= 1)}") )); then
            SIZE_DISPLAY="${SIZE_GB} GB"
        else
            SIZE_DISPLAY="${SIZE_MB} MB"
        fi

        PUSHED_DATE=$(echo "$LATEST_INFO" | jq -r '.pushed')
        DIGEST=$(echo "$LATEST_INFO" | jq -r '.digest')
        ALL_TAGS=$(echo "$LATEST_INFO" | jq -r '.all_tags | join(", ")')

        # Calculate age
        IMAGE_EPOCH=$(echo "$LATEST_INFO" | jq -r '.epoch')
        NOW_EPOCH=$(date +%s)
        AGE_SECONDS=$((NOW_EPOCH - IMAGE_EPOCH))
        AGE_DAYS=$((AGE_SECONDS / 86400))

        echo "  ✓ Found 'latest' tag"
        echo "    • Pushed: $PUSHED_DATE ($AGE_DAYS days ago)"
        echo "    • Size: $SIZE_DISPLAY"
        echo "    • Digest: ${DIGEST:0:27}..."
        echo "    • All tags: $ALL_TAGS"

        # Save to temp file
        echo "${REPO}|${PUSHED_DATE}|${AGE_DAYS}|${SIZE_DISPLAY}|${ALL_TAGS}" >> "$TEMP_FILE"

        echo ""
    else
        echo "  ✗ No 'latest' tag"
    fi

done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY - REPOSITORIES WITH 'latest' TAG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TOTAL_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_LATEST_SIZE / 1024 / 1024 / 1024}")

echo "Total Repositories Scanned: $REPO_COUNT"

if [ -f "$TEMP_FILE" ] && [ -s "$TEMP_FILE" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DETAILED LIST - REPOSITORIES WITH 'latest' TAG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "%-50s | %-25s | %8s | %10s\n" "REPOSITORY" "PUSHED" "AGE" "SIZE"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    while IFS='|' read -r REPO PUSHED AGE SIZE TAGS; do
        if [ -n "$REPO" ]; then
            printf "%-50s | %-25s | %5dd | %10s\n" "$REPO" "${PUSHED:0:25}" "$AGE" "$SIZE"
        fi
    done < "$TEMP_FILE"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ANALYSIS BY AGE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Count by age ranges
    FRESH=0      # < 7 days
    RECENT=0     # 7-30 days
    OLD=0        # 31-90 days
    VERY_OLD=0   # > 90 days

    while IFS='|' read -r REPO PUSHED AGE SIZE TAGS; do
        if [ -n "$AGE" ]; then
            if [ "$AGE" -lt 7 ]; then
                FRESH=$((FRESH + 1))
            elif [ "$AGE" -lt 31 ]; then
                RECENT=$((RECENT + 1))
            elif [ "$AGE" -lt 91 ]; then
                OLD=$((OLD + 1))
            else
                VERY_OLD=$((VERY_OLD + 1))
            fi
        fi
    done < "$TEMP_FILE"

    echo "Age Distribution:"
    echo "  • Fresh (< 7 days):     $FRESH repositories"
    echo "  • Recent (7-30 days):   $RECENT repositories"
    echo "  • Old (31-90 days):     $OLD repositories"
    echo "  • Very Old (> 90 days): $VERY_OLD repositories"

    if [ "$VERY_OLD" -gt 0 ]; then
        echo ""
        echo "⚠️  WARNING: $VERY_OLD repositories have 'latest' tags older than 90 days!"
        echo ""
        echo "Repositories with very old 'latest' tags:"
        while IFS='|' read -r REPO PUSHED AGE SIZE TAGS; do
            if [ -n "$AGE" ] && [ "$AGE" -gt 90 ]; then
                echo "  • $REPO (${AGE} days old)"
            fi
        done < "$TEMP_FILE"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
