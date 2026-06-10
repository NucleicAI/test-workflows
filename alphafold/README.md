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
