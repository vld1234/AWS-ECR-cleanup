#!/bin/bash
################################################################################
# ECR - Commit Tag Cleanup with Protected Tags
#
# Purpose:
#   - Keep latest 10 digests (PROTECTED - never delete the digest itself)
#   - Within those 10 digests, keep max 25 commit tags per digest
#   - Always protect 'latest' tag and release tags (X.Y.Z)
#   - Always protect explicitly listed release tags (e.g., 5.0.96-p1)
#   - Delete excess commit tags and old digests beyond the 10
################################################################################

set -euo pipefail

# Configuration
readonly DRY_RUN=false  # Set to false to actually delete images
readonly KEEP_DIGEST_COUNT=10  # Keep latest N image digests (PROTECTED)
readonly KEEP_TAGS_PER_DIGEST=25  # Keep max N commit tags per digest

# Explicitly protected release tags that should NEVER be deleted
readonly PROTECTED_RELEASE_TAGS=("1.1.1-p1")

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-7}"
REPO_PREFIX="project/"

# Create temp file to store results
TEMP_RESULTS="/tmp/ecr-commit-results-$$.txt"
TEMP_REPOS="/tmp/ecr-repos-$$.txt"
> "$TEMP_RESULTS"

trap "rm -f $TEMP_RESULTS $TEMP_REPOS" EXIT

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║           AOS ECR - COMMIT TAG CLEANUP WITH PROTECTED TAGS                   ║"
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
echo "  • Keep ${KEEP_DIGEST_COUNT} most recent image digests (PROTECTED - never deleted)"
echo "  • Keep up to ${KEEP_TAGS_PER_DIGEST} commit tags per digest"
echo "  • Keep 'latest' tag (always protected)"
echo "  • Keep all release tags (X.Y.Z, X.Y.Z-suffix) (always protected)"
echo "  • Delete excess commit tags beyond ${KEEP_TAGS_PER_DIGEST} per digest"
echo "  • Delete all digests beyond the latest ${KEEP_DIGEST_COUNT}"
echo ""
echo "Protected tags:"
echo "  🛡️  'latest' tag"
echo "  🛡️  All release tags: X.Y.Z, X.Y.Z-suffix (e.g., 1.0.0, 5.1.214)"
echo ""
echo "🛡️🔒 EXPLICITLY PROTECTED RELEASE TAGS (NEVER DELETED):"
printf "  • %s\n" "${PROTECTED_RELEASE_TAGS[@]}"
echo ""
echo "Commit tag format: 8 hex characters (e.g., 9a6b6994, 04c93447)"
echo ""
echo "Fetching repositories..."

# Create JSON array of explicitly protected tags
PROTECTED_TAGS_JSON=$(printf '%s\n' "${PROTECTED_RELEASE_TAGS[@]}" | jq -R . | jq -s .)

# Get repositories
aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --output json 2>/dev/null | \
    jq -r --arg prefix "${REPO_PREFIX}" \
        '.repositories[] | select(.repositoryName | startswith($prefix)) | .repositoryName' | \
    sort > "$TEMP_REPOS"

REPO_COUNT=$(wc -l < "$TEMP_REPOS")
echo "Found ${REPO_COUNT} repositories"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STARTING SCAN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

COUNT=0
TOTAL_EXPLICITLY_PROTECTED_FOUND=0

# Process each repository
while IFS= read -r REPO || [ -n "$REPO" ]; do
    [ -z "$REPO" ] && continue

    COUNT=$((COUNT + 1))

    echo "[$COUNT/$REPO_COUNT] $REPO"

    # Get all images with their tags categorized
    ALL_IMAGE_DATA=$(aws ecr describe-images \
        --repository-name "${REPO}" \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null | \
        jq -c --argjson protected "$PROTECTED_TAGS_JSON" '
            [.imageDetails[] |
                select(.imageTags != null and .imageTags != []) |
                {
                    digest: .imageDigest,
                    pushed: .imagePushedAt,
                    epoch: (.imagePushedAt | gsub("\\.[0-9]+\\+"; "+") | gsub("\\+00:00"; "Z") | fromdateiso8601),
                    size: .imageSizeInBytes,
                    all_tags: .imageTags,
                    commit_tags: [.imageTags[] | select(test("^[0-9a-f]{8}$"))],
                    latest_tag: ([.imageTags[] | select(. == "latest")] | length > 0),
                    release_tags: [.imageTags[] | select(
                        test("^[0-9]+\\.[0-9]+$") or
                        test("^[0-9]+\\.[0-9]+\\.[0-9]+$") or
                        test("^[0-9]+\\.[0-9]+\\.[0-9]+-[a-zA-Z0-9]+$")
                    )],
                    explicitly_protected_tags: [.imageTags[] | select(. as $t | $protected | index($t) != null)],
                    has_explicitly_protected_tag: ([.imageTags[] | select(. as $t | $protected | index($t) != null)] | length > 0),
                    has_protected_tag: (
                        ([.imageTags[] | select(. == "latest")] | length > 0) or
                        ([.imageTags[] | select(
                            test("^[0-9]+\\.[0-9]+$") or
                            test("^[0-9]+\\.[0-9]+\\.[0-9]+$") or
                            test("^[0-9]+\\.[0-9]+\\.[0-9]+-[a-zA-Z0-9]+$")
                        )] | length > 0)
                    )
                }
            ] |
            sort_by(.epoch) | reverse
        ')

    TOTAL_IMAGES=$(echo "$ALL_IMAGE_DATA" | jq 'length')

    if [ "$TOTAL_IMAGES" -eq 0 ]; then
        echo "  No images found"
        echo ""
        continue
    fi

    # Check for explicitly protected tags in this repo
    EXPLICITLY_PROTECTED_IN_REPO=$(echo "$ALL_IMAGE_DATA" | jq -r '[.[] | select(.has_explicitly_protected_tag == true)] | length')

    if [ "$EXPLICITLY_PROTECTED_IN_REPO" -gt 0 ]; then
        TOTAL_EXPLICITLY_PROTECTED_FOUND=$((TOTAL_EXPLICITLY_PROTECTED_FOUND + EXPLICITLY_PROTECTED_IN_REPO))

        echo "  ✅ 🛡️🔒 FOUND ${EXPLICITLY_PROTECTED_IN_REPO} IMAGE(S) WITH EXPLICITLY PROTECTED TAG: ${PROTECTED_RELEASE_TAGS[*]}"

        echo "$ALL_IMAGE_DATA" | jq -r '[.[] | select(.has_explicitly_protected_tag == true)][] |
            "      🔒 Digest: \(.digest[7:27])... | Pushed: \(.pushed)" +
            "\n         All tags: " + (.all_tags | join(", ")) +
            "\n         Protected tag(s): " + (.explicitly_protected_tags | join(", ")) +
            (if (.commit_tags | length) > 0 then "\n         Commit tags: " + (.commit_tags | join(", ")) else "\n         (No commit tags)" end) +
            "\n         ✅ STATUS: PROTECTED - Will NEVER be deleted"'
        echo ""
    fi

    # Filter to only images with commit tags
    IMAGES_WITH_COMMITS=$(echo "$ALL_IMAGE_DATA" | jq -c '[.[] | select((.commit_tags | length) > 0)]')
    IMAGES_WITH_COMMITS_COUNT=$(echo "$IMAGES_WITH_COMMITS" | jq 'length')

    if [ "$IMAGES_WITH_COMMITS_COUNT" -eq 0 ]; then
        echo "  No commit-tagged images"
        echo ""
        continue
    fi

    TOTAL_COMMIT_TAGS=$(echo "$IMAGES_WITH_COMMITS" | jq '[.[].commit_tags | length] | add // 0')

    echo "  Total images with commit tags: $IMAGES_WITH_COMMITS_COUNT"
    echo "  Total commit tags: $TOTAL_COMMIT_TAGS"

    # Separate images by protection status
    PROTECTED_BY_TAG=$(echo "$IMAGES_WITH_COMMITS" | jq -c '[.[] | select(.has_protected_tag == true)]')
    PROTECTED_BY_TAG_COUNT=$(echo "$PROTECTED_BY_TAG" | jq 'length')

    EXPLICITLY_PROTECTED_WITH_COMMITS=$(echo "$IMAGES_WITH_COMMITS" | jq -c '[.[] | select(.has_explicitly_protected_tag == true)]')
    EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT=$(echo "$EXPLICITLY_PROTECTED_WITH_COMMITS" | jq 'length')

    NON_PROTECTED_IMAGES=$(echo "$IMAGES_WITH_COMMITS" | jq -c '[.[] | select(.has_protected_tag == false)]')
    NON_PROTECTED_COUNT=$(echo "$NON_PROTECTED_IMAGES" | jq 'length')

    if [ "$PROTECTED_BY_TAG_COUNT" -gt 0 ]; then
        echo "  🛡️  Found $PROTECTED_BY_TAG_COUNT images with protected tags (latest/release)"
        if [ "$EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT" -gt 0 ]; then
            echo "      └─ Including $EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT with EXPLICITLY protected tags (${PROTECTED_RELEASE_TAGS[*]})"
        fi
    fi
    echo "  Images without protected tags: $NON_PROTECTED_COUNT"

    # Keep first N non-protected digests (PROTECTED by retention policy)
    PROTECTED_BY_RETENTION=$(echo "$NON_PROTECTED_IMAGES" | jq -c --argjson keep "$KEEP_DIGEST_COUNT" '
        if length > $keep then .[0:$keep] else . end
    ')
    PROTECTED_BY_RETENTION_COUNT=$(echo "$PROTECTED_BY_RETENTION" | jq 'length')

    # Old digests to DELETE completely
    OLD_DIGESTS=$(echo "$NON_PROTECTED_IMAGES" | jq -c --argjson keep "$KEEP_DIGEST_COUNT" '
        if length > $keep then .[$keep:] else [] end
    ')
    OLD_DIGEST_COUNT=$(echo "$OLD_DIGESTS" | jq 'length')

    TOTAL_PROTECTED=$((PROTECTED_BY_TAG_COUNT + PROTECTED_BY_RETENTION_COUNT))

    echo ""
    echo "  📊 PROTECTION SUMMARY:"
    echo "      ├─ Protected by tags (latest/release): $PROTECTED_BY_TAG_COUNT digests"
    if [ "$EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT" -gt 0 ]; then
        echo "      │  └─ 🔒 Explicitly protected (${PROTECTED_RELEASE_TAGS[*]}): $EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT digests"
    fi
    echo "      ├─ Protected by retention (top $KEEP_DIGEST_COUNT): $PROTECTED_BY_RETENTION_COUNT digests"
    echo "      └─ TOTAL PROTECTED: $TOTAL_PROTECTED digests"
    echo ""
    echo "      ❌ Old digests to DELETE: $OLD_DIGEST_COUNT digests"

    # Calculate deletions
    TAGS_TO_DELETE_FROM_OLD=0
    TAGS_TO_DELETE_FROM_EXCESS=0
    OLD_DIGEST_SIZE=0

    if [ "$OLD_DIGEST_COUNT" -gt 0 ]; then
        TAGS_TO_DELETE_FROM_OLD=$(echo "$OLD_DIGESTS" | jq '[.[].commit_tags | length] | add // 0')
        OLD_DIGEST_SIZE=$(echo "$OLD_DIGESTS" | jq '[.[].size] | add // 0')
    fi

    # Check for excess tags in PROTECTED digests (both types)
    ALL_PROTECTED=$(echo "$PROTECTED_BY_TAG" "$PROTECTED_BY_RETENTION" | jq -s 'add | unique_by(.digest)')

    DIGESTS_WITH_EXCESS=$(echo "$ALL_PROTECTED" | jq -c --argjson max_tags "$KEEP_TAGS_PER_DIGEST" '
        [.[] | select((.commit_tags | length) > $max_tags)]
    ')
    DIGESTS_WITH_EXCESS_COUNT=$(echo "$DIGESTS_WITH_EXCESS" | jq 'length')

    if [ "$DIGESTS_WITH_EXCESS_COUNT" -gt 0 ]; then
        TAGS_TO_DELETE_FROM_EXCESS=$(echo "$DIGESTS_WITH_EXCESS" | jq --argjson max_tags "$KEEP_TAGS_PER_DIGEST" '
            [.[] | ((.commit_tags | length) - $max_tags)] | add // 0
        ')
    fi

    TOTAL_TAGS_TO_DELETE=$((TAGS_TO_DELETE_FROM_OLD + TAGS_TO_DELETE_FROM_EXCESS))

    if [ "$TOTAL_TAGS_TO_DELETE" -eq 0 ]; then
        echo ""
        echo "  ✅ OK - all images within retention limits"
        echo ""
        continue
    fi

    echo ""
    echo "  🗑️  DELETION PLAN:"
    if [ "$TAGS_TO_DELETE_FROM_OLD" -gt 0 ]; then
        echo "      ├─ Delete $OLD_DIGEST_COUNT old digests ($TAGS_TO_DELETE_FROM_OLD commit tags)"
    fi
    if [ "$TAGS_TO_DELETE_FROM_EXCESS" -gt 0 ]; then
        echo "      ├─ Delete $TAGS_TO_DELETE_FROM_EXCESS excess commit tags from $DIGESTS_WITH_EXCESS_COUNT protected digests"
    fi
    echo "      └─ TOTAL: $TOTAL_TAGS_TO_DELETE commit tags to delete"

    DELETE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $OLD_DIGEST_SIZE / 1024 / 1024 / 1024}")
    DELETE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $OLD_DIGEST_SIZE / 1024 / 1024}")

    if (( $(awk "BEGIN {print ($DELETE_SIZE_GB >= 1)}") )); then
        SIZE_DISPLAY="${DELETE_SIZE_GB} GB"
    else
        SIZE_DISPLAY="${DELETE_SIZE_MB} MB"
    fi
    echo "      Size to free: $SIZE_DISPLAY"

    # Show explicitly protected images FIRST
    if [ "$EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT" -gt 0 ]; then
        echo ""
        echo "  🛡️🔒 EXPLICITLY PROTECTED IMAGES (${PROTECTED_RELEASE_TAGS[*]}):"
        echo "$EXPLICITLY_PROTECTED_WITH_COMMITS" | jq -r '.[0:3][] |
            "    🔒 \(.digest[7:27])... | Pushed: \(.pushed) | Commits: \((.commit_tags | length))" +
            "\n      Protected tag(s): " + (.explicitly_protected_tags | join(", ")) +
            (if (.release_tags | length) > 0 then "\n      Other release tags: " + (.release_tags | join(", ")) else "" end) +
            (if .latest_tag then "\n      + latest tag" else "" end) +
            "\n      Commit tags: " + (.commit_tags | join(", ")) +
            "\n      ✓ PROTECTED - will NEVER be deleted"'

        if [ "$EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT" -gt 3 ]; then
            echo "    ... and $((EXPLICITLY_PROTECTED_WITH_COMMITS_COUNT - 3)) more"
        fi
    fi

    # Show other protected images by tag (sample)
    OTHER_PROTECTED_BY_TAG=$(echo "$PROTECTED_BY_TAG" | jq -c '[.[] | select(.has_explicitly_protected_tag == false)]')
    OTHER_PROTECTED_BY_TAG_COUNT=$(echo "$OTHER_PROTECTED_BY_TAG" | jq 'length')

    if [ "$OTHER_PROTECTED_BY_TAG_COUNT" -gt 0 ]; then
        echo ""
        echo "  🛡️  OTHER PROTECTED by tag (latest/release) - sample:"
        echo "$OTHER_PROTECTED_BY_TAG" | jq -r '.[0:3][] |
            "    🛡️  \(.digest[7:27])... | Pushed: \(.pushed)" +
            (if (.commit_tags | length) > 0 then " | Commits: \((.commit_tags | length))" else "" end) +
            "\n      Tags: " +
            (if .latest_tag then "latest" else "" end) +
            (if (.latest_tag and (.release_tags | length > 0)) then ", " else "" end) +
            (.release_tags | join(", "))'

        if [ "$OTHER_PROTECTED_BY_TAG_COUNT" -gt 3 ]; then
            echo "    ... and $((OTHER_PROTECTED_BY_TAG_COUNT - 3)) more"
        fi
    fi

    # Show protected images by retention (sample)
    if [ "$PROTECTED_BY_RETENTION_COUNT" -gt 0 ]; then
        echo ""
        echo "  🛡️  PROTECTED by retention (top $KEEP_DIGEST_COUNT) - sample:"
        echo "$PROTECTED_BY_RETENTION" | jq -r '.[0:3][] |
            "    🛡️  \(.digest[7:27])... | Pushed: \(.pushed) | Commits: \((.commit_tags | length))\n      Commit tags: \(.commit_tags[0:5] | join(", "))" +
            (if (.commit_tags | length) > 5 then " ..." else "" end)'

        if [ "$PROTECTED_BY_RETENTION_COUNT" -gt 3 ]; then
            echo "    ... and $((PROTECTED_BY_RETENTION_COUNT - 3)) more"
        fi
    fi

    # Show digests with excess tags
    if [ "$DIGESTS_WITH_EXCESS_COUNT" -gt 0 ]; then
        echo ""
        echo "  ⚠️  PROTECTED digests with EXCESS commit tags (>$KEEP_TAGS_PER_DIGEST):"
        echo "$DIGESTS_WITH_EXCESS" | jq -r --argjson max "$KEEP_TAGS_PER_DIGEST" '.[0:3][] |
            "    ⚠️  \(.digest[7:27])... | Has: \((.commit_tags | length)) tags | Will keep: \($max) | Delete: \(((.commit_tags | length) - $max))\n      Keep: \(.commit_tags[0:$max] | join(", "))\n      Delete: \(.commit_tags[$max:] | join(", "))"'

        if [ "$DIGESTS_WITH_EXCESS_COUNT" -gt 3 ]; then
            echo "    ... and $((DIGESTS_WITH_EXCESS_COUNT - 3)) more with excess"
        fi
    fi

    # Show old digests to delete
    if [ "$OLD_DIGEST_COUNT" -gt 0 ]; then
        echo ""
        echo "  ❌  OLD DIGESTS to DELETE (beyond top $KEEP_DIGEST_COUNT):"
        echo "$OLD_DIGESTS" | jq -r '.[0:5][] |
            "    ✗ \(.digest[7:27])... | Pushed: \(.pushed)\n      Delete ALL commit tags: \(.commit_tags | join(", "))"'

        if [ "$OLD_DIGEST_COUNT" -gt 5 ]; then
            echo "    ... and $((OLD_DIGEST_COUNT - 5)) more old digests"
        fi
    fi

    # Save to temp file for summary
    echo "${REPO}|${OLD_DIGEST_COUNT}|${TOTAL_TAGS_TO_DELETE}|${OLD_DIGEST_SIZE}" >> "$TEMP_RESULTS"

    # DELETE
    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "  [DRY-RUN] Would delete $TOTAL_TAGS_TO_DELETE commit tags"
    else
        echo ""
        echo "  [DELETING] Removing $TOTAL_TAGS_TO_DELETE commit tags..."

        DELETED_COUNT=0

        # Delete all tags from old digests
        if [ "$OLD_DIGEST_COUNT" -gt 0 ]; then
            OLD_COMMIT_TAGS=$(echo "$OLD_DIGESTS" | jq -r '.[].commit_tags[]')

            while IFS= read -r TAG_NAME; do
                if [ -n "$TAG_NAME" ]; then
                    aws ecr batch-delete-image \
                        --repository-name "${REPO}" \
                        --region "${AWS_REGION}" \
                        --image-ids imageTag="${TAG_NAME}" \
                        --output json > /dev/null 2>&1

                    DELETED_COUNT=$((DELETED_COUNT + 1))

                    if [ $((DELETED_COUNT % 10)) -eq 0 ]; then
                        echo "    Deleted $DELETED_COUNT/$TOTAL_TAGS_TO_DELETE tags..."
                    fi
                fi
            done <<< "$OLD_COMMIT_TAGS"
        fi

        # Delete excess tags from protected digests
        if [ "$DIGESTS_WITH_EXCESS_COUNT" -gt 0 ]; then
            EXCESS_TAGS=$(echo "$DIGESTS_WITH_EXCESS" | jq -r --argjson max "$KEEP_TAGS_PER_DIGEST" '
                .[].commit_tags[$max:][]
            ')

            while IFS= read -r TAG_NAME; do
                if [ -n "$TAG_NAME" ]; then
                    aws ecr batch-delete-image \
                        --repository-name "${REPO}" \
                        --region "${AWS_REGION}" \
                        --image-ids imageTag="${TAG_NAME}" \
                        --output json > /dev/null 2>&1

                    DELETED_COUNT=$((DELETED_COUNT + 1))

                    if [ $((DELETED_COUNT % 10)) -eq 0 ]; then
                        echo "    Deleted $DELETED_COUNT/$TOTAL_TAGS_TO_DELETE tags..."
                    fi
                fi
            done <<< "$EXCESS_TAGS"
        fi

        echo "  [SUCCESS] Deleted $DELETED_COUNT commit tags"
    fi

    echo ""

done < "$TEMP_REPOS"

# FORCE SYNC
sync

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Calculate summary from temp file
FOUND_REPOS=0
TOTAL_DIGESTS_DELETED=0
TOTAL_TAGS_TO_DELETE=0
TOTAL_SIZE=0

if [ -f "$TEMP_RESULTS" ] && [ -s "$TEMP_RESULTS" ]; then
    while IFS='|' read -r REPO DIGEST_COUNT TAG_COUNT SIZE; do
        if [ -n "$REPO" ] && [ -n "$DIGEST_COUNT" ] && [ -n "$TAG_COUNT" ] && [ -n "$SIZE" ]; then
            FOUND_REPOS=$((FOUND_REPOS + 1))
            TOTAL_DIGESTS_DELETED=$((TOTAL_DIGESTS_DELETED + DIGEST_COUNT))
            TOTAL_TAGS_TO_DELETE=$((TOTAL_TAGS_TO_DELETE + TAG_COUNT))
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
        fi
    done < "$TEMP_RESULTS"
fi

TOTAL_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE / 1024 / 1024 / 1024}")

echo "Repositories scanned: $COUNT"
echo "Repositories with deletable commits: $FOUND_REPOS"
echo "Total old digests to delete: $TOTAL_DIGESTS_DELETED"
echo "Total commit tags to delete: $TOTAL_TAGS_TO_DELETE"
echo "Total size to free: ${TOTAL_SIZE_GB} GB"
echo ""

if [ "$TOTAL_EXPLICITLY_PROTECTED_FOUND" -gt 0 ]; then
    echo "✅ 🛡️🔒 EXPLICITLY PROTECTED IMAGES FOUND: $TOTAL_EXPLICITLY_PROTECTED_FOUND"
    echo "    Tags: ${PROTECTED_RELEASE_TAGS[*]}"
    echo "    These images are COMPLETELY SAFE and will NEVER be deleted!"
else
    echo "ℹ️  No explicitly protected tags (${PROTECTED_RELEASE_TAGS[*]}) found in any repository"
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "⚠️  DRY-RUN MODE: No images were deleted"
    echo ""
    echo "Retention Policy Applied:"
    echo "  🔒 HIGHEST: Explicitly protected tags: ${PROTECTED_RELEASE_TAGS[*]}"
    echo "  🛡️  Keep ALL images with 'latest' or release tags (NEVER deleted)"
    echo "  🛡️  Keep ${KEEP_DIGEST_COUNT} most recent digests (PROTECTED - digest never deleted)"
    echo "  ✓ Keep up to ${KEEP_TAGS_PER_DIGEST} commit tags per protected digest"
    echo "  ✗ Delete excess commit tags beyond ${KEEP_TAGS_PER_DIGEST} per digest"
    echo "  ✗ Delete ALL commit tags from digests beyond top ${KEEP_DIGEST_COUNT}"
    echo ""
    echo "To actually delete:"
    echo "  1. Review the deletion list above"
    echo "  2. Edit script: readonly DRY_RUN=false"
    echo "  3. Run again"
else
    echo ""
    echo "✅ DELETED: $TOTAL_TAGS_TO_DELETE commit tags from $TOTAL_DIGESTS_DELETED old digests"
    echo "💾 FREED: ${TOTAL_SIZE_GB} GB"
    echo ""
    echo "🛡️  Protected digests and tags were preserved per policy"
    if [ "$TOTAL_EXPLICITLY_PROTECTED_FOUND" -gt 0 ]; then
        echo "🛡️🔒 Explicitly protected: $TOTAL_EXPLICITLY_PROTECTED_FOUND images (${PROTECTED_RELEASE_TAGS[*]})"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
