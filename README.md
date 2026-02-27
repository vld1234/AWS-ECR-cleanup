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
* Always run in DRY-RUN mode first
* Review the output and verify expected behavior
* If satisfied, disable DRY-RUN and execute live deletion
* Monitor results and check for any issues

# Storage Optimization
These scripts help optimize ECR storage costs by:

* Removing dangling untagged images
* Limiting the number of commit-tagged images
* Enforcing time-based retention for releases
* Preventing accumulation of unused images
