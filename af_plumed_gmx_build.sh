#!/usr/bin/env bash
###############################################################################
# Generalized CUDA / OpenMPI / FFTW / Boost / spdlog / ArrayFire / PLUMED / GROMACS build
#
# Builds a self-contained scientific software stack with an ArrayFire CUDA
# backend, a PLUMED installation (ISDB/SAXS + ArrayFire CUDA), and a
# PLUMED-patched GROMACS installation, suitable for workstations and HPC
# login/compute nodes.
#
# Key features vs. the original recipe:
#   * CUDA toolkit is auto-detected, or given explicitly with --cuda <path>.
#   * Install location is composed from --dir <parent> and --name <env-name>;
#     everything lands under <dir>/<name>.
#   * A checkpoint system lets the build resume from the last completed stage
#     (or from/at an explicit stage) instead of restarting from scratch.
#   * Optional activation alias written into ~/.bashrc or ~/.bash_aliases.
#   * Preflight checks for write permission and required tooling.
#   * Optional PLUMED/SAXS source overrides can live in plumed_patch next to
#     this installer, so fresh builds patch SAXS.cpp before compiling PLUMED.
#   * GROMACS is built after PLUMED, so an existing successful PLUMED build can
#     be reused and the new run can continue directly with the gromacs stage.
#
# Quick start:
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --arch 90 -j 16 \
#                            --write-bashrc
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --from gromacs
#
# See --help for all options.
###############################################################################

set -Eeuo pipefail
umask 022

SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_VERSION="4.8-gmx-auto-v25-arrayfire-libdir-postflight"

###############################################################################
# Component versions (override from the environment if needed, e.g.
#   BOOST_VERSION=1.86.0 ./af_plumed_build.sh ...).
###############################################################################
OPENMPI_VERSION="${OPENMPI_VERSION:-5.0.10}"
FFTW_VERSION="${FFTW_VERSION:-3.3.11}"
BOOST_VERSION="${BOOST_VERSION:-1.85.0}"
FMT_VERSION="${FMT_VERSION:-11.2.0}"
SPDLOG_VERSION="${SPDLOG_VERSION:-1.9.2}"
ARRAYFIRE_VERSION="${ARRAYFIRE_VERSION:-3.9.0}"
PLUMED_REPO="${PLUMED_REPO:-https://github.com/plumed/plumed2.git}"
# Disable PLUMED Python wrappers by default. The core PLUMED library, plumed driver,
# and GROMACS mdrun -plumed do not need Python.h / python3-dev.
PLUMED_DISABLE_PYTHON="${PLUMED_DISABLE_PYTHON:-1}"
# Optional local PLUMED source overrides for development/testing. By default the
# script first looks for plumed_patch next to this installer script, then for
# <install-root>/plumed_patch. It accepts SAXS.cpp either directly in that folder
# or as src/isdb/SAXS.cpp inside it, and copies it over src/isdb/SAXS.cpp
# immediately after cloning PLUMED and before the first PLUMED compilation.
PLUMED_PATCH_DIR="${PLUMED_PATCH_DIR:-auto}"
PLUMED_SAXS_CPP="${PLUMED_SAXS_CPP:-}"

# Rootless auto-repair layer for heterogeneous/HPC installations.  This keeps
# normal /usr/local/cuda-style installs untouched, but can create a private CUDA
# shim when CUDA is installed in Debian/Ubuntu split locations such as
# /usr/bin/nvcc + /usr/include + /usr/lib/x86_64-linux-gnu.  The shim only
# contains symlinks inside the install root; no system files are modified.
AUTO_REPAIR="${AUTO_REPAIR:-1}"
CUDA_SHIM_DIR="${CUDA_SHIM_DIR:-auto}"
# Optional extra search locations for unusual CUDA packages.  Separate entries
# with ':' like PATH, e.g. CUDA_EXTRA_INCLUDE_DIRS=/opt/cuda/include:/foo/include.
CUDA_EXTRA_INCLUDE_DIRS="${CUDA_EXTRA_INCLUDE_DIRS:-}"
CUDA_EXTRA_LIB_DIRS="${CUDA_EXTRA_LIB_DIRS:-}"

# Default GROMACS selection is automatic:
#   * GCC/G++ 11+ and CUDA >=12.1 -> GROMACS 2025.4, patched with gromacs-2025.0
#   * GCC/G++ <11 or CUDA <12.1   -> GROMACS 2024.6, patched with gromacs-2024.3
# Override with GROMACS_VERSION=2025.4/2024.6 or --gromacs-version <v>.
GROMACS_VERSION="${GROMACS_VERSION:-auto}"
GROMACS_URL="${GROMACS_URL:-}"
GROMACS_FTP_URL="${GROMACS_FTP_URL:-}"
PLUMED_GROMACS_PATCH="${PLUMED_GROMACS_PATCH:-auto}"
GMX_SIMD="${GMX_SIMD:-AVX2_256}"

# CPU tuning for FFTW (and -O3 native by default). On heterogeneous HPC clusters
# where the build node differs from compute nodes, set MARCH to a common
# baseline, e.g. MARCH=x86-64-v3 to stay portable.
MARCH="${MARCH:-native}"

# Ordered list of build stages used by the checkpoint system.
STAGES=(openmpi fftw boost fmt spdlog arrayfire plumed gromacs)

###############################################################################
# Argument defaults
###############################################################################
CUDA_PATH=""               # --cuda
DIR=""                     # --dir   (required)
NAME=""                    # --name  (default: build_<cudaver>)
NPROC="${NPROC:-}"         # -j/--jobs
CUDA_ARCHS="${CUDA_ARCHS:-80}"   # --arch  (e.g. 80 or "70;80;90")
PLUMED_REF="${PLUMED_REF:-master}"  # --plumed-ref
FROM_STAGE=""              # --from
ONLY_STAGE=""              # --only
FORCE=0                    # --force
WRITE_BASHRC=0             # --write-bashrc
WRITE_ALIASES=0            # --write-aliases
DO_STATUS=0                # --status
DRY_RUN=0                  # --dry-run
ASSUME_YES=0              # -y/--yes: assume "yes" (e.g. reuse a non-empty dir)
NO_COLOR="${NO_COLOR:-0}"  # --no-color

# Populated later
CUDA_HOME=""
CUDA_VERSION=""
INSTALL_ROOT=""
SRC=""
LOG_DIR=""
LOG_FILE=""
CKPT_DIR=""
GMX_ROOT=""
ALIAS_NAME=""

###############################################################################
# Logging helpers
###############################################################################
setup_colors() {
  if [[ "${NO_COLOR}" != "0" ]] || [[ ! -t 1 ]]; then
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_DIM=""; C_RST=""
  else
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
  fi
}

info() { echo "${C_BLU}[INFO]${C_RST} $*"; }
ok()   { echo "${C_GRN}[ OK ]${C_RST} $*"; }
warn() { echo "${C_YEL}[WARN]${C_RST} $*" >&2; }
err()  { echo "${C_RED}[FAIL]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

section() {
  echo
  echo "${C_DIM}#############################################################################${C_RST}"
  echo "# $*"
  echo "${C_DIM}#############################################################################${C_RST}"
}

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<'EOF'
Usage: af_plumed_gmx_build.sh --dir <parent-dir> [options]

Builds OpenMPI, FFTW, Boost, fmt, spdlog, ArrayFire (CUDA), PLUMED and a
PLUMED-patched GROMACS installation into <parent-dir>/<name>, with
checkpointing so the build can resume.

Required:
  --dir <path>          Parent directory for the installation. The actual
                        install root is <dir>/<name>.

Common options:
  --name <name>         Environment name and install subfolder. Also used to
                        build the activation alias. Default: build_<cudaver>.
                        If <dir>/<name> already exists and is non-empty (and is
                        not a previous run of this script), the build aborts and
                        asks for a different --name.
  --cuda <path>         CUDA toolkit root (must contain bin/nvcc). If omitted,
                        the toolkit is auto-detected (env vars, PATH, then common
                        locations such as /usr/local/cuda*).
  --arch <archs>        CUDA compute architecture(s), e.g. 80, 86, 90, or 120.
                        Default: 80. For RTX 50-series / Blackwell, use 120.
  -j, --jobs <n>        Parallel build jobs. Default: nproc.
  --plumed-ref <ref>    Git branch/tag/commit for PLUMED. Default: master.
  --gromacs-version <v> GROMACS version, or auto. Default: auto.
                        auto selects 2025.4 only when GCC/G++ >=11 and CUDA >=12.1;
                        otherwise it falls back to 2024.6.
  --gromacs-url <url>   Primary GROMACS source tarball URL. Default: official HTTPS
                        for the selected version.
  --gromacs-patch <e>  PLUMED patch engine name, or auto. Default: auto
                        (gromacs-2025.0 for 2025.x, gromacs-2024.3 for 2024.x).
  --gmx-simd <simd>    GROMACS SIMD target. Default: AVX2_256.

PLUMED/SAXS development:
  --plumed-patch-dir <dir>
                        Directory containing local PLUMED source overrides.
                        Default: ./plumed_patch next to this installer script
                        when present; otherwise <install-root>/plumed_patch
                        when present; otherwise ./plumed_patch next to the script.
                        For SAXS development, place SAXS.cpp either directly
                        in this folder or as src/isdb/SAXS.cpp inside it. The
                        replacement is applied immediately after cloning PLUMED
                        and before the first PLUMED compilation.
  --saxs-cpp <path>     Explicit replacement file for PLUMED src/isdb/SAXS.cpp.
                        This takes precedence over --plumed-patch-dir.

Auto-repair / HPC compatibility:
  --no-auto-repair     Disable rootless compatibility fixes. By default the script
                        can create a private CUDA shim when nvcc, headers and
                        libraries are split across /usr/bin, /usr/include and
                        /usr/lib/x86_64-linux-gnu.
  --cuda-shim-dir <d>  Directory for an automatically generated CUDA shim.
                        Default: <install-root>/cuda-<version>-shim.

Activation / environment export:
  --write-bashrc        Append an activation alias to ~/.bashrc.
  --write-aliases       Append an activation alias to ~/.bash_aliases.
                        (An activate.sh is always written into the install root.)

Checkpoint control:
  --from <stage>        Build from <stage> onward (earlier stages assumed done).
  --only <stage>        Build only <stage>.
  --force               Ignore checkpoints / rebuild everything; also permits
                        installing into a non-empty directory.
  --status              Print checkpoint status for the resolved install and exit.

Other:
  --dry-run             Resolve everything, run preflight, print the plan and the
                        activation script that would be generated, then exit
                        without building.
  --no-color            Disable coloured output.
  -y, --yes             Assume "yes": reuse a non-empty install dir instead of
                        aborting (a lighter-weight alternative to --force that
                        keeps existing checkpoints).
  -h, --help            Show this help.

Stages, in order: openmpi fftw boost fmt spdlog arrayfire plumed gromacs

Selected environment overrides (export before running):
  OPENMPI_VERSION FFTW_VERSION BOOST_VERSION FMT_VERSION SPDLOG_VERSION ARRAYFIRE_VERSION
  PLUMED_REPO GROMACS_VERSION GROMACS_URL GROMACS_FTP_URL PLUMED_GROMACS_PATCH
  GMX_SIMD MARCH AUTO_REPAIR CUDA_SHIM_DIR CUDA_EXTRA_INCLUDE_DIRS CUDA_EXTRA_LIB_DIRS

Examples:
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv
  ./af_plumed_gmx_build.sh --dir $HOME/sw --name plumed_a100 --arch 80 -j 32 --write-bashrc
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --from gromacs    # continue after PLUMED
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --status
EOF
}

###############################################################################
# Small utilities
###############################################################################
abspath() {
  local p="${1}"
  # Expand a leading ~ that survived as a literal (e.g. from a quoted --dir).
  # shellcheck disable=SC2088  # intentional literal-tilde detection, not expansion
  if [[ "${p}" == "~" ]]; then
    p="${HOME}"
  elif [[ "${p:0:2}" == "~/" ]]; then
    p="${HOME}/${p:2}"
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "${p}" 2>/dev/null && return 0
  fi
  case "${p}" in
    /*) printf '%s\n' "${p}" ;;
    *)  printf '%s\n' "$(pwd)/${p}" ;;
  esac
}

# Escape a string so it can be used inside a sed BRE address (/.../).
regex_escape() { printf '%s' "${1}" | sed 's/[.[\*^$/]/\\&/g'; }

is_valid_stage() {
  local s="${1}" st
  for st in "${STAGES[@]}"; do [[ "${st}" == "${s}" ]] && return 0; done
  return 1
}

stage_index() {
  local s="${1}" i=0 st
  for st in "${STAGES[@]}"; do
    [[ "${st}" == "${s}" ]] && { printf '%s\n' "${i}"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# Download helper: prefers wget, falls back to curl. Saves to basename in cwd.
download() {
  local url="${1}" fname
  fname="$(basename "${url}")"
  if [[ -f "${fname}" ]]; then
    info "Archive ${fname} already present; resuming/validating download."
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -c "${url}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL -C - -O "${url}"
  else
    die "Neither wget nor curl is available to fetch ${url}"
  fi
}

download_first_available() {
  # download_first_available <output-filename> <url1> [url2 ...]
  local fname="${1}" url
  shift
  if [[ $# -lt 1 ]]; then
    die "download_first_available needs at least one URL."
  fi
  for url in "$@"; do
    info "Fetching ${fname} from ${url}"
    if command -v wget >/dev/null 2>&1; then
      if wget -c -O "${fname}" "${url}"; then
        return 0
      fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -fL -C - -o "${fname}" "${url}"; then
        return 0
      fi
    else
      die "Neither wget nor curl is available to fetch ${url}"
    fi
    warn "Download failed from ${url}; trying the next source if available."
  done
  die "Could not download ${fname} from any configured source."
}

###############################################################################
# Argument parsing
###############################################################################
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --cuda)         CUDA_PATH="${2:?--cuda requires a path}"; shift 2 ;;
      --cuda=*)       CUDA_PATH="${1#*=}"; shift ;;
      --dir)          DIR="${2:?--dir requires a path}"; shift 2 ;;
      --dir=*)        DIR="${1#*=}"; shift ;;
      --name)         NAME="${2:?--name requires a value}"; shift 2 ;;
      --name=*)       NAME="${1#*=}"; shift ;;
      -j|--jobs)      NPROC="${2:?--jobs requires a number}"; shift 2 ;;
      --jobs=*)       NPROC="${1#*=}"; shift ;;
      --arch)         CUDA_ARCHS="${2:?--arch requires a value}"; shift 2 ;;
      --arch=*)       CUDA_ARCHS="${1#*=}"; shift ;;
      --plumed-ref)   PLUMED_REF="${2:?--plumed-ref requires a value}"; shift 2 ;;
      --plumed-ref=*) PLUMED_REF="${1#*=}"; shift ;;
      --gromacs-version) GROMACS_VERSION="${2:?--gromacs-version requires a value}"; shift 2 ;;
      --gromacs-version=*) GROMACS_VERSION="${1#*=}"; shift ;;
      --gromacs-url) GROMACS_URL="${2:?--gromacs-url requires a URL}"; shift 2 ;;
      --gromacs-url=*) GROMACS_URL="${1#*=}"; shift ;;
      --gromacs-patch) PLUMED_GROMACS_PATCH="${2:?--gromacs-patch requires an engine name}"; shift 2 ;;
      --gromacs-patch=*) PLUMED_GROMACS_PATCH="${1#*=}"; shift ;;
      --gmx-simd)     GMX_SIMD="${2:?--gmx-simd requires a value}"; shift 2 ;;
      --gmx-simd=*)   GMX_SIMD="${1#*=}"; shift ;;
      --plumed-patch-dir) PLUMED_PATCH_DIR="${2:?--plumed-patch-dir requires a path}"; shift 2 ;;
      --plumed-patch-dir=*) PLUMED_PATCH_DIR="${1#*=}"; shift ;;
      --saxs-cpp)     PLUMED_SAXS_CPP="${2:?--saxs-cpp requires a file}"; shift 2 ;;
      --saxs-cpp=*)   PLUMED_SAXS_CPP="${1#*=}"; shift ;;
      --cuda-shim-dir) CUDA_SHIM_DIR="${2:?--cuda-shim-dir requires a path}"; shift 2 ;;
      --cuda-shim-dir=*) CUDA_SHIM_DIR="${1#*=}"; shift ;;
      --no-auto-repair) AUTO_REPAIR=0; shift ;;
      --from)         FROM_STAGE="${2:?--from requires a stage}"; shift 2 ;;
      --from=*)       FROM_STAGE="${1#*=}"; shift ;;
      --only)         ONLY_STAGE="${2:?--only requires a stage}"; shift 2 ;;
      --only=*)       ONLY_STAGE="${1#*=}"; shift ;;
      --force)        FORCE=1; shift ;;
      --write-bashrc) WRITE_BASHRC=1; shift ;;
      --write-aliases) WRITE_ALIASES=1; shift ;;
      --status)       DO_STATUS=1; shift ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --no-color)     NO_COLOR=1; shift ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      --) shift; break ;;
      -*) err "Unknown option: ${1}"; usage; exit 2 ;;
      *)  err "Unexpected argument: ${1}"; usage; exit 2 ;;
    esac
  done
}

validate_args() {
  [[ -n "${DIR}" ]] || { err "--dir is required."; usage; exit 2; }

  if [[ -n "${FROM_STAGE}" ]] && ! is_valid_stage "${FROM_STAGE}"; then
    die "Invalid --from stage '${FROM_STAGE}'. Valid: ${STAGES[*]}"
  fi
  if [[ -n "${ONLY_STAGE}" ]] && ! is_valid_stage "${ONLY_STAGE}"; then
    die "Invalid --only stage '${ONLY_STAGE}'. Valid: ${STAGES[*]}"
  fi
  if [[ -n "${FROM_STAGE}" && -n "${ONLY_STAGE}" ]]; then
    die "--from and --only are mutually exclusive."
  fi
  if [[ -n "${NAME}" && "${NAME}" == */* ]]; then
    die "--name must be a single folder component (no '/'). Use --dir for the parent path."
  fi
  if [[ -n "${PLUMED_SAXS_CPP}" && ! -f "${PLUMED_SAXS_CPP}" ]]; then
    die "--saxs-cpp file not found: ${PLUMED_SAXS_CPP}"
  fi

}

###############################################################################
# CUDA detection
###############################################################################
get_cuda_version() {
  # Prints "major.minor", e.g. 12.8
  local nvcc="${1}"
  "${nvcc}" --version 2>/dev/null \
    | grep -oE 'release [0-9]+\.[0-9]+' | head -n1 | awk '{print $2}'
}

detect_cuda() {
  local cand=""

  if [[ -n "${CUDA_PATH}" ]]; then
    # Explicit path: prefer the requested CUDA root when it has bin/nvcc.  On
    # split Debian/Ubuntu CUDA installs, users may pass /usr/lib/cuda even
    # though nvcc is /usr/bin/nvcc; with auto-repair enabled we accept that as a
    # hint and consolidate the final layout into a private shim later.
    if [[ -x "${CUDA_PATH}/bin/nvcc" ]]; then
      cand="${CUDA_PATH}"
    elif [[ "${AUTO_REPAIR}" == "1" ]] && command -v nvcc >/dev/null 2>&1; then
      warn "--cuda '${CUDA_PATH}' has no bin/nvcc; using $(command -v nvcc) and the auto-repair CUDA shim."
      cand="$(dirname "$(dirname "$(command -v nvcc)")")"
    else
      die "--cuda '${CUDA_PATH}' has no bin/nvcc."
    fi
  elif [[ -n "${CUDA_HOME:-}" && -x "${CUDA_HOME%/}/bin/nvcc" ]]; then
    cand="${CUDA_HOME%/}"
  elif [[ -n "${CUDA_ROOT:-}" && -x "${CUDA_ROOT%/}/bin/nvcc" ]]; then
    cand="${CUDA_ROOT%/}"
  elif command -v nvcc >/dev/null 2>&1; then
    cand="$(dirname "$(dirname "$(command -v nvcc)")")"
  else
    local d candidates=()
    shopt -s nullglob
    for d in /usr/local/cuda /opt/cuda /usr/lib/cuda; do
      [[ -x "${d}/bin/nvcc" ]] && candidates+=("${d}")
    done
    # Versioned trees, highest version first.
    local versioned=()
    for d in /usr/local/cuda-*; do
      [[ -x "${d}/bin/nvcc" ]] && versioned+=("${d}")
    done
    shopt -u nullglob
    if [[ ${#versioned[@]} -gt 0 ]]; then
      while IFS= read -r d; do candidates+=("${d}"); done \
        < <(printf '%s\n' "${versioned[@]}" | sort -Vr)
    fi
    [[ ${#candidates[@]} -gt 0 ]] && cand="${candidates[0]}"
  fi

  if [[ -z "${cand}" ]]; then
    die "Could not locate a CUDA toolkit. Pass --cuda <path>, set CUDA_HOME, \
load your CUDA module, or install CUDA in a standard location."
  fi

  CUDA_HOME="$(abspath "${cand}")"
  CUDA_VERSION="$(get_cuda_version "${CUDA_HOME}/bin/nvcc")"
  [[ -n "${CUDA_VERSION}" ]] \
    || die "Found nvcc at ${CUDA_HOME}/bin/nvcc but could not parse its version."
  export CUDA_HOME
  export CUDA_ROOT="${CUDA_HOME}"
  if [[ -x "${CUDA_HOME}/bin/nvcc" ]]; then
    export CUDACXX="${CUDA_HOME}/bin/nvcc"
  fi
}

###############################################################################
# Path / name resolution
###############################################################################
resolve_paths() {
  DIR="$(abspath "${DIR}")"
  if [[ -z "${NAME}" ]]; then
    NAME="build_${CUDA_VERSION}"
  fi

  # Default parallel jobs to the core count (fall back to 1 if nproc is absent).
  if [[ -z "${NPROC}" ]]; then
    if command -v nproc >/dev/null 2>&1; then
      NPROC="$(nproc)"
    else
      NPROC=1
    fi
  fi
  if ! [[ "${NPROC}" =~ ^[1-9][0-9]*$ ]]; then
    die "--jobs must be a positive integer (got: ${NPROC})"
  fi

  INSTALL_ROOT="${DIR%/}/${NAME}"
  SRC="${INSTALL_ROOT}/src"
  LOG_DIR="${INSTALL_ROOT}/build_logs"
  CKPT_DIR="${INSTALL_ROOT}/.checkpoints"

  # Activation alias must be a valid shell identifier; sanitize if needed.
  if [[ "${NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    ALIAS_NAME="${NAME}"
  else
    ALIAS_NAME="$(printf '%s' "${NAME}" | sed 's/[^A-Za-z0-9_]/_/g')"
    [[ "${ALIAS_NAME}" =~ ^[A-Za-z_] ]] || ALIAS_NAME="env_${ALIAS_NAME}"
  fi
}

###############################################################################
# Checkpoints
###############################################################################
stage_done()      { [[ -f "${CKPT_DIR}/${1}.done" ]]; }
mark_stage_done() { mkdir -p "${CKPT_DIR}"; date > "${CKPT_DIR}/${1}.done"; }

should_run() {
  local stage="${1}" idx fidx
  idx="$(stage_index "${stage}")"

  if [[ -n "${ONLY_STAGE}" ]]; then
    [[ "${stage}" == "${ONLY_STAGE}" ]]
    return
  fi
  if [[ -n "${FROM_STAGE}" ]]; then
    fidx="$(stage_index "${FROM_STAGE}")"
    [[ "${idx}" -ge "${fidx}" ]]
    return
  fi
  if [[ "${FORCE}" -eq 1 ]]; then return 0; fi
  stage_done "${stage}" && return 1
  return 0
}

###############################################################################
# Pre-existing directory guard (requirement #3)
###############################################################################
check_install_dir() {
  if [[ -d "${INSTALL_ROOT}" ]] && [[ -n "$(ls -A "${INSTALL_ROOT}" 2>/dev/null)" ]]; then
    # Non-empty. Allow if it is a previous run of this script (has checkpoints),
    # or the user explicitly asked to resume/force.
    if [[ -d "${CKPT_DIR}" ]] || [[ "${FORCE}" -eq 1 ]] \
       || [[ -n "${FROM_STAGE}" ]] || [[ -n "${ONLY_STAGE}" ]] \
       || [[ "${ASSUME_YES}" -eq 1 ]]; then
      info "Reusing existing install root (resume): ${INSTALL_ROOT}"
    else
      die "Install folder already exists and is not empty:
    ${INSTALL_ROOT}
Choose a different environment name with --name, or pass --force (rebuild all)
or -y/--yes (reuse and keep checkpoints) to install into it anyway."
    fi
  fi
}

###############################################################################
# Preflight (requirement #5)
###############################################################################
version_ge() {
  # version_ge A B  -> true if A >= B
  [[ "$(printf '%s\n%s\n' "${2}" "${1}" | sort -V | head -n1)" == "${2}" ]]
}

path_list_to_array() {
  # path_list_to_array <colon-separated-string>
  local list="${1:-}" item
  [[ -n "${list}" ]] || return 0
  IFS=':' read -r -a _path_items <<< "${list}"
  for item in "${_path_items[@]}"; do
    [[ -n "${item}" && -d "${item}" ]] && printf '%s
' "$(abspath "${item}")"
  done
}

first_existing_file() {
  # first_existing_file <name> <dir1> [dir2 ...]
  local name="${1}" d
  shift
  for d in "$@"; do
    [[ -f "${d}/${name}" ]] && { printf '%s
' "${d}/${name}"; return 0; }
  done
  return 1
}

first_existing_library() {
  # first_existing_library <libname-or-glob> <dir1> [dir2 ...]
  local pat="${1}" d f
  shift
  shopt -s nullglob
  for d in "$@"; do
    for f in "${d}/${pat}"; do
      [[ -f "${f}" || -L "${f}" ]] && { printf '%s
' "${f}"; shopt -u nullglob; return 0; }
    done
  done
  shopt -u nullglob
  return 1
}

cuda_candidate_include_dirs() {
  local d
  for d in     "${CUDA_HOME}/include"     "${CUDA_HOME}/targets/x86_64-linux/include"     "${CUDA_HOME%/}/../include"     /usr/local/cuda/include     /usr/local/cuda-*/include     /usr/lib/cuda/include     /usr/include; do
    [[ -d "${d}" ]] && printf '%s
' "$(abspath "${d}")"
  done
  path_list_to_array "${CUDA_EXTRA_INCLUDE_DIRS}"
}

cuda_candidate_lib_dirs() {
  local d
  for d in     "${CUDA_HOME}/lib64"     "${CUDA_HOME}/targets/x86_64-linux/lib"     "${CUDA_HOME%/}/../lib64"     /usr/local/cuda/lib64     /usr/local/cuda-*/lib64     /usr/lib/cuda/lib64     /usr/lib/x86_64-linux-gnu     /lib/x86_64-linux-gnu; do
    [[ -d "${d}" ]] && printf '%s
' "$(abspath "${d}")"
  done
  path_list_to_array "${CUDA_EXTRA_LIB_DIRS}"
}

unique_lines() { awk '!seen[$0]++'; }

cuda_header_ok() {
  local h
  for h in cuda.h cuda_runtime.h cuComplex.h cuda_fp16.h math_constants.h; do
    [[ -f "${CUDA_HOME}/include/${h}" || -f "${CUDA_HOME}/targets/x86_64-linux/include/${h}" ]] || return 1
  done
  return 0
}

cuda_lib_ok() {
  local l
  for l in libcudart.so libcublas.so libcufft.so libcusolver.so libnvrtc.so; do
    [[ -e "${CUDA_HOME}/lib64/${l}" || -e "${CUDA_HOME}/targets/x86_64-linux/lib/${l}" ]] || return 1
  done
  return 0
}

needs_cuda_shim() {
  # Normal NVIDIA toolkit layouts should pass without any shim.  Split distro
  # layouts, e.g. /usr/bin/nvcc + /usr/include + /usr/lib/x86_64-linux-gnu,
  # generally need a private consolidated prefix.
  [[ "${AUTO_REPAIR}" == "1" ]] || return 1
  [[ ! -x "${CUDA_HOME}/bin/nvcc" ]] && return 0
  [[ "${CUDA_HOME}" == "/usr" || "${CUDA_HOME}" == "/" ]] && return 0
  cuda_header_ok || return 0
  cuda_lib_ok || return 0
  return 1
}

link_cuda_headers_into_shim() {
  local shim="${1}" d f base sub nvml
  mkdir -p "${shim}/include"
  while IFS= read -r d; do
    [[ -d "${d}" ]] || continue
    # Link broad CUDA-ish top-level headers. This is intentionally broader than
    # the exact headers we already hit (cuComplex.h, cuda_fp16.h,
    # math_constants.h), because ArrayFire/NVRTC generates a bundle from many
    # CUDA headers and future versions may require more.
    shopt -s nullglob
    for f in "${d}"/*.h "${d}"/*.hpp; do
      base="$(basename "${f}")"
      case "${base}" in
        cuda*|cu*|nv*|math*|device*|host*|builtin_types.h|driver_types.h|vector_types.h|vector_functions.h|surface_types.h|texture_types.h|channel_descriptor.h|library_types.h|surface_functions.h|texture_fetch_functions.h|crtdef.h)
          ln -sfn "${f}" "${shim}/include/${base}"
          ;;
      esac
    done
    shopt -u nullglob
    for sub in crt cooperative_groups nv cccl; do
      [[ -d "${d}/${sub}" ]] && ln -sfn "${d}/${sub}" "${shim}/include/${sub}"
    done
  done < <(cuda_candidate_include_dirs | unique_lines)

  # nvml.h is sometimes nested (e.g. /usr/include/nvidia/gdk/nvml.h).
  if [[ ! -f "${shim}/include/nvml.h" ]]; then
    nvml="$(find /usr /usr/local -path '*/nvml.h' -type f 2>/dev/null | head -n1 || true)"
    [[ -n "${nvml}" ]] && ln -sfn "${nvml}" "${shim}/include/nvml.h"
  fi
  return 0
}

link_cuda_libs_into_shim() {
  local shim="${1}" d f base lib stem
  mkdir -p "${shim}/lib64" "${shim}/lib64/stubs"
  while IFS= read -r d; do
    [[ -d "${d}" ]] || continue
    shopt -s nullglob
    for f in       "${d}"/libcuda.so*       "${d}"/libcudart.so*       "${d}"/libcublas.so*       "${d}"/libcublasLt.so*       "${d}"/libcufft.so*       "${d}"/libcusolver.so*       "${d}"/libcusparse.so*       "${d}"/libnvrtc.so*       "${d}"/libnvJitLink.so*       "${d}"/libnvidia-ml.so*; do
      [[ -e "${f}" ]] || continue
      base="$(basename "${f}")"
      ln -sfn "${f}" "${shim}/lib64/${base}"
      # Also provide an unversioned .so if only a versioned SONAME was present.
      if [[ "${base}" =~ ^(lib[^.]+)\.so\. ]]; then
        stem="${BASH_REMATCH[1]}.so"
        [[ -e "${shim}/lib64/${stem}" ]] || ln -sfn "${base}" "${shim}/lib64/${stem}"
      fi
    done
    shopt -u nullglob
  done < <(cuda_candidate_lib_dirs | unique_lines)

  # GROMACS' NVML discovery often asks specifically for lib64/stubs/libnvidia-ml.so.
  if [[ ! -e "${shim}/lib64/stubs/libnvidia-ml.so" && -e "${shim}/lib64/libnvidia-ml.so" ]]; then
    ln -sfn "../libnvidia-ml.so" "${shim}/lib64/stubs/libnvidia-ml.so"
  fi
  return 0
}

create_or_update_cuda_shim() {
  local shim nvcc_real
  if [[ "${CUDA_SHIM_DIR}" == "auto" || -z "${CUDA_SHIM_DIR}" ]]; then
    shim="${INSTALL_ROOT}/cuda-${CUDA_VERSION}-shim"
  else
    shim="$(abspath "${CUDA_SHIM_DIR}")"
  fi
  if [[ -x "${CUDA_HOME}/bin/nvcc" ]]; then
    nvcc_real="${CUDA_HOME}/bin/nvcc"
  else
    nvcc_real="$(command -v nvcc 2>/dev/null || true)"
  fi
  [[ -x "${nvcc_real}" ]] || die "Cannot create CUDA shim because nvcc was not found/runnable."

  info "Creating/updating private CUDA shim: ${shim}"
  mkdir -p "${shim}/bin" "${shim}/targets/x86_64-linux"
  ln -sfn "${nvcc_real}" "${shim}/bin/nvcc"
  link_cuda_headers_into_shim "${shim}"
  link_cuda_libs_into_shim "${shim}"
  rm -f "${shim}/targets/x86_64-linux/include" "${shim}/targets/x86_64-linux/lib"
  ln -sfn "${shim}/include" "${shim}/targets/x86_64-linux/include"
  ln -sfn "${shim}/lib64" "${shim}/targets/x86_64-linux/lib"

  CUDA_HOME="$(abspath "${shim}")"
  CUDA_VERSION="$(get_cuda_version "${CUDA_HOME}/bin/nvcc")"
  export CUDA_HOME CUDA_ROOT="${CUDA_HOME}"
  export CUDACXX="${CUDA_HOME}/bin/nvcc"
}

ensure_cuda_development_layout() {
  section "CUDA development-layout check"
  if needs_cuda_shim; then
    create_or_update_cuda_shim
  else
    ok "CUDA toolkit layout looks usable without a shim."
  fi

  local missing_headers=() missing_libs=() h l
  for h in cuda.h cuda_runtime.h cuComplex.h cuda_fp16.h math_constants.h; do
    [[ -f "${CUDA_HOME}/include/${h}" || -f "${CUDA_HOME}/targets/x86_64-linux/include/${h}" ]] || missing_headers+=("${h}")
  done
  for l in libcudart.so libcublas.so libcufft.so libcusolver.so libnvrtc.so; do
    [[ -e "${CUDA_HOME}/lib64/${l}" || -e "${CUDA_HOME}/targets/x86_64-linux/lib/${l}" ]] || missing_libs+=("${l}")
  done

  if [[ ${#missing_headers[@]} -gt 0 ]]; then
    die "CUDA headers missing after auto-repair: ${missing_headers[*]}. Add their locations with CUDA_EXTRA_INCLUDE_DIRS or load a fuller CUDA module."
  fi
  if [[ ${#missing_libs[@]} -gt 0 ]]; then
    die "CUDA libraries missing after auto-repair: ${missing_libs[*]}. Add their locations with CUDA_EXTRA_LIB_DIRS or load a fuller CUDA module."
  fi
  ok "CUDA hot headers/libraries available from ${CUDA_HOME}."
}

preflight() {
  section "Preflight checks"

  # Under --dry-run we want to surface problems but still print the full plan,
  # so downgrade otherwise-fatal checks to warnings.
  _pf_fail() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      warn "$1"
    else
      die "$1"
    fi
  }

  local missing=()
  local c
  for c in git tar make cmake pkg-config gcc g++ awk sed grep find; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    missing+=("wget-or-curl")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    _pf_fail "Missing required tools: ${missing[*]}
On HPC, try 'module load' for the relevant compilers/cmake/git, or ask your admin."
  else
    ok "Required tools present."
  fi

  # CMake version. ArrayFire can work with older CMake releases. GROMACS
  # requirements depend on the selected branch: 2024.x needs 3.18.4+, while
  # 2025.x needs 3.28+. In auto mode, keep preflight permissive because the
  # GROMACS stage can fall back to 2024.6 on old GCC/G++ toolchains.
  if command -v cmake >/dev/null 2>&1; then
    local cmake_ver cmake_min cmake_msg
    cmake_ver="$(cmake --version | head -n1 | awk '{print $3}')"
    cmake_min="3.16"
    cmake_msg="3.16+ is recommended for ArrayFire."
    if should_run gromacs; then
      case "${GROMACS_VERSION}" in
        2025*)
          cmake_min="3.28"
          cmake_msg="GROMACS ${GROMACS_VERSION} needs CMake 3.28+."
          ;;
        2024*)
          cmake_min="3.18.4"
          cmake_msg="GROMACS ${GROMACS_VERSION} needs CMake 3.18.4+."
          ;;
        auto)
          cmake_min="3.18.4"
          cmake_msg="GROMACS auto mode needs CMake 3.18.4+ for the 2024 fallback; 2025.4 will additionally require 3.28+ if selected."
          ;;
      esac
    fi
    if ! version_ge "${cmake_ver}" "${cmake_min}"; then
      _pf_fail "CMake ${cmake_ver} detected; ${cmake_msg}"
    else
      ok "CMake ${cmake_ver}."
    fi
  fi

  # CUDA sanity.
  if "${CUDA_HOME}/bin/nvcc" --version >/dev/null 2>&1; then
    ok "CUDA ${CUDA_VERSION} at ${CUDA_HOME}."
    export CUDACXX="${CUDA_HOME}/bin/nvcc"
  else
    _pf_fail "nvcc at ${CUDA_HOME}/bin/nvcc is not runnable."
  fi

  # Hot CUDA files that previously caused failures on split Ubuntu/HPC CUDA
  # packages. The auto-repair shim should have made these visible before we get
  # here.
  local hot_missing=() hf
  for hf in     "${CUDA_HOME}/include/cuComplex.h"     "${CUDA_HOME}/include/cuda_fp16.h"     "${CUDA_HOME}/include/math_constants.h"     "${CUDA_HOME}/lib64/libcudart.so"     "${CUDA_HOME}/lib64/libcublas.so"     "${CUDA_HOME}/lib64/libcufft.so"     "${CUDA_HOME}/lib64/libcusolver.so"     "${CUDA_HOME}/lib64/libnvrtc.so"; do
    [[ -e "${hf}" ]] || hot_missing+=("${hf}")
  done
  if [[ ${#hot_missing[@]} -gt 0 ]]; then
    _pf_fail "Missing hot CUDA headers/libraries: ${hot_missing[*]}"
  else
    ok "Hot CUDA headers/libraries present."
  fi

  if [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]]; then
    ok "PLUMED Python wrapper disabled; Python.h/pip/venv are not required."
  elif command -v python3 >/dev/null 2>&1; then
    if python3 - <<'PYEOF' >/dev/null 2>&1
import sysconfig, pathlib
p = pathlib.Path(sysconfig.get_paths().get('include', '')) / 'Python.h'
raise SystemExit(0 if p.exists() else 1)
PYEOF
    then
      ok "Python.h detected for optional PLUMED Python wrapper."
    else
      warn "Python.h not detected; PLUMED Python wrapper may fail unless --disable-python is used."
    fi
  fi

  # Write-permission test on the install location (or nearest existing parent).
  local probe="${INSTALL_ROOT}"
  while [[ ! -e "${probe}" && "${probe}" != "/" ]]; do
    probe="$(dirname "${probe}")"
  done
  if [[ ! -w "${probe}" ]]; then
    _pf_fail "No write permission for ${probe} (needed to create ${INSTALL_ROOT}).
Re-run as the owner, choose a --dir you can write to, or run with sudo."
  else
    ok "Write permission for ${probe}."
  fi

  # Disk space (soft warning).
  local avail_kb avail_gb
  avail_kb="$(df -Pk "${probe}" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "${avail_kb}" ]]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ "${avail_gb}" -lt 20 ]]; then
      warn "Only ~${avail_gb} GB free at ${probe}; the full build can need 15-25 GB."
    else
      ok "~${avail_gb} GB free at ${probe}."
    fi
  fi
}

###############################################################################
# Build-time environment
###############################################################################
setup_environment() {
  export MPI_ROOT="${INSTALL_ROOT}/openmpi"
  export FFTW_ROOT="${INSTALL_ROOT}/fftw"
  export BOOST_ROOT="${INSTALL_ROOT}/boost"
  export FMT_ROOT="${INSTALL_ROOT}/fmt"
  export SPDLOG_ROOT="${INSTALL_ROOT}/spdlog"
  export AF_ROOT="${INSTALL_ROOT}/arrayfire"
  export GMX_ROOT="${INSTALL_ROOT}/gromacs"
  # Keep PLUMED_ROOT as a shell variable, not an exported environment variable,
  # during the build. A build-tree plumed executable can interpret an exported
  # PLUMED_ROOT as an installed runtime tree; before installation that directory
  # may not exist yet and JSON generation can crash while scanning it.
  unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"

  # Known to interfere with pkg-config / FFTW discovery.
  unset PKG_CONFIG_LIBDIR 2>/dev/null || true

  # Prepend our trees so they win, but keep the existing PATH/library paths so
  # HPC module-provided compilers and tools remain available.
  # Make CMake CUDA-language discovery deterministic on HPC nodes where nvcc is
  # not exposed through the default environment.
  if [[ -x "${CUDA_HOME}/bin/nvcc" ]]; then
    export CUDACXX="${CUDA_HOME}/bin/nvcc"
  fi
  export PATH="${GMX_ROOT}/bin:${PLUMED_ROOT}/bin:${MPI_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${PLUMED_ROOT}/lib:${AF_ROOT}/lib:${AF_ROOT}/lib64:${FFTW_ROOT}/lib:${BOOST_ROOT}/lib:${FMT_ROOT}/lib:${FMT_ROOT}/lib64:${SPDLOG_ROOT}/lib:${SPDLOG_ROOT}/lib64:${MPI_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${GMX_ROOT}/lib/pkgconfig:${GMX_ROOT}/lib64/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${FMT_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="${GMX_ROOT}:${PLUMED_ROOT}:${AF_ROOT}:${FFTW_ROOT}:${BOOST_ROOT}:${FMT_ROOT}:${SPDLOG_ROOT}:${MPI_ROOT}:${CUDA_HOME}:${CMAKE_PREFIX_PATH:-}"
  export BOOST_INCLUDEDIR="${BOOST_ROOT}/include"
  export BOOST_LIBRARYDIR="${BOOST_ROOT}/lib"

  # If spdlog is already installed, expose its CMake package dir.
  if [[ -d "${SPDLOG_ROOT}" ]]; then
    local f
    f="$(find "${SPDLOG_ROOT}" -name spdlogConfig.cmake 2>/dev/null | head -n1 || true)"
    if [[ -n "${f}" ]]; then
      SPDLOG_CMAKE_DIR="$(dirname "${f}")"
      export SPDLOG_CMAKE_DIR
    fi
  fi
}

# CMake can discover packages from the prefix that provided the cmake executable
# (for example, Conda).  Keep the cmake binary usable, but make
# package discovery ignore Conda prefixes so ArrayFire cannot silently link to
# Conda libraries such as libfmt.so.11.
cmake_ignore_prefixes() {
  local prefixes=() p conda_bin conda_root out=""
  for p in "${CONDA_PREFIX:-}" "${CONDA_PREFIX_1:-}"; do
    [[ -n "${p}" && -d "${p}" ]] && prefixes+=("$(abspath "${p}")")
  done
  if command -v conda >/dev/null 2>&1; then
    conda_bin="$(command -v conda)"
    conda_root="$(dirname "$(dirname "${conda_bin}")")"
    [[ -d "${conda_root}" ]] && prefixes+=("$(abspath "${conda_root}")")
  fi

  local seen=";"
  for p in "${prefixes[@]}"; do
    [[ "${seen}" == *";${p};"* ]] && continue
    seen+="${p};"
    if [[ -z "${out}" ]]; then out="${p}"; else out="${out};${p}"; fi
  done
  printf '%s\n' "${out}"
}

cmake_common_isolation_args() {
  local ignore
  ignore="$(cmake_ignore_prefixes)"
  [[ -n "${ignore}" ]] || return 0
  printf '%s\n' \
    "-DCMAKE_IGNORE_PREFIX_PATH=${ignore}" \
    "-DCMAKE_SYSTEM_IGNORE_PREFIX_PATH=${ignore}" \
    "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE" \
    "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE"
}

assert_no_missing_libs() {
  local so="${1}" label="${2}" tmp
  tmp="$(mktemp)"
  ldd "${so}" | tee "${tmp}" | grep -Ei "not found|fmt|fftw|cuda|cudart|mpi" || true
  if grep -q "not found" "${tmp}"; then
    rm -f "${tmp}"
    die "${label} has unresolved runtime libraries. Fix this stage before continuing."
  fi
  rm -f "${tmp}"
}

###############################################################################
# Build stages
###############################################################################
stage_openmpi() {
  section "OpenMPI ${OPENMPI_VERSION} (CUDA-aware)"
  local series tarball
  series="$(printf '%s' "${OPENMPI_VERSION}" | cut -d. -f1,2)"
  tarball="openmpi-${OPENMPI_VERSION}.tar.gz"
  cd "${SRC}"
  download "https://download.open-mpi.org/release/open-mpi/v${series}/${tarball}"
  rm -rf "openmpi-${OPENMPI_VERSION}"
  tar -xf "${tarball}"
  cd "openmpi-${OPENMPI_VERSION}"
  ./configure --prefix="${MPI_ROOT}" --with-cuda="${CUDA_HOME}"
  make -j"${NPROC}"
  make install
  "${MPI_ROOT}/bin/mpicc" --showme >/dev/null
  "${MPI_ROOT}/bin/mpicxx" --showme >/dev/null
  ok "OpenMPI installed at ${MPI_ROOT}"
  mark_stage_done openmpi
}

stage_fftw() {
  section "FFTW ${FFTW_VERSION} (single + double precision)"
  local tarball="fftw-${FFTW_VERSION}.tar.gz"
  cd "${SRC}"
  download "https://www.fftw.org/${tarball}"
  rm -rf "fftw-${FFTW_VERSION}"
  tar -xf "${tarball}"
  cd "fftw-${FFTW_VERSION}"

  rm -rf build-float build-double

  mkdir -p build-float && cd build-float
  ../configure --prefix="${FFTW_ROOT}" --enable-float --enable-shared \
    --enable-sse2 --enable-avx --enable-avx2 --enable-avx512 \
    CFLAGS="-O3 -march=${MARCH}"
  make -j"${NPROC}"
  make install
  cd ..

  mkdir -p build-double && cd build-double
  ../configure --prefix="${FFTW_ROOT}" --enable-shared \
    --enable-sse2 --enable-avx --enable-avx2 --enable-avx512 \
    CFLAGS="-O3 -march=${MARCH}"
  make -j"${NPROC}"
  make install
  cd ..

  unset PKG_CONFIG_LIBDIR 2>/dev/null || true
  export PKG_CONFIG_PATH="${FFTW_ROOT}/lib/pkgconfig:${FMT_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  pkg-config --modversion fftw3  >/dev/null
  pkg-config --modversion fftw3f >/dev/null
  ok "FFTW installed at ${FFTW_ROOT}"
  mark_stage_done fftw
}

stage_boost() {
  section "Boost ${BOOST_VERSION}"
  local us tarball
  us="${BOOST_VERSION//./_}"
  tarball="boost_${us}.tar.gz"
  cd "${SRC}"
  download "https://archives.boost.io/release/${BOOST_VERSION}/source/${tarball}"
  rm -rf "boost_${us}"
  tar -xf "${tarball}"
  cd "boost_${us}"
  ./bootstrap.sh --prefix="${BOOST_ROOT}"
  ./b2 -j"${NPROC}" install --prefix="${BOOST_ROOT}" --without-python cxxflags="-fPIC"
  [[ -f "${BOOST_ROOT}/include/boost/version.hpp" ]] \
    || die "Boost headers not found after install."
  ok "Boost installed at ${BOOST_ROOT}"
  mark_stage_done boost
}

stage_fmt() {
  section "fmt ${FMT_VERSION}"
  cd "${SRC}"
  rm -rf "fmt-${FMT_VERSION}"
  git clone --branch "${FMT_VERSION}" --depth 1 \
    https://github.com/fmtlib/fmt.git "fmt-${FMT_VERSION}"
  cd "fmt-${FMT_VERSION}"
  rm -rf build_cuda && mkdir -p build_cuda && cd build_cuda
  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${FMT_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DFMT_DOC=OFF \
    -DFMT_TEST=OFF \
    "${cmake_iso[@]}"
  make -j"${NPROC}"
  make install

  [[ -f "${FMT_ROOT}/lib/libfmt.so" || -f "${FMT_ROOT}/lib64/libfmt.so" ]] \
    || die "libfmt.so not found after fmt install."

  local f
  f="$(find "${FMT_ROOT}" \( -name 'fmtConfig.cmake' -o -name 'fmt-config.cmake' \) 2>/dev/null | head -n1 || true)"
  [[ -n "${f}" ]] || die "fmt CMake package not found after fmt install."
  ok "fmt installed at ${FMT_ROOT} (cmake: $(dirname "${f}"))"
  mark_stage_done fmt
}

stage_spdlog() {
  section "spdlog ${SPDLOG_VERSION}"
  cd "${SRC}"
  rm -rf "spdlog-${SPDLOG_VERSION}"
  git clone --branch "v${SPDLOG_VERSION}" --depth 1 \
    https://github.com/gabime/spdlog.git "spdlog-${SPDLOG_VERSION}"
  cd "spdlog-${SPDLOG_VERSION}"
  rm -rf build_cuda && mkdir -p build_cuda && cd build_cuda
  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${SPDLOG_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSPDLOG_BUILD_SHARED=ON \
    -DSPDLOG_FMT_EXTERNAL=OFF \
    "${cmake_iso[@]}"
  make -j"${NPROC}"
  make install

  local f
  f="$(find "${SPDLOG_ROOT}" -name spdlogConfig.cmake 2>/dev/null | head -n1 || true)"
  [[ -n "${f}" ]] || die "spdlogConfig.cmake not found after install."
  SPDLOG_CMAKE_DIR="$(dirname "${f}")"
  export SPDLOG_CMAKE_DIR
  ok "spdlog installed at ${SPDLOG_ROOT} (cmake: ${SPDLOG_CMAKE_DIR})"
  mark_stage_done spdlog
}

stage_arrayfire() {
  section "ArrayFire ${ARRAYFIRE_VERSION} (CUDA backend, arch=${CUDA_ARCHS})"
  cd "${SRC}"
  rm -rf "arrayfire-${ARRAYFIRE_VERSION}"
  git clone --recursive --branch "v${ARRAYFIRE_VERSION}" \
    https://github.com/arrayfire/arrayfire.git "arrayfire-${ARRAYFIRE_VERSION}"
  cd "arrayfire-${ARRAYFIRE_VERSION}"
  git submodule update --init --recursive

  # Compatibility patch for ArrayFire 3.9.0 with newer GCC/libstdc++
  # versions (e.g. GCC 13 on Ubuntu 24.04): std::isnan is available but
  # ::isnan may not be declared when compiling C++17 code.  This patch is
  # intentionally narrow and only touches the CUDA backend math helper that
  # fails during afcuda compilation.
  local af_cuda_math="src/backend/cuda/math.hpp"
  if [[ -f "${af_cuda_math}" ]]; then
    if grep -q '::isnan' "${af_cuda_math}"; then
      info "Patching ArrayFire CUDA math.hpp for GCC/libstdc++ isnan compatibility."
      sed -i 's/::isnan/std::isnan/g' "${af_cuda_math}"
    fi
  fi

  # CUDA 13 moved Thrust/CCCL headers under include/cccl and no longer exposes
  # some old internal Thrust headers used by ArrayFire 3.9.0. ArrayFire only
  # needs the public CUDA execution-policy header here, so replace the removed
  # internal include with the public one. This is intentionally narrow and is
  # applied only when the source contains the legacy include.
  local af_thrust_utils="src/backend/cuda/thrust_utils.hpp"
  if [[ -f "${af_thrust_utils}" ]]; then
    if grep -q 'thrust/system/cuda/detail/par.h' "${af_thrust_utils}"; then
      info "Patching ArrayFire thrust_utils.hpp for CUDA 13/CCCL Thrust header layout."
      sed -i 's#<thrust/system/cuda/detail/par.h>#<thrust/system/cuda/execution_policy.h>#' "${af_thrust_utils}"
    fi
  fi

  # CUDA 13/CCCL removed the legacy internal header
  # <thrust/system/cuda/detail/par.h>. ArrayFire 3.9.0 uses it in more than
  # one CUDA backend file, so patch any remaining occurrences after the
  # dedicated thrust_utils.hpp compatibility edit above. The replacement is the
  # public execution policy header, which is the same replacement already proven
  # for thrust_utils.hpp on this CUDA 13 build.
  local af_legacy_thrust_files
  af_legacy_thrust_files="$(grep -RIl 'thrust/system/cuda/detail/par.h' src/backend/cuda 2>/dev/null || true)"
  if [[ -n "${af_legacy_thrust_files}" ]]; then
    info "Patching remaining ArrayFire legacy Thrust par.h includes for CUDA 13/CCCL."
    while IFS= read -r af_legacy_file; do
      [[ -n "${af_legacy_file}" ]] || continue
      info "  ${af_legacy_file}"
      sed -i 's#<thrust/system/cuda/detail/par.h>#<thrust/system/cuda/execution_policy.h>#g' "${af_legacy_file}"
    done <<< "${af_legacy_thrust_files}"
  fi

  # CUDA 13/CCCL removed/changed visibility of a few legacy Thrust adapter
  # APIs used by ArrayFire 3.9.0.  The inheritance from thrust::unary_function
  # is only a deprecated typedef-style adapter and is not needed for the functor
  # itself, while thrust::distance simply needs its public header.
  local af_regions_hpp="src/backend/cuda/kernel/regions.hpp"
  if [[ -f "${af_regions_hpp}" ]]; then
    if grep -q 'thrust::unary_function' "${af_regions_hpp}"; then
      info "Patching ArrayFire regions.hpp for CUDA 13/CCCL thrust::unary_function removal."
      python3 - "${af_regions_hpp}" <<'PYEOF'
import pathlib
import re
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
new_text = re.sub(
    r'\s*:\s*public\s+thrust::unary_function\s*<\s*T\s*,\s*T\s*>',
    '',
    text,
)
if new_text == text:
    raise SystemExit("Could not patch thrust::unary_function in regions.hpp")
path.write_text(new_text)
PYEOF
    fi
  fi

  local af_set_cu="src/backend/cuda/set.cu"
  if [[ -f "${af_set_cu}" ]]; then
    if grep -q 'thrust::distance' "${af_set_cu}"        && ! grep -q '#include <thrust/distance.h>' "${af_set_cu}"; then
      info "Patching ArrayFire set.cu to include <thrust/distance.h> for CUDA 13/CCCL."
      python3 - "${af_set_cu}" <<'PYEOF'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
include = '#include <thrust/distance.h>\n'
if include in text:
    sys.exit(0)
lines = text.splitlines(True)
insert_at = 0
for i, line in enumerate(lines):
    if line.startswith('#include '):
        insert_at = i + 1
lines.insert(insert_at, include)
path.write_text(''.join(lines))
PYEOF
    fi
  fi

  # CUDA 13 removed the legacy cudaDeviceProp::clockRate field from
  # cudaDeviceProp. ArrayFire 3.9.0 only uses it to estimate a device GFLOP/s
  # score for sorting CUDA devices. Query the same value via the public runtime
  # attribute API on CUDA 13+, while preserving the old field path for older
  # toolkits.
  local af_device_manager_cpp="src/backend/cuda/device_manager.cpp"
  if [[ -f "${af_device_manager_cpp}" ]]; then
    if grep -q 'dev\.prop\.clockRate' "${af_device_manager_cpp}"; then
      info "Patching ArrayFire device_manager.cpp for CUDA 13 cudaDeviceProp::clockRate removal."
      python3 - "${af_device_manager_cpp}" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "af_cuda_clock_rate_khz" in text:
    sys.exit(0)
lines = text.splitlines(True)
out = []
inserted = False
replaced = False
for line in lines:
    if (not inserted) and "dev.flops" in line:
        indent = line[: len(line) - len(line.lstrip())]
        out.extend([
            f"{indent}int af_cuda_clock_rate_khz = 0;\n",
            f"{indent}#if defined(CUDA_VERSION) && CUDA_VERSION >= 13000\n",
            f"{indent}CUDA_CHECK(cudaDeviceGetAttribute(&af_cuda_clock_rate_khz,\n",
            f"{indent}                                     cudaDevAttrClockRate, i));\n",
            f"{indent}#else\n",
            f"{indent}af_cuda_clock_rate_khz = dev.prop.clockRate;\n",
            f"{indent}#endif\n",
        ])
        inserted = True
    if "dev.prop.clockRate" in line:
        line = line.replace("dev.prop.clockRate", "af_cuda_clock_rate_khz")
        replaced = True
    out.append(line)
new_text = ''.join(out)
if not inserted:
    raise SystemExit("Could not find dev.flops assignment in device_manager.cpp")
if not replaced:
    raise SystemExit("Could not replace dev.prop.clockRate in device_manager.cpp")
path.write_text(new_text)
PYEOF
    fi
  fi

  # Note: v22 had an optional CUDA 13/Blackwell runtime-table patch here.
  # It was removed in v23 because ArrayFire 3.9.0 source variants differ in
  # table names. The confirmed required CUDA 13 fix is the clock-rate patch above.

  # CUDA 13/CCCL no longer makes thrust::pair visible through the headers that
  # ArrayFire 3.9.0 includes indirectly. The type is still available when the
  # public <thrust/pair.h> header is included. Keep ArrayFire's code unchanged
  # and add the missing public include to its custom Thrust policy header.
  local af_thrust_policy="src/backend/cuda/ThrustArrayFirePolicy.hpp"
  if [[ -f "${af_thrust_policy}" ]]; then
    if grep -q 'thrust::pair' "${af_thrust_policy}" \
       && ! grep -q '#include <thrust/pair.h>' "${af_thrust_policy}"; then
      info "Patching ArrayFire ThrustArrayFirePolicy.hpp to include <thrust/pair.h> for CUDA 13/CCCL."
      sed -i '/#include <thrust\/memory.h>/a #include <thrust/pair.h>' "${af_thrust_policy}"
    fi
  fi

  # CUDA 13 removes/does not expose a few legacy cuFFT result enum values
  # that ArrayFire 3.9.0 still lists in its error-string switch. These values
  # are only used for human-readable diagnostics.  Patch the whole diagnostic
  # function rather than deleting individual case labels: this preserves the
  # surrounding source structure and avoids brittle sed range mistakes.
  local af_cufft="src/backend/cuda/cufft.cu"
  if [[ -f "${af_cufft}" ]]; then
    if grep -Eq 'CUFFT_INCOMPLETE_PARAMETER_LIST|CUFFT_PARSE_ERROR|CUFFT_LICENSE_ERROR' "${af_cufft}"; then
      info "Patching ArrayFire cufft.cu for CUDA 13 legacy cuFFT enum compatibility."
      python3 - "${af_cufft}" <<'PYEOF'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
replacement = '''const char *_cufftGetResultString(cufftResult res) {
    switch (res) {
        case CUFFT_SUCCESS: return "cuFFT: success";
        case CUFFT_INVALID_PLAN: return "cuFFT: invalid plan handle passed";
        case CUFFT_ALLOC_FAILED: return "cuFFT: resources allocation failed";
        case CUFFT_INVALID_TYPE: return "cuFFT: invalid type (deprecated)";
        case CUFFT_INVALID_VALUE:
            return "cuFFT: invalid parameters passed to cuFFT API";
        case CUFFT_INTERNAL_ERROR:
            return "cuFFT: internal error detected using cuFFT";
        case CUFFT_EXEC_FAILED: return "cuFFT: FFT execution failed";
        case CUFFT_SETUP_FAILED: return "cuFFT: library initialization failed";
        case CUFFT_INVALID_SIZE: return "cuFFT: invalid size parameters passed";
        case CUFFT_UNALIGNED_DATA: return "cuFFT: unaligned data (deprecated)";
        case CUFFT_INVALID_DEVICE:
            return "cuFFT: plan execution different than plan creation";
        case CUFFT_NO_WORKSPACE: return "cuFFT: no workspace provided";
        case CUFFT_NOT_IMPLEMENTED: return "cuFFT: not implemented";
#if CUDA_VERSION >= 8000
        case CUFFT_NOT_SUPPORTED: return "cuFFT: not supported";
#endif
    }

    return "cuFFT: unknown error";
}'''
pattern = re.compile(
    r'const char\s+\*_cufftGetResultString\s*\(\s*cufftResult\s+res\s*\)\s*\{.*?\n\}',
    re.S,
)
new_text, n = pattern.subn(replacement, text, count=1)
if n != 1:
    raise SystemExit("Could not locate exactly one _cufftGetResultString function in cufft.cu")
if new_text.count("{") != new_text.count("}"):
    raise SystemExit("Refusing to write cufft.cu: brace count mismatch after patch")
path.write_text(new_text)
PYEOF
    fi
  fi

  rm -rf build_cuda && mkdir -p build_cuda && cd build_cuda

  unset PKG_CONFIG_LIBDIR 2>/dev/null || true
  export PKG_CONFIG_PATH="${FFTW_ROOT}/lib/pkgconfig:${FMT_ROOT}/lib/pkgconfig"
  pkg-config --modversion fftw3 >/dev/null

  if [[ -z "${SPDLOG_CMAKE_DIR:-}" ]]; then
    local f
    f="$(find "${SPDLOG_ROOT}" -name spdlogConfig.cmake 2>/dev/null | head -n1 || true)"
    if [[ -n "${f}" ]]; then
      SPDLOG_CMAKE_DIR="$(dirname "${f}")"
      export SPDLOG_CMAKE_DIR
    fi
  fi
  local FMT_CMAKE_FILE FMT_CMAKE_DIR
  FMT_CMAKE_FILE="$(find "${FMT_ROOT}" \( -name 'fmtConfig.cmake' -o -name 'fmt-config.cmake' \) 2>/dev/null | head -n1 || true)"
  [[ -n "${FMT_CMAKE_FILE}" ]] || die "fmt CMake package not found under ${FMT_ROOT}. Rebuild from the fmt stage."
  FMT_CMAKE_DIR="$(dirname "${FMT_CMAKE_FILE}")"
  info "Using fmt CMake package: ${FMT_CMAKE_FILE}"

  local cuda_cccl_args=()
  if [[ -d "${CUDA_HOME}/include/cccl" ]]; then
    info "CUDA CCCL headers detected; adding ${CUDA_HOME}/include/cccl to ArrayFire C++/CUDA include paths."
    export CPATH="${CUDA_HOME}/include/cccl:${CPATH:-}"
    export CPLUS_INCLUDE_PATH="${CUDA_HOME}/include/cccl:${CPLUS_INCLUDE_PATH:-}"
    cuda_cccl_args+=("-DCMAKE_CUDA_FLAGS=-I${CUDA_HOME}/include/cccl ${CMAKE_CUDA_FLAGS:-}")
    cuda_cccl_args+=("-DCMAKE_CXX_FLAGS=-I${CUDA_HOME}/include/cccl ${CMAKE_CXX_FLAGS:-}")
  fi

  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${AF_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_STANDARD_REQUIRED=ON \
    -DCMAKE_CUDA_STANDARD=17 \
    -DCMAKE_CUDA_STANDARD_REQUIRED=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
    -DCMAKE_CUDA_COMPILER="${CUDACXX:-${CUDA_HOME}/bin/nvcc}" \
    -DCMAKE_PREFIX_PATH="${FMT_ROOT};${FFTW_ROOT};${BOOST_ROOT};${SPDLOG_ROOT};${CUDA_HOME}" \
    -DCMAKE_BUILD_RPATH="${FMT_ROOT}/lib;${FMT_ROOT}/lib64;${FFTW_ROOT}/lib;${CUDA_HOME}/lib64;${CUDA_HOME}/targets/x86_64-linux/lib" \
    -DCMAKE_INSTALL_RPATH="${FMT_ROOT}/lib;${FMT_ROOT}/lib64;${AF_ROOT}/lib;${AF_ROOT}/lib64;${FFTW_ROOT}/lib;${CUDA_HOME}/lib64;${CUDA_HOME}/targets/x86_64-linux/lib" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
    -DAF_BUILD_OPENCL=OFF \
    -DAF_BUILD_CPU=OFF \
    -DAF_BUILD_CUDA=ON \
    -DAF_BUILD_FORGE=OFF \
    -DFFTW_INCLUDE_DIR="${FFTW_ROOT}/include" \
    -DFFTWF_LIBRARY="${FFTW_ROOT}/lib/libfftw3f.so" \
    -DFFTW_LIBRARY="${FFTW_ROOT}/lib/libfftw3.so" \
    -DBOOST_ROOT="${BOOST_ROOT}" \
    -DBoost_INCLUDE_DIR="${BOOST_ROOT}/include" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DBoost_NO_BOOST_CMAKE=ON \
    -DCUDA_TOOLKIT_ROOT_DIR="${CUDA_HOME}" \
    -DNVPRUNE="${CUDA_HOME}/bin/nvprune" \
    -Dfmt_DIR="${FMT_CMAKE_DIR}" \
    ${SPDLOG_CMAKE_DIR:+-Dspdlog_DIR="${SPDLOG_CMAKE_DIR}"} \
    "${cuda_cccl_args[@]}" \
    "${cmake_iso[@]}"

  info "ArrayFire FFTW cache entries:"
  grep -i fftw CMakeCache.txt || true
  make -j"${NPROC}"
  make install

  [[ -f "${AF_ROOT}/include/arrayfire.h" ]] \
    || die "arrayfire.h not found after install."
  local af_installed_libdir="${AF_ROOT}/lib"
  [[ -e "${af_installed_libdir}/libafcuda.so" ]] || af_installed_libdir="${AF_ROOT}/lib64"
  [[ -e "${af_installed_libdir}/libafcuda.so" ]] \
    || die "ArrayFire CUDA library not found under ${AF_ROOT}/lib or ${AF_ROOT}/lib64."
  assert_no_missing_libs "${af_installed_libdir}/libafcuda.so" "ArrayFire CUDA library"
  ok "ArrayFire installed at ${AF_ROOT} (${af_installed_libdir})"
  mark_stage_done arrayfire
}


# PLUMED's python interface build runs "python3 -m build". Some HPC Python
# installations lack the Debian/Ubuntu python3-venv/ensurepip package, so a
# normal "python3 -m venv" may fail without root privileges. Prefer a local
# --target installation using pip when available, and fall back to venv only
# if the system Python supports it. Nothing is installed system-wide.
ensure_python_build_module() {
  if command -v python3 >/dev/null 2>&1 \
     && python3 - <<'PYEOF' >/dev/null 2>&1
import build.__main__  # noqa: F401
PYEOF
  then
    ok "python3 can already run 'python3 -m build'."
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || die "python3 is required to build PLUMED."

  local pybuild_target="${INSTALL_ROOT}/pybuild_packages"
  local pybuild_prefix="${INSTALL_ROOT}/pybuild_pip"
  local getpip pip_cmd_str pip_site pip_exe

  _try_import_build() {
    python3 - <<'PYEOF' >/dev/null 2>&1
import build.__main__  # noqa: F401
PYEOF
  }

  _find_private_pip_site() {
    find "${pybuild_prefix}" -type d \
      \( -path '*/python*/site-packages/pip' -o -path '*/python*/dist-packages/pip' \) \
      -print 2>/dev/null | head -n1 | xargs -r dirname
  }

  _find_private_pip_exe() {
    find "${pybuild_prefix}/bin" -maxdepth 1 -type f \
      \( -name 'pip' -o -name 'pip3' -o -name 'pip3.*' \) \
      -print 2>/dev/null | sort | head -n1
  }

  _try_install_build_with_cmd() {
    # $1 is a shell command string, e.g. "python3 -m pip" or "/path/pip3".
    local cmd="$1"
    rm -rf "${pybuild_target}"
    mkdir -p "${pybuild_target}"
    # PIP_BREAK_SYSTEM_PACKAGES avoids Debian/Ubuntu PEP668 blocking local installs.
    if PIP_BREAK_SYSTEM_PACKAGES=1 ${cmd} install --upgrade \
         --target "${pybuild_target}" --no-warn-script-location \
         build setuptools wheel; then
      export PYTHONPATH="${pybuild_target}:${PYTHONPATH:-}"
      if _try_import_build; then
        ok "Using local Python build package directory: ${pybuild_target}"
        return 0
      fi
      warn "pip install completed, but python3 still cannot import build.__main__."
    fi
    return 1
  }

  if python3 -m pip --version >/dev/null 2>&1; then
    warn "python3 cannot run 'python3 -m build'; installing Python build tooling locally with python3 -m pip."
    _try_install_build_with_cmd "python3 -m pip" && return 0
  elif command -v pip3 >/dev/null 2>&1; then
    warn "python3 cannot run 'python3 -m build'; installing Python build tooling locally with pip3."
    _try_install_build_with_cmd "pip3" && return 0
  else
    warn "No python3 -m pip or pip3 found; bootstrapping a private pip without root."
  fi

  # Rootless pip bootstrap for minimal Debian/Ubuntu Python installs that lack
  # python3-pip and python3-venv. This requires outbound HTTPS, which the build
  # already needs for source downloads.
  rm -rf "${pybuild_prefix}"
  mkdir -p "${pybuild_prefix}" "${SRC}"
  getpip="${SRC}/get-pip.py"
  if [[ ! -f "${getpip}" ]]; then
    if command -v wget >/dev/null 2>&1; then
      wget -O "${getpip}" https://bootstrap.pypa.io/get-pip.py
    elif command -v curl >/dev/null 2>&1; then
      curl -fL -o "${getpip}" https://bootstrap.pypa.io/get-pip.py
    else
      die "Neither wget nor curl is available to bootstrap pip."
    fi
  fi

  # Install private pip under pybuild_pip. On this HPC, the prefix install puts
  # packages under .../local/lib/pythonX.Y/dist-packages, not always site-packages.
  if ! python3 "${getpip}" --prefix "${pybuild_prefix}" --no-warn-script-location pip setuptools wheel; then
    warn "get-pip prefix install failed; retrying with --break-system-packages."
    python3 "${getpip}" --prefix "${pybuild_prefix}" --break-system-packages \
      --no-warn-script-location pip setuptools wheel \
      || die "Could not bootstrap pip into ${pybuild_prefix}."
  fi

  pip_site="$(_find_private_pip_site || true)"
  if [[ -n "${pip_site}" ]]; then
    export PYTHONPATH="${pip_site}:${PYTHONPATH:-}"
    info "Private pip Python path: ${pip_site}"
  else
    warn "Could not locate the private pip package directory under ${pybuild_prefix}."
  fi
  export PATH="${pybuild_prefix}/bin:${pybuild_prefix}/local/bin:${PATH}"

  if python3 -m pip --version >/dev/null 2>&1; then
    _try_install_build_with_cmd "python3 -m pip" && return 0
  fi

  pip_exe="$(_find_private_pip_exe || true)"
  if [[ -n "${pip_exe}" ]]; then
    info "Trying private pip executable: ${pip_exe}"
    _try_install_build_with_cmd "${pip_exe}" && return 0
  fi

  # Last fallback: try venv if the system has ensurepip after all.
  local pybuild_env="${INSTALL_ROOT}/pybuild"
  rm -rf "${pybuild_env}"
  if python3 -m venv "${pybuild_env}" >/dev/null 2>&1; then
    "${pybuild_env}/bin/python" -m pip install --upgrade pip setuptools wheel build \
      || die "Could not install Python build tooling into ${pybuild_env}."
    "${pybuild_env}/bin/python" - <<'PYEOF'
import build.__main__  # noqa: F401
PYEOF
    export PATH="${pybuild_env}/bin:${PATH}"
    ok "Using private Python build environment: ${pybuild_env}"
    return 0
  fi

  die "Could not provide the Python 'build' module without root privileges. Manual fallback: install a user Python with pip, then rerun from the plumed stage."
}


resolve_plumed_patch_dir() {
  if [[ "${PLUMED_PATCH_DIR}" == "auto" || -z "${PLUMED_PATCH_DIR}" ]]; then
    # v12 default: prefer a patch folder shipped next to the installer script.
    # This lets a fresh installation pick up local SAXS.cpp changes before the
    # first PLUMED compilation, avoiding install-then-recompile workflows.
    local script_patch install_patch
    script_patch="${SCRIPT_DIR}/plumed_patch"
    install_patch="${INSTALL_ROOT}/plumed_patch"
    if [[ -d "${script_patch}" ]]; then
      printf '%s\n' "${script_patch}"
    elif [[ -d "${install_patch}" ]]; then
      printf '%s\n' "${install_patch}"
    else
      printf '%s\n' "${script_patch}"
    fi
  else
    abspath "${PLUMED_PATCH_DIR}"
  fi
}

apply_plumed_local_patches() {
  # apply_plumed_local_patches <plumed-source-tree>
  # Currently supports a development override for src/isdb/SAXS.cpp.
  local plumed_src="${1}"
  local patch_dir candidate target backup_dir

  patch_dir="$(resolve_plumed_patch_dir)"
  target="${plumed_src}/src/isdb/SAXS.cpp"
  candidate=""

  if [[ -n "${PLUMED_SAXS_CPP}" ]]; then
    candidate="$(abspath "${PLUMED_SAXS_CPP}")"
  elif [[ -f "${patch_dir}/SAXS.cpp" ]]; then
    candidate="${patch_dir}/SAXS.cpp"
  elif [[ -f "${patch_dir}/src/isdb/SAXS.cpp" ]]; then
    candidate="${patch_dir}/src/isdb/SAXS.cpp"
  fi

  if [[ -n "${candidate}" ]]; then
    [[ -f "${candidate}" ]] || die "Configured SAXS.cpp override not found: ${candidate}"
    [[ -f "${target}" ]] || die "PLUMED SAXS.cpp target not found: ${target}"
    backup_dir="${plumed_src}/.local_patch_backups/src/isdb"
    mkdir -p "${backup_dir}"
    cp "${target}" "${backup_dir}/SAXS.cpp.orig.$(date +%Y%m%d_%H%M%S)"
    cp "${candidate}" "${target}"
    info "Applied local SAXS.cpp override: ${candidate} -> ${target}"
    return 0
  fi

  if [[ -d "${patch_dir}" ]]; then
    info "Local PLUMED patch dir exists but no SAXS.cpp override was found: ${patch_dir}"
  else
    info "No local PLUMED patch dir found at ${patch_dir}; using upstream PLUMED SAXS.cpp."
  fi
}

stage_plumed() {
  section "PLUMED (FFTW + ArrayFire CUDA + ISDB/SAXS, ref=${PLUMED_REF})"
  unset PLUMED_PREFIX PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"
  mkdir -p "${PLUMED_ROOT}"
  export PATH="${MPI_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${AF_ROOT}/lib:${AF_ROOT}/lib64:${FFTW_ROOT}/lib:${FMT_ROOT}/lib:${FMT_ROOT}/lib64:${MPI_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
  unset PKG_CONFIG_LIBDIR 2>/dev/null || true
  export PKG_CONFIG_PATH="${FFTW_ROOT}/lib/pkgconfig:${FMT_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  local plumed_python_config=()
  if [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]]; then
    info "Disabling PLUMED Python wrappers (--disable-python); core PLUMED/GROMACS integration does not need Python.h."
    plumed_python_config=(--disable-python)
  else
    ensure_python_build_module
  fi

  local plumed_src="${SRC}/plumed2"
  cd "${SRC}"
  rm -rf "${plumed_src}"
  git clone --recursive "${PLUMED_REPO}" "${plumed_src}"
  cd "${plumed_src}"
  if [[ "${PLUMED_REF}" != "master" ]]; then
    git checkout "${PLUMED_REF}"
    git submodule update --init --recursive
  fi
  info "PLUMED commit: $(git rev-parse HEAD)"
  make distclean 2>/dev/null || true
  apply_plumed_local_patches "${plumed_src}"

  # PLUMED's configure check for ArrayFire is easy to miss: without an
  # explicit LIBS value it may find arrayfire.h but fail the af_is_double link
  # test, then silently continue without __PLUMED_HAS_ARRAYFIRE.  For SAXS this
  # is fatal, so first prove a small program can link against the installed
  # ArrayFire libraries and then pass exactly those libraries to configure.
  local af_libdir="${AF_ROOT}/lib"
  [[ -d "${af_libdir}" ]] || af_libdir="${AF_ROOT}/lib64"
  [[ -d "${af_libdir}" ]] || die "ArrayFire library directory not found under ${AF_ROOT}"
  [[ -f "${af_libdir}/libafcuda.so" ]] || die "ArrayFire CUDA library not found: ${af_libdir}/libafcuda.so"

  local af_probe_src="${plumed_src}/arrayfire_link_probe.cpp"
  local af_probe_bin="${plumed_src}/arrayfire_link_probe.exe"
  cat > "${af_probe_src}" <<'EOF_AF_LINK_PROBE'
#include <arrayfire.h>
int main() {
    (void)&af_is_double;
    return 0;
}
EOF_AF_LINK_PROBE

  local plumed_cppflags="-I${AF_ROOT}/include -I${FFTW_ROOT}/include -I${CUDA_HOME}/include -I${CUDA_HOME}/targets/x86_64-linux/include"
  local plumed_ldflags="-L${af_libdir} -Wl,-rpath,${af_libdir} -L${FFTW_ROOT}/lib -Wl,-rpath,${FFTW_ROOT}/lib -L${FMT_ROOT}/lib -Wl,-rpath,${FMT_ROOT}/lib -L${FMT_ROOT}/lib64 -Wl,-rpath,${FMT_ROOT}/lib64 -L${MPI_ROOT}/lib -Wl,-rpath,${MPI_ROOT}/lib -L${CUDA_HOME}/lib64 -Wl,-rpath,${CUDA_HOME}/lib64 -L${CUDA_HOME}/targets/x86_64-linux/lib -Wl,-rpath,${CUDA_HOME}/targets/x86_64-linux/lib"
  local arrayfire_libs=""
  local candidate_libs
  local af_link_log="${plumed_src}/arrayfire_link_probe.log"
  : > "${af_link_log}"
  for candidate_libs in \
      "-lafcuda -laf -lstdc++" \
      "-laf -lafcuda -lstdc++" \
      "-lafcuda -lstdc++" \
      "-laf -lstdc++"; do
    info "Testing PLUMED ArrayFire link flags: ${candidate_libs}"
    if env LD_LIBRARY_PATH="${af_libdir}:${LD_LIBRARY_PATH:-}" \
      "${MPI_ROOT}/bin/mpicxx" ${plumed_cppflags} "${af_probe_src}" \
      ${plumed_ldflags} ${candidate_libs} -o "${af_probe_bin}" \
      >> "${af_link_log}" 2>&1; then
      arrayfire_libs="${candidate_libs}"
      break
    fi
  done

  if [[ -z "${arrayfire_libs}" ]]; then
    warn "PLUMED ArrayFire link probe failed. Last link output:"
    tail -n 120 "${af_link_log}" || true
    warn "Installed ArrayFire libraries:"
    ls -lh "${af_libdir}"/libaf*.so* 2>/dev/null || true
    if command -v nm >/dev/null 2>&1; then
      warn "af_is_double symbols visible in ArrayFire libraries:"
      nm -D "${af_libdir}"/libaf*.so* 2>/dev/null | grep 'af_is_double' || true
    fi
    warn "ldd on libafcuda.so:"
    ldd "${af_libdir}/libafcuda.so" || true
    die "Cannot link a test program against ArrayFire; refusing to build PLUMED without ArrayFire support."
  fi
  ok "PLUMED ArrayFire link probe passed with LIBS='${arrayfire_libs}'."

  export LIBRARY_PATH="${af_libdir}:${FFTW_ROOT}/lib:${FMT_ROOT}/lib:${FMT_ROOT}/lib64:${MPI_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LIBRARY_PATH:-}"
  local plumed_configure_log="${plumed_src}/configure_plumed_arrayfire.log"

  env LIBS="${arrayfire_libs}" ./configure \
    --prefix="${PLUMED_ROOT}" \
    CC="${MPI_ROOT}/bin/mpicc" \
    CXX="${MPI_ROOT}/bin/mpicxx" \
    CFLAGS="-O3 -Wno-error" \
    CXXFLAGS="-O3 -Wno-error" \
    --enable-modules=all \
    --disable-basic-warnings \
    --enable-asmjit \
    --enable-fftw \
    --enable-af_cuda \
    "${plumed_python_config[@]}" \
    --verbose \
    CPPFLAGS="${plumed_cppflags}" \
    LDFLAGS="${plumed_ldflags}" \
    2>&1 | tee "${plumed_configure_log}"

  info "Requested PLUMED features after configure:"
  grep -E "has arrayfire|has arrayfire_cuda|has fftw|has mpi|module isdb|__PLUMED_HAS_ARRAYFIRE" \
    src/config/config.txt src/config/config.h "${plumed_configure_log}" 2>/dev/null || true

  if grep -Eq "cannot enable __PLUMED_HAS_ARRAYFIRE(_CUDA)?" "${plumed_configure_log}" config.log 2>/dev/null; then
    die "PLUMED configure could not enable ArrayFire/ArrayFire-CUDA; refusing to continue because SAXS requires it. See ${plumed_configure_log}"
  fi

  local plumed_af_ok=0 plumed_af_cuda_ok=0
  if grep -R -Eq '(^|[[:space:]])#define[[:space:]]+__PLUMED_HAS_ARRAYFIRE[[:space:]]+1|(^|[[:space:]])__PLUMED_HAS_ARRAYFIRE([[:space:]=]|$)|has arrayfire([^_[:alnum:]]|[[:space:]]).*yes' src/config "${plumed_configure_log}" config.log 2>/dev/null; then
    plumed_af_ok=1
  fi
  if grep -R -Eq '(^|[[:space:]])#define[[:space:]]+__PLUMED_HAS_ARRAYFIRE_CUDA[[:space:]]+1|(^|[[:space:]])__PLUMED_HAS_ARRAYFIRE_CUDA([[:space:]=]|$)|has arrayfire_cuda([^[:alnum:]]|[[:space:]]).*yes' src/config "${plumed_configure_log}" config.log 2>/dev/null; then
    plumed_af_cuda_ok=1
  fi
  [[ "${plumed_af_ok}" -eq 1 ]] || die "PLUMED configured without __PLUMED_HAS_ARRAYFIRE; stopping instead of installing a useless SAXS build."
  [[ "${plumed_af_cuda_ok}" -eq 1 ]] || die "PLUMED configured without __PLUMED_HAS_ARRAYFIRE_CUDA; stopping instead of installing a useless SAXS build."
  ok "PLUMED configure enabled ArrayFire and ArrayFire-CUDA."
  # Do not let PLUMED runtime environment variables leak into the build-tree
  # executable used for generated files such as json/syntax.json.
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make -j"${NPROC}"
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make install
  ok "PLUMED installed at ${PLUMED_ROOT}"
  mark_stage_done plumed
}



compiler_version_string() {
  # compiler_version_string <compiler-or-wrapper>
  # Prints the first version-like token from '<cmd> --version'.
  local cmd="${1}" out ver
  out="$(${cmd} --version 2>/dev/null | head -n1 || true)"
  ver="$(printf '%s\n' "${out}" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
  printf '%s\n' "${ver}"
}

mpi_cxx_compiler_version_string() {
  # Prefer the compiler behind the OpenMPI wrapper when available, because that
  # is what CMake/GROMACS will identify during configuration.
  local wrapper="${MPI_ROOT}/bin/mpicxx" cmd ver
  if [[ -x "${wrapper}" ]]; then
    cmd="$(${wrapper} --showme:command 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "${cmd}" ]] && command -v "${cmd}" >/dev/null 2>&1; then
      ver="$(compiler_version_string "${cmd}")"
      [[ -n "${ver}" ]] && { printf '%s\n' "${ver}"; return 0; }
    fi
    ver="$(compiler_version_string "${wrapper}")"
    [[ -n "${ver}" ]] && { printf '%s\n' "${ver}"; return 0; }
  fi

  if command -v g++ >/dev/null 2>&1; then
    compiler_version_string "g++"
  fi
}

ensure_cmake_for_selected_gromacs() {
  local cmake_ver min msg
  command -v cmake >/dev/null 2>&1 || die "cmake not found; cannot configure GROMACS."
  cmake_ver="$(cmake --version | head -n1 | awk '{print $3}')"
  case "${GROMACS_VERSION}" in
    2025*) min="3.28";   msg="GROMACS ${GROMACS_VERSION} requires CMake 3.28+." ;;
    2024*) min="3.18.4"; msg="GROMACS ${GROMACS_VERSION} requires CMake 3.18.4+." ;;
    *)     min="3.18.4"; msg="GROMACS ${GROMACS_VERSION} requires a recent CMake." ;;
  esac
  version_ge "${cmake_ver}" "${min}" || die "CMake ${cmake_ver} detected; ${msg}"
}

resolve_gromacs_selection() {
  # Resolves GROMACS_VERSION, PLUMED_GROMACS_PATCH and source URLs.
  # In auto mode, choose the newest GROMACS branch that the available toolchain
  # can configure: GROMACS 2025 requires both GCC/G++ >=11 and CUDA >=12.1.
  # On systems with CUDA 12.0, fall back to GROMACS 2024.6.
  local ver major reason=""
  if [[ "${GROMACS_VERSION}" == "auto" ]]; then
    ver="$(mpi_cxx_compiler_version_string || true)"
    major="${ver%%.*}"

    if [[ -n "${ver}" && "${major}" =~ ^[0-9]+$ && "${major}" -lt 11 ]]; then
      reason="GCC/G++ ${ver} is older than 11"
    elif ! version_ge "${CUDA_VERSION}" "12.1"; then
      reason="CUDA ${CUDA_VERSION} is older than 12.1"
    fi

    if [[ -n "${reason}" ]]; then
      GROMACS_VERSION="2024.6"
      info "${reason}; selecting GROMACS ${GROMACS_VERSION} fallback."
    else
      GROMACS_VERSION="2025.4"
      if [[ -n "${ver}" ]]; then
        info "Detected GCC/G++ ${ver} and CUDA ${CUDA_VERSION}; selecting GROMACS ${GROMACS_VERSION}."
      else
        warn "Could not determine compiler version, but CUDA ${CUDA_VERSION} is >=12.1; defaulting to GROMACS ${GROMACS_VERSION}."
      fi
    fi
  fi

  if [[ "${GROMACS_VERSION}" == 2025* ]] && ! version_ge "${CUDA_VERSION}" "12.1"; then
    die "GROMACS ${GROMACS_VERSION} with CUDA requires CUDA >=12.1, but CUDA ${CUDA_VERSION} was detected. Use --gromacs-version 2024.6 --gromacs-patch gromacs-2024.3, or install/load CUDA >=12.1."
  fi

  if [[ "${PLUMED_GROMACS_PATCH}" == "auto" || -z "${PLUMED_GROMACS_PATCH}" ]]; then
    case "${GROMACS_VERSION}" in
      2024*) PLUMED_GROMACS_PATCH="gromacs-2024.3" ;;
      2025*) PLUMED_GROMACS_PATCH="gromacs-2025.0" ;;
      *) die "Cannot auto-select PLUMED GROMACS patch for GROMACS_VERSION='${GROMACS_VERSION}'. Pass --gromacs-patch explicitly." ;;
    esac
  fi

  GROMACS_URL="${GROMACS_URL:-https://ftp.gromacs.org/gromacs/gromacs-${GROMACS_VERSION}.tar.gz}"
  GROMACS_FTP_URL="${GROMACS_FTP_URL:-ftp://ftp.gromacs.org/gromacs/gromacs-${GROMACS_VERSION}.tar.gz}"
}

patch_gromacs_with_plumed() {
  local engine="${1}"

  if command -v plumed-patch >/dev/null 2>&1; then
    plumed-patch -p -e "${engine}"
  elif command -v plumed >/dev/null 2>&1; then
    plumed patch -p -e "${engine}"
  else
    die "Neither plumed-patch nor plumed is on PATH; activate/rebuild PLUMED before the GROMACS stage."
  fi
}

stage_gromacs() {
  resolve_gromacs_selection
  ensure_cmake_for_selected_gromacs
  section "GROMACS ${GROMACS_VERSION} (PLUMED-patched with ${PLUMED_GROMACS_PATCH}, MPI + CUDA, SIMD=${GMX_SIMD})"
  local plumed_prefix="${INSTALL_ROOT}/plumed"
  local plumed_runtime_root="${plumed_prefix}/lib/plumed"
  local plumed_kernel="${plumed_prefix}/lib/libplumedKernel.so"
  local gmx_tarball="gromacs-${GROMACS_VERSION}.tar.gz"
  local gmx_src="${SRC}/gromacs-${GROMACS_VERSION}"

  [[ -x "${plumed_prefix}/bin/plumed" ]] \
    || die "PLUMED executable not found at ${plumed_prefix}/bin/plumed. Build the plumed stage first."
  [[ -f "${plumed_kernel}" ]] \
    || die "PLUMED kernel not found at ${plumed_kernel}. Build/fix the plumed stage first."

  export PATH="${plumed_prefix}/bin:${MPI_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${plumed_prefix}/lib:${AF_ROOT}/lib:${AF_ROOT}/lib64:${FFTW_ROOT}/lib:${FMT_ROOT}/lib:${FMT_ROOT}/lib64:${MPI_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${plumed_prefix}/lib/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${FMT_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="${plumed_prefix}:${FFTW_ROOT}:${MPI_ROOT}:${CUDA_HOME}:${CMAKE_PREFIX_PATH:-}"

  cd "${SRC}"
  download_first_available "${gmx_tarball}" "${GROMACS_URL}" "${GROMACS_FTP_URL}"
  rm -rf "${gmx_src}"
  tar -xf "${gmx_tarball}"

  cd "${gmx_src}"
  info "Patching GROMACS with PLUMED engine '${PLUMED_GROMACS_PATCH}'."
  (
    export PLUMED_PREFIX="${plumed_prefix}"
    export PLUMED_ROOT="${plumed_runtime_root}"
    export PLUMED_KERNEL="${plumed_kernel}"
    patch_gromacs_with_plumed "${PLUMED_GROMACS_PATCH}"
  )

  rm -rf build
  mkdir -p build
  cd build

  local nvml_args=()
  if [[ -f "${CUDA_HOME}/include/nvml.h" ]]; then
    nvml_args+=("-DNVML_INCLUDE_DIR=${CUDA_HOME}/include")
  elif [[ -f "${CUDA_HOME}/targets/x86_64-linux/include/nvml.h" ]]; then
    nvml_args+=("-DNVML_INCLUDE_DIR=${CUDA_HOME}/targets/x86_64-linux/include")
  fi
  if [[ -f "${CUDA_HOME}/lib64/stubs/libnvidia-ml.so" ]]; then
    nvml_args+=("-DNVML_LIBRARY=${CUDA_HOME}/lib64/stubs/libnvidia-ml.so")
  elif [[ -f "${CUDA_HOME}/targets/x86_64-linux/lib/stubs/libnvidia-ml.so" ]]; then
    nvml_args+=("-DNVML_LIBRARY=${CUDA_HOME}/targets/x86_64-linux/lib/stubs/libnvidia-ml.so")
  fi

  local cuda_cccl_args=()
  if [[ -d "${CUDA_HOME}/include/cccl" ]]; then
    info "CUDA CCCL headers detected; adding ${CUDA_HOME}/include/cccl to GROMACS CUDA include paths."
    cuda_cccl_args+=("-DCMAKE_CUDA_FLAGS=-I${CUDA_HOME}/include/cccl ${CMAKE_CUDA_FLAGS:-}")
  fi

  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${GMX_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_STANDARD=17 \
    -DCMAKE_CUDA_STANDARD_REQUIRED=ON \
    -DCMAKE_C_COMPILER="${MPI_ROOT}/bin/mpicc" \
    -DCMAKE_CXX_COMPILER="${MPI_ROOT}/bin/mpicxx" \
    -DCMAKE_CUDA_COMPILER="${CUDACXX:-${CUDA_HOME}/bin/nvcc}" \
    -DGMX_MPI=ON \
    -DGMX_THREAD_MPI=OFF \
    -DGMX_GPU=CUDA \
    -DGMX_USE_PLUMED=ON \
    -DGMX_FFT_LIBRARY=fftw3 \
    -DFFTWF_INCLUDE_DIR="${FFTW_ROOT}/include" \
    -DFFTWF_LIBRARY="${FFTW_ROOT}/lib/libfftw3f.so" \
    -DGMX_SIMD="${GMX_SIMD}" \
    -DGMXAPI=OFF \
    -DGMX_INSTALL_LEGACY_API=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DGMX_INSTALL_NBLIB_API=ON \
    -DREGRESSIONTEST_DOWNLOAD=OFF \
    -DCUDA_TOOLKIT_ROOT_DIR="${CUDA_HOME}" \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
    -DCMAKE_PREFIX_PATH="${plumed_prefix};${FFTW_ROOT};${MPI_ROOT};${CUDA_HOME}" \
    -DCMAKE_BUILD_RPATH="${plumed_prefix}/lib;${FFTW_ROOT}/lib;${MPI_ROOT}/lib;${CUDA_HOME}/lib64;${CUDA_HOME}/targets/x86_64-linux/lib" \
    -DCMAKE_INSTALL_RPATH="${plumed_prefix}/lib;${FFTW_ROOT}/lib;${MPI_ROOT}/lib;${CUDA_HOME}/lib64;${CUDA_HOME}/targets/x86_64-linux/lib" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
    "${nvml_args[@]}" \
    "${cuda_cccl_args[@]}" \
    "${cmake_iso[@]}"

  info "GROMACS PLUMED/CUDA/MPI cache entries:"
  grep -Ei "GMX_USE_PLUMED|GMX_MPI|GMX_THREAD_MPI|GMX_GPU|CUDA|FFTWF|NVML" CMakeCache.txt || true

  make -j"${NPROC}"
  make install

  [[ -x "${GMX_ROOT}/bin/gmx_mpi" ]] \
    || die "gmx_mpi not found after GROMACS install."
  ok "GROMACS installed at ${GMX_ROOT}"
  mark_stage_done gromacs
}

run_stage() {
  local stage="${1}"
  case "${stage}" in
    openmpi)   stage_openmpi   ;;
    fftw)      stage_fftw      ;;
    boost)     stage_boost     ;;
    fmt)       stage_fmt       ;;
    spdlog)    stage_spdlog    ;;
    arrayfire) stage_arrayfire ;;
    plumed)    stage_plumed    ;;
    gromacs)  stage_gromacs  ;;
    *) die "Unknown stage '${stage}'" ;;
  esac
}

###############################################################################
# Final checks
###############################################################################
final_checks() {
  section "Final PLUMED checks"
  command -v plumed >/dev/null 2>&1 || die "plumed not found on PATH after build."
  plumed --is-installed
  plumed --has-mpi   || warn "plumed reports no MPI."
  plumed --has-dlopen || true

  [[ -f "${PLUMED_KERNEL}" ]] || die "PLUMED kernel not found: ${PLUMED_KERNEL}"
  info "PLUMED kernel link check:"
  assert_no_missing_libs "${PLUMED_KERNEL}" "PLUMED kernel"
  ok "PLUMED runtime libraries resolved."
}


final_gromacs_checks() {
  section "Final GROMACS checks"
  if [[ ! -x "${GMX_ROOT}/bin/gmx_mpi" ]]; then
    warn "gmx_mpi not found; skipping final GROMACS checks."
    return 0
  fi

  local plumed_prefix="${INSTALL_ROOT}/plumed"
  (
    # Do not source GMXRC here: this installer runs with `set -u`, while some
    # GROMACS GMXRC variants intentionally reference optional variables before
    # defining them.  Export the needed runtime paths explicitly instead.
    export GROMACS_DIR="${GMX_ROOT}"
    export GMXBIN="${GMX_ROOT}/bin"
    export GMXLDLIB="${GMX_ROOT}/lib"
    export GMXMAN="${GMX_ROOT}/share/man"
    export GMXDATA="${GMX_ROOT}/share/gromacs"
    export PATH="${GMX_ROOT}/bin:${plumed_prefix}/bin:${MPI_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${plumed_prefix}/lib:${LD_LIBRARY_PATH:-}"
    export PLUMED_PREFIX="${plumed_prefix}"
    export PLUMED_ROOT="${PLUMED_PREFIX}/lib/plumed"
    export PLUMED_KERNEL="${PLUMED_PREFIX}/lib/libplumedKernel.so"
    export AF_DISABLE_GRAPHICS="${AF_DISABLE_GRAPHICS:-1}"

    gmx_mpi --version | grep -Ei "GROMACS version|MPI|GPU|CUDA|PLUMED" || true
  )
  ok "GROMACS runtime check completed. Use: gmx_mpi mdrun -plumed plumed.dat"
}

postflight_stack_checks() {
  section "Post-flight stack sanity checks"
  local failures=0
  _pf_ok_file() {
    if [[ -e "$1" ]]; then ok "$2"; else warn "$2 missing: $1"; failures=$((failures + 1)); fi
  }
  _pf_ok_exe() {
    if [[ -x "$1" ]]; then ok "$2"; else warn "$2 missing/not executable: $1"; failures=$((failures + 1)); fi
  }

  if stage_done openmpi || [[ -x "${MPI_ROOT}/bin/mpicc" ]]; then _pf_ok_exe "${MPI_ROOT}/bin/mpicc" "OpenMPI mpicc"; fi
  if stage_done fftw || [[ -e "${FFTW_ROOT}/lib/libfftw3f.so" ]]; then _pf_ok_file "${FFTW_ROOT}/lib/libfftw3f.so" "FFTW single-precision library"; fi
  local af_pf_lib=""
  if [[ -e "${AF_ROOT}/lib/libafcuda.so" ]]; then
    af_pf_lib="${AF_ROOT}/lib/libafcuda.so"
  elif [[ -e "${AF_ROOT}/lib64/libafcuda.so" ]]; then
    af_pf_lib="${AF_ROOT}/lib64/libafcuda.so"
  else
    af_pf_lib="$(find "${AF_ROOT}" -maxdepth 3 -name 'libafcuda.so*' -print 2>/dev/null | sort | head -n1 || true)"
  fi
  if stage_done arrayfire || [[ -n "${af_pf_lib}" ]]; then
    if [[ -n "${af_pf_lib}" ]]; then
      _pf_ok_file "${af_pf_lib}" "ArrayFire CUDA library"
    else
      warn "ArrayFire CUDA library missing under ${AF_ROOT}/lib or ${AF_ROOT}/lib64"; failures=$((failures + 1))
    fi
  fi
  if stage_done plumed || [[ -x "${PLUMED_ROOT}/bin/plumed" ]]; then
    _pf_ok_exe "${PLUMED_ROOT}/bin/plumed" "PLUMED executable"
    _pf_ok_file "${PLUMED_ROOT}/lib/libplumedKernel.so" "PLUMED kernel"
    if [[ "${PLUMED_GROMACS_PATCH}" != "auto" && -n "${PLUMED_GROMACS_PATCH}" ]]; then
      _pf_ok_file "${PLUMED_ROOT}/lib/plumed/patches/${PLUMED_GROMACS_PATCH}.diff" "PLUMED GROMACS patch file (${PLUMED_GROMACS_PATCH})"
    fi
  fi
  if [[ -x "${GMX_ROOT}/bin/gmx_mpi" ]]; then
    _pf_ok_exe "${GMX_ROOT}/bin/gmx_mpi" "GROMACS MPI executable"
    assert_no_missing_libs "${GMX_ROOT}/bin/gmx_mpi" "GROMACS executable"
  else
    warn "GROMACS executable not present; this is expected if the gromacs stage was not built."
  fi

  if [[ -f "${PLUMED_ROOT}/lib/plumed/src/config/config.txt" ]]; then
    grep -Ei "has arrayfire|has arrayfire_cuda|has fftw|has mpi|module isdb"       "${PLUMED_ROOT}/lib/plumed/src/config/config.txt" || true
  fi

  if [[ "${failures}" -gt 0 ]]; then
    warn "Post-flight found ${failures} missing expected file(s). Check the stage plan if you intentionally built only a subset."
  else
    ok "Post-flight checks completed."
  fi
}

###############################################################################
# Activation script + shell rc integration (requirement #4)
###############################################################################
generate_activate_script() {
  local out="${INSTALL_ROOT}/activate.sh"
  cat > "${out}" <<EOF
#!/usr/bin/env bash
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date).
# Activate the '${NAME}' CUDA/PLUMED/GROMACS build environment:  source "${out}"

export CUDA_HOME="${CUDA_HOME}"
export CUDA_ROOT="\${CUDA_HOME}"
export CUDACXX="\${CUDA_HOME}/bin/nvcc"
export MPI_ROOT="${MPI_ROOT}"
export FFTW_ROOT="${FFTW_ROOT}"
export BOOST_ROOT="${BOOST_ROOT}"
export FMT_ROOT="${FMT_ROOT}"
export SPDLOG_ROOT="${SPDLOG_ROOT}"
export AF_ROOT="${AF_ROOT}"
export GMX_ROOT="${GMX_ROOT}"

# PLUMED installs executable/library files under the prefix, but its runtime
# data tree (patches/, scripts/, json/, vim/) lives under lib/plumed.
# Setting PLUMED_ROOT to the prefix makes "plumed" look for missing
# <prefix>/patches and <prefix>/scripts directories, so keep these separate.
export PLUMED_PREFIX="${PLUMED_ROOT}"
export PLUMED_ROOT="\${PLUMED_PREFIX}/lib/plumed"
export PLUMED_KERNEL="\${PLUMED_PREFIX}/lib/libplumedKernel.so"

# Suppress ArrayFire/GLFW attempts to open an X11 window on headless/login nodes.
export AF_DISABLE_GRAPHICS="\${AF_DISABLE_GRAPHICS:-1}"

# GROMACS runtime variables.  We avoid sourcing GMXRC here so activation also
# works in shells that have `set -u` / nounset enabled.
export GROMACS_DIR="\${GMX_ROOT}"
export GMXBIN="\${GMX_ROOT}/bin"
export GMXLDLIB="\${GMX_ROOT}/lib"
export GMXMAN="\${GMX_ROOT}/share/man"
export GMXDATA="\${GMX_ROOT}/share/gromacs"

export PATH="\${GMX_ROOT}/bin:\${PLUMED_PREFIX}/bin:\${MPI_ROOT}/bin:\${CUDA_HOME}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GMX_ROOT}/lib:\${GMX_ROOT}/lib64:\${PLUMED_PREFIX}/lib:\${AF_ROOT}/lib:\${AF_ROOT}/lib64:\${FFTW_ROOT}/lib:\${BOOST_ROOT}/lib:\${FMT_ROOT}/lib:\${FMT_ROOT}/lib64:\${SPDLOG_ROOT}/lib:\${SPDLOG_ROOT}/lib64:\${MPI_ROOT}/lib:\${CUDA_HOME}/lib64:\${CUDA_HOME}/targets/x86_64-linux/lib:\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\${GMX_ROOT}/lib/pkgconfig:\${GMX_ROOT}/lib64/pkgconfig:\${PLUMED_PREFIX}/lib/pkgconfig:\${FFTW_ROOT}/lib/pkgconfig:\${FMT_ROOT}/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="\${GMX_ROOT}:\${PLUMED_PREFIX}:\${AF_ROOT}:\${FFTW_ROOT}:\${BOOST_ROOT}:\${FMT_ROOT}:\${SPDLOG_ROOT}:\${MPI_ROOT}:\${CUDA_HOME}:\${CMAKE_PREFIX_PATH:-}"

echo "Activated '${NAME}': GMX_ROOT=\${GMX_ROOT}, PLUMED_PREFIX=\${PLUMED_PREFIX}, CUDA=\${CUDA_HOME}"
EOF
  chmod +x "${out}"
  printf '%s\n' "${out}"
}

write_rc_block() {
  # write_rc_block <rcfile>
  local rcfile="${1}"
  local start="# >>> ${NAME} CUDA/PLUMED env (managed by ${SCRIPT_NAME}) >>>"
  local end="# <<< ${NAME} CUDA/PLUMED env <<<"
  touch "${rcfile}"

  # Replace any previous managed block for this NAME (idempotent re-runs).
  if grep -qF "${start}" "${rcfile}"; then
    local es ee
    es="$(regex_escape "${start}")"
    ee="$(regex_escape "${end}")"
    sed -i "/${es}/,/${ee}/d" "${rcfile}"
  fi

  {
    echo "${start}"
    echo "# Added on $(date). Type '${ALIAS_NAME}' to load the environment."
    echo "alias ${ALIAS_NAME}='source \"${INSTALL_ROOT}/activate.sh\"'"
    echo "${end}"
  } >> "${rcfile}"
  info "Updated ${rcfile} (alias: ${ALIAS_NAME})."
}

integrate_shell_rc() {
  if [[ "${WRITE_BASHRC}" -eq 1 ]]; then
    write_rc_block "${HOME}/.bashrc"
  fi
  if [[ "${WRITE_ALIASES}" -eq 1 ]]; then
    write_rc_block "${HOME}/.bash_aliases"
  fi
}

###############################################################################
# Reporting
###############################################################################
print_config() {
  section "Build configuration"
  printf '  %-22s : %s\n' "Script version" "${SCRIPT_VERSION}"
  printf '  %-22s : %s\n' "Script dir"     "${SCRIPT_DIR}"
  printf '  %-22s : %s\n' "CUDA toolkit"   "${CUDA_HOME} (v${CUDA_VERSION})"
  printf '  %-22s : %s\n' "CUDA compiler"  "${CUDACXX:-${CUDA_HOME}/bin/nvcc}"
  printf '  %-22s : %s\n' "Parent dir"     "${DIR}"
  printf '  %-22s : %s\n' "Env name"       "${NAME}"
  printf '  %-22s : %s\n' "Install root"   "${INSTALL_ROOT}"
  printf '  %-22s : %s\n' "Sources"        "${SRC}"
  printf '  %-22s : %s\n' "Checkpoints"    "${CKPT_DIR}"
  printf '  %-22s : %s\n' "Activation alias" "${ALIAS_NAME}"
  printf '  %-22s : %s\n' "CUDA arch(s)"   "${CUDA_ARCHS}"
  printf '  %-22s : %s\n' "Parallel jobs"  "${NPROC}"
  printf '  %-22s : %s\n' "PLUMED ref"     "${PLUMED_REF}"
  printf '  %-22s : %s\n' "PLUMED Python"  "$([[ "${PLUMED_DISABLE_PYTHON}" == "1" ]] && echo disabled || echo enabled)"
  printf '  %-22s : %s\n' "PLUMED patch dir" "$(resolve_plumed_patch_dir 2>/dev/null || printf '%s' "${PLUMED_PATCH_DIR}")"
  printf '  %-22s : %s\n' "SAXS override"   "${PLUMED_SAXS_CPP:-auto-detect}"
  printf '  %-22s : %s\n' "GROMACS version" "${GROMACS_VERSION}"
  printf '  %-22s : %s\n' "GROMACS patch" "${PLUMED_GROMACS_PATCH}"
  printf '  %-22s : %s\n' "GROMACS SIMD" "${GMX_SIMD}"
  printf '  %-22s : %s\n' "Auto repair"    "${AUTO_REPAIR}"
  printf '  %-22s : %s\n' "CUDA shim dir"  "${CUDA_SHIM_DIR}"
  printf '  %-22s : %s\n' "FFTW -march"    "${MARCH}"
}

print_plan() {
  section "Stage plan"
  local s state
  for s in "${STAGES[@]}"; do
    if should_run "${s}"; then
      state="${C_GRN}BUILD${C_RST}"
    elif stage_done "${s}"; then
      state="${C_DIM}skip (checkpoint present)${C_RST}"
    else
      state="${C_DIM}skip${C_RST}"
    fi
    printf '  %-10s : %b\n' "${s}" "${state}"
  done
}

print_status() {
  section "Checkpoint status: ${INSTALL_ROOT}"
  local s
  for s in "${STAGES[@]}"; do
    if stage_done "${s}"; then
      printf '  %-10s : %bdone%b   (%s)\n' "${s}" "${C_GRN}" "${C_RST}" \
        "$(cat "${CKPT_DIR}/${s}.done" 2>/dev/null)"
    else
      printf '  %-10s : %bpending%b\n' "${s}" "${C_YEL}" "${C_RST}"
    fi
  done
}

print_done_banner() {
  section "Build completed successfully"
  echo "  Install root : ${INSTALL_ROOT}"
  echo "  PLUMED       : ${PLUMED_ROOT}"
  echo "  PLUMED kernel: ${PLUMED_KERNEL}"
  echo "  GROMACS      : ${GMX_ROOT}"
  echo "  ArrayFire    : ${AF_ROOT}"
  echo "  FFTW         : ${FFTW_ROOT}"
  echo "  fmt          : ${FMT_ROOT}"
  echo "  OpenMPI      : ${MPI_ROOT}"
  echo "  CUDA         : ${CUDA_HOME}"
  echo "  Log file     : ${LOG_FILE}"
  echo
  echo "  Activate this environment with:"
  echo "      source \"${INSTALL_ROOT}/activate.sh\""
  echo "      gmx_mpi --version"
  echo "      gmx_mpi mdrun -plumed plumed.dat"
  if [[ "${WRITE_BASHRC}" -eq 1 || "${WRITE_ALIASES}" -eq 1 ]]; then
    echo "  or, in a new shell, simply:"
    echo "      ${ALIAS_NAME}"
  fi
}

###############################################################################
# Main
###############################################################################
main() {
  setup_colors
  parse_args "$@"
  setup_colors   # re-apply in case --no-color was passed
  validate_args

  detect_cuda
  resolve_paths

  if [[ "${DO_STATUS}" -eq 1 ]]; then
    print_status
    exit 0
  fi

  check_install_dir

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    # Create the tree early so the rootless auto-repair layer can place private
    # compatibility shims inside the install root before preflight/configuration.
    mkdir -p "${INSTALL_ROOT}" "${SRC}" "${LOG_DIR}" "${CKPT_DIR}"
    LOG_FILE="${LOG_DIR}/build_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    info "Logging to ${LOG_FILE}"

    # Avoid Conda contaminating compiler/library discovery (no-op if absent).
    conda deactivate 2>/dev/null || true

    ensure_cuda_development_layout
  else
    # Dry-run should not write shims, but still report obvious layout risks.
    if needs_cuda_shim; then
      warn "CUDA appears to use a split/non-standard layout. A real run will create a private CUDA shim under the install root."
    fi
  fi

  # Set path variables before resolving the GROMACS auto-selection, because the
  # compiler check should inspect the MPI wrapper from this environment.
  setup_environment
  if should_run gromacs; then
    resolve_gromacs_selection
  fi

  print_config

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    preflight
    print_plan
    section "Activation script preview (not written in --dry-run)"
    echo "Would write: ${INSTALL_ROOT}/activate.sh"
    echo "Would add alias '${ALIAS_NAME}' to:"
    [[ "${WRITE_BASHRC}" -eq 1 ]]  && echo "  ${HOME}/.bashrc"
    [[ "${WRITE_ALIASES}" -eq 1 ]] && echo "  ${HOME}/.bash_aliases"
    [[ "${WRITE_BASHRC}" -eq 0 && "${WRITE_ALIASES}" -eq 0 ]] \
      && echo "  (no shell rc requested; use --write-bashrc/--write-aliases)"
    echo
    info "Dry run complete; nothing was built or written."
    exit 0
  fi

  preflight
  setup_environment

  print_plan

  local s
  for s in "${STAGES[@]}"; do
    if should_run "${s}"; then
      run_stage "${s}"
    else
      info "Skipping stage '${s}'."
    fi
  done

  # If we only built a subset, PLUMED/GROMACS may not be present yet; guard final checks.
  if [[ -x "${PLUMED_ROOT}/bin/plumed" ]]; then
    export PATH="${PLUMED_ROOT}/bin:${PATH}"
    export LD_LIBRARY_PATH="${PLUMED_ROOT}/lib:${LD_LIBRARY_PATH:-}"
    final_checks
  else
    warn "PLUMED not installed in this run; skipping final PLUMED checks."
  fi

  if [[ -x "${GMX_ROOT}/bin/gmx_mpi" ]]; then
    final_gromacs_checks
  else
    warn "GROMACS not installed in this run; skipping final GROMACS checks."
  fi

  postflight_stack_checks
  generate_activate_script >/dev/null
  integrate_shell_rc
  print_done_banner
}

on_err() {
  local rc=$?
  echo
  err "Build failed at line ${BASH_LINENO[0]} (exit ${rc})."
  echo "Log file: ${LOG_FILE:-<not created>}"
  exit "${rc}"
}
trap on_err ERR

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
