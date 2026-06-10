#!/usr/bin/env bash
# Verifies the database path-derivation logic against a fake mounted-disk tree.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=alphafold/tests/db_paths.lib.sh
source "${HERE}/db_paths.lib.sh"

MNT="$(mktemp -d)"
trap 'rm -rf "${MNT}"' EXIT

NS="${MNT}/my-bucket/v2.3.2"
mkdir -p \
  "${NS}/bfd" "${NS}/uniref30" "${NS}/pdb70" \
  "${NS}/pdb_mmcif/mmcif_files" "${NS}/params"

# Files whose names AlphaFold's download_all_data.sh produces.
touch "${NS}/bfd/${BFD_PREFIX}_hhm.ffindex"
touch "${NS}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex"
touch "${NS}/pdb70/${PDB70_PREFIX}_hhm.ffindex"
touch "${NS}/pdb_mmcif/obsolete.dat"
touch "${NS}/pdb_mmcif/mmcif_files/1abc.cif"
touch "${NS}/params/params_model_1.npz"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Assert the exact derived value, then that it resolves in the fake tree.
bfd_db="$(derive_bfd_db "${NS}/bfd/${BFD_PREFIX}_hhm.ffindex")"
[[ "${bfd_db}" == "${NS}/bfd/${BFD_PREFIX}" ]] || fail "bfd_db wrong: '${bfd_db}'"
ls "${bfd_db}"* >/dev/null 2>&1 || fail "bfd prefix '${bfd_db}' matched no files"

uniref30_db="$(derive_uniref30_db "${NS}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex")"
[[ "${uniref30_db}" == "${NS}/uniref30/${UNIREF30_PREFIX}" ]] || fail "uniref30_db wrong: '${uniref30_db}'"
ls "${uniref30_db}"* >/dev/null 2>&1 || fail "uniref30 prefix '${uniref30_db}' matched no files"

pdb70_db="$(derive_pdb70_db "${NS}/pdb70/${PDB70_PREFIX}_hhm.ffindex")"
[[ "${pdb70_db}" == "${NS}/pdb70/${PDB70_PREFIX}" ]] || fail "pdb70_db wrong: '${pdb70_db}'"
ls "${pdb70_db}"* >/dev/null 2>&1 || fail "pdb70 prefix '${pdb70_db}' matched no files"

tmpl="$(derive_template_dir "${NS}/pdb_mmcif/obsolete.dat")"
[[ "${tmpl}" == "${NS}/pdb_mmcif/mmcif_files" ]] || fail "template dir wrong: '${tmpl}'"
[[ -d "${tmpl}" ]] || fail "template dir '${tmpl}' is not a directory"

data_dir="$(derive_data_dir "${NS}/params/params_model_1.npz")"
[[ "${data_dir}" == "${NS}" ]] || fail "data_dir wrong: '${data_dir}'"
[[ -d "${data_dir}/params" ]] || fail "data_dir '${data_dir}' has no params/ subdir"

echo "PASS: all database paths derived correctly"
