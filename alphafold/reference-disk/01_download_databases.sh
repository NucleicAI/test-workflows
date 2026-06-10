#!/usr/bin/env bash
# Download all AlphaFold genetic databases into a tree that mirrors the gs://
# namespace used by the workflow inputs. Run this on a build VM with a ~3 TB
# data disk mounted at ${DOWNLOAD_ROOT}. Downloads ~2.6 TB; takes hours.
set -euo pipefail

: "${ALPHAFOLD_REPO:?set to a clone of github.com/google-deepmind/alphafold}"
: "${DOWNLOAD_ROOT:?set to the data-disk mount, e.g. /mnt/data}"
: "${BUCKET:?set to your reference bucket name, e.g. my-alphafold-refs}"
: "${PREFIX:?set to a version prefix, e.g. v2.3.2}"

DEST="${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}"
mkdir -p "${DEST}"

# Pulls full BFD, UniRef30, small_bfd, params, pdb70, pdb_mmcif, pdb_seqres,
# uniprot, uniref90, mgnify — i.e. both db_presets and both model_presets.
bash "${ALPHAFOLD_REPO}/scripts/download_all_data.sh" "${DEST}"

echo "Done. Layout under ${DOWNLOAD_ROOT} now mirrors gs://${BUCKET}/${PREFIX}/..."
echo "Manifest scan root will be: ${DOWNLOAD_ROOT}"
