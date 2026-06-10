# AlphaFold on Cromwell (GCP Batch) — Design

**Date:** 2026-06-10
**Status:** Approved design, ready for implementation planning

## Goal

Build a WDL workflow, runnable by Cromwell on the GCP Batch backend, that runs
[AlphaFold 2](https://github.com/google-deepmind/alphafold) for protein structure
prediction. AlphaFold's genetic databases (~2.6 TB) are served from a Cromwell
[reference disk](https://cromwell.readthedocs.io/en/latest/backends/GCPBatch/#reference-disk-support)
rather than localized per run.

## Decisions (locked in during brainstorming)

| Decision | Choice |
|----------|--------|
| Reference disk | Does **not** exist yet — creating it (download + image + manifest) is in scope. |
| Model scope | Both monomer and multimer, selectable via a `model_preset` input. |
| Pipeline architecture | A single GPU task running `run_alphafold.py` end-to-end (matches upstream). |
| Container image | Built from AlphaFold's official `docker/Dockerfile`, pushed to the user's Artifact Registry. |
| Database preset | Both `full_dbs` and `reduced_dbs` selectable at runtime; the disk holds full BFD + UniRef30 + small_bfd (~2.6 TB). |

## Background: how Cromwell reference disks work

When any workflow input `File` is a `gs://` path that matches an entry in a configured
manifest, Cromwell mounts the corresponding prebuilt GCP disk image read-only and rewrites
that input to point at the on-disk copy, bypassing localization. Because the disk is a
physical image, **every** file baked into it is present at the mount once mounted —
including files the WDL never explicitly references.

The manifest is produced by the `CromwellRefdiskManifestCreator` tool (in the Cromwell
repo). It scans a local directory recursively and records, for each file, its path
**relative to the scan root** plus a crc32c checksum. Therefore the on-disk layout, the
`gs://` input paths, and the manifest entries must all mirror each other. Reference-disk
use is opt-in per submission via the `"use_reference_disks": true` workflow option.

GPU on GCP Batch is requested through runtime attributes: `gpuType` / `gpuCount` (supported
types include `nvidia-tesla-v100`, `nvidia-tesla-p100`, `nvidia-tesla-p4`, `nvidia-tesla-t4`),
or a GPU `predefinedMachineType` such as `a2-highgpu-1g` for A100s. GPU needs no special
backend config — only that the chosen `zones` actually have the GPU type available.

## Deliverables

A new `alphafold/` directory in this repo:

- **`alphafold.wdl`** — the workflow (one GPU task).
- **`alphafold.inputs.json`** — example inputs; database paths default to `gs://` paths that mirror the manifest namespace.
- **`alphafold.options.json`** — workflow options, including `"use_reference_disks": true`.
- **`docker/README.md`** — build the image from AlphaFold's official `docker/Dockerfile` and push to Artifact Registry.
- **`reference-disk/`** — scripts + runbook to download databases, lay them out, build the GCE disk image, and generate the manifest.
- **`backend-config-snippet.conf`** — HOCON to drop into Cromwell's GCP Batch backend (`reference-disk-localization-manifests` + GPU notes).
- **`README.md`** — the end-to-end runbook tying it together.

## The workflow (`alphafold.wdl`)

A single task `run_alphafold` invokes `run_alphafold.py` end-to-end on a GPU machine,
matching upstream behavior. (The GPU is idle during the CPU-bound MSA phase; this is
accepted for the first version. Splitting MSA onto a CPU task is a documented future
optimization, not in scope.)

### Inputs

- `File fasta` — input sequence(s). For multimer, multiple sequences in one FASTA.
- `String max_template_date` — e.g. `"2022-01-01"`.
- `String model_preset` — `monomer` | `monomer_ptm` | `monomer_casp14` | `multimer` (default `monomer`).
- `String db_preset` — `full_dbs` | `reduced_dbs` (default `full_dbs`).
- `String models_to_relax` — `all` | `best` | `none` (default `best`); this is AlphaFold 2.3.x's
  Amber-relaxation control (it replaced the older `--run_relax` boolean). `Boolean use_gpu_relax` (default `true`).
- Database **anchor** `File` inputs (see "Reference-disk wiring" below), each defaulting to a real `gs://` path on the disk.
- Runtime knobs: `String docker_image`, `String gpu_type` (default `nvidia-tesla-v100`),
  `Int gpu_count` (default 1), `Int cpu` (default 8), `Int memory_gb` (default 64),
  `Int scratch_disk_gb` (default 100).

Note on A100: GCP Batch exposes A100 only via a GPU `predefinedMachineType` (`a2-highgpu-1g`),
which WDL 1.0 cannot conditionally include in a `runtime` block without overriding cpu/memory/gpu.
So v1 wires the GPU through `gpu_type`/`gpu_count` (v100/p100/p4/t4); using A100 requires editing
the task's `runtime` block, documented in the README. (This is a deliberate narrowing from the
earlier "optional `predefined_machine_type` input" idea.)

### Outputs

- `Array[File] ranked_pdbs` — `ranked_*.pdb`.
- `File best_model` — `ranked_0.pdb`, the top-ranked structure (relaxed when relaxation ran).
  Works for both monomer and multimer regardless of `models_to_relax`, unlike a hard-coded
  `relaxed_model_1.pdb` (whose name differs for multimer).
- `File ranking_debug` — `ranking_debug.json`.
- `File timings` — `timings.json`.
- `File output_tarball` — the full output directory, tarred, for completeness.

### Command logic

The task builds the `run_alphafold.py` flag list conditionally:

- `db_preset == full_dbs` → emit `--bfd_database_path` and `--uniref30_database_path`.
- `db_preset == reduced_dbs` → emit `--small_bfd_database_path`.
- `model_preset` starts with `monomer` → emit `--pdb70_database_path`.
- `model_preset == multimer` → emit `--pdb_seqres_database_path` and `--uniprot_database_path`.

Always emit `--uniref90_database_path`, `--mgnify_database_path`, `--template_mmcif_dir`,
`--obsolete_pdbs_path`, `--data_dir`, `--max_template_date`, `--model_preset`, `--db_preset`,
`--output_dir`, `--fasta_paths`, `--models_to_relax=<all|best|none>`, and
`--use_gpu_relax=<bool>`.

## Reference-disk wiring (chosen approach: "anchor file per database")

AlphaFold needs a mix of path shapes — single files, multi-file prefixes, and a directory
of ~200k template files — but WDL `File` is single-file only. The chosen approach:

Declare **one `File` input per database region**, each defaulting to a real `gs://` path on
the disk:

| Flag / use | Anchor file | How the task derives the value |
|------------|-------------|-------------------------------|
| `--uniref90_database_path` | `uniref90/uniref90.fasta` | used directly |
| `--mgnify_database_path` | `mgnify/mgy_clusters_2022_05.fa` | used directly |
| `--bfd_database_path` (full) | one real BFD file | `$(dirname <anchor>)/bfd_metaclust_clu_complete_id30_c90_final_seq.sorted_opt` |
| `--uniref30_database_path` (full) | one real UniRef30 file | `$(dirname <anchor>)/UniRef30_2021_03` |
| `--small_bfd_database_path` (reduced) | `small_bfd/bfd-first_non_consensus_sequences.fasta` | used directly |
| `--pdb70_database_path` (monomer) | one real pdb70 file | `$(dirname <anchor>)/pdb70` |
| `--pdb_seqres_database_path` (multimer) | `pdb_seqres/pdb_seqres.txt` | used directly |
| `--uniprot_database_path` (multimer) | `uniprot/uniprot.fasta` | used directly |
| `--template_mmcif_dir` | `pdb_mmcif/obsolete.dat` | `$(dirname <anchor>)/mmcif_files` |
| `--obsolete_pdbs_path` | `pdb_mmcif/obsolete.dat` | used directly (same anchor as above) |
| `--data_dir` | one file under `params/` | `$(dirname $(dirname <anchor>))` |

This makes every database explicit in the inputs JSON, triggers the disk mount, and lets the
task discover on-disk paths at runtime via `dirname` + the known fixed basenames — no
hard-coded mount point. All anchors point at the same disk, so referencing anchors unused by
a given preset is harmless (the disk mounts once regardless).

**Alternatives considered and rejected:**
- **Single anchor + string-strip the mount root** — fewer inputs, but fragile (encodes the
  relative-path layout in string math) and opaque in the inputs JSON.
- **No reference disk; localize normally** — ~2.6 TB of localization per run, defeating the purpose.

## Container image (`docker/README.md`)

Build from AlphaFold's own `docker/Dockerfile` and push to the user's registry:

```
git clone https://github.com/google-deepmind/alphafold
cd alphafold
docker build -f docker/Dockerfile -t \
  us-docker.pkg.dev/<PROJECT>/<REPO>/alphafold:2.3.2 .
docker push us-docker.pkg.dev/<PROJECT>/<REPO>/alphafold:2.3.2
```

The upstream image's `ENTRYPOINT` runs `run_docker.py`; the WDL invokes `run_alphafold.py`
directly, so the task command does not rely on the entrypoint (Cromwell runs the command via
the shell). The image tag is pinned (default `2.3.2`).

## Reference-disk creation (`reference-disk/`)

A one-time manual op, delivered as a runbook plus helper scripts:

1. **Provision** a build VM with a ~3 TB `pd-balanced` data disk.
2. **Download** all databases with AlphaFold's `scripts/download_all_data.sh <DIR>`, where
   `<DIR>` mirrors the `gs://` namespace, e.g. `/mnt/data/<BUCKET>/<PREFIX>/` so relative
   paths become `<BUCKET>/<PREFIX>/bfd/...`, matching `gs://<BUCKET>/<PREFIX>/bfd/...`. This
   pulls full BFD, UniRef30, small_bfd, params, and the rest (both presets).
3. **(Recommended) Mirror to GCS** (`gsutil rsync` to `gs://<BUCKET>/<PREFIX>/`) so the
   `gs://` input paths are real and non-reference-disk localization still works as a fallback.
4. **Build the image:** create a disk from the data, then
   `gcloud compute images create alphafold-refs-<DATE> --source-disk=...`.
5. **Generate the manifest** with `CromwellRefdiskManifestCreator` (positional args:
   `<nThreads> <imageIdentifier> <diskSizeGb> <scanDir> <manifestOut>`), where
   `imageIdentifier = projects/<PROJECT>/global/images/alphafold-refs-<DATE>` and `scanDir`
   is the root whose children are `<BUCKET>/...`.

### Rough cost (GCP list price, indicative)

- Custom image storage (recurring): ~$130/month for ~2.6 TB.
- Per-run reference disk (standard PD, billed only while a task VM runs): <~$1/run.
- One-time build: a big VM + ~3 TB scratch disk running for hours, roughly $20–50.
- GPU compute per run is separate and depends on protein size / GPU type.

## Backend config (`backend-config-snippet.conf`)

HOCON to merge into the GCP Batch provider's `config`: the generated manifest under
`reference-disk-localization-manifests`, plus notes that GPU needs no special backend config
(it is all runtime attributes) and that the chosen `zones` must have the GPU type available.

## Testing

- **Static:** `womtool validate alphafold.wdl` against the example inputs.
- **Smoke test:** a tiny peptide FASTA with `reduced_dbs` + a T4 GPU for a cheap end-to-end run.
- **Caveat:** full end-to-end validation requires the disk image to exist; it cannot be
  exercised in CI in this repo. The spec and README note this explicitly.

## Out of scope

- Splitting MSA (CPU) and inference (GPU) into separate tasks (future optimization).
- AlphaFold 3 (different repo, model weights, and database requirements).
- Automating the one-time reference-disk build as a workflow.
