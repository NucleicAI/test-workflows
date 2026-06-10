#!/usr/bin/env bash
# Build the Cromwell reference-disk manifest by scanning the local data tree and
# checksumming each file. Requires Maven and a checkout of the cromwell repo.
set -euo pipefail

: "${CROMWELL_REPO:?path to a checkout of github.com/broadinstitute/cromwell}"
: "${DOWNLOAD_ROOT:?the manifest scan root (parent of the bucket dir)}"
: "${PROJECT:?}"
: "${IMAGE_NAME:?must match the image created by 03_build_image.sh}"
: "${DISK_SIZE_GB:?the reference disk size in GB, e.g. 3000}"
: "${N_THREADS:=8}"
: "${MANIFEST_OUT:=alphafold-refs-manifest.json}"

IMAGE_ID="projects/${PROJECT}/global/images/${IMAGE_NAME}"

# Build the tool (one-time).
mvn -q -f "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/pom.xml" -DskipTests package
JAR="$(find "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/target" \
  -name '*-jar-with-dependencies.jar' -print -quit)"

# Positional args: <nThreads> <imageIdentifier> <diskSizeGb> <scanDir> <manifestOut>
java -jar "${JAR}" "${N_THREADS}" "${IMAGE_ID}" "${DISK_SIZE_GB}" \
  "${DOWNLOAD_ROOT}" "${MANIFEST_OUT}"

echo "Wrote manifest to ${MANIFEST_OUT}"
echo "Its file paths are relative to ${DOWNLOAD_ROOT} (i.e. <BUCKET>/<PREFIX>/...),"
echo "matching the gs:// input paths without the leading 'gs://'."
