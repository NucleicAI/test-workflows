#!/usr/bin/env bash
# Verifies the database path-derivation logic.
#
# Reference-disk inputs are localized as SYMLINKS into the task's execution dir
# (pointing at the real files on the mounted image), WITHOUT their sibling files.
# So the derivation must resolve each anchor symlink to its real location before
# taking dirname. This test reproduces that: a real "mounted disk" tree, plus an
# "exec dir" holding only anchor symlinks, and checks the derived paths land in
# the REAL tree (where the sibling/prefix files actually are).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=alphafold/tests/db_paths.lib.sh
source "${HERE}/db_paths.lib.sh"

# Canonicalize (on macOS /var -> /private/var) so expected paths match what
# `readlink -f` produces in the derivations under test.
MNT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${MNT}"' EXIT

# Real mounted-disk tree (all DB files present together).
NS="${MNT}/disk/my-bucket/v2.3.2"
mkdir -p \
  "${NS}/bfd" "${NS}/uniref30" "${NS}/pdb70" \
  "${NS}/pdb_mmcif/mmcif_files" "${NS}/params"
touch "${NS}/bfd/${BFD_PREFIX}_hhm.ffindex"
touch "${NS}/bfd/${BFD_PREFIX}_a3m.ffdata"
touch "${NS}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex"
touch "${NS}/pdb70/${PDB70_PREFIX}_hhm.ffindex"
touch "${NS}/pdb_mmcif/obsolete.dat"
touch "${NS}/pdb_mmcif/mmcif_files/1abc.cif"
touch "${NS}/params/params_model_1.npz"

# Exec dir: only the anchors, as symlinks to the real files (no siblings) — this
# is how Cromwell faux-localizes matched reference-disk inputs.
EXEC="${MNT}/exec/my-bucket/v2.3.2"
mkdir -p \
  "${EXEC}/bfd" "${EXEC}/uniref30" "${EXEC}/pdb70" \
  "${EXEC}/pdb_mmcif" "${EXEC}/params"
ln -s "${NS}/bfd/${BFD_PREFIX}_hhm.ffindex"           "${EXEC}/bfd/${BFD_PREFIX}_hhm.ffindex"
ln -s "${NS}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex" "${EXEC}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex"
ln -s "${NS}/pdb70/${PDB70_PREFIX}_hhm.ffindex"       "${EXEC}/pdb70/${PDB70_PREFIX}_hhm.ffindex"
ln -s "${NS}/pdb_mmcif/obsolete.dat"                  "${EXEC}/pdb_mmcif/obsolete.dat"
ln -s "${NS}/params/params_model_1.npz"               "${EXEC}/params/params_model_1.npz"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Derive from the SYMLINK paths; expect them to resolve into the REAL tree (NS),
# where the sibling/prefix files actually live.
bfd_db="$(derive_bfd_db "${EXEC}/bfd/${BFD_PREFIX}_hhm.ffindex")"
[[ "${bfd_db}" == "${NS}/bfd/${BFD_PREFIX}" ]] || fail "bfd_db wrong: '${bfd_db}'"
ls "${bfd_db}"* >/dev/null 2>&1 || fail "bfd prefix '${bfd_db}' matched no files"

uniref30_db="$(derive_uniref30_db "${EXEC}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex")"
[[ "${uniref30_db}" == "${NS}/uniref30/${UNIREF30_PREFIX}" ]] || fail "uniref30_db wrong: '${uniref30_db}'"

pdb70_db="$(derive_pdb70_db "${EXEC}/pdb70/${PDB70_PREFIX}_hhm.ffindex")"
[[ "${pdb70_db}" == "${NS}/pdb70/${PDB70_PREFIX}" ]] || fail "pdb70_db wrong: '${pdb70_db}'"

tmpl="$(derive_template_dir "${EXEC}/pdb_mmcif/obsolete.dat")"
[[ "${tmpl}" == "${NS}/pdb_mmcif/mmcif_files" ]] || fail "template dir wrong: '${tmpl}'"
[[ -d "${tmpl}" ]] || fail "template dir '${tmpl}' is not a directory"

data_dir="$(derive_data_dir "${EXEC}/params/params_model_1.npz")"
[[ "${data_dir}" == "${NS}" ]] || fail "data_dir wrong: '${data_dir}'"
[[ -d "${data_dir}/params" ]] || fail "data_dir '${data_dir}' has no params/ subdir"

echo "PASS: all database paths derived correctly (through localized symlinks)"
