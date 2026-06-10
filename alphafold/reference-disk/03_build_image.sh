#!/usr/bin/env bash
# Create a GCE image from the data disk holding the databases. Detach the disk
# from any VM (or stop the VM) before running this.
set -euo pipefail

: "${PROJECT:?}"
: "${ZONE:?the zone of the data disk}"
: "${DATA_DISK:?the name of the GCE disk holding the downloaded data}"
: "${IMAGE_NAME:?e.g. alphafold-refs-20260610}"

gcloud compute images create "${IMAGE_NAME}" \
  --project="${PROJECT}" \
  --source-disk="${DATA_DISK}" \
  --source-disk-zone="${ZONE}" \
  --storage-location=us

echo "Created image: projects/${PROJECT}/global/images/${IMAGE_NAME}"
