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
