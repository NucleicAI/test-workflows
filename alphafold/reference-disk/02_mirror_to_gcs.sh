#!/usr/bin/env bash
# (Recommended) Mirror the downloaded databases to GCS so the workflow's gs://
# input paths are real and non-reference-disk localization works as a fallback.
# This is an additive copy (no --delete): re-running re-uploads changed files but
# never removes objects already in the destination bucket.
set -euo pipefail

: "${DOWNLOAD_ROOT:?}"
: "${BUCKET:?}"
: "${PREFIX:?}"

gsutil -m rsync -r \
  "${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}" \
  "gs://${BUCKET}/${PREFIX}"

echo "Mirrored to gs://${BUCKET}/${PREFIX}"
