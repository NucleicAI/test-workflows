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

## Compute: CPU-only (default) and GPU mode

**This workflow runs CPU-only by default** (no GPU is requested, and
`use_gpu_relax=false`). AlphaFold's genetic search (jackhmmer/hhblits) is
CPU-bound regardless; only the model-inference and relaxation steps lose GPU
acceleration, so a CPU run is slower but completes — and it sidesteps GPU quota
and capacity limits entirely. For a tolerable runtime, use `db_preset=reduced_dbs`
and a short sequence, and consider raising `cpu`. With no GPU and no
`cpuPlatform`, Cromwell's Batch backend builds an `n2-custom` VM. The task sets
no `zones`, so placement (zone/region) is left to the caller — the backend's
`default-runtime-attributes`.

### Enabling GPU mode

To run on GPU, set `use_gpu_relax=true` and restore the GPU lines in the
`run_alphafold` `runtime` block (`gpu`, `gpuType`, `gpuCount`, `cpuPlatform`),
as noted in `alphafold.wdl`. In GPU mode the workflow requests GPUs via
`gpu_type`/`gpu_count`, defaulting to `nvidia-tesla-t4` — the cheapest GPU the
stock AlphaFold 2.3.2 image (CUDA 11.1, `jaxlib 0.3.25+cuda11`) can drive.
`nvidia-tesla-{v100,p100,p4}` also work; all four attach **only to N1** machine
types. Note: launching any GPU also requires non-zero `GPUS_ALL_REGIONS` (and
per-type) quota in the project.

**GPU placement must target a zone that offers `gpu_type`.** The workflow no
longer sets `zones` — placement is left to the caller. For GPU mode, add a
`zones` attribute to the task runtime (or set it in the backend's
`default-runtime-attributes`) listing zones that offer `gpu_type`, e.g.
`us-west1-{a,b}` (T4/V100) or `us-central1-{a,b,c,f}` (widest selection). If the
VM lands in a zone without the requested GPU, GCE fails with `INVALID_FIELD_VALUE`
at instance creation; if a zone is capacity-exhausted, switch to another. **Do
not target newer regions such as `us-south1`**: their only GPUs are Blackwell
(G4/A4) and Hopper (A3 Ultra), which are not N1-attachable *and* are too new for
the CUDA 11.1 image (they need CUDA 12.8+).

**Why N1 is forced via `cpuPlatform`.** Cromwell's GCP Batch backend picks the
machine family from the `cpuPlatform` attribute alone — with none set it
defaults to `n2`, which these GPUs reject (`machine type n2-custom-… is not
compatible with accelerators`). The `runtime` block therefore pins
`cpuPlatform: "Intel Broadwell"` to force an N1 custom type; `cpu`/`memory_gb`
still apply (an 8 vCPU / 64 GB request is emitted as `custom-10-65536` —
Cromwell's bare `custom-` prefix denotes N1 — since N1 caps memory at
6.5 GB/vCPU and Cromwell bumps the CPU count from 8 to 10 to compensate).
Broadwell (not a newer floor like Skylake) is deliberate: `minCpuPlatform` is a
floor, so the oldest platform the GPU hosts use maximizes the eligible host
pool and reduces `ZONE_RESOURCE_POOL_EXHAUSTED`. T4/V100/P100/P4 hosts are all
Broadwell-or-newer, so going older adds no capacity and may be rejected.

Large multimers may need an A100, which GCP Batch exposes only through a GPU
`predefinedMachineType` (`a2-highgpu-1g`, in A100 zones such as
`us-central1-{a,b,c,f}`). WDL 1.0 cannot conditionally add that runtime key, so
to use an A100 edit the `runtime` block of `run_alphafold` in `alphafold.wdl`:
remove `gpuType`/`gpuCount`/`cpu`/`memory`/`cpuPlatform` and add
`predefinedMachineType: "a2-highgpu-1g"`.

## Validating changes

```bash
bash alphafold/validate.sh alphafold/alphafold.wdl alphafold/alphafold.inputs.json
bash alphafold/tests/derive_paths_test.sh
```

Full end-to-end execution requires the reference disk and a real GCP project, so
it cannot be exercised from this repo alone. Run a cheap smoke test (a short
peptide FASTA, `db_preset=reduced_dbs`, a T4 GPU) once the disk exists.
