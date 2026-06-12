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
export PROJECT=nucleicai-ops
export ZONE=us-central1-a
export BUCKET=nucleicai-alphafold-refs
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

## No GCS mirror (but anchor stubs are required)

The build does not copy the databases to GCS — at runtime each anchor is served
from the mounted reference disk image, not fetched from the bucket, so there's no
reason to pay for a second terabyte-scale copy.

However, the anchor objects cannot be fully absent. When
`reference-disk-localization-manifests` is configured, Cromwell **validates every
manifest entry at startup** by doing a GCS `get` for each object and reading its
crc32c (`GcpBatchReferenceFilesMappingOperations.bulkValidateCrc32cs`). A
*missing* object makes the batch result `null` and Cromwell NPEs on boot:

```
Cannot invoke "...BlobInfo.getCrc32c()" because the return value of
"...StorageBatchResult.get()" is null
```

(Note: a checksum *mismatch* is tolerated — the file is dropped from the mapping
with a warning and then localized normally — but a missing object is not.)

So each anchor needs a GCS object that exists with a crc32c matching the
manifest. We satisfy that with `seed_anchor_stubs.py`, which uploads a 4-byte
decoy per anchor whose crc32c is forged to equal the manifest value. The decoys
are never read at runtime (validated files come from the disk image); they exist
only so the boot-time validation finds an object and its checksum agrees.

```bash
# Prove the forge locally first (no GCS, no auth):
python3 seed_anchor_stubs.py --dry-run

# Then create the stubs (add --create-bucket if the bucket doesn't exist yet):
python3 seed_anchor_stubs.py --project nucleicai-ops
```

The script self-tests its CRC32C, asserts each forged stub before upload, and
reads the crc32c back from GCS after upload — so it can never silently publish a
wrong checksum (which would drop the file from the mapping and make Cromwell try
to localize the 4-byte decoy as if it were the real database).

## Rough cost (GCP list price, indicative)

- Custom image storage (recurring): ~$130/month for ~2.6 TB.
- Per-run reference disk (standard PD, billed only while a task VM runs): under ~$1/run.
- One-time build: an e2-standard-8 VM + a ~3 TB pd-balanced disk for several
  hours (both deleted at the end by default), roughly $30–60.
- GPU compute per prediction is separate and depends on protein size / GPU type.
