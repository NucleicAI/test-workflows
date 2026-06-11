#!/usr/bin/env bash
# Runs ON the build VM. Shipped and invoked by build_reference_disk.sh — you do
# not normally run this by hand. Formats/mounts the data disk, installs deps,
# downloads the AlphaFold databases, and builds the Cromwell reference-disk
# manifest. Image creation and teardown happen back on the orchestrator.
set -euo pipefail

: "${DATA_DEVICE:?attached data-disk device path, e.g. /dev/disk/by-id/google-alphafold-data}"
: "${DOWNLOAD_ROOT:?mount point for the data disk, e.g. /mnt/data}"
: "${BUCKET:?reference namespace}"
: "${PREFIX:?version prefix}"
: "${IMAGE_ID:?fully-qualified image identifier to record in the manifest}"
: "${DISK_SIZE_GB:?reference disk size in GB}"
: "${ALPHAFOLD_VERSION:=v2.3.2}"
: "${N_THREADS:=8}"
: "${MANIFEST_OUT:=${HOME}/alphafold-refs-manifest.json}"
: "${FORCE_DOWNLOAD:=0}"

ALPHAFOLD_REPO="${HOME}/alphafold"
CROMWELL_REPO="${HOME}/cromwell"
DEST="${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}"
DOWNLOAD_MARKER="${DEST}/.download_complete"

log() { printf '\n=== [vm] %s ===\n' "$*"; }

log "Mount data disk ${DATA_DEVICE} at ${DOWNLOAD_ROOT}"
if ! sudo blkid "${DATA_DEVICE}" >/dev/null 2>&1; then
  echo "[vm] Formatting ${DATA_DEVICE} as ext4 (new disk)."
  sudo mkfs.ext4 -F -m 0 "${DATA_DEVICE}"
fi
sudo mkdir -p "${DOWNLOAD_ROOT}"
mountpoint -q "${DOWNLOAD_ROOT}" || sudo mount -o discard,defaults "${DATA_DEVICE}" "${DOWNLOAD_ROOT}"
sudo chown "$(id -un):$(id -gn)" "${DOWNLOAD_ROOT}"

log "Install dependencies"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq git aria2 rsync default-jdk maven >/dev/null

log "Clone repositories"
[[ -d "${ALPHAFOLD_REPO}/.git" ]] \
  || git clone --depth 1 --branch "${ALPHAFOLD_VERSION}" \
       https://github.com/google-deepmind/alphafold "${ALPHAFOLD_REPO}"
[[ -d "${CROMWELL_REPO}/.git" ]] \
  || git clone --depth 1 https://github.com/broadinstitute/cromwell "${CROMWELL_REPO}"

# Build the manifest tool BEFORE the long download, so a JDK/Maven problem fails
# in minutes rather than after hours of downloading.
log "Build manifest tool"
mvn -q -f "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/pom.xml" -DskipTests package
JAR="$(find "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/target" \
  -name '*-jar-with-dependencies.jar' -print -quit)"
[[ -n "${JAR}" ]] || { echo "[vm] ERROR: manifest jar not found; did 'mvn package' succeed?" >&2; exit 1; }

log "Download databases into ${DEST}"
if [[ "${FORCE_DOWNLOAD}" != "1" && -f "${DOWNLOAD_MARKER}" ]]; then
  echo "[vm] Marker present; databases already downloaded — skipping."
else
  mkdir -p "${DEST}"
  # Full set: full BFD, UniRef30, UniRef90, MGnify, pdb70, pdb_mmcif, pdb_seqres,
  # uniprot, params.
  bash "${ALPHAFOLD_REPO}/scripts/download_all_data.sh" "${DEST}"
  # "full" mode does NOT fetch small_bfd; add it so reduced_dbs is also usable.
  bash "${ALPHAFOLD_REPO}/scripts/download_small_bfd.sh" "${DEST}"
  touch "${DOWNLOAD_MARKER}"
fi

log "Build reference-disk manifest"
# Scan from DOWNLOAD_ROOT so manifest paths are <BUCKET>/<PREFIX>/... — matching
# the workflow's gs:// inputs minus the leading 'gs://'. The tool refuses to
# overwrite, so clear any prior manifest first.
rm -f "${MANIFEST_OUT}"
# Positional args: <nThreads> <imageIdentifier> <diskSizeGb> <scanDir> <manifestOut>
java -jar "${JAR}" "${N_THREADS}" "${IMAGE_ID}" "${DISK_SIZE_GB}" \
  "${DOWNLOAD_ROOT}" "${MANIFEST_OUT}"
echo "[vm] Manifest written to ${MANIFEST_OUT} (imageIdentifier=${IMAGE_ID})."
