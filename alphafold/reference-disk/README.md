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
