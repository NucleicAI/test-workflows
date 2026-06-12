#!/usr/bin/env bash
# Generate a TRIMMED Cromwell reference-disk manifest: only the files the
# AlphaFold WDL references as inputs (the "anchors"), not every file on the disk.
#
# Why: Cromwell matches reference-disk files per workflow input. Only inputs that
# match a manifest entry get faux-localized; once any one matches, the whole disk
# image is mounted and every other file (the ~250k mmCIF files, BFD ffdata, etc.)
# is reachable by the task via the real mount path. So the manifest only needs
# the ~10 anchor entries — trimming it from ~255k keeps the Cromwell config small.
#
# How: build a staging tree of symlinks to just the anchors (mirroring the gs://
# namespace layout) and run CromwellRefdiskManifestCreator on that. crc32c is read
# from the symlink targets, and recorded paths are <BUCKET>/<PREFIX>/... — matching
# the workflow's gs:// inputs minus the leading 'gs://'.
#
# The anchor set below MUST stay consistent with alphafold.inputs.json and the
# WDL's path derivations.
set -euo pipefail

: "${DOWNLOAD_ROOT:?manifest scan root / data-disk mount, e.g. /mnt/data}"
: "${BUCKET:?reference namespace}"
: "${PREFIX:?version prefix}"
: "${CROMWELL_REPO:?checkout of github.com/broadinstitute/cromwell}"
: "${IMAGE_ID:?fully-qualified image identifier}"
: "${DISK_SIZE_GB:?reference disk size in GB}"
: "${MANIFEST_OUT:=${HOME}/alphafold-refs-manifest.json}"
: "${N_THREADS:=8}"

DATA="${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}"

# One anchor per database. Globs tolerate version differences; pick the first match.
ANCHOR_GLOBS=(
  "${DATA}/uniref90/uniref90.fasta"
  "${DATA}/mgnify/"*.fa
  "${DATA}/bfd/"*_hhm.ffindex
  "${DATA}/uniref30/"*_hhm.ffindex
  "${DATA}/small_bfd/"*.fasta
  "${DATA}/pdb70/"*_hhm.ffindex
  "${DATA}/pdb_seqres/pdb_seqres.txt"
  "${DATA}/uniprot/uniprot.fasta"
  "${DATA}/pdb_mmcif/obsolete.dat"
  "${DATA}/params/params_model_1.npz"
)

# Resolve each glob to exactly one existing file.
anchors=()
for g in "${ANCHOR_GLOBS[@]}"; do
  f="$(ls -1d ${g} 2>/dev/null | head -n1)"
  [ -n "${f}" ] && [ -e "${f}" ] || { echo "ERROR: no anchor file matched: ${g}" >&2; exit 1; }
  anchors+=("${f}")
done

# Staging tree of symlinks mirroring <BUCKET>/<PREFIX>/... under a scan root.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
echo "Anchors (${#anchors[@]}):"
for f in "${anchors[@]}"; do
  rel="${f#"${DOWNLOAD_ROOT}"/}"
  mkdir -p "${STAGE}/$(dirname "${rel}")"
  ln -s "${f}" "${STAGE}/${rel}"
  echo "  ${rel}"
done

# Build the manifest tool if it isn't already built.
JAR="$(find "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/target" -name '*-jar-with-dependencies.jar' -print -quit 2>/dev/null || true)"
if [ -z "${JAR}" ]; then
  mvn -q -f "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/pom.xml" -DskipTests package
  JAR="$(find "${CROMWELL_REPO}/CromwellRefdiskManifestCreator/target" -name '*-jar-with-dependencies.jar' -print -quit)"
fi
[ -n "${JAR}" ] || { echo "ERROR: manifest jar not found; did 'mvn package' succeed?" >&2; exit 1; }

rm -f "${MANIFEST_OUT}"
# Scan the staging tree -> anchor-only manifest, paths relative to STAGE.
# args: nThreads imageIdentifier diskSizeGb scanDir manifestOut
java -jar "${JAR}" "${N_THREADS}" "${IMAGE_ID}" "${DISK_SIZE_GB}" "${STAGE}" "${MANIFEST_OUT}"
echo "Trimmed manifest written to ${MANIFEST_OUT} ($(grep -c crc32c "${MANIFEST_OUT}" 2>/dev/null || echo '?') file entries)"
