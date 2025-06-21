#!/bin/bash

# SCRIPT: delete_s3_buckets_by_name.sh
# DESCRIPTION:
#   This script lists S3 buckets in your AWS account and deletes those
#   whose names contain a specified string. It handles non-empty buckets
#   by forcefully deleting all contents (objects, object versions, delete markers)
#   before attempting to delete the bucket itself.
#
# USAGE:
#   ./delete_s3_buckets_by_name.sh <string_to_filter>
#
#   <string_to_filter>: A case-insensitive string to match against bucket names.
#
# WARNING:
#   This script performs PERMANENT DELETION.
#   All objects and their versions within matching buckets will be irrevocably lost.
#   Ensure you have appropriate backups and understand the consequences.
#
# PREREQUISITES:
#   - AWS CLI configured with credentials that have sufficient permissions:
#     - s3:ListAllMyBuckets (to list buckets)
#     - s3:ListBucketVersions (to list object versions and delete markers)
#     - s3:DeleteObject (to delete current objects)
#     - s3:DeleteObjectVersion (to delete specific object versions)
#     - s3:DeleteBucket (to delete buckets)
#   - Bash shell environment.
#   - 'jq' utility installed for JSON parsing.

# Function to display usage information and exit
usage() {
  echo "Usage: $0 <string_to_filter>"
  echo ""
  echo "Deletes all S3 buckets whose names contain the provided string (case-insensitive)."
  echo "WARNING: This script will PERMANENTLY DELETE all objects and versions within matching buckets."
  echo "         This action cannot be undone."
  echo ""
  exit 1
}

# --- Input Validation ---
# Check if an input parameter is provided
if [ -z "$1" ]; then
  echo "Error: Missing input parameter for filtering buckets."
  usage
fi

# Check for jq installation
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install 'jq' to run this script."
    echo "  (e.g., sudo apt-get install jq on Debian/Ubuntu, brew install jq on macOS)"
    exit 1
fi

FILTER_STRING="$1"
FOUND_BUCKETS=()

echo "---------------------------------------------------------"
echo "S3 Bucket Deletion Script"
echo "---------------------------------------------------------"
echo "Searching for S3 buckets containing \"${FILTER_STRING}\"..."
echo ""

# --- List and Filter Buckets ---
# Use aws s3api list-buckets to get all bucket names.
# --query "Buckets[].Name" extracts only the names.
# --output text formats the output as plain text, one name per line.
# Redirect stderr to /dev/null to suppress non-critical AWS CLI warnings
BUCKET_NAMES=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null)

# Check if the AWS CLI command succeeded
if [ $? -ne 0 ]; then
  echo "Error: Failed to list S3 buckets. Please check your AWS CLI configuration and permissions."
  exit 1
fi

# Filter buckets based on the input string (case-insensitive comparison)
for BUCKET in ${BUCKET_NAMES}; do
  # Convert both the bucket name and filter string to lowercase for comparison
  if [[ "${BUCKET,,}" == *"${FILTER_STRING,,}"* ]]; then
    FOUND_BUCKETS+=("${BUCKET}")
  fi
done

# --- Confirm Deletion with User ---
# Check if any buckets were found matching the filter
if [ ${#FOUND_BUCKETS[@]} -eq 0 ]; then
  echo "No S3 buckets found matching \"${FILTER_STRING}\"."
  exit 0
fi

echo "The following buckets and ALL their contents will be PERMANENTLY DELETED:"
for BUCKET in "${FOUND_BUCKETS[@]}"; do
  echo "  - ${BUCKET}"
done
echo ""

read -p "Type 'YES' (in uppercase) to confirm permanent deletion of these buckets: " CONFIRMATION

if [[ "${CONFIRMATION}" != "YES" ]]; then
  echo "Deletion cancelled by user. No buckets were deleted."
  exit 0
fi

echo ""
echo "Initiating deletion process..."
echo "---------------------------------------------------------"

# --- Delete Matching Buckets ---
for BUCKET_TO_DELETE in "${FOUND_BUCKETS[@]}"; do
  echo "Attempting to delete bucket: ${BUCKET_TO_DELETE}"

  echo "  - Deleting all object versions and delete markers..."

  # Use a single jq command to process the list-object-versions output
  # and create a stream of {Key: ..., VersionId: ...} objects, one per line.
  # This handles both 'Versions' and 'DeleteMarkers' arrays, even if empty.
  # `.?` for optional chaining, `// empty` to filter out nulls from combined streams.
  # `jq -r @json` outputs each object as a single, unescaped JSON string on a line,
  # making `read -r` reliable.
  OBJECTS_TO_DELETE=$(aws s3api list-object-versions --bucket "${BUCKET_TO_DELETE}" 2>/dev/null | \
    jq -r '
      [
        (.Versions[]? | {Key: .Key, VersionId: (.VersionId // "null")}),
        (.DeleteMarkers[]? | {Key: .Key, VersionId: (.VersionId // "null")})
      ] | .[] | select(.Key != null) | @json
    ')

  if [ -n "${OBJECTS_TO_DELETE}" ]; then
    echo "${OBJECTS_TO_DELETE}" | while IFS= read -r obj_json; do
      KEY=$(echo "${obj_json}" | jq -r '.Key')
      VERSION_ID=$(echo "${obj_json}" | jq -r '.VersionId')

      if [ "${VERSION_ID}" != "null" ]; then
        echo "    Deleting object version: s3://${BUCKET_TO_DELETE}/${KEY} with VersionId: ${VERSION_ID}"
        aws s3api delete-object --bucket "${BUCKET_TO_DELETE}" --key "${KEY}" --version-id "${VERSION_ID}" 2>/dev/null
      else
        # This case handles non-versioned objects or current objects without an explicit VersionId
        echo "    Deleting object: s3://${BUCKET_TO_DELETE}/${KEY}"
        aws s3api delete-object --bucket "${BUCKET_TO_DELETE}" --key "${KEY}" 2>/dev/null
      fi
    done
  else
    echo "    No objects or versions found in bucket '${BUCKET_TO_DELETE}'. Proceeding with bucket deletion."
  fi

  # After emptying the bucket, attempt to delete the bucket itself
  echo "  - Attempting to delete the empty bucket..."
  aws s3api delete-bucket --bucket "${BUCKET_TO_DELETE}" 2>/dev/null

  if [ $? -eq 0 ]; then
    echo "  SUCCESS: Bucket '${BUCKET_TO_DELETE}' and its contents have been permanently deleted."
  else
    echo "  ERROR: Failed to delete bucket '${BUCKET_TO_DELETE}'. This might be due to a bucket policy, MFA Delete, or other configurations. Please check your AWS CLI permissions or manual intervention might be required for this bucket in the AWS Console."
    echo "         You may try running the command with --debug flag for more details:"
    echo "         aws s3api delete-bucket --bucket ${BUCKET_TO_DELETE} --debug"
  fi
  echo ""
done

echo "---------------------------------------------------------"
echo "Script execution complete."
echo "---------------------------------------------------------"

