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

The build script lays the data out and scans it so these line up automatically.

## One command, from your laptop

`build_reference_disk.sh` runs **locally** and handles all the GCP mechanics:
provisions a build VM + a ~3 TB data disk, runs the download and manifest build
on the VM (via `vm_build.sh`), fetches the manifest back to your machine,
snapshots the disk into a GCE image, and — once the image is `READY` — deletes
the VM and data disk (keeping only the image).

Requirements on your machine: an authenticated `gcloud` (`gcloud auth login`) and
permission to create Compute Engine resources in the project. Nothing else is
installed locally; the databases and the Maven build happen on the VM.

```bash
export PROJECT=my-gcp-project
export ZONE=us-central1-a
export BUCKET=my-alphafold-refs
export PREFIX=v2.3.2
export IMAGE_NAME=alphafold-refs-20260611

bash build_reference_disk.sh
```

It prompts once before creating billable resources (`ASSUME_YES=1` to skip).
Useful overrides (all have defaults): `DISK_SIZE_GB` (3000), `MACHINE_TYPE`
(e2-standard-8), `DATA_DISK_TYPE` (pd-balanced), `STORAGE_LOCATION` (us),
`MANIFEST_OUT` (./alphafold-refs-manifest.json), and `KEEP_BUILD_RESOURCES=1` to
retain the (stopped) VM and disk for re-runs instead of deleting them.

On any failure it stops and leaves the VM and disk in place, printing the
commands to delete them once you've finished debugging.

When it finishes, wire the downloaded manifest into Cromwell — see
`../backend-config-snippet.conf`.

`vm_build.sh` is the VM-side worker that `build_reference_disk.sh` ships and runs
over SSH; you do not run it by hand.

## No GCS mirror

The build does not copy the databases to GCS. The workflow's `gs://` inputs are
only a string key matched against the manifest (no fetch), so the reference disk
works without the objects existing. Leaving them non-existent is the safer
default: a manifest **miss** then fails fast with "not found" rather than
silently localizing terabytes — and you avoid paying for a second copy in GCS.

## Rough cost (GCP list price, indicative)

- Custom image storage (recurring): ~$130/month for ~2.6 TB.
- Per-run reference disk (standard PD, billed only while a task VM runs): under ~$1/run.
- One-time build: an e2-standard-8 VM + a ~3 TB pd-balanced disk for several
  hours (both deleted at the end by default), roughly $30–60.
- GPU compute per prediction is separate and depends on protein size / GPU type.
