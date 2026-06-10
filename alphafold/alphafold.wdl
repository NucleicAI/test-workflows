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

    # --- Validate enum inputs up front (fail before mounting the reference disk) ---
    case "~{model_preset}" in
      monomer|monomer_ptm|monomer_casp14|multimer) ;;
      *) echo "ERROR: invalid model_preset '~{model_preset}' (expected monomer|monomer_ptm|monomer_casp14|multimer)" >&2; exit 1 ;;
    esac
    case "~{db_preset}" in
      full_dbs|reduced_dbs) ;;
      *) echo "ERROR: invalid db_preset '~{db_preset}' (expected full_dbs|reduced_dbs)" >&2; exit 1 ;;
    esac
    case "~{models_to_relax}" in
      all|best|none) ;;
      *) echo "ERROR: invalid models_to_relax '~{models_to_relax}' (expected all|best|none)" >&2; exit 1 ;;
    esac

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
      --use_gpu_relax='~{if use_gpu_relax then "true" else "false"}' \
      "${DB_FLAGS[@]}"

    # --- Collect outputs ---
    # AlphaFold writes results under ${OUTPUT_DIR}/<fasta basename>/.
    PRED_DIR="$(find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "${PRED_DIR}" ]] || { echo "ERROR: AlphaFold produced no output directory under ${OUTPUT_DIR}" >&2; exit 1; }
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
    # Execution scratch only; the genetic databases live on the reference disk.
    disks: "local-disk ~{scratch_disk_gb} SSD"
    bootDiskSizeGb: 50
    zones: "us-central1-a us-central1-b us-central1-c us-central1-f"
  }
}
