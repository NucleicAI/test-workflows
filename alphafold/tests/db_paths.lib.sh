#!/usr/bin/env bash
# Database path-derivation logic. Given an anchor file's path, echo the
# directory/prefix argument AlphaFold needs.
#
# IMPORTANT: keep these expressions in sync with the command block in
# alphafold/alphafold.wdl (Task 3). They must produce identical results.

BFD_PREFIX="bfd_metaclust_clu_complete_id30_c90_final_seq.sorted_opt"
UNIREF30_PREFIX="UniRef30_2021_03"
PDB70_PREFIX="pdb70"

# arg: a real BFD file (e.g. <dir>/<BFD_PREFIX>_hhm.ffindex)
derive_bfd_db()       { printf '%s/%s\n' "$(dirname "$1")" "${BFD_PREFIX}"; }
# arg: a real UniRef30 file
derive_uniref30_db()  { printf '%s/%s\n' "$(dirname "$1")" "${UNIREF30_PREFIX}"; }
# arg: a real pdb70 file
derive_pdb70_db()     { printf '%s/%s\n' "$(dirname "$1")" "${PDB70_PREFIX}"; }
# arg: pdb_mmcif/obsolete.dat — template mmcif dir is its sibling
derive_template_dir() { printf '%s/mmcif_files\n' "$(dirname "$1")"; }
# arg: any file under params/ — data_dir is the parent of params/
derive_data_dir()     { dirname "$(dirname "$1")"; }
