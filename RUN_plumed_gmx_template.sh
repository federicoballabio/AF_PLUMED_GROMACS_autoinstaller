#!/usr/bin/env bash
#SBATCH --job-name=GMX_PLMD
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --partition=gpu
#SBATCH --time=24:00:00
#SBATCH --gres=gpu:1
#SBATCH --output=GMX_PLMD_%j.out
#SBATCH --error=GMX_PLMD_%j.err

###############################################################################
# Generic Slurm template for PLUMED-driven GROMACS runs
#
# Edit the SBATCH resources and ENV_ROOT before use.
# The environment must have been built with af_plumed_gmx_build.sh.
###############################################################################

set -Eeuo pipefail

# Path to the installation created by af_plumed_gmx_build.sh.
ENV_ROOT="${ENV_ROOT:-/path/to/plumed_gmx_cuda}"

# GROMACS/PLUMED run settings.
# The script expects ${DEFFNM}.tpr in the submission directory.
DEFFNM="${DEFFNM:-production}"
PLUMED_INPUT="${PLUMED_INPUT:-plumed.dat}"
RESTART_CPT="${RESTART_CPT:-}"       # Optional, e.g. production.cpt
MAXH="${MAXH:-}"                     # Optional, e.g. 23.5 for a 24 h allocation
GPU_ID="${GPU_ID:-}"                 # Optional; often leave empty under Slurm.
NOMP="${SLURM_CPUS_PER_TASK:-1}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

log "Job ID              : ${SLURM_JOB_ID:-not_under_slurm}"
log "Node list           : ${SLURM_NODELIST:-$(hostname)}"
log "Host                : $(hostname)"
log "Tasks               : ${SLURM_NTASKS:-1}"
log "CPUs per task       : ${SLURM_CPUS_PER_TASK:-1}"
log "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-unset}"
log "ENV_ROOT            : ${ENV_ROOT}"
log "DEFFNM              : ${DEFFNM}"
log "PLUMED_INPUT        : ${PLUMED_INPUT}"

if [[ ! -f "${ENV_ROOT}/activate.sh" ]]; then
  echo "ERROR: activation script not found: ${ENV_ROOT}/activate.sh" >&2
  exit 1
fi

# Load the self-contained stack. This replaces manual PATH/LD_LIBRARY_PATH edits.
# shellcheck source=/dev/null
source "${ENV_ROOT}/activate.sh"

export AF_DISABLE_GRAPHICS="${AF_DISABLE_GRAPHICS:-1}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-${NOMP}}"
export OMP_PROC_BIND="${OMP_PROC_BIND:-true}"
export OMP_PLACES="${OMP_PLACES:-cores}"

# Optional GROMACS GPU communication controls. Tune for your hardware/system.
export GMX_GPU_DD_COMMS="${GMX_GPU_DD_COMMS:-false}"
export GMX_GPU_PME_PP_COMMS="${GMX_GPU_PME_PP_COMMS:-false}"
export GMX_FORCE_UPDATE_DEFAULT_GPU="${GMX_FORCE_UPDATE_DEFAULT_GPU:-false}"

MDRUN="$(command -v gmx_mpi || true)"
[[ -n "${MDRUN}" ]] || { echo "ERROR: gmx_mpi not found" >&2; exit 1; }
command -v plumed >/dev/null 2>&1 || { echo "ERROR: plumed not found" >&2; exit 1; }
[[ -f "${DEFFNM}.tpr" ]] || { echo "ERROR: missing ${DEFFNM}.tpr" >&2; exit 1; }
[[ -f "${PLUMED_INPUT}" ]] || { echo "ERROR: missing ${PLUMED_INPUT}" >&2; exit 1; }

log "Using gmx_mpi       : ${MDRUN}"
log "Using PLUMED_KERNEL : ${PLUMED_KERNEL:-unset}"
"${MDRUN}" --version | head -n 30

args=(
  mdrun
  -v
  -deffnm "${DEFFNM}"
  -pin on
  -ntomp "${NOMP}"
  -dlb yes
  -nb gpu
  -bonded gpu
  -pme gpu
  -plumed "${PLUMED_INPUT}"
  -nsteps -1
)

[[ -n "${MAXH}" ]] && args+=( -maxh "${MAXH}" )
[[ -n "${RESTART_CPT}" && -f "${RESTART_CPT}" ]] && args+=( -cpi "${RESTART_CPT}" )
[[ -n "${GPU_ID}" ]] && args+=( -gpu_id "${GPU_ID}" )

log "Command: ${MDRUN} ${args[*]}"
"${MDRUN}" "${args[@]}"
