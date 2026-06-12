#!/usr/bin/env bash
# Database path-derivation logic. Given an anchor file's path, echo the
# directory/prefix argument AlphaFold needs.
#
# Reference-disk inputs are localized as symlinks, so resolve each anchor to its
# real path with `readlink -f` before taking dirname (the sibling/prefix files
# live next to the REAL file on the mounted image, not next to the symlink).
#
# IMPORTANT: keep these expressions in sync with the command block in
# alphafold/alphafold.wdl (task run_alphafold). They must produce identical results.

BFD_PREFIX="bfd_metaclust_clu_complete_id30_c90_final_seq.sorted_opt"
UNIREF30_PREFIX="UniRef30_2021_03"
PDB70_PREFIX="pdb70"

# arg: a BFD anchor (e.g. <dir>/<BFD_PREFIX>_hhm.ffindex), possibly a symlink
derive_bfd_db()       { printf '%s/%s\n' "$(dirname "$(readlink -f "$1")")" "${BFD_PREFIX}"; }
# arg: a UniRef30 anchor (e.g. <dir>/<UNIREF30_PREFIX>_hhm.ffindex)
derive_uniref30_db()  { printf '%s/%s\n' "$(dirname "$(readlink -f "$1")")" "${UNIREF30_PREFIX}"; }
# arg: a pdb70 anchor (e.g. <dir>/<PDB70_PREFIX>_hhm.ffindex)
derive_pdb70_db()     { printf '%s/%s\n' "$(dirname "$(readlink -f "$1")")" "${PDB70_PREFIX}"; }
# arg: pdb_mmcif/obsolete.dat — template mmcif dir is its sibling on the disk
derive_template_dir() { printf '%s/mmcif_files\n' "$(dirname "$(readlink -f "$1")")"; }
# arg: any file under params/ — data_dir is the parent of params/
derive_data_dir()     { dirname "$(dirname "$(readlink -f "$1")")"; }
