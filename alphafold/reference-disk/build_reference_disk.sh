#!/usr/bin/env bash
# Build the AlphaFold reference disk from your LOCAL machine.
#
# Provisions a GCP build VM + a ~3 TB data disk, runs the database download and
# manifest build on the VM (via vm_build.sh), fetches the manifest back here,
# snapshots the data disk into a GCE image, and — once the image is READY —
# deletes the VM and data disk (keeping only the image).
#
# It does NOT mirror the databases to GCS (the gs:// inputs are only a match key;
# see this directory's README). On any failure it leaves the VM and disk in place
# for debugging.
#
# Run locally with: an authenticated gcloud (`gcloud auth login`), permission to
# create Compute Engine resources in ${PROJECT}, and the sibling vm_build.sh
# present next to this script.
set -euo pipefail

# --- Required configuration -------------------------------------------------
: "${PROJECT:?GCP project to build in and host the image}"
: "${ZONE:?zone for the build VM, data disk, and image source, e.g. us-central1-a}"
: "${BUCKET:?reference namespace, e.g. my-alphafold-refs}"
: "${PREFIX:?version prefix, e.g. v2.3.2}"
: "${IMAGE_NAME:?image name to create, e.g. alphafold-refs-20260611}"

# --- Optional configuration (sensible defaults) -----------------------------
: "${DISK_SIZE_GB:=3000}"             # data disk size and manifest diskSizeGb
: "${DATA_DISK_TYPE:=pd-balanced}"
: "${MACHINE_TYPE:=e2-standard-8}"
: "${BOOT_DISK_SIZE_GB:=50}"
: "${VM_NAME:=alphafold-build}"
: "${DATA_DISK:=alphafold-build-data}"
: "${DOWNLOAD_ROOT:=/mnt/data}"       # where the data disk is mounted on the VM
: "${STORAGE_LOCATION:=us}"           # image storage location
: "${ALPHAFOLD_VERSION:=v2.3.2}"
: "${N_THREADS:=8}"
: "${MANIFEST_OUT:=${PWD}/alphafold-refs-manifest.json}"
: "${KEEP_BUILD_RESOURCES:=0}"        # 1 = keep the VM (stopped) and disk after success
: "${ASSUME_YES:=0}"                  # 1 = skip the confirmation prompt

DEVICE_NAME="alphafold-data"
DATA_DEVICE="/dev/disk/by-id/google-${DEVICE_NAME}"
IMAGE_ID="projects/${PROJECT}/global/images/${IMAGE_NAME}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GC=(gcloud --project="${PROJECT}" --quiet)

log() { printf '\n=== %s ===\n' "$*"; }

# --- Preflight --------------------------------------------------------------
log "Preflight"
command -v gcloud >/dev/null || { echo "ERROR: gcloud not found on PATH" >&2; exit 1; }
gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . \
  || { echo "ERROR: no active gcloud account; run 'gcloud auth login'" >&2; exit 1; }
[[ -f "${HERE}/vm_build.sh" ]] || { echo "ERROR: ${HERE}/vm_build.sh not found" >&2; exit 1; }
echo "Project = ${PROJECT}    Zone = ${ZONE}"
echo "VM      = ${VM_NAME} (${MACHINE_TYPE})"
echo "Disk    = ${DATA_DISK} (${DISK_SIZE_GB} GB ${DATA_DISK_TYPE})"
echo "Image   = ${IMAGE_ID}"
if [[ "${KEEP_BUILD_RESOURCES}" == "1" ]]; then
  echo "Cleanup = keep VM (stopped) + disk"
else
  echo "Cleanup = DELETE VM + disk once the image is READY"
fi
if [[ "${ASSUME_YES}" != "1" ]]; then
  echo "This creates billable resources and downloads ~2.6 TB on the VM."
  read -r -p "Proceed? [y/N] " reply || reply=""
  [[ "${reply}" == "y" || "${reply}" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

# Leave resources in place if anything fails before teardown.
cleanup_on_error() {
  {
    echo ""
    echo "ERROR: build failed. Resources left in place for debugging:"
    echo "  VM:   ${VM_NAME} (zone ${ZONE})"
    echo "  Disk: ${DATA_DISK} (zone ${ZONE})"
    echo "Remove them when done:"
    echo "  gcloud --project=${PROJECT} compute instances delete ${VM_NAME} --zone=${ZONE} --quiet"
    echo "  gcloud --project=${PROJECT} compute disks delete ${DATA_DISK} --zone=${ZONE} --quiet"
  } >&2
}
trap cleanup_on_error ERR

# --- Step 1: data disk ------------------------------------------------------
log "Step 1/6: Create data disk ${DATA_DISK}"
if "${GC[@]}" compute disks describe "${DATA_DISK}" --zone="${ZONE}" >/dev/null 2>&1; then
  echo "Disk ${DATA_DISK} already exists; reusing."
else
  "${GC[@]}" compute disks create "${DATA_DISK}" \
    --zone="${ZONE}" --size="${DISK_SIZE_GB}GB" --type="${DATA_DISK_TYPE}"
fi

# --- Step 2: build VM with the data disk attached ---------------------------
log "Step 2/6: Create build VM ${VM_NAME}"
if "${GC[@]}" compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
  echo "VM ${VM_NAME} already exists; reusing."
else
  "${GC[@]}" compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size="${BOOT_DISK_SIZE_GB}GB" \
    --disk="name=${DATA_DISK},device-name=${DEVICE_NAME},mode=rw,boot=no,auto-delete=no"
fi

# --- Step 3: wait for SSH ---------------------------------------------------
log "Step 3/6: Wait for SSH"
ssh_ready=0
for _ in $(seq 1 30); do
  if "${GC[@]}" compute ssh "${VM_NAME}" --zone="${ZONE}" --command="true" >/dev/null 2>&1; then
    ssh_ready=1; echo "SSH ready."; break
  fi
  sleep 10
done
[[ "${ssh_ready}" == "1" ]] || { echo "ERROR: SSH not ready after retries" >&2; exit 1; }

# --- Step 4: run the build on the VM, fetch the manifest --------------------
log "Step 4/6: Run download + manifest build on the VM"
"${GC[@]}" compute scp "${HERE}/vm_build.sh" "${VM_NAME}:~/vm_build.sh" --zone="${ZONE}"
REMOTE_ENV="DATA_DEVICE='${DATA_DEVICE}' DOWNLOAD_ROOT='${DOWNLOAD_ROOT}'"
REMOTE_ENV+=" BUCKET='${BUCKET}' PREFIX='${PREFIX}' IMAGE_ID='${IMAGE_ID}'"
REMOTE_ENV+=" DISK_SIZE_GB='${DISK_SIZE_GB}' ALPHAFOLD_VERSION='${ALPHAFOLD_VERSION}'"
REMOTE_ENV+=" N_THREADS='${N_THREADS}' MANIFEST_OUT=\$HOME/alphafold-refs-manifest.json"
"${GC[@]}" compute ssh "${VM_NAME}" --zone="${ZONE}" \
  --command="${REMOTE_ENV} bash \$HOME/vm_build.sh"

log "Fetch manifest to ${MANIFEST_OUT}"
"${GC[@]}" compute scp "${VM_NAME}:~/alphafold-refs-manifest.json" "${MANIFEST_OUT}" --zone="${ZONE}"

# --- Step 5: stop the VM and snapshot the disk into an image ----------------
log "Step 5/6: Stop VM and create image ${IMAGE_NAME}"
"${GC[@]}" compute instances stop "${VM_NAME}" --zone="${ZONE}"
if "${GC[@]}" compute images describe "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "Image ${IMAGE_NAME} already exists; skipping create."
else
  "${GC[@]}" compute images create "${IMAGE_NAME}" \
    --source-disk="${DATA_DISK}" --source-disk-zone="${ZONE}" \
    --storage-location="${STORAGE_LOCATION}"
fi
status="$("${GC[@]}" compute images describe "${IMAGE_NAME}" --format='value(status)')"
[[ "${status}" == "READY" ]] || { echo "ERROR: image status is '${status}', not READY" >&2; exit 1; }
echo "Image ${IMAGE_ID} is READY."

# --- Step 6: teardown (only on success) -------------------------------------
log "Step 6/6: Cleanup"
trap - ERR   # past the failure-sensitive section
if [[ "${KEEP_BUILD_RESOURCES}" == "1" ]]; then
  echo "KEEP_BUILD_RESOURCES=1; leaving VM ${VM_NAME} (stopped) and disk ${DATA_DISK} in place."
else
  "${GC[@]}" compute instances delete "${VM_NAME}" --zone="${ZONE}"
  "${GC[@]}" compute disks delete "${DATA_DISK}" --zone="${ZONE}"
  echo "Deleted VM ${VM_NAME} and data disk ${DATA_DISK}."
fi

log "Done"
echo "Image:    ${IMAGE_ID}"
echo "Manifest: ${MANIFEST_OUT}"
echo "Next:"
echo "  - Wire the manifest into Cromwell (see ${HERE}/../backend-config-snippet.conf)."
echo "  - To share across projects, grant each consuming project's Batch service"
echo "    account roles/compute.imageUser on the image."
