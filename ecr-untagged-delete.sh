#!/bin/bash
################################################################################
# ECR - Delete Untagged Images with DRY-RUN
# Keeps: Only the 1 most recent untagged image
################################################################################

set -euo pipefail

# Configuration
readonly DRY_RUN=false  # Set to false to actually delete images
readonly KEEP_UNTAGGED_COUNT=1  # Keep only the latest 1 untagged image

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-7}"
REPO_PREFIX="project/"

# Create temp file to store results
TEMP_RESULTS="/tmp/ecr-untagged-results-$$.txt"
> "$TEMP_RESULTS"  # Create/clear the file

trap "rm -f $TEMP_RESULTS" EXIT

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║           ECR - DELETE UNTAGGED IMAGES                                   ║"
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
echo "  • Keep ONLY the ${KEEP_UNTAGGED_COUNT} most recent untagged image per repository"
echo "  • Delete all other untagged images"
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
echo "STARTING SCAN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

COUNT=0

# Process each repository
echo "$REPOS" | while IFS= read -r REPO; do
    COUNT=$((COUNT + 1))

    echo "[$COUNT/$REPO_COUNT] $REPO"

    # Get ALL untagged images sorted by push date (newest first)
    ALL_UNTAGGED_DATA=$(aws ecr describe-images \
        --repository-name "${REPO}" \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null | \
        jq -c '[.imageDetails[] |
                select(.imageTags == null or .imageTags == []) |
                {
                    digest: .imageDigest,
                    pushed: .imagePushedAt,
                    epoch: (.imagePushedAt | gsub("\\.[0-9]+\\+"; "+") | gsub("\\+00:00"; "Z") | fromdateiso8601),
                    size: .imageSizeInBytes
                }] | sort_by(.epoch) | reverse')

    TOTAL_UNTAGGED=$(echo "$ALL_UNTAGGED_DATA" | jq 'length')

    if [ "$TOTAL_UNTAGGED" -gt 0 ]; then
        echo "  Total untagged: $TOTAL_UNTAGGED images"

        # Keep only the first (most recent) image
        IMAGES_TO_KEEP=$(echo "$ALL_UNTAGGED_DATA" | jq -c --argjson keep_count "$KEEP_UNTAGGED_COUNT" '.[0:$keep_count]')
        KEEP_COUNT=$(echo "$IMAGES_TO_KEEP" | jq 'length')

        # Delete all others
        IMAGES_TO_DELETE=$(echo "$ALL_UNTAGGED_DATA" | jq -c --argjson keep_count "$KEEP_UNTAGGED_COUNT" '.[$keep_count:]')
        DELETE_COUNT=$(echo "$IMAGES_TO_DELETE" | jq 'length')

        if [ "$DELETE_COUNT" -gt 0 ]; then
            echo "  >>> KEEP: $KEEP_COUNT image (most recent)"
            echo "  >>> DELETE: $DELETE_COUNT images"

            # Calculate delete size
            DELETE_SIZE=$(echo "$IMAGES_TO_DELETE" | jq '[.[].size] | add // 0')

            DELETE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $DELETE_SIZE / 1024 / 1024 / 1024}")
            DELETE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $DELETE_SIZE / 1024 / 1024}")

            if (( $(awk "BEGIN {print ($DELETE_SIZE_GB >= 1)}") )); then
                SIZE_DISPLAY="${DELETE_SIZE_GB} GB"
            else
                SIZE_DISPLAY="${DELETE_SIZE_MB} MB"
            fi

            echo "  >>> SIZE TO FREE: $SIZE_DISPLAY"

            # Show image to keep
            echo ""
            echo "  Image to KEEP (most recent):"
            echo "$IMAGES_TO_KEEP" | jq -r '.[] |
                "    ✓ \(.digest[7:27])... | \(.pushed) | \((.size/1024/1024|floor))MB"'

            echo ""
            echo "  Images to DELETE:"
            # Show first 10 to delete
            if [ "$DELETE_COUNT" -le 10 ]; then
                echo "$IMAGES_TO_DELETE" | jq -r '.[] |
                    "    ✗ \(.digest[7:27])... | \(.pushed) | \((.size/1024/1024|floor))MB"'
            else
                echo "$IMAGES_TO_DELETE" | jq -r '.[0:10][] |
                    "    ✗ \(.digest[7:27])... | \(.pushed) | \((.size/1024/1024|floor))MB"'
                echo "    ... and $((DELETE_COUNT - 10)) more"
            fi

            # Save to temp file for summary
            echo "${REPO}|${DELETE_COUNT}|${DELETE_SIZE}" >> "$TEMP_RESULTS"

            # DELETE IMAGES
            if [ "$DRY_RUN" = true ]; then
                echo ""
                echo "  [DRY-RUN] Would delete $DELETE_COUNT images"
            else
                echo ""
                echo "  [DELETING] Removing $DELETE_COUNT images..."

                # Get digests and delete
                DIGESTS=$(echo "$IMAGES_TO_DELETE" | jq -r '.[].digest')
                DELETED_COUNT=0

                echo "$DIGESTS" | while IFS= read -r DIGEST; do
                    if [ -n "$DIGEST" ]; then
                        aws ecr batch-delete-image \
                            --repository-name "${REPO}" \
                            --region "${AWS_REGION}" \
                            --image-ids imageDigest="${DIGEST}" \
                            --output json > /dev/null 2>&1

                        DELETED_COUNT=$((DELETED_COUNT + 1))

                        if [ $((DELETED_COUNT % 10)) -eq 0 ]; then
                            echo "    Deleted $DELETED_COUNT/$DELETE_COUNT images..." >&2
                        fi
                    fi
                done

                echo "  [SUCCESS] Deleted $DELETE_COUNT images"
            fi

            echo ""
        else
            echo "  OK - only 1 untagged image (already at minimum)"
            echo ""
        fi
    else
        echo "  OK - no untagged images"
    fi

done

# FORCE SYNC
sync
sleep 1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Calculate summary from temp file
FOUND_REPOS=0
TOTAL_TO_DELETE=0
TOTAL_SIZE=0

if [ -f "$TEMP_RESULTS" ] && [ -s "$TEMP_RESULTS" ]; then
    while IFS='|' read -r REPO DELETE_COUNT SIZE; do
        if [ -n "$REPO" ] && [ -n "$DELETE_COUNT" ] && [ -n "$SIZE" ]; then
            FOUND_REPOS=$((FOUND_REPOS + 1))
            TOTAL_TO_DELETE=$((TOTAL_TO_DELETE + DELETE_COUNT))
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
        fi
    done < "$TEMP_RESULTS"
fi

TOTAL_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE / 1024 / 1024 / 1024}")

echo "Repositories scanned: $REPO_COUNT"
echo "Repositories with deletable untagged: $FOUND_REPOS"
echo "Total images to delete: $TOTAL_TO_DELETE"
echo "Total size to free: ${TOTAL_SIZE_GB} GB"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "⚠️  DRY-RUN MODE: No images were deleted"
    echo ""
    echo "Retention Policy Applied:"
    echo "  ✓ Kept ONLY the ${KEEP_UNTAGGED_COUNT} most recent untagged image per repository"
    echo "  ✓ All older untagged images will be deleted"
    echo ""
    echo "To actually delete images:"
    echo "  1. Review the deletion list above"
    echo "  2. Edit the script and set: readonly DRY_RUN=false"
    echo "  3. Run the script again"
else
    echo ""
    echo "✅ DELETED: $TOTAL_TO_DELETE images"
    echo "💾 FREED: ${TOTAL_SIZE_GB} GB"
    echo ""
    echo "Retention Policy Applied:"
    echo "  ✓ Kept ONLY the ${KEEP_UNTAGGED_COUNT} most recent untagged image per repository"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
