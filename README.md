# AWS-ECR-cleanup

# Overview
The scripts provide comprehensive ECR image lifecycle management, including discovery, analysis, and automated cleanup of various image tag types (commit tags, release tags, and untagged images).

# Prerequisites
AWS CLI - Configured with appropriate credentials and permissions;
jq - JSON processor for parsing AWS CLI output

# Dry-Run Mode
IMPORTANT: All deletion scripts support dry-run mode.
# Enabling Dry-Run
To enable dry-run mode, edit the script and change:

readonly DRY_RUN=false

to:

readonly DRY_RUN=true

# Recommended Workflow
1. Always run in DRY-RUN mode first
2. Review the output and verify expected behavior
3. If satisfied, disable DRY-RUN and execute live deletion
4. Monitor results and check for any issues

# Storage Optimization
These scripts help optimize ECR storage costs by:

1. Removing dangling untagged images
2. Limiting the number of commit-tagged images
3. Enforcing time-based retention for releases
4. Preventing accumulation of unused images
