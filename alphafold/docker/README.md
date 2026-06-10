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
