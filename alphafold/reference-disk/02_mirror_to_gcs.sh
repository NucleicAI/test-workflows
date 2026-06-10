#!/usr/bin/env bash
# (Recommended) Mirror the downloaded databases to GCS so the workflow's gs://
# input paths are real and non-reference-disk localization works as a fallback.
set -euo pipefail

: "${DOWNLOAD_ROOT:?}"
: "${BUCKET:?}"
: "${PREFIX:?}"

gsutil -m rsync -r \
  "${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}" \
  "gs://${BUCKET}/${PREFIX}"

echo "Mirrored to gs://${BUCKET}/${PREFIX}"
