#!/bin/bash
################################################################################
# ECR - Release Tag Cleanup for staging/project
################################################################################

set -euo pipefail

# Configuration
readonly DRY_RUN=false  # Set to false to actually delete images
readonly KEEP_RELEASE_COUNT=10  # Keep latest N release tags
readonly KEEP_RELEASE_AGE_DAYS=7  # Keep release tags younger than N days

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-7}"
REPO_PREFIX="staging/project/"

TEMP_RESULTS="/tmp/ecr-release-results-$$.txt"
TEMP_REPOS="/tmp/ecr-repos-$$.txt"
TEMP_KEPT_RELEASES="/tmp/ecr-kept-releases-$$.txt"
> "$TEMP_RESULTS"
> "$TEMP_KEPT_RELEASES"

trap "rm -f $TEMP_RESULTS $TEMP_REPOS $TEMP_KEPT_RELEASES" EXIT

# Debug function
debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo "[DEBUG] $*" >&2
    fi
}

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║           ECR - RELEASE TAG CLEANUP (staging/project)                ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Region: ${AWS_REGION}"
echo "Prefix: ${REPO_PREFIX}"

if [ "$DRY_RUN" = true ]; then
    echo "Mode: DRY-RUN (no deletions will occur)"
else
    echo "Mode: LIVE - IMAGES WILL BE DELETED!"
fi

echo ""
echo "Retention Policy:"
echo "  • Keep ${KEEP_RELEASE_COUNT} most recent release tags per repository"
echo "  • Keep all release tags younger than ${KEEP_RELEASE_AGE_DAYS} days"
echo ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo "ERROR: aws CLI not found"
    exit 1
fi

# Check jq
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq not found"
    exit 1
fi

echo "Fetching repositories..."

# Fetch repositories with error handling
if ! aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --output json 2>&1 | \
    jq -r --arg prefix "${REPO_PREFIX}" \
        '.repositories[] | select(.repositoryName | startswith($prefix)) | .repositoryName' | \
    sort > "$TEMP_REPOS"; then
    echo "ERROR: Failed to fetch repositories"
    exit 1
fi

if [ ! -s "$TEMP_REPOS" ]; then
    echo "ERROR: No repositories found or file is empty"
    exit 1
fi

REPO_COUNT=$(wc -l < "$TEMP_REPOS" | tr -d ' ')
echo "Found ${REPO_COUNT} repositories"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STARTING SCAN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

COUNT=0

# Calculate cutoff date using Python (more portable than date command)
CUTOFF_DATE=$(python3 -c "import time; print(int(time.time() - (${KEEP_RELEASE_AGE_DAYS} * 86400)))" 2>/dev/null || \
              python -c "import time; print(int(time.time() - (${KEEP_RELEASE_AGE_DAYS} * 86400)))" 2>/dev/null || \
              awk "BEGIN {print int(systime() - (${KEEP_RELEASE_AGE_DAYS} * 86400))}" 2>/dev/null)

if [ -z "$CUTOFF_DATE" ] || [ "$CUTOFF_DATE" = "0" ]; then
    echo "ERROR: Unable to calculate cutoff date"
    echo "Trying alternative method..."
    # Fallback: use current time minus days in seconds
    CURRENT_TIME=$(date +%s 2>/dev/null || echo "0")
    if [ "$CURRENT_TIME" != "0" ]; then
        CUTOFF_DATE=$((CURRENT_TIME - (KEEP_RELEASE_AGE_DAYS * 86400)))
    else
        echo "ERROR: All date calculation methods failed"
        exit 1
    fi
fi

debug "Cutoff date (epoch): $CUTOFF_DATE"
CUTOFF_DATE_HUMAN=$(date -u -d "@${CUTOFF_DATE}" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || \
                     date -u -r "${CUTOFF_DATE}" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || \
                     echo "unknown")
echo "Cutoff date for age policy: ${CUTOFF_DATE_HUMAN}"
echo ""

while IFS= read -r REPO || [ -n "$REPO" ]; do
    [ -z "$REPO" ] && continue

    COUNT=$((COUNT + 1))

    echo "[$COUNT/$REPO_COUNT] $REPO"
    debug "Processing repository: $REPO"

    # Get all images with error handling
    if ! RAW_IMAGE_DATA=$(aws ecr describe-images \
        --repository-name "${REPO}" \
        --region "${AWS_REGION}" \
        --output json 2>&1); then
        echo "  ERROR: Failed to fetch images for $REPO"
        debug "AWS error: $RAW_IMAGE_DATA"
        echo ""
        continue
    fi

    debug "Raw image data fetched successfully"

    # Parse and categorize images
    ALL_IMAGE_DATA=$(echo "$RAW_IMAGE_DATA" | jq -c --argjson cutoff "$CUTOFF_DATE" '
        [.imageDetails[] |
            select(.imageTags != null and (.imageTags | length) > 0) |
            {
                digest: .imageDigest,
                pushed: .imagePushedAt,
                epoch: (
                    .imagePushedAt
                    | gsub("\\.[0-9]+\\+"; "+")
                    | gsub("\\+00:00"; "Z")
                    | fromdateiso8601
                ),
                size: .imageSizeInBytes,
                all_tags: .imageTags,
                commit_tags: [.imageTags[] | select(test("^[0-9a-f]{8}$"))],
                latest_tag: ([.imageTags[] | select(. == "latest")] | length > 0),
                release_tags: [.imageTags[] | select(
                    test("^[0-9]+\\.[0-9]+$") or
                    test("^[0-9]+\\.[0-9]+\\.[0-9]+$") or
                    test("^[0-9]+\\.[0-9]+\\.[0-9]+-[a-zA-Z0-9]+$")
                )],
                is_recent: (.imagePushedAt | gsub("\\.[0-9]+\\+"; "+") | gsub("\\+00:00"; "Z") | fromdateiso8601) >= $cutoff
            }
        ] | sort_by(.epoch) | reverse
    ' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to parse image data"
        debug "jq error: $ALL_IMAGE_DATA"
        echo ""
        continue
    fi

    if [ -z "$ALL_IMAGE_DATA" ] || [ "$ALL_IMAGE_DATA" = "null" ] || [ "$ALL_IMAGE_DATA" = "[]" ]; then
        echo "  No images found"
        echo ""
        continue
    fi

    debug "Images parsed and categorized"

    # Filter to images with release tags
    IMAGES_WITH_RELEASES=$(echo "$ALL_IMAGE_DATA" | jq -c '[.[] | select((.release_tags | length) > 0)]' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to filter release images"
        debug "jq error: $IMAGES_WITH_RELEASES"
        echo ""
        continue
    fi

    IMAGES_WITH_RELEASES_COUNT=$(echo "$IMAGES_WITH_RELEASES" | jq 'length' 2>&1)

    if [ "$IMAGES_WITH_RELEASES_COUNT" = "0" ] || [ -z "$IMAGES_WITH_RELEASES_COUNT" ]; then
        echo "  No release-tagged images"
        echo ""
        continue
    fi

    TOTAL_RELEASE_TAGS=$(echo "$IMAGES_WITH_RELEASES" | jq '[.[].release_tags | length] | add // 0' 2>&1)

    echo "  Total images with release tags: $IMAGES_WITH_RELEASES_COUNT"
    echo "  Total release tags: $TOTAL_RELEASE_TAGS"

    # Get unique release-tagged images sorted by date (newest first)
    UNIQUE_RELEASE_IMAGES=$(echo "$IMAGES_WITH_RELEASES" | jq -c '
        group_by(.digest) | map(.[0]) | sort_by(.epoch) | reverse
    ' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to get unique images"
        debug "jq error: $UNIQUE_RELEASE_IMAGES"
        echo ""
        continue
    fi

    UNIQUE_RELEASE_COUNT=$(echo "$UNIQUE_RELEASE_IMAGES" | jq 'length' 2>&1)
    debug "Unique release images: $UNIQUE_RELEASE_COUNT"

    # Get recent images (within the age threshold)
    RECENT_IMAGES=$(echo "$UNIQUE_RELEASE_IMAGES" | jq -c '[.[] | select(.is_recent == true)]' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to filter recent images"
        debug "jq error: $RECENT_IMAGES"
        echo ""
        continue
    fi

    # Get top N most recent
    TOP_N_IMAGES=$(echo "$UNIQUE_RELEASE_IMAGES" | jq -c --arg keep_count "$KEEP_RELEASE_COUNT" '
        .[0:($keep_count | tonumber)]
    ' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to get top N images"
        debug "jq error: $TOP_N_IMAGES"
        echo ""
        continue
    fi

    # Combine and deduplicate by digest
    IMAGES_TO_KEEP=$(echo "$RECENT_IMAGES" "$TOP_N_IMAGES" | jq -s -c '
        add | group_by(.digest) | map(.[0]) | sort_by(.epoch) | reverse
    ' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to combine keep lists"
        debug "jq error: $IMAGES_TO_KEEP"
        echo ""
        continue
    fi

    KEEP_COUNT=$(echo "$IMAGES_TO_KEEP" | jq 'length' 2>&1)

    # Count how many are kept by each policy
    KEEP_BY_RECENT=$(echo "$IMAGES_TO_KEEP" | jq '[.[] | select(.is_recent == true)] | length' 2>&1)
    KEEP_BY_TOP_N=$(echo "$IMAGES_TO_KEEP" | jq --arg keep_count "$KEEP_RELEASE_COUNT" '
        [.[0:($keep_count | tonumber)]] | length
    ' 2>&1)

    # Get list of digests to keep
    KEEP_DIGESTS=$(echo "$IMAGES_TO_KEEP" | jq -c '[.[].digest]' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to get keep digests"
        debug "jq error: $KEEP_DIGESTS"
        echo ""
        continue
    fi

    # Images to DELETE - those not in the keep list
    IMAGES_TO_DELETE=$(echo "$UNIQUE_RELEASE_IMAGES" | jq -c --argjson keep_digests "$KEEP_DIGESTS" '
        [.[] | select(.digest as $d | $keep_digests | index($d) | not)]
    ' 2>&1)

    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to get delete list"
        debug "jq error: $IMAGES_TO_DELETE"
        echo ""
        continue
    fi

    DELETE_COUNT=$(echo "$IMAGES_TO_DELETE" | jq 'length' 2>&1)
    DELETE_RELEASE_TAG_COUNT=$(echo "$IMAGES_TO_DELETE" | jq '[.[].release_tags | length] | add // 0' 2>&1)
    DELETE_SIZE=$(echo "$IMAGES_TO_DELETE" | jq '[.[].size] | add // 0' 2>&1)

    echo "  >>> KEEP: $KEEP_COUNT release images ($KEEP_BY_RECENT by age, top $KEEP_BY_TOP_N by recency)"
    echo "  >>> DELETE: $DELETE_COUNT release images ($DELETE_RELEASE_TAG_COUNT release tags)"

    if [ "$DELETE_COUNT" -gt 0 ] 2>/dev/null; then
        DELETE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $DELETE_SIZE / 1024 / 1024 / 1024}" 2>/dev/null || echo "0.00")
        echo "  >>> SIZE TO FREE: ${DELETE_SIZE_GB} GB"
    fi

    # Show images to KEEP
    if [ "$KEEP_COUNT" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "  🛡️  IMAGES TO KEEP ($KEEP_COUNT):"
        echo "$IMAGES_TO_KEEP" | jq -r '.[0:10][] |
            "    ✓ \(.digest[0:24])... | Pushed: \(.pushed)\n      Release tags: \(.release_tags | join(", "))" +
            (if .latest_tag then " (has latest tag)" else "" end) +
            (if .is_recent then " [RECENT <7d]" else "" end)' 2>&1 || echo "  ERROR: Failed to display kept images"

        if [ "$KEEP_COUNT" -gt 10 ]; then
            echo "    ... and $((KEEP_COUNT - 10)) more images to keep"
        fi

        # Save kept releases for summary
        echo "$IMAGES_TO_KEEP" | jq -r --arg repo "$REPO" '
            .[] | "\($repo)|\(.release_tags | join(","))|\(.pushed)|\(if .is_recent then "RECENT" else "TOP_N" end)"
        ' >> "$TEMP_KEPT_RELEASES" 2>&1 || debug "Failed to save kept releases"
    fi

    # Show images to DELETE
    if [ "$DELETE_COUNT" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "  ✗ IMAGES TO DELETE ($DELETE_COUNT):"
        echo "$IMAGES_TO_DELETE" | jq -r '.[0:10][] |
            "    ✗ \(.digest[0:24])... | Pushed: \(.pushed)\n      Release tags: \(.release_tags | join(", "))" +
            (if .latest_tag then " (also has latest tag)" else "" end)' 2>&1 || echo "  ERROR: Failed to display delete list"

        if [ "$DELETE_COUNT" -gt 10 ]; then
            echo "    ... and $((DELETE_COUNT - 10)) more images to delete"
        fi

        echo "${REPO}|${DELETE_COUNT}|${DELETE_RELEASE_TAG_COUNT}|${DELETE_SIZE}" >> "$TEMP_RESULTS"

        if [ "$DRY_RUN" = true ]; then
            echo ""
            echo "  [DRY-RUN] Would delete $DELETE_RELEASE_TAG_COUNT release tags from $DELETE_COUNT images"
        else
            echo ""
            echo "  [LIVE] Deleting images..."
            DELETED=0
            echo "$IMAGES_TO_DELETE" | jq -r '.[] | .digest' | while read -r DIGEST; do
                if aws ecr batch-delete-image \
                    --repository-name "${REPO}" \
                    --region "${AWS_REGION}" \
                    --image-ids imageDigest="${DIGEST}" \
                    --output json > /dev/null 2>&1; then
                    DELETED=$((DELETED + 1))
                    echo "    Deleted: ${DIGEST:0:24}..."
                else
                    echo "    Failed to delete: ${DIGEST:0:24}..."
                fi
            done
        fi
    else
        echo "  OK - all release images are within retention policy"
    fi

    echo ""

done < "$TEMP_REPOS"

sync

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY - RELEASES TO KEEP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$TEMP_KEPT_RELEASES" ] && [ -s "$TEMP_KEPT_RELEASES" ]; then
    echo "Releases that will be KEPT:"
    echo ""

    CURRENT_REPO=""
    while IFS='|' read -r REPO RELEASES PUSHED REASON; do
        [ -n "$REPO" ] && [ -n "$RELEASES" ] && [ -n "$PUSHED" ] || continue

        if [ "$REPO" != "$CURRENT_REPO" ]; then
            [ -n "$CURRENT_REPO" ] && echo ""
            echo "Repository: $REPO"
            CURRENT_REPO="$REPO"
        fi

        REASON_TEXT=""
        if [ "$REASON" = "RECENT" ]; then
            REASON_TEXT=" [RECENT <${KEEP_RELEASE_AGE_DAYS}d]"
        elif [ "$REASON" = "TOP_N" ]; then
            REASON_TEXT=" [TOP ${KEEP_RELEASE_COUNT}]"
        fi

        echo "  ✓ $RELEASES (pushed: $PUSHED)${REASON_TEXT}"
    done < "$TEMP_KEPT_RELEASES"
else
    echo "No kept releases recorded"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY - DELETIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

FOUND_REPOS=0
TOTAL_IMAGES_DELETED=0
TOTAL_TAGS_TO_DELETE=0
TOTAL_SIZE=0

if [ -f "$TEMP_RESULTS" ] && [ -s "$TEMP_RESULTS" ]; then
    while IFS='|' read -r REPO IMAGE_COUNT TAG_COUNT SIZE; do
        [ -n "$REPO" ] && [ -n "$IMAGE_COUNT" ] && [ -n "$TAG_COUNT" ] && [ -n "$SIZE" ] || continue
        FOUND_REPOS=$((FOUND_REPOS + 1))
        TOTAL_IMAGES_DELETED=$((TOTAL_IMAGES_DELETED + IMAGE_COUNT))
        TOTAL_TAGS_TO_DELETE=$((TOTAL_TAGS_TO_DELETE + TAG_COUNT))
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
    done < "$TEMP_RESULTS"
fi

TOTAL_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE / 1024 / 1024 / 1024}" 2>/dev/null || echo "0.00")

echo "Repositories scanned: $COUNT"
echo "Repositories with deletable releases: $FOUND_REPOS"
echo "Total images to delete: $TOTAL_IMAGES_DELETED"
echo "Total release tags to delete: $TOTAL_TAGS_TO_DELETE"
echo "Total size to free: ${TOTAL_SIZE_GB} GB"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "⚠️  DRY-RUN MODE: No images were deleted"
    echo ""
    echo "Retention Policy Applied:"
    echo "  ✓ Keep ${KEEP_RELEASE_COUNT} most recent release tags per repository"
    echo "  ✓ Keep all release tags younger than ${KEEP_RELEASE_AGE_DAYS} days"
    echo "  ✗ Delete all older release images"
    echo ""
    echo "To actually delete:"
    echo "  1. Review the deletion list above"
    echo "  2. Edit script: readonly DRY_RUN=false"
    echo "  3. Run again"
else
    echo ""
    echo "✅ DELETED: $TOTAL_TAGS_TO_DELETE release tags from $TOTAL_IMAGES_DELETED images"
    echo "💾 FREED: ${TOTAL_SIZE_GB} GB"
    echo ""
    echo "🛡️  Preserved: ${KEEP_RELEASE_COUNT} most recent releases + all releases <${KEEP_RELEASE_AGE_DAYS} days old"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
