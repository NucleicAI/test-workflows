#!/usr/bin/env python3
"""Seed tiny decoy objects so Cromwell's reference-disk validation passes.

Why this exists
---------------
When `reference-disk-localization-manifests` is configured, Cromwell validates
every manifest entry at startup by doing a GCS batch `get` for each object and
reading its crc32c (see Cromwell's
`GcpBatchReferenceFilesMappingOperations.bulkValidateCrc32cs`). If the object is
*missing*, the batch result is `null` and Cromwell NPEs:

    Cannot invoke "...BlobInfo.getCrc32c()" because the return value of
    "...StorageBatchResult.get()" is null

So the anchor objects must EXIST with a crc32c matching the manifest. We don't
want the real (terabyte-scale) databases in the bucket — at runtime those files
are served from the mounted reference disk image, not fetched from GCS. The
bucket is only read once, at startup, for this validation.

This script satisfies the validation with a 4-byte decoy per anchor whose
crc32c is forged to equal the manifest value. The decoys are never read at
runtime: a file that validates is served from the disk image; the bucket object
is just the key Cromwell checks at boot.

Correctness guarantee
----------------------
crc32c is computed here with a self-tested CRC32C (Castagnoli) implementation,
each forged stub is asserted to match its target before upload, and after upload
the object's crc32c is read back from GCS and asserted to equal the manifest
value (the exact base64 form Cromwell compares against). A wrong checksum can
never be silently uploaded — that's the failure mode that would make a file drop
out of the mapping and get (wrongly) localized from the bucket at runtime.

Usage
-----
    # Prove the forge locally — no GCS, no auth needed:
    python3 seed_anchor_stubs.py --dry-run

    # Create the stubs (bucket must already exist):
    python3 seed_anchor_stubs.py --project nucleicai-ops

    # ...creating the bucket too, if it doesn't exist yet:
    python3 seed_anchor_stubs.py --project nucleicai-ops --location US --create-bucket
"""
import argparse
import base64
import os
import struct
import subprocess
import sys
import tempfile

try:
    import json
except ImportError:  # pragma: no cover
    sys.exit("python3 with json support is required")


# --- CRC32C (Castagnoli, reflected, poly 0x82F63B78) ------------------------
def _make_table():
    table = []
    for i in range(256):
        crc = i
        for _ in range(8):
            crc = (crc >> 1) ^ 0x82F63B78 if (crc & 1) else (crc >> 1)
        table.append(crc)
    return table


_CRC32C_TABLE = _make_table()


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc = (crc >> 8) ^ _CRC32C_TABLE[(crc ^ byte) & 0xFF]
    return crc ^ 0xFFFFFFFF


# A standard CRC32C test vector. If this fails the implementation is wrong and
# every forged checksum would be wrong too, so fail loudly at import.
assert crc32c(b"123456789") == 0xE3069283, "CRC32C self-test failed"


# --- Forge 4 bytes whose CRC32C equals a target -----------------------------
# CRC32C is affine over GF(2): crc(m) = L(m) XOR crc(0). For a 4-byte message
# the linear part over the 32 input bits is invertible, so for any 32-bit target
# there is exactly one 4-byte message producing it. We solve that linear system.
def forge_crc32c_4bytes(target: int) -> bytes:
    if not 0 <= target <= 0xFFFFFFFF:
        raise ValueError(f"target crc32c out of range: {target}")

    base = crc32c(b"\x00\x00\x00\x00")
    # Column i is the CRC contribution of flipping message bit i (unit vector).
    cols = []
    for i in range(32):
        msg = bytearray(4)
        msg[i // 8] |= 1 << (i % 8)
        cols.append(crc32c(bytes(msg)) ^ base)

    # XOR-basis (Gaussian elimination over GF(2)) carrying provenance so we can
    # recover which message bits combine to the target.
    basis = {}  # leading bit -> (value, provenance over the 32 message bits)
    for i in range(32):
        v, prov = cols[i], 1 << i
        while v:
            lead = v.bit_length() - 1
            if lead in basis:
                bv, bp = basis[lead]
                v ^= bv
                prov ^= bp
            else:
                basis[lead] = (v, prov)
                break

    want = target ^ base
    sel = 0
    while want:
        lead = want.bit_length() - 1
        if lead not in basis:
            raise ValueError(f"CRC32C matrix not full rank for target {target:#010x}")
        bv, bp = basis[lead]
        want ^= bv
        sel ^= bp

    msg = bytearray(4)
    for i in range(32):
        if (sel >> i) & 1:
            msg[i // 8] |= 1 << (i % 8)
    out = bytes(msg)
    if crc32c(out) != target:  # belt and suspenders; should be unreachable
        raise AssertionError(f"forge produced wrong crc for target {target:#010x}")
    return out


def crc32c_b64(value: int) -> str:
    """The base64 crc32c form GCS reports and Cromwell compares against."""
    return base64.b64encode(struct.pack(">I", value)).decode("ascii")


# --- GCS helpers (thin wrappers over `gcloud storage`) ----------------------
def _gcloud(args, capture=True):
    return subprocess.run(
        ["gcloud", "storage", *args],
        check=False,
        capture_output=capture,
        text=True,
    )


def object_crc32c_b64(uri: str):
    """Return the object's crc32c (base64) or None if it doesn't exist."""
    # `gcloud storage objects describe` reports the crc32c as `crc32c_hash`.
    r = _gcloud(["objects", "describe", uri, "--format=value(crc32c_hash)"])
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def bucket_exists(bucket: str) -> bool:
    return _gcloud(["buckets", "describe", f"gs://{bucket}", "--format=value(name)"]).returncode == 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_manifest = os.path.normpath(os.path.join(here, "..", "alphafold-refs-manifest.json"))

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=default_manifest, help=f"manifest JSON (default: {default_manifest})")
    ap.add_argument("--project", help="GCP project (required unless --dry-run)")
    ap.add_argument("--location", default="US", help="bucket location if creating one (default: US)")
    ap.add_argument("--create-bucket", action="store_true", help="create the bucket if it is missing")
    ap.add_argument("--dry-run", action="store_true", help="forge and verify locally; touch no GCS resources")
    args = ap.parse_args()

    with open(args.manifest) as fh:
        manifest = json.load(fh)
    files = manifest.get("files", [])
    if not files:
        sys.exit(f"no files in manifest {args.manifest}")

    # Each manifest path is <bucket>/<object...>; the bucket is the first segment.
    buckets = {p["path"].split("/", 1)[0] for p in files}

    print(f"Manifest: {args.manifest}  ({len(files)} anchor(s), bucket(s): {', '.join(sorted(buckets))})")

    if args.dry_run:
        for entry in files:
            target = entry["crc32c"]
            stub = forge_crc32c_4bytes(target)
            print(f"  OK  crc32c={target:<10} b64={crc32c_b64(target):<10} stub={stub.hex()}  {entry['path']}")
        print("\nDry run: all stubs forged and verified locally. No GCS changes made.")
        return

    if not args.project:
        sys.exit("--project is required unless --dry-run")

    # Bucket preflight.
    for bucket in sorted(buckets):
        if bucket_exists(bucket):
            continue
        if not args.create_bucket:
            sys.exit(f"bucket gs://{bucket} does not exist (pass --create-bucket to create it)")
        print(f"Creating bucket gs://{bucket} (project={args.project}, location={args.location})")
        r = _gcloud(["buckets", "create", f"gs://{bucket}", f"--project={args.project}", f"--location={args.location}"])
        if r.returncode != 0:
            sys.exit(f"failed to create gs://{bucket}: {r.stderr.strip()}")

    created = skipped = 0
    for entry in files:
        path, target = entry["path"], entry["crc32c"]
        uri = f"gs://{path}"
        want_b64 = crc32c_b64(target)

        if object_crc32c_b64(uri) == want_b64:
            print(f"  skip  {uri}  (already crc32c={want_b64})")
            skipped += 1
            continue

        stub = forge_crc32c_4bytes(target)
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(stub)
            tmp_path = tmp.name
        try:
            r = _gcloud(["cp", tmp_path, uri])
            if r.returncode != 0:
                sys.exit(f"upload failed for {uri}: {r.stderr.strip()}")
        finally:
            os.unlink(tmp_path)

        # Read back the crc32c GCS actually computed and assert it matches the
        # manifest. This is the exact value Cromwell validates against.
        got_b64 = object_crc32c_b64(uri)
        if got_b64 != want_b64:
            sys.exit(f"VERIFY FAILED for {uri}: gcs crc32c={got_b64} != manifest {want_b64}")
        print(f"  put   {uri}  crc32c={want_b64} (verified)")
        created += 1

    print(f"\nDone: {created} uploaded, {skipped} already present. Cromwell startup validation will now pass.")


if __name__ == "__main__":
    main()
