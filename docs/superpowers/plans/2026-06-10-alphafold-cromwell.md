# AlphaFold on Cromwell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Cromwell/GCP-Batch WDL workflow that runs AlphaFold 2 with its genetic databases served from a reference disk, plus the tooling to build that disk.

**Architecture:** A single WDL task runs `run_alphafold.py` end-to-end on a GPU VM. Databases are passed as "anchor" `File` inputs whose `gs://` paths match a reference-disk manifest; the task reconstructs directory/prefix arguments from the mounted anchor paths with `dirname`. Supporting deliverables build the container image, build the reference disk + manifest, and configure the backend.

**Tech Stack:** WDL 1.0, Cromwell GCP Batch backend, Cromwell `womtool` (validation), AlphaFold 2.3.2 Docker image, bash, `gcloud`/`gsutil`, Maven (`CromwellRefdiskManifestCreator`).

**Reference spec:** `docs/superpowers/specs/2026-06-10-alphafold-cromwell-design.md`

**Environment notes for the implementer:**
- Work happens in `/Users/dvoet/projects/test-workflows` on branch `alphafold-workflow`.
- `java` (v25) is available; `mvn`, `gcloud`, `gsutil`, `docker` are NOT needed to *author/validate* these files — they are only run later on a build VM. Do not try to run them.
- `python3` is used to lint JSON. `bash` runs the script tests.
- Full end-to-end execution requires the reference disk to exist and a real GCP project, so it is OUT OF SCOPE here (per the spec). Validation is limited to `womtool validate`, the bash path-derivation test, `bash -n`, and JSON linting.

---

## File Structure

```
alphafold/
  alphafold.wdl                 # the workflow (one GPU task)
  alphafold.inputs.json         # example inputs (gs:// db paths mirror the manifest)
  alphafold.options.json        # workflow options (use_reference_disks: true)
  backend-config-snippet.conf   # HOCON to merge into the GCP Batch backend config
  validate.sh                   # downloads womtool on demand and validates the WDL
  .gitignore                    # ignores validate.sh's downloaded jar
  README.md                     # end-to-end runbook
  docker/
    README.md                   # build + push the AlphaFold image
  reference-disk/
    README.md                   # runbook for building the disk + manifest
    01_download_databases.sh
    02_mirror_to_gcs.sh
    03_build_image.sh
    04_make_manifest.sh
  tests/
    db_paths.lib.sh             # path-derivation logic (kept in sync with the WDL)
    derive_paths_test.sh        # test for db_paths.lib.sh
```

---

## Task 1: Project scaffold & womtool harness

**Files:**
- Create: `alphafold/.gitignore`
- Create: `alphafold/validate.sh`

- [ ] **Step 1: Create `alphafold/.gitignore`**

```
# Downloaded by validate.sh; not committed.
.tools/
```

- [ ] **Step 2: Create `alphafold/validate.sh`**

```bash
#!/usr/bin/env bash
# Validate a WDL (and optionally its inputs) using Cromwell's womtool.
# Downloads the womtool jar into alphafold/.tools/ on first use.
#
# Usage:
#   bash alphafold/validate.sh alphafold/alphafold.wdl
#   bash alphafold/validate.sh alphafold/alphafold.wdl alphafold/alphafold.inputs.json
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WOMTOOL_VERSION="87"
TOOLS="${HERE}/.tools"
JAR="${TOOLS}/womtool-${WOMTOOL_VERSION}.jar"

mkdir -p "${TOOLS}"
if [[ ! -f "${JAR}" ]]; then
  echo "Downloading womtool ${WOMTOOL_VERSION}..." >&2
  curl -fSL -o "${JAR}" \
    "https://github.com/broadinstitute/cromwell/releases/download/${WOMTOOL_VERSION}/womtool-${WOMTOOL_VERSION}.jar"
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: validate.sh <wdl> [inputs.json]" >&2
  exit 2
fi

if [[ $# -ge 2 ]]; then
  java -jar "${JAR}" validate "$1" --inputs "$2"
else
  java -jar "${JAR}" validate "$1"
fi
```

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n alphafold/validate.sh && echo OK`
Expected: prints `OK` with no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add alphafold/.gitignore alphafold/validate.sh
git commit -m "Add AlphaFold project scaffold and womtool validate harness"
```

---

## Task 2: Database path-derivation library (TDD)

This is the trickiest logic: turning an anchor file's mounted path into the directory/prefix arguments AlphaFold expects. We test it against a fake disk tree first.

**Files:**
- Test: `alphafold/tests/derive_paths_test.sh`
- Create: `alphafold/tests/db_paths.lib.sh`

- [ ] **Step 1: Write the failing test**

Create `alphafold/tests/derive_paths_test.sh`:

```bash
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

bfd_db="$(derive_bfd_db "${NS}/bfd/${BFD_PREFIX}_hhm.ffindex")"
ls "${bfd_db}"* >/dev/null 2>&1 || fail "bfd prefix '${bfd_db}' matched no files"

uniref30_db="$(derive_uniref30_db "${NS}/uniref30/${UNIREF30_PREFIX}_hhm.ffindex")"
ls "${uniref30_db}"* >/dev/null 2>&1 || fail "uniref30 prefix '${uniref30_db}' matched no files"

pdb70_db="$(derive_pdb70_db "${NS}/pdb70/${PDB70_PREFIX}_hhm.ffindex")"
ls "${pdb70_db}"* >/dev/null 2>&1 || fail "pdb70 prefix '${pdb70_db}' matched no files"

tmpl="$(derive_template_dir "${NS}/pdb_mmcif/obsolete.dat")"
[[ -d "${tmpl}" ]] || fail "template dir '${tmpl}' is not a directory"

data_dir="$(derive_data_dir "${NS}/params/params_model_1.npz")"
[[ -d "${data_dir}/params" ]] || fail "data_dir '${data_dir}' has no params/ subdir"

echo "PASS: all database paths derived correctly"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash alphafold/tests/derive_paths_test.sh`
Expected: FAIL — `db_paths.lib.sh` does not exist yet, so `source` errors with "No such file or directory".

- [ ] **Step 3: Write the library to make it pass**

Create `alphafold/tests/db_paths.lib.sh`:

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash alphafold/tests/derive_paths_test.sh`
Expected: prints `PASS: all database paths derived correctly`.

- [ ] **Step 5: Commit**

```bash
git add alphafold/tests/db_paths.lib.sh alphafold/tests/derive_paths_test.sh
git commit -m "Add tested database path-derivation logic for reference disk"
```

---

## Task 3: The AlphaFold WDL workflow

**Files:**
- Create: `alphafold/alphafold.wdl`

- [ ] **Step 1: Write the workflow**

Create `alphafold/alphafold.wdl`. The command block's path-derivation expressions
mirror `alphafold/tests/db_paths.lib.sh` (Task 2). Boolean relax flag is rendered
with `if/then/else`. Outputs are collected into the execution dir.

```wdl
version 1.0

workflow alphafold {
  input {
    File fasta
    String max_template_date
    String model_preset = "monomer"
    String db_preset = "full_dbs"
    String models_to_relax = "best"
    Boolean use_gpu_relax = true

    # Reference-disk database anchors (gs:// paths matching the manifest).
    File uniref90_database
    File mgnify_database
    File bfd_anchor
    File uniref30_anchor
    File small_bfd_database
    File pdb70_anchor
    File pdb_seqres_database
    File uniprot_database
    File obsolete_pdbs
    File params_anchor

    # Runtime knobs.
    String docker_image
    String gpu_type = "nvidia-tesla-v100"
    Int gpu_count = 1
    Int cpu = 8
    Int memory_gb = 64
    Int scratch_disk_gb = 100
  }

  call run_alphafold {
    input:
      fasta = fasta,
      max_template_date = max_template_date,
      model_preset = model_preset,
      db_preset = db_preset,
      models_to_relax = models_to_relax,
      use_gpu_relax = use_gpu_relax,
      uniref90_database = uniref90_database,
      mgnify_database = mgnify_database,
      bfd_anchor = bfd_anchor,
      uniref30_anchor = uniref30_anchor,
      small_bfd_database = small_bfd_database,
      pdb70_anchor = pdb70_anchor,
      pdb_seqres_database = pdb_seqres_database,
      uniprot_database = uniprot_database,
      obsolete_pdbs = obsolete_pdbs,
      params_anchor = params_anchor,
      docker_image = docker_image,
      gpu_type = gpu_type,
      gpu_count = gpu_count,
      cpu = cpu,
      memory_gb = memory_gb,
      scratch_disk_gb = scratch_disk_gb
  }

  output {
    Array[File] ranked_pdbs = run_alphafold.ranked_pdbs
    File best_model = run_alphafold.best_model
    File ranking_debug = run_alphafold.ranking_debug
    File timings = run_alphafold.timings
    File output_tarball = run_alphafold.output_tarball
  }
}

task run_alphafold {
  input {
    File fasta
    String max_template_date
    String model_preset
    String db_preset
    String models_to_relax
    Boolean use_gpu_relax

    File uniref90_database
    File mgnify_database
    File bfd_anchor
    File uniref30_anchor
    File small_bfd_database
    File pdb70_anchor
    File pdb_seqres_database
    File uniprot_database
    File obsolete_pdbs
    File params_anchor

    String docker_image
    String gpu_type
    Int gpu_count
    Int cpu
    Int memory_gb
    Int scratch_disk_gb
  }

  # Fixed AlphaFold 2.3.x prefix basenames. Keep in sync with
  # alphafold/tests/db_paths.lib.sh.
  String bfd_prefix = "bfd_metaclust_clu_complete_id30_c90_final_seq.sorted_opt"
  String uniref30_prefix = "UniRef30_2021_03"
  String pdb70_prefix = "pdb70"

  command <<<
    set -euo pipefail

    # --- Derive on-disk database paths from anchor file locations ---
    # Mirrors alphafold/tests/db_paths.lib.sh.
    BFD_DB="$(dirname '~{bfd_anchor}')/~{bfd_prefix}"
    UNIREF30_DB="$(dirname '~{uniref30_anchor}')/~{uniref30_prefix}"
    PDB70_DB="$(dirname '~{pdb70_anchor}')/~{pdb70_prefix}"
    TEMPLATE_MMCIF_DIR="$(dirname '~{obsolete_pdbs}')/mmcif_files"
    DATA_DIR="$(dirname "$(dirname '~{params_anchor}')")"

    OUTPUT_DIR="$(pwd)/output"
    mkdir -p "${OUTPUT_DIR}"

    # --- Preset-specific database flags ---
    DB_FLAGS=()
    if [[ "~{db_preset}" == "full_dbs" ]]; then
      DB_FLAGS+=(--bfd_database_path="${BFD_DB}")
      DB_FLAGS+=(--uniref30_database_path="${UNIREF30_DB}")
    else
      DB_FLAGS+=(--small_bfd_database_path='~{small_bfd_database}')
    fi

    if [[ "~{model_preset}" == "multimer" ]]; then
      DB_FLAGS+=(--pdb_seqres_database_path='~{pdb_seqres_database}')
      DB_FLAGS+=(--uniprot_database_path='~{uniprot_database}')
    else
      DB_FLAGS+=(--pdb70_database_path="${PDB70_DB}")
    fi

    python /app/alphafold/run_alphafold.py \
      --fasta_paths='~{fasta}' \
      --output_dir="${OUTPUT_DIR}" \
      --data_dir="${DATA_DIR}" \
      --uniref90_database_path='~{uniref90_database}' \
      --mgnify_database_path='~{mgnify_database}' \
      --template_mmcif_dir="${TEMPLATE_MMCIF_DIR}" \
      --obsolete_pdbs_path='~{obsolete_pdbs}' \
      --max_template_date='~{max_template_date}' \
      --model_preset='~{model_preset}' \
      --db_preset='~{db_preset}' \
      --models_to_relax='~{models_to_relax}' \
      --use_gpu_relax=~{if use_gpu_relax then "true" else "false"} \
      "${DB_FLAGS[@]}"

    # --- Collect outputs ---
    # AlphaFold writes results under ${OUTPUT_DIR}/<fasta basename>/.
    PRED_DIR="$(find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    cp "${PRED_DIR}/ranked_0.pdb" best_model.pdb
    cp "${PRED_DIR}/ranking_debug.json" ranking_debug.json
    cp "${PRED_DIR}/timings.json" timings.json
    tar -czf output.tar.gz -C "${OUTPUT_DIR}" .
  >>>

  output {
    Array[File] ranked_pdbs = glob("output/*/ranked_*.pdb")
    File best_model = "best_model.pdb"
    File ranking_debug = "ranking_debug.json"
    File timings = "timings.json"
    File output_tarball = "output.tar.gz"
  }

  runtime {
    docker: docker_image
    cpu: cpu
    memory: "~{memory_gb} GB"
    gpu: true
    gpuType: gpu_type
    gpuCount: gpu_count
    disks: "local-disk ~{scratch_disk_gb} SSD"
    bootDiskSizeGb: 50
    zones: "us-central1-a us-central1-b us-central1-c us-central1-f"
  }
}
```

- [ ] **Step 2: Validate the WDL structure**

Run: `bash alphafold/validate.sh alphafold/alphafold.wdl`
Expected: downloads womtool on first run, then prints `Success!`.
(If it prints a syntax/type error instead, fix the WDL and re-run until `Success!`.)

- [ ] **Step 3: Commit**

```bash
git add alphafold/alphafold.wdl
git commit -m "Add AlphaFold WDL workflow with reference-disk anchor wiring"
```

---

## Task 4: Example inputs and workflow options

**Files:**
- Create: `alphafold/alphafold.inputs.json`
- Create: `alphafold/alphafold.options.json`

- [ ] **Step 1: Create `alphafold/alphafold.inputs.json`**

`<BUCKET>`, `<PREFIX>`, `<PROJECT>`, `<REPO>` are deployment placeholders the user
fills in. The `gs://` database paths must exactly match the reference-disk manifest.
The anchor file names (e.g. `*_hhm.ffindex`) are real files produced by
`download_all_data.sh`; confirm them against your actual download.

```json
{
  "alphafold.fasta": "gs://<BUCKET>/<PREFIX>/examples/query.fasta",
  "alphafold.max_template_date": "2022-01-01",
  "alphafold.model_preset": "monomer",
  "alphafold.db_preset": "full_dbs",
  "alphafold.models_to_relax": "best",
  "alphafold.use_gpu_relax": true,

  "alphafold.docker_image": "us-docker.pkg.dev/<PROJECT>/<REPO>/alphafold:2.3.2",
  "alphafold.gpu_type": "nvidia-tesla-v100",
  "alphafold.gpu_count": 1,
  "alphafold.cpu": 8,
  "alphafold.memory_gb": 64,
  "alphafold.scratch_disk_gb": 100,

  "alphafold.uniref90_database": "gs://<BUCKET>/<PREFIX>/uniref90/uniref90.fasta",
  "alphafold.mgnify_database": "gs://<BUCKET>/<PREFIX>/mgnify/mgy_clusters_2022_05.fa",
  "alphafold.bfd_anchor": "gs://<BUCKET>/<PREFIX>/bfd/bfd_metaclust_clu_complete_id30_c90_final_seq.sorted_opt_hhm.ffindex",
  "alphafold.uniref30_anchor": "gs://<BUCKET>/<PREFIX>/uniref30/UniRef30_2021_03_hhm.ffindex",
  "alphafold.small_bfd_database": "gs://<BUCKET>/<PREFIX>/small_bfd/bfd-first_non_consensus_sequences.fasta",
  "alphafold.pdb70_anchor": "gs://<BUCKET>/<PREFIX>/pdb70/pdb70_hhm.ffindex",
  "alphafold.pdb_seqres_database": "gs://<BUCKET>/<PREFIX>/pdb_seqres/pdb_seqres.txt",
  "alphafold.uniprot_database": "gs://<BUCKET>/<PREFIX>/uniprot/uniprot.fasta",
  "alphafold.obsolete_pdbs": "gs://<BUCKET>/<PREFIX>/pdb_mmcif/obsolete.dat",
  "alphafold.params_anchor": "gs://<BUCKET>/<PREFIX>/params/params_model_1.npz"
}
```

- [ ] **Step 2: Create `alphafold/alphafold.options.json`**

```json
{
  "use_reference_disks": true,
  "read_from_cache": true,
  "write_to_cache": true
}
```

- [ ] **Step 3: Lint both JSON files**

Run:
```bash
python3 -m json.tool alphafold/alphafold.inputs.json > /dev/null && \
python3 -m json.tool alphafold/alphafold.options.json > /dev/null && echo "JSON OK"
```
Expected: prints `JSON OK`.

- [ ] **Step 4: Validate the WDL against the inputs**

Run: `bash alphafold/validate.sh alphafold/alphafold.wdl alphafold/alphafold.inputs.json`
Expected: prints `Success!` (all required inputs are satisfied and types match).

- [ ] **Step 5: Commit**

```bash
git add alphafold/alphafold.inputs.json alphafold/alphafold.options.json
git commit -m "Add example inputs and workflow options for AlphaFold WDL"
```

---

## Task 5: Container image build instructions

**Files:**
- Create: `alphafold/docker/README.md`

- [ ] **Step 1: Create `alphafold/docker/README.md`**

```markdown
# AlphaFold container image

DeepMind does not publish an official AlphaFold image to a public registry; you
build it from the repo's own Dockerfile and push it to your Artifact Registry so
Cromwell can pull it.

## Build & push

```bash
git clone --branch v2.3.2 https://github.com/google-deepmind/alphafold
cd alphafold

PROJECT=<your-gcp-project>
REPO=<your-artifact-registry-repo>      # e.g. created with: gcloud artifacts repositories create
IMAGE=us-docker.pkg.dev/${PROJECT}/${REPO}/alphafold:2.3.2

docker build -f docker/Dockerfile -t "${IMAGE}" .
gcloud auth configure-docker us-docker.pkg.dev
docker push "${IMAGE}"
```

Put the resulting `${IMAGE}` value into `alphafold.docker_image` in
`alphafold.inputs.json`.

## Note on the entrypoint

The upstream image's `ENTRYPOINT` runs `run_docker.py` (a host-side launcher).
The workflow does **not** use it — the WDL task calls
`python /app/alphafold/run_alphafold.py` directly, and Cromwell runs the task
command through the shell, which bypasses the entrypoint. No image changes are
required.

## Version pinning

The workflow defaults to the `2.3.2` tag. If you build a different AlphaFold
version, also confirm the database file names and relax flags
(`--models_to_relax`, `--use_gpu_relax`) match that version's `run_alphafold.py`.
```

- [ ] **Step 2: Commit**

```bash
git add alphafold/docker/README.md
git commit -m "Add AlphaFold container image build instructions"
```

---

## Task 6: Reference-disk build scripts

**Files:**
- Create: `alphafold/reference-disk/01_download_databases.sh`
- Create: `alphafold/reference-disk/02_mirror_to_gcs.sh`
- Create: `alphafold/reference-disk/03_build_image.sh`
- Create: `alphafold/reference-disk/04_make_manifest.sh`

- [ ] **Step 1: Create `01_download_databases.sh`**

```bash
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
```

- [ ] **Step 2: Create `02_mirror_to_gcs.sh`**

```bash
#!/usr/bin/env bash
# (Recommended) Mirror the downloaded databases to GCS so the workflow's gs://
# input paths are real and non-reference-disk localization works as a fallback.
set -euo pipefail

: "${DOWNLOAD_ROOT:?}"
: "${BUCKET:?}"
: "${PREFIX:?}"

gsutil -m rsync -r \
  "${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}" \
  "gs://${BUCKET}/${PREFIX}"

echo "Mirrored to gs://${BUCKET}/${PREFIX}"
```

- [ ] **Step 3: Create `03_build_image.sh`**

```bash
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
```

- [ ] **Step 4: Create `04_make_manifest.sh`**

```bash
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
```

- [ ] **Step 5: Syntax-check all four scripts**

Run:
```bash
for f in alphafold/reference-disk/0*.sh; do bash -n "$f" || exit 1; done && echo "scripts OK"
```
Expected: prints `scripts OK`.

- [ ] **Step 6: Commit**

```bash
git add alphafold/reference-disk/0*.sh
git commit -m "Add reference-disk download, image, and manifest build scripts"
```

---

## Task 7: Reference-disk runbook

**Files:**
- Create: `alphafold/reference-disk/README.md`

- [ ] **Step 1: Create `alphafold/reference-disk/README.md`**

```markdown
# Building the AlphaFold reference disk

A one-time operation: download ~2.6 TB of databases, snapshot them into a GCP
disk image, and generate a Cromwell manifest. The workflow then mounts the disk
read-only instead of localizing the databases per run.

## Why the layout matters

`CromwellRefdiskManifestCreator` records each file's path **relative to the scan
root**. Cromwell matches a workflow input against the manifest by comparing the
input's `gs://` path (minus `gs://`) to those relative paths. So three things
must mirror each other:

- on-disk layout: `${DOWNLOAD_ROOT}/<BUCKET>/<PREFIX>/uniref90/uniref90.fasta`
- manifest scan root: `${DOWNLOAD_ROOT}` → entry `…/<BUCKET>/<PREFIX>/uniref90/uniref90.fasta`
- workflow input: `gs://<BUCKET>/<PREFIX>/uniref90/uniref90.fasta`

## Steps

Set these for every script:

```bash
export ALPHAFOLD_REPO=~/alphafold          # git clone of google-deepmind/alphafold
export CROMWELL_REPO=~/cromwell             # git checkout of broadinstitute/cromwell
export DOWNLOAD_ROOT=/mnt/data              # the ~3 TB data disk mount
export BUCKET=my-alphafold-refs
export PREFIX=v2.3.2
export PROJECT=my-gcp-project
export ZONE=us-central1-a
export DATA_DISK=alphafold-data-disk        # the GCE disk backing ${DOWNLOAD_ROOT}
export IMAGE_NAME=alphafold-refs-20260610
export DISK_SIZE_GB=3000
```

1. `bash 01_download_databases.sh` — populate `${DOWNLOAD_ROOT}/${BUCKET}/${PREFIX}` (~2.6 TB, hours).
2. `bash 02_mirror_to_gcs.sh` — (recommended) copy the same tree to `gs://${BUCKET}/${PREFIX}`.
3. Stop the VM / detach the data disk, then `bash 03_build_image.sh` — create the GCE image.
4. `bash 04_make_manifest.sh` — produces `alphafold-refs-manifest.json`.
5. Wire the manifest into the backend (see `../backend-config-snippet.conf`).

## Rough cost (GCP list price, indicative)

- Custom image storage (recurring): ~$130/month for ~2.6 TB.
- Per-run reference disk (standard PD, billed only while a task VM runs): under ~$1/run.
- One-time build: a big VM + ~3 TB scratch disk for several hours, ~$20–50.
- GPU compute per prediction is separate and depends on protein size / GPU type.
```

- [ ] **Step 2: Commit**

```bash
git add alphafold/reference-disk/README.md
git commit -m "Add reference-disk build runbook"
```

---

## Task 8: Backend config snippet

**Files:**
- Create: `alphafold/backend-config-snippet.conf`

- [ ] **Step 1: Create `alphafold/backend-config-snippet.conf`**

```hocon
# Merge this into your Cromwell GCP Batch provider's `config` stanza.
# Start from the example at cromwell.example.backends/GCPBATCH.conf.
#
# The manifest produced by reference-disk/04_make_manifest.sh has thousands of
# file entries, so reference it rather than pasting it inline. JSON is valid
# HOCON, so `include` works:

backend {
  providers {
    GCPBATCH {
      config {

        # Opt-in reference disk. Each array element is one manifest object
        # ({ imageIdentifier, diskSizeGb, files: [...] }). Load the generated
        # file as that object:
        reference-disk-localization-manifests = [
          ${alphafoldRefdiskManifest}
        ]

      }
    }
  }
}

# Point this at the manifest file generated by 04_make_manifest.sh.
alphafoldRefdiskManifest {
  include required(file("/abs/path/to/alphafold-refs-manifest.json"))
}

# GPU notes:
# - No special backend config is needed for GPUs; gpuType/gpuCount/gpu come from
#   the WDL runtime block.
# - Ensure the runtime `zones` actually offer the requested GPU type. The WDL
#   defaults to us-central1-{a,b,c,f} with nvidia-tesla-v100.
# - Reference disks require the `use_reference_disks: true` workflow option,
#   already set in alphafold.options.json.
```

- [ ] **Step 2: Commit**

```bash
git add alphafold/backend-config-snippet.conf
git commit -m "Add GCP Batch backend config snippet for reference disk + GPU"
```

---

## Task 9: Top-level runbook

**Files:**
- Create: `alphafold/README.md`

- [ ] **Step 1: Create `alphafold/README.md`**

```markdown
# AlphaFold on Cromwell (GCP Batch)

A WDL workflow that runs AlphaFold 2 with its genetic databases served from a
Cromwell reference disk instead of being localized per run.

See `../docs/superpowers/specs/2026-06-10-alphafold-cromwell-design.md` for the
full design.

## Files

| File | Purpose |
|------|---------|
| `alphafold.wdl` | The workflow: one GPU task running `run_alphafold.py`. |
| `alphafold.inputs.json` | Example inputs; fill in `<PROJECT>/<REPO>/<BUCKET>/<PREFIX>`. |
| `alphafold.options.json` | Workflow options (`use_reference_disks: true`). |
| `backend-config-snippet.conf` | HOCON to merge into the GCP Batch backend. |
| `docker/` | Build & push the AlphaFold image. |
| `reference-disk/` | Build the database disk image + manifest. |
| `validate.sh` | `womtool` validation helper. |
| `tests/` | Test for the database path-derivation logic. |

## One-time setup

1. **Image** — build and push the AlphaFold container (`docker/README.md`).
2. **Reference disk** — download databases, build the disk image, and generate
   the manifest (`reference-disk/README.md`).
3. **Backend** — merge `backend-config-snippet.conf` into your Cromwell GCP Batch
   config and restart Cromwell.

## Per-prediction

1. Edit `alphafold.inputs.json`: set `alphafold.fasta`, `model_preset`
   (`monomer` | `monomer_ptm` | `monomer_casp14` | `multimer`), `db_preset`
   (`full_dbs` | `reduced_dbs`), `max_template_date`, and `docker_image`.
2. Submit with the options file, e.g.:

   ```bash
   curl -X POST http://<cromwell-host>/api/workflows/v1 \
     -F workflowSource=@alphafold/alphafold.wdl \
     -F workflowInputs=@alphafold/alphafold.inputs.json \
     -F workflowOptions=@alphafold/alphafold.options.json
   ```

3. Outputs: `ranked_pdbs` (all ranked structures), `best_model` (`ranked_0.pdb`),
   `ranking_debug`, `timings`, and `output_tarball` (the full output directory).

## GPUs and A100

The workflow requests GPUs via `gpu_type`/`gpu_count`. GCP Batch's `gpuType`
supports `nvidia-tesla-{v100,p100,p4,t4}`. Large multimers may need an A100,
which GCP Batch exposes only through a GPU `predefinedMachineType`
(`a2-highgpu-1g`). WDL 1.0 cannot conditionally add that runtime key, so to use
an A100 edit the `runtime` block of `run_alphafold` in `alphafold.wdl`: remove
`gpuType`/`gpuCount`/`cpu`/`memory` and add `predefinedMachineType: "a2-highgpu-1g"`.

## Validating changes

```bash
bash alphafold/validate.sh alphafold/alphafold.wdl alphafold/alphafold.inputs.json
bash alphafold/tests/derive_paths_test.sh
```

Full end-to-end execution requires the reference disk and a real GCP project, so
it cannot be exercised from this repo alone. Run a cheap smoke test (a short
peptide FASTA, `db_preset=reduced_dbs`, a T4 GPU) once the disk exists.
```

- [ ] **Step 2: Commit**

```bash
git add alphafold/README.md
git commit -m "Add top-level AlphaFold workflow runbook"
```

---

## Task 10: Final validation sweep

- [ ] **Step 1: Run every check together**

Run:
```bash
bash alphafold/tests/derive_paths_test.sh && \
python3 -m json.tool alphafold/alphafold.inputs.json > /dev/null && \
python3 -m json.tool alphafold/alphafold.options.json > /dev/null && \
for f in alphafold/validate.sh alphafold/reference-disk/0*.sh; do bash -n "$f" || exit 1; done && \
bash alphafold/validate.sh alphafold/alphafold.wdl alphafold/alphafold.inputs.json && \
echo "ALL CHECKS PASSED"
```
Expected: the path test prints `PASS`, womtool prints `Success!`, and the final
line is `ALL CHECKS PASSED`.

- [ ] **Step 2: Confirm the tree matches the plan**

Run: `find alphafold -type f -not -path '*/.tools/*' | sort`
Expected (order aside):
```
alphafold/.gitignore
alphafold/README.md
alphafold/alphafold.inputs.json
alphafold/alphafold.options.json
alphafold/alphafold.wdl
alphafold/backend-config-snippet.conf
alphafold/docker/README.md
alphafold/reference-disk/01_download_databases.sh
alphafold/reference-disk/02_mirror_to_gcs.sh
alphafold/reference-disk/03_build_image.sh
alphafold/reference-disk/04_make_manifest.sh
alphafold/reference-disk/README.md
alphafold/validate.sh
alphafold/tests/db_paths.lib.sh
alphafold/tests/derive_paths_test.sh
```

- [ ] **Step 3: Final commit (if anything is uncommitted)**

```bash
git add -A alphafold
git commit -m "Finalize AlphaFold on Cromwell workflow and tooling" || echo "nothing to commit"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- WDL single GPU task → Task 3. ✅
- monomer + multimer, full/reduced presets (conditional flags) → Task 3 command block. ✅
- Reference-disk anchor wiring + path derivation → Task 2 (tested) + Task 3. ✅
- Example inputs / options (`use_reference_disks`) → Task 4. ✅
- Container image build → Task 5. ✅
- Reference-disk download/image/manifest tooling → Tasks 6–7. ✅
- Backend config snippet → Task 8. ✅
- Top-level runbook + A100 note + test caveat → Task 9. ✅
- Testing strategy (womtool, bash test, lint) → Tasks 1–4, 10. ✅

**Placeholder scan:** `<BUCKET>`, `<PREFIX>`, `<PROJECT>`, `<REPO>` are intentional
deployment placeholders documented as such; no TODO/TBD steps; every code step
contains complete content.

**Type/name consistency:** WDL input/output names match between workflow and task
and between Task 3 and the inputs JSON in Task 4. The derivation function names
(`derive_bfd_db`, `derive_uniref30_db`, `derive_pdb70_db`, `derive_template_dir`,
`derive_data_dir`) and prefix variables (`BFD_PREFIX`/`bfd_prefix`,
`UNIREF30_PREFIX`/`uniref30_prefix`, `PDB70_PREFIX`/`pdb70_prefix`) are consistent
between the test library (Task 2) and the WDL command block (Task 3).
```
