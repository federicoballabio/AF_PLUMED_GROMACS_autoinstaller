#!/usr/bin/env bash
###############################################################################
# Generalized CUDA / OpenMPI / FFTW / Boost / spdlog / ArrayFire / PLUMED / GROMACS build
#
# Default route: builds a self-contained scientific software stack with an
# ArrayFire CUDA backend, PLUMED (ISDB/SAXS + ArrayFire CUDA), and a
# PLUMED-patched external-MPI GROMACS installation.
#
# Optional --gromacs-only route: builds only FFTW and standalone CUDA GROMACS,
# with external MPI disabled and built-in thread-MPI enabled. This route is
# intended for fast single-node workstation/HPC GPU installations.
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
#   * A dedicated --update-saxs route reuses an existing configured PLUMED
#     checkout, incrementally rebuilds/installs only PLUMED, and never touches
#     the GROMACS source, build, installation, or checkpoints.
#   * v31 preserves the retained PLUMED Python-wrapper capability and repairs
#     missing/shadowed PyPA build tooling privately under the install root.
#   * v31 snapshots the complete installed PLUMED prefix plus the pre-update
#     tracked source state and restores them transactionally if the update fails.
#   * Rootless HPC operation is an explicit invariant: no sudo/system package
#     manager is invoked and no system software prefix is modified.
#   * Persistent install reports, source/kernel hashes, update history, and
#     out-of-tree backups make later SAXS development updates reproducible.
#   * GROMACS is built after PLUMED, so an existing successful PLUMED build can
#     be reused and the new run can continue directly with the gromacs stage.
#
# Quick start:
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --arch 90 -j 16 \
#                            --write-bashrc
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --from gromacs
#   ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --update-saxs
#
# See --help for all options.
###############################################################################

set -Eeuo pipefail
umask 022

SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_VERSION="6.0-gmx-auto-v31-transactional-saxs"

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

# Ordered build-stage routes used by the checkpoint system. The full PLUMED
# stack remains the default. --gromacs-only reduces the route to FFTW+GROMACS.
FULL_STAGES=(openmpi fftw boost fmt spdlog arrayfire plumed gromacs)
GROMACS_ONLY_STAGES=(fftw gromacs)
STAGES=("${FULL_STAGES[@]}")

###############################################################################
# Argument defaults
###############################################################################
CUDA_PATH="auto"           # --cuda (auto or explicit toolkit root)
DIR=""                     # --dir   (required)
NAME=""                    # --name  (default: build_<cudaver>)
NPROC="${NPROC:-}"         # -j/--jobs
CUDA_ARCHS="${CUDA_ARCHS:-auto}"   # --arch  (auto, 80, or "70;80;90")
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
BUILD_MODE="${BUILD_MODE:-full}"  # full | gromacs-only
BUILD_MODE_EXPLICIT=0
UPDATE_SAXS=0              # --update-saxs: incremental PLUMED/SAXS update
ALLOW_DIRTY_PLUMED=0       # --allow-dirty-plumed: permit other tracked edits
RUN_INSTALLCHECK=0         # --installcheck: run PLUMED's installed regtests

# SAXS-update state used for automatic failure rollback.
CURRENT_OPERATION="build"
SAXS_UPDATE_ACTIVE=0
SAXS_UPDATE_BACKUP_DIR=""
SAXS_UPDATE_SOURCE=""
SAXS_UPDATE_TARGET=""
SAXS_UPDATE_OLD_HASH=""
SAXS_UPDATE_NEW_HASH=""
SAXS_UPDATE_OLD_KERNEL_HASH=""
SAXS_UPDATE_NEW_KERNEL_HASH=""
SAXS_UPDATE_COMMIT=""
SAXS_UPDATE_ID=""
LAST_SAXS_CANDIDATE=""
SAXS_UPDATE_FAILURE_HANDLED=0
SAXS_UPDATE_PREFIX_SNAPSHOT=""
SAXS_UPDATE_PREFIX_SNAPSHOT_SHA256=""
SAXS_UPDATE_PYTHON_ENABLED=0
SAXS_UPDATE_PYTHON_CONFIGURED=""
SAXS_UPDATE_PYTHON_RESOLVED=""
SAXS_UPDATE_PYTHON_BUILD_STATUS="disabled"
SAXS_UPDATE_PYTHON_BUILD_ORIGIN=""
SAXS_UPDATE_PYTHON_BUILD_VERSION=""
SAXS_UPDATE_PYTHON_DEPS_DIR=""
SAXS_UPDATE_PYTHON_PIP_DIR=""
SAXS_UPDATE_TRACKED_DIRTY_LIST=""
SAXS_UPDATE_TRACKED_DIRTY_ARCHIVE=""
SAXS_UPDATE_TRACKED_MISSING_LIST=""

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
die()  {
  local message="$*"
  err "${message}"
  # An explicit exit does not fire Bash's ERR trap. Once an update snapshot is
  # active, invoke the same rollback path directly so validation failures are
  # just as recoverable as failed external commands.
  if [[ "${SAXS_UPDATE_ACTIVE:-0}" -eq 1 ]] \
     && declare -F handle_failed_saxs_update >/dev/null 2>&1; then
    handle_failed_saxs_update 1 "explicit failure: ${message}" "${BASH_LINENO[0]:-unknown}"
  fi
  exit 1
}

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

By default, builds OpenMPI, FFTW, Boost, fmt, spdlog, ArrayFire (CUDA),
PLUMED and a PLUMED-patched external-MPI GROMACS installation into
<parent-dir>/<name>. With --gromacs-only, builds only FFTW and standalone CUDA
GROMACS with built-in thread-MPI. Both routes retain checkpoint/resume support.

With --update-saxs, reuses the existing configured PLUMED checkout under
<parent-dir>/<name>/src/plumed2, replaces only src/isdb/SAXS.cpp, preserves the
retained PLUMED Python-wrapper setting, performs an incremental PLUMED
build/install, validates the installed kernel, and leaves GROMACS untouched.
Before make install it snapshots the complete installed PLUMED prefix so a
failed update can restore the pre-update installation. No source clone,
checkout, configure, distclean, or GROMACS build is performed in this mode.

Required:
  --dir <path>          Parent directory for the installation. The actual
                        install root is <dir>/<name>.

Build route:
  --gromacs-only       Build only FFTW + standalone CUDA GROMACS. Configures
                       GMX_MPI=OFF and GMX_THREAD_MPI=ON, and does not apply a
                       PLUMED patch. The executable is `gmx` (not `gmx_mpi`).
  --mode <mode>        Explicit route: full or gromacs-only. Default: full.
  --full-stack         Explicitly select the original full PLUMED stack.

Common options:
  --name <name>         Environment name and install subfolder. Also used to
                        build the activation alias. Default: build_<cudaver>.
                        If <dir>/<name> already exists and is non-empty (and is
                        not a previous run of this script), the build aborts and
                        asks for a different --name.
  --cuda <path|auto>    CUDA toolkit root (must contain bin/nvcc), or auto.
                        Default: auto. Auto mode searches only fast/common places
                        (CUDA_HOME/CUDA_ROOT, PATH, --dir, script/current/home
                        software folders, /mnt/data/software, /usr/local, /opt,
                        /usr/lib) and selects the newest valid CUDA toolkit.
                        Manual --cuda /path still takes precedence.
  --arch <archs>        CUDA compute architecture(s), e.g. auto, 80, 86, 90, or 120.
                        Default: auto. In auto mode the script queries visible
                        NVIDIA GPU compute capabilities and converts them to
                        CMake CUDA architectures. For RTX 50-series / Blackwell,
                        auto should resolve to 120; manual override remains
                        possible with --arch 120.
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
  --update-saxs       Incrementally rebuild/install PLUMED after replacing only
                       src/isdb/SAXS.cpp in an existing full-stack installation.
                       --name is required. The default candidate is the
                       install-owned <install-root>/plumed_patch/SAXS.cpp.
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
                        This takes precedence over --plumed-patch-dir. In
                        --update-saxs mode, it is also copied into the canonical
                        install-owned plumed_patch/SAXS.cpp location.
  --allow-dirty-plumed  Permit tracked PLUMED source changes other than
                        src/isdb/SAXS.cpp during --update-saxs. By default such
                        changes abort the update so they cannot be linked in
                        accidentally. Generated/untracked build files are okay.
  --installcheck       After a successful SAXS install, run PLUMED's full
                       `make installcheck` installed regression-test target.
                       The default update performs fast build-tree and installed
                       SAXS/kernel checks; use this option for release updates.

Auto-repair / HPC compatibility:
  --no-auto-repair     Disable rootless compatibility fixes. By default the script
                        can create a private CUDA shim when nvcc, headers and
                        libraries are split across /usr/bin, /usr/include and
                        /usr/lib/x86_64-linux-gnu.
  --cuda-shim-dir <d>  Directory for an automatically generated CUDA shim.
                        Default: <install-root>/cuda-<version>-shim.

Rootless/HPC invariant:
  The installer never invokes sudo or a system package manager. Persistent
  components, compatibility shims, SAXS-update rollback snapshots, and Python
  build tooling provisioned by the installer stay below <install-root>. Normal
  temporary build files may use the host TMPDIR. Host
  compiler/CMake/Git/CUDA-driver/toolkit prerequisites may come from HPC
  modules, administrator installations, or user-owned prefixes. ~/.bashrc and
  ~/.bash_aliases are touched only when their explicit options are requested.

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
  --dry-run             Resolve everything and print the selected plan without
                        building. With --update-saxs, also prints source,
                        candidate, commit, and SHA-256 drift without writing.
  --no-color            Disable coloured output.
  -y, --yes             Assume "yes": reuse a non-empty install dir instead of
                        aborting (a lighter-weight alternative to --force that
                        keeps existing checkpoints).
  -h, --help            Show this help.

Full-stack stages: openmpi fftw boost fmt spdlog arrayfire plumed gromacs
GROMACS-only stages: fftw gromacs

Selected environment overrides (export before running):
  OPENMPI_VERSION FFTW_VERSION BOOST_VERSION FMT_VERSION SPDLOG_VERSION ARRAYFIRE_VERSION
  PLUMED_REPO GROMACS_VERSION GROMACS_URL GROMACS_FTP_URL PLUMED_GROMACS_PATCH
  GMX_SIMD MARCH AUTO_REPAIR CUDA_SHIM_DIR CUDA_EXTRA_INCLUDE_DIRS CUDA_EXTRA_LIB_DIRS

Examples:
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv
  ./af_plumed_gmx_build.sh --dir $HOME/sw --name plumed_a100 --arch 80 -j 32 --write-bashrc
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --from gromacs    # continue after PLUMED
  mkdir -p $HOME/software/myenv/plumed_patch
  cp /path/to/new/SAXS.cpp $HOME/software/myenv/plumed_patch/SAXS.cpp
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --update-saxs --dry-run
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --update-saxs -j 4
  ./af_plumed_gmx_build.sh --dir $HOME/software --name gmx_gpu --gromacs-only --write-bashrc
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

sha256_file() {
  local file="${1}"
  [[ -f "${file}" ]] || return 1
  sha256sum -- "${file}" | awk '{print $1}'
}

single_line() {
  tr '\r\n\t' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

json_string() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "${value}"
}

is_full_stack()    { [[ "${BUILD_MODE}" == "full" ]]; }
is_gromacs_only() { [[ "${BUILD_MODE}" == "gromacs-only" ]]; }

configure_build_mode() {
  case "${BUILD_MODE}" in
    full)
      STAGES=("${FULL_STAGES[@]}")
      ;;
    gromacs-only|gromacs_only|gmx-only|gmx_only)
      BUILD_MODE="gromacs-only"
      STAGES=("${GROMACS_ONLY_STAGES[@]}")
      ;;
    *)
      die "Invalid build mode '${BUILD_MODE}'. Use full or gromacs-only."
      ;;
  esac
}

gmx_executable_name() {
  if is_gromacs_only; then printf '%s\n' gmx; else printf '%s\n' gmx_mpi; fi
}

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
      --gromacs-only) BUILD_MODE="gromacs-only"; BUILD_MODE_EXPLICIT=1; shift ;;
      --full-stack)   BUILD_MODE="full"; BUILD_MODE_EXPLICIT=1; shift ;;
      --mode)         BUILD_MODE="${2:?--mode requires full or gromacs-only}"; BUILD_MODE_EXPLICIT=1; shift 2 ;;
      --mode=*)       BUILD_MODE="${1#*=}"; BUILD_MODE_EXPLICIT=1; shift ;;
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
      --update-saxs)  UPDATE_SAXS=1; CURRENT_OPERATION="update-saxs"; shift ;;
      --allow-dirty-plumed) ALLOW_DIRTY_PLUMED=1; shift ;;
      --installcheck) RUN_INSTALLCHECK=1; shift ;;
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

  if [[ "${UPDATE_SAXS}" -eq 1 ]]; then
    [[ -n "${NAME}" ]] \
      || die "--update-saxs requires --name so an existing installation is selected explicitly."
    is_full_stack \
      || die "--update-saxs is only valid for a full PLUMED/GROMACS installation."
    [[ -z "${FROM_STAGE}" && -z "${ONLY_STAGE}" ]] \
      || die "--update-saxs cannot be combined with --from or --only."
    [[ "${WRITE_BASHRC}" -eq 0 && "${WRITE_ALIASES}" -eq 0 ]] \
      || die "--update-saxs does not modify shell activation aliases; omit --write-bashrc/--write-aliases."
    [[ "${DO_STATUS}" -eq 0 ]] \
      || die "--update-saxs and --status are separate operations; run them independently."
  else
    [[ "${ALLOW_DIRTY_PLUMED}" -eq 0 ]] \
      || die "--allow-dirty-plumed is only valid with --update-saxs."
    [[ "${RUN_INSTALLCHECK}" -eq 0 ]] \
      || die "--installcheck is only valid with --update-saxs."
  fi

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
  if is_full_stack && [[ -n "${PLUMED_SAXS_CPP}" && ! -f "${PLUMED_SAXS_CPP}" ]]; then
    die "--saxs-cpp file not found: ${PLUMED_SAXS_CPP}"
  fi
  if is_gromacs_only; then
    [[ -n "${PLUMED_SAXS_CPP}" ]] && warn "--saxs-cpp is ignored in --gromacs-only mode."
    [[ "${PLUMED_PATCH_DIR}" != "auto" ]] && warn "--plumed-patch-dir is ignored in --gromacs-only mode."
  fi

  return 0
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

_cuda_maybe_add_candidate() {
  # _cuda_maybe_add_candidate <candidate-array-name> <path>
  # Adds a CUDA root only when it has bin/nvcc and is not already present.
  local -n _arr="$1"
  local d="${2:-}" existing=""
  [[ -n "${d}" ]] || return 0
  d="${d%/}"
  [[ -x "${d}/bin/nvcc" ]] || return 0
  d="$(abspath "${d}")"
  for existing in "${_arr[@]:-}"; do
    [[ "${existing}" == "${d}" ]] && return 0
  done
  _arr+=("${d}")
}

_select_newest_cuda_candidate() {
  # Prints the candidate with the highest nvcc major.minor version. Ties keep the
  # earlier discovery order, so explicit/env/PATH candidates remain stable when
  # two paths point to the same CUDA version.
  local candidates=("$@")
  local best="" best_major=-1 best_minor=-1
  local cand ver major minor
  for cand in "${candidates[@]}"; do
    ver="$(get_cuda_version "${cand}/bin/nvcc" || true)"
    [[ "${ver}" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    major="${ver%%.*}"
    minor="${ver#*.}"
    if (( major > best_major || (major == best_major && minor > best_minor) )); then
      best="${cand}"
      best_major="${major}"
      best_minor="${minor}"
    fi
  done
  [[ -n "${best}" ]] && printf '%s\n' "${best}"
}

detect_cuda() {
  local cand=""

  if [[ -n "${CUDA_PATH}" && "${CUDA_PATH}" != "auto" ]]; then
    # Explicit path: prefer the requested CUDA root when it has bin/nvcc.  On
    # split Debian/Ubuntu CUDA installs, users may pass /usr/lib/cuda even
    # though nvcc is /usr/bin/nvcc; with auto-repair enabled we accept that as a
    # hint and consolidate the final layout into a private shim later.
    if [[ -x "${CUDA_PATH%/}/bin/nvcc" ]]; then
      cand="${CUDA_PATH%/}"
    elif [[ "${AUTO_REPAIR}" == "1" ]] && command -v nvcc >/dev/null 2>&1; then
      warn "--cuda '${CUDA_PATH}' has no bin/nvcc; using $(command -v nvcc) and the auto-repair CUDA shim."
      cand="$(dirname "$(dirname "$(command -v nvcc)")")"
    else
      die "--cuda '${CUDA_PATH}' has no bin/nvcc."
    fi
  else
    local d nvcc_path search_root
    local candidates=()
    shopt -s nullglob

    # 1) Existing environment and PATH hints.
    _cuda_maybe_add_candidate candidates "${CUDA_HOME:-}"
    _cuda_maybe_add_candidate candidates "${CUDA_ROOT:-}"
    if command -v nvcc >/dev/null 2>&1; then
      nvcc_path="$(command -v nvcc)"
      _cuda_maybe_add_candidate candidates "$(dirname "$(dirname "${nvcc_path}")")"
    fi

    # 2) Fast common local/project locations. This intentionally avoids a full
    # filesystem scan. The --dir parent is included before global locations so
    # installs like /mnt/data/software/cuda are found without manual exports.
    for d in \
      "${DIR%/}/cuda" "${DIR%/}"/cuda-* \
      "${SCRIPT_DIR}/cuda" "${SCRIPT_DIR}"/cuda-* \
      "$(pwd -P)/cuda" "$(pwd -P)"/cuda-* \
      "${HOME:-}/cuda" "${HOME:-}/software/cuda" "${HOME:-}/software"/cuda-* \
      /mnt/data/software/cuda /mnt/data/software/cuda-* \
      /usr/local/cuda /usr/local/cuda-* \
      /opt/cuda /opt/cuda-* \
      /usr/lib/cuda; do
      _cuda_maybe_add_candidate candidates "${d}"
    done

    # 3) Shallow, bounded find only in a few likely roots. This catches layouts
    # such as /mnt/data/software/cuda-12.5/bin/nvcc without touching the whole
    # machine or deep scratch trees.
    for search_root in "${DIR:-}" /mnt/data/software /usr/local /opt "${HOME:-}/software"; do
      [[ -d "${search_root}" ]] || continue
      while IFS= read -r nvcc_path; do
        _cuda_maybe_add_candidate candidates "$(dirname "$(dirname "${nvcc_path}")")"
      done < <(find "${search_root}" -maxdepth 3 -type f -path '*/bin/nvcc' -perm -111 2>/dev/null || true)
    done
    shopt -u nullglob

    if [[ ${#candidates[@]} -gt 0 ]]; then
      cand="$(_select_newest_cuda_candidate "${candidates[@]}" || true)"
      if [[ -n "${cand}" ]]; then
        info "Auto-detected CUDA toolkit: ${cand} ($(get_cuda_version "${cand}/bin/nvcc"))"
      fi
    fi
  fi

  if [[ -z "${cand}" ]]; then
    die "Could not locate a CUDA toolkit. Pass --cuda <path>, set CUDA_HOME, load your CUDA module, or install CUDA in a standard location."
  fi

  CUDA_HOME="$(abspath "${cand}")"
  CUDA_VERSION="$(get_cuda_version "${CUDA_HOME}/bin/nvcc")"
  [[ -n "${CUDA_VERSION}" ]] \
    || die "Found nvcc at ${CUDA_HOME}/bin/nvcc but could not parse its version."

  # Export the CUDA environment internally so users do not have to pre-export
  # CUDA_HOME/CUDA_ROOT/CUDACXX/PATH/LD_LIBRARY_PATH before invoking the script.
  export CUDA_HOME
  export CUDA_ROOT="${CUDA_HOME}"
  export CUDACXX="${CUDA_HOME}/bin/nvcc"
  export PATH="${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
}

###############################################################################
# CUDA architecture resolution
###############################################################################
_normalize_cuda_arch_token() {
  local tok="$1"
  tok="${tok//[[:space:]]/}"
  tok="${tok#sm_}"
  tok="${tok#compute_}"
  if [[ "${tok}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "${tok}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${tok}"
  fi
}

_unique_arch_list() {
  awk 'NF && !seen[$0]++' | paste -sd';' -
}

_detect_cuda_archs_nvidia_smi() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  local caps=""
  caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null || true)"
  if [[ -z "${caps}" ]]; then
    # Older nvidia-smi builds sometimes only accept paired fields.
    caps="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits 2>/dev/null \
      | awk -F, '{print $NF}' || true)"
  fi
  [[ -n "${caps}" ]] || return 0
  while IFS= read -r cap; do
    _normalize_cuda_arch_token "${cap}"
  done <<< "${caps}" | sort -n | _unique_arch_list
}

_detect_cuda_archs_runtime_probe() {
  [[ -x "${CUDA_HOME}/bin/nvcc" ]] || return 0
  local tmp exe out
  tmp="$(mktemp -d 2>/dev/null || mktemp -d -t af_cuda_arch_probe)"
  cat > "${tmp}/detect_cuda_arch.cu" <<'EOF_ARCH_PROBE'
#include <cuda_runtime.h>
#include <cstdio>
int main() {
    int n = 0;
    cudaError_t err = cudaGetDeviceCount(&n);
    if (err != cudaSuccess || n <= 0) return 1;
    for (int i = 0; i < n; ++i) {
        cudaDeviceProp prop{};
        err = cudaGetDeviceProperties(&prop, i);
        if (err == cudaSuccess) std::printf("%d%d\n", prop.major, prop.minor);
    }
    return 0;
}
EOF_ARCH_PROBE
  exe="${tmp}/detect_cuda_arch"
  if "${CUDA_HOME}/bin/nvcc" -std=c++17 "${tmp}/detect_cuda_arch.cu" -o "${exe}" >/dev/null 2>&1; then
    out="$(LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}" "${exe}" 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      printf '%s\n' "${out}" | sort -n | _unique_arch_list
    fi
  fi
  rm -rf "${tmp}"
}

resolve_cuda_archs() {
  local raw="${CUDA_ARCHS:-auto}"
  raw="${raw,,}"

  if [[ "${raw}" == "auto" ]]; then
    local detected=""
    detected="$(_detect_cuda_archs_nvidia_smi || true)"
    if [[ -z "${detected}" ]]; then
      detected="$(_detect_cuda_archs_runtime_probe || true)"
    fi

    if [[ -z "${detected}" ]]; then
      local msg="Could not auto-detect CUDA compute capability. Run 'nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader' and pass the converted value with --arch, e.g. --arch 86 or --arch 120."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        warn "${msg}"
        CUDA_ARCHS="auto-unresolved"
      else
        die "${msg}"
      fi
    else
      CUDA_ARCHS="${detected}"
      info "Auto-detected CUDA architecture(s): ${CUDA_ARCHS}"
    fi
  else
    CUDA_ARCHS="${CUDA_ARCHS//,/;}"
    CUDA_ARCHS="${CUDA_ARCHS//[[:space:]]/}"
  fi

  if [[ "${CUDA_ARCHS}" != "auto-unresolved" ]] && ! [[ "${CUDA_ARCHS}" =~ ^[0-9]+([;][0-9]+)*$ ]]; then
    die "Invalid CUDA architecture list '${CUDA_ARCHS}'. Use --arch auto, --arch 86, --arch 120, or a semicolon/comma list such as --arch '80;86'."
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
  local mode_marker="${INSTALL_ROOT}/.installer_build_mode"
  if [[ -f "${mode_marker}" ]]; then
    local existing_mode
    existing_mode="$(head -n1 "${mode_marker}" 2>/dev/null || true)"
    if [[ -n "${existing_mode}" && "${existing_mode}" != "${BUILD_MODE}" && "${FORCE}" -ne 1 ]]; then
      die "Install root was created in build mode '${existing_mode}', but '${BUILD_MODE}' was requested:\n    ${INSTALL_ROOT}\nUse a new --name, or pass --force to replace/rebuild the selected route."
    fi
  elif [[ -d "${CKPT_DIR}" ]] && is_gromacs_only && [[ "${FORCE}" -ne 1 ]]; then
    die "Existing checkpointed install has no build-mode marker and is assumed to be a legacy full-stack environment. Use a new --name for --gromacs-only, or pass --force."
  fi

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

cuda_required_headers() {
  if is_gromacs_only; then
    printf '%s\n' cuda.h cuda_runtime.h cufft.h
  else
    printf '%s\n' cuda.h cuda_runtime.h cuComplex.h cuda_fp16.h math_constants.h
  fi
}

cuda_required_libraries() {
  if is_gromacs_only; then
    printf '%s\n' libcudart.so libcufft.so
  else
    printf '%s\n' libcudart.so libcublas.so libcufft.so libcusolver.so libnvrtc.so
  fi
}

cuda_header_ok() {
  local h
  while IFS= read -r h; do
    [[ -f "${CUDA_HOME}/include/${h}" || -f "${CUDA_HOME}/targets/x86_64-linux/include/${h}" ]] || return 1
  done < <(cuda_required_headers)
  return 0
}

cuda_lib_ok() {
  local l
  while IFS= read -r l; do
    [[ -e "${CUDA_HOME}/lib64/${l}" || -e "${CUDA_HOME}/targets/x86_64-linux/lib/${l}" ]] || return 1
  done < <(cuda_required_libraries)
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
  while IFS= read -r h; do
    [[ -f "${CUDA_HOME}/include/${h}" || -f "${CUDA_HOME}/targets/x86_64-linux/include/${h}" ]] || missing_headers+=("${h}")
  done < <(cuda_required_headers)
  while IFS= read -r l; do
    [[ -e "${CUDA_HOME}/lib64/${l}" || -e "${CUDA_HOME}/targets/x86_64-linux/lib/${l}" ]] || missing_libs+=("${l}")
  done < <(cuda_required_libraries)

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
  local c required_tools=(tar make cmake pkg-config gcc g++ awk sed grep find)
  if is_full_stack; then required_tools+=(git); fi
  for c in "${required_tools[@]}"; do
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
  local hot_missing=() hf h l
  while IFS= read -r h; do
    if [[ ! -e "${CUDA_HOME}/include/${h}" && ! -e "${CUDA_HOME}/targets/x86_64-linux/include/${h}" ]]; then
      hot_missing+=("${h}")
    fi
  done < <(cuda_required_headers)
  while IFS= read -r l; do
    if [[ ! -e "${CUDA_HOME}/lib64/${l}" && ! -e "${CUDA_HOME}/targets/x86_64-linux/lib/${l}" ]]; then
      hot_missing+=("${l}")
    fi
  done < <(cuda_required_libraries)
  if [[ ${#hot_missing[@]} -gt 0 ]]; then
    _pf_fail "Missing hot CUDA headers/libraries: ${hot_missing[*]}"
  else
    ok "Hot CUDA headers/libraries present."
  fi

  if is_gromacs_only; then
    ok "GROMACS-only mode: PLUMED/Python/ArrayFire development dependencies are not required."
  elif [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]]; then
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
Choose a user-owned --dir (for example under HOME or SCRATCH) or ask the HPC administrator to provide a writable project location. This installer does not require or invoke sudo."
  else
    ok "Write permission for ${probe}."
  fi

  # Disk space (soft warning).
  local avail_kb avail_gb
  avail_kb="$(df -Pk "${probe}" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "${avail_kb}" ]]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ "${avail_gb}" -lt 20 ]]; then
      if is_gromacs_only; then
        warn "Only ~${avail_gb} GB free at ${probe}; the GROMACS-only build still needs several GB for sources and compilation."
      else
        warn "Only ~${avail_gb} GB free at ${probe}; the full build can need 15-25 GB."
      fi
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

  unset PKG_CONFIG_LIBDIR 2>/dev/null || true
  if [[ -x "${CUDA_HOME}/bin/nvcc" ]]; then
    export CUDACXX="${CUDA_HOME}/bin/nvcc"
  fi

  if is_gromacs_only; then
    # Prevent a previously activated PLUMED/ArrayFire/external-MPI stack from
    # influencing the standalone thread-MPI build.
    unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_PREFIX PLUMED_KERNEL 2>/dev/null || true
    export PATH="${GMX_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${FFTW_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
    export PKG_CONFIG_PATH="${GMX_ROOT}/lib/pkgconfig:${GMX_ROOT}/lib64/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CMAKE_PREFIX_PATH="${GMX_ROOT}:${FFTW_ROOT}:${CUDA_HOME}:${CMAKE_PREFIX_PATH:-}"
    return 0
  fi

  # Keep PLUMED_ROOT as a shell variable, not exported, during the build.
  unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"

  export PATH="${GMX_ROOT}/bin:${PLUMED_ROOT}/bin:${MPI_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${PLUMED_ROOT}/lib:${AF_ROOT}/lib:${AF_ROOT}/lib64:${FFTW_ROOT}/lib:${BOOST_ROOT}/lib:${FMT_ROOT}/lib:${FMT_ROOT}/lib64:${SPDLOG_ROOT}/lib:${SPDLOG_ROOT}/lib64:${MPI_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${GMX_ROOT}/lib/pkgconfig:${GMX_ROOT}/lib64/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${FMT_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="${GMX_ROOT}:${PLUMED_ROOT}:${AF_ROOT}:${FFTW_ROOT}:${BOOST_ROOT}:${FMT_ROOT}:${SPDLOG_ROOT}:${MPI_ROOT}:${CUDA_HOME}:${CMAKE_PREFIX_PATH:-}"
  export BOOST_INCLUDEDIR="${BOOST_ROOT}/include"
  export BOOST_LIBRARYDIR="${BOOST_ROOT}/lib"

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

  # Compatibility patch for ArrayFire 3.9.0 math.hpp across both normal
  # host compilation and NVRTC runtime JIT compilation.  Some newer host
  # compiler/libstdc++ combinations need std::isnan, while NVRTC does not
  # provide std::isnan in the runtime-compiled CUDA header path.  Use a tiny
  # wrapper macro: std::isnan for normal C++ compilation, global isnan for
  # NVRTC (__CUDACC_RTC__).  This avoids the runtime PLUMED/SAXS failure:
  #   NVRTC_ERROR_COMPILATION: namespace "std" has no member "isnan".
  local af_cuda_math="src/backend/cuda/math.hpp"
  if [[ -f "${af_cuda_math}" ]]; then
    if grep -Eq '(^|[^A-Za-z0-9_])(::|std::)?isnan[[:space:]]*\(' "${af_cuda_math}"; then
      info "Patching ArrayFire CUDA math.hpp for host+NVRTC isnan compatibility."
      python3 - "${af_cuda_math}" <<'PYEOF'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

macro = """#ifndef AF_CUDA_MATH_ISNAN
#  if defined(__CUDACC_RTC__)
#    define AF_CUDA_MATH_ISNAN(x) isnan(x)
#  else
#    define AF_CUDA_MATH_ISNAN(x) std::isnan(x)
#  endif
#endif
"""

if 'AF_CUDA_MATH_ISNAN' not in text:
    # Put the macro after the last leading #include block.  This keeps it near
    # the math declarations while avoiding assumptions about exact line numbers.
    lines = text.splitlines(True)
    insert_at = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#include'):
            insert_at = i + 1
    lines.insert(insert_at, '\n' + macro + '\n')
    text = ''.join(lines)

# Replace only namespace-qualified/global isnan calls, not the helper/macro name.
# The original ArrayFire source uses ::isnan; earlier installer versions changed
# that to std::isnan.  Both variants are normalized here.
text = re.sub(r'(?<![A-Za-z0-9_])(?:std::|::)?isnan\s*\(', 'AF_CUDA_MATH_ISNAN(', text)

# The replacement above must not rewrite the macro body itself.
text = text.replace('#    define AF_CUDA_MATH_ISNAN(x) AF_CUDA_MATH_ISNAN(x)', '#    define AF_CUDA_MATH_ISNAN(x) isnan(x)')
text = text.replace('#    define AF_CUDA_MATH_ISNAN(x) std::AF_CUDA_MATH_ISNAN(x)', '#    define AF_CUDA_MATH_ISNAN(x) std::isnan(x)')

path.write_text(text)
PYEOF
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
    export PYTHONPATH="${pip_site}${PYTHONPATH:+:${PYTHONPATH}}"
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


# v31: retained-install Python handling for --update-saxs.
# A retained PLUMED tree may have Python support enabled even though fresh v30+
# builds default to --disable-python. The update route must preserve that
# capability without reconfiguring PLUMED and without modifying system/Conda
# Python installations. In particular, do not trust the historical
# plumed_found_python_build=yes flag: PLUMED 2.11's configure probe only tests
# `import build`, while the build step actually needs `python -m build`.
saxs_update_python_can_build() {
  local py="${1}"
  "${py}" - <<'PYEOF' >/dev/null 2>&1
import build.__main__  # noqa: F401
PYEOF
  "${py}" -m build --version >/dev/null 2>&1
}

saxs_update_python_details() {
  # saxs_update_python_details <python-executable>
  # Prints two lines: origin and distribution/version. Never fails the update.
  local py="${1}"
  "${py}" - <<'PYEOF' 2>/dev/null || true
import importlib.metadata
import importlib.util
try:
    spec = importlib.util.find_spec("build")
    origin = getattr(spec, "origin", None) if spec else None
    locations = list(getattr(spec, "submodule_search_locations", []) or []) if spec else []
    if origin:
        print(origin)
    elif locations:
        print(";".join(locations))
    else:
        print("unresolved")
except Exception:
    print("unresolved")
try:
    print(importlib.metadata.version("build"))
except Exception:
    print("unknown")
PYEOF
}

inspect_saxs_update_python() {
  # Read only the retained PLUMED configuration. No configure step is run.
  local plumed_src="${1}" config makeconf configured="" resolved="" details=""
  config="${plumed_src}/src/config/config.txt"
  makeconf="${plumed_src}/Makefile.conf"

  SAXS_UPDATE_PYTHON_ENABLED=0
  SAXS_UPDATE_PYTHON_CONFIGURED=""
  SAXS_UPDATE_PYTHON_RESOLVED=""
  SAXS_UPDATE_PYTHON_BUILD_STATUS="disabled"
  SAXS_UPDATE_PYTHON_BUILD_ORIGIN=""
  SAXS_UPDATE_PYTHON_BUILD_VERSION=""
  SAXS_UPDATE_PYTHON_DEPS_DIR=""
  SAXS_UPDATE_PYTHON_PIP_DIR=""

  if grep -Eq '(^|:)has python[[:space:]]+(on|yes)([[:space:]]|$)|__PLUMED_HAS_PYTHON' "${config}" 2>/dev/null; then
    SAXS_UPDATE_PYTHON_ENABLED=1
  elif grep -Eq '(^|[[:space:]])-D__PLUMED_HAS_PYTHON=1([[:space:]]|$)' "${makeconf}" 2>/dev/null; then
    SAXS_UPDATE_PYTHON_ENABLED=1
  fi

  if [[ "${SAXS_UPDATE_PYTHON_ENABLED}" -eq 0 ]]; then
    return 0
  fi

  configured="$(awk -F= '$1=="python_bin"{print substr($0,index($0,"=")+1)}' "${makeconf}" 2>/dev/null | tail -n1)"
  if [[ -z "${configured}" ]]; then
    configured="$(awk '$1=="python_bin"{print $2}' "${config}" 2>/dev/null | tail -n1)"
  fi
  [[ -n "${configured}" ]] || die "Retained PLUMED reports Python support enabled but no configured python_bin could be recovered. Refusing to reconfigure or guess."
  SAXS_UPDATE_PYTHON_CONFIGURED="${configured}"

  if [[ "${configured}" == */* ]]; then
    resolved="$(abspath "${configured}")"
    [[ -x "${resolved}" ]] || die "Retained PLUMED python_bin is not executable: ${configured}"
  else
    resolved="$(command -v -- "${configured}" 2>/dev/null || true)"
    [[ -n "${resolved}" && -x "${resolved}" ]] \
      || die "Retained PLUMED python_bin '${configured}' is not available in the current update environment. Activate/provide the compatible Python environment and retry."
  fi
  SAXS_UPDATE_PYTHON_RESOLVED="${resolved}"

  # PLUMED's extension build needs Python headers for the same interpreter.
  "${resolved}" - <<'PYEOF' >/dev/null 2>&1 || die "Python headers are missing for retained PLUMED python_bin: ${resolved}. Provide the matching Python development headers/environment; v31 will not disable retained Python support."
import pathlib, sysconfig
inc = pathlib.Path(sysconfig.get_paths().get("include", "")) / "Python.h"
raise SystemExit(0 if inc.is_file() else 1)
PYEOF

  details="$(saxs_update_python_details "${resolved}")"
  SAXS_UPDATE_PYTHON_BUILD_ORIGIN="$(printf '%s\n' "${details}" | sed -n '1p')"
  SAXS_UPDATE_PYTHON_BUILD_VERSION="$(printf '%s\n' "${details}" | sed -n '2p')"
  if saxs_update_python_can_build "${resolved}"; then
    SAXS_UPDATE_PYTHON_BUILD_STATUS="ready"
  else
    SAXS_UPDATE_PYTHON_BUILD_STATUS="repair-required"
  fi
}

ensure_saxs_update_python_build_module() {
  [[ "${SAXS_UPDATE_PYTHON_ENABLED}" -eq 1 ]] || return 0
  local py="${SAXS_UPDATE_PYTHON_RESOLVED}"
  local support="${INSTALL_ROOT}/saxs_update_support"
  local deps="${support}/python_build_deps"
  local pip_prefix="${support}/python_pip"
  local getpip="${support}/get-pip.py"
  local pip_site="" details=""

  if saxs_update_python_can_build "${py}"; then
    ok "Retained PLUMED Python build tooling is already usable: ${py}"
  else
    warn "Retained PLUMED has Python support enabled, but '${py} -m build' is not usable. Provisioning PyPA build tooling privately under ${support}."
    mkdir -p "${support}"
    rm -rf "${deps}"
    mkdir -p "${deps}"

    if ! "${py}" -m pip --version >/dev/null 2>&1; then
      warn "Configured PLUMED Python has no usable pip; bootstrapping a private pip without root privileges."
      rm -rf "${pip_prefix}"
      mkdir -p "${pip_prefix}"
      if [[ ! -f "${getpip}" ]]; then
        if command -v wget >/dev/null 2>&1; then
          wget -O "${getpip}" https://bootstrap.pypa.io/get-pip.py
        elif command -v curl >/dev/null 2>&1; then
          curl -fL -o "${getpip}" https://bootstrap.pypa.io/get-pip.py
        else
          die "Neither wget nor curl is available to bootstrap the private Python build tooling required by this retained PLUMED installation."
        fi
      fi
      if ! PIP_BREAK_SYSTEM_PACKAGES=1 "${py}" "${getpip}" \
             --prefix "${pip_prefix}" --no-warn-script-location pip setuptools wheel; then
        PIP_BREAK_SYSTEM_PACKAGES=1 "${py}" "${getpip}" \
          --prefix "${pip_prefix}" --break-system-packages \
          --no-warn-script-location pip setuptools wheel \
          || die "Could not bootstrap a private pip for retained PLUMED Python: ${py}"
      fi
      pip_site="$(find "${pip_prefix}" -type d \
        \( -path '*/python*/site-packages/pip' -o -path '*/python*/dist-packages/pip' \) \
        -print 2>/dev/null | head -n1 | xargs -r dirname)"
      [[ -n "${pip_site}" ]] \
        || die "Private pip bootstrap completed, but its package directory could not be located under ${pip_prefix}."
      export PYTHONPATH="${pip_site}:${PYTHONPATH:-}"
      "${py}" -m pip --version >/dev/null 2>&1 \
        || die "Private pip was provisioned but is not importable by retained PLUMED Python: ${py}"
      SAXS_UPDATE_PYTHON_PIP_DIR="${pip_prefix}"
    fi

    mkdir -p "${support}/pip-cache"
    PIP_CACHE_DIR="${support}/pip-cache" PIP_BREAK_SYSTEM_PACKAGES=1 "${py}" -m pip install --upgrade \
      --target "${deps}" --no-warn-script-location \
      build setuptools wheel \
      || die "Could not install private PyPA build tooling under ${deps}."
    export PYTHONPATH="${deps}${PYTHONPATH:+:${PYTHONPATH}}"
    SAXS_UPDATE_PYTHON_DEPS_DIR="${deps}"

    saxs_update_python_can_build "${py}" \
      || die "Private Python build-tool installation completed, but '${py} -m build' still fails. Refusing to start the PLUMED update."
    ok "Private retained-Python build tooling validated: ${deps}"
  fi

  details="$(saxs_update_python_details "${py}")"
  SAXS_UPDATE_PYTHON_BUILD_ORIGIN="$(printf '%s\n' "${details}" | sed -n '1p')"
  SAXS_UPDATE_PYTHON_BUILD_VERSION="$(printf '%s\n' "${details}" | sed -n '2p')"
  SAXS_UPDATE_PYTHON_BUILD_STATUS="ready"
  info "Retained PLUMED Python: configured='${SAXS_UPDATE_PYTHON_CONFIGURED}', resolved='${SAXS_UPDATE_PYTHON_RESOLVED}'"
  info "Python build package: origin='${SAXS_UPDATE_PYTHON_BUILD_ORIGIN:-unknown}', version='${SAXS_UPDATE_PYTHON_BUILD_VERSION:-unknown}'"
}


resolve_plumed_patch_dir() {
  if [[ "${PLUMED_PATCH_DIR}" == "auto" || -z "${PLUMED_PATCH_DIR}" ]]; then
    # The install-owned folder is canonical after an environment has been
    # created. A patch shipped beside the installer seeds a genuinely fresh
    # installation only when no install-owned candidate exists yet.
    local script_patch install_patch
    script_patch="${SCRIPT_DIR}/plumed_patch"
    install_patch="${INSTALL_ROOT}/plumed_patch"
    if [[ -f "${install_patch}/SAXS.cpp" || -f "${install_patch}/src/isdb/SAXS.cpp" ]]; then
      printf '%s\n' "${install_patch}"
    elif [[ -d "${script_patch}" ]]; then
      printf '%s\n' "${script_patch}"
    elif [[ -d "${install_patch}" ]]; then
      printf '%s\n' "${install_patch}"
    else
      printf '%s\n' "${install_patch}"
    fi
  else
    abspath "${PLUMED_PATCH_DIR}"
  fi
}

select_saxs_candidate_from_dir() {
  # select_saxs_candidate_from_dir <patch-dir>
  # Refuse ambiguous direct/nested candidates unless their bytes are identical.
  local patch_dir="${1}" direct nested
  direct="${patch_dir}/SAXS.cpp"
  nested="${patch_dir}/src/isdb/SAXS.cpp"
  if [[ -f "${direct}" && -f "${nested}" ]]; then
    cmp -s -- "${direct}" "${nested}" \
      || die "Two different SAXS.cpp candidates exist under ${patch_dir}. Keep one, make them identical, or pass --saxs-cpp explicitly."
    printf '%s\n' "${direct}"
  elif [[ -f "${direct}" ]]; then
    printf '%s\n' "${direct}"
  elif [[ -f "${nested}" ]]; then
    printf '%s\n' "${nested}"
  fi
}

apply_plumed_local_patches() {
  # apply_plumed_local_patches <plumed-source-tree>
  # Currently supports a development override for src/isdb/SAXS.cpp.
  local plumed_src="${1}"
  local patch_dir candidate target backup_dir canonical timestamp

  patch_dir="$(resolve_plumed_patch_dir)"
  target="${plumed_src}/src/isdb/SAXS.cpp"
  candidate=""

  if [[ -n "${PLUMED_SAXS_CPP}" ]]; then
    candidate="$(abspath "${PLUMED_SAXS_CPP}")"
  else
    candidate="$(select_saxs_candidate_from_dir "${patch_dir}")"
  fi

  if [[ -n "${candidate}" ]]; then
    [[ -f "${candidate}" ]] || die "Configured SAXS.cpp override not found: ${candidate}"
    [[ -f "${target}" ]] || die "PLUMED SAXS.cpp target not found: ${target}"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="${INSTALL_ROOT}/saxs_updates/fresh-build-backups/${timestamp}"
    mkdir -p "${backup_dir}"
    cp -- "${target}" "${backup_dir}/SAXS.cpp.upstream"
    cp -- "${candidate}" "${backup_dir}/SAXS.cpp.candidate"

    # Seed/update the canonical install-owned development candidate so later
    # --update-saxs runs never depend on the installer's current directory.
    canonical="${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
    mkdir -p "$(dirname "${canonical}")"
    if [[ "$(abspath "${candidate}")" != "$(abspath "${canonical}")" ]]; then
      [[ ! -f "${canonical}" ]] || cp -- "${canonical}" "${backup_dir}/SAXS.cpp.previous-canonical"
      cp -- "${candidate}" "${canonical}"
    fi
    candidate="${canonical}"
    cp -- "${candidate}" "${target}"
    LAST_SAXS_CANDIDATE="${candidate}"
    info "Applied local SAXS.cpp override: ${candidate} -> ${target}"
    info "Persistent fresh-build SAXS backup: ${backup_dir}"
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

###############################################################################
# Incremental SAXS-only update and persistent installation reporting (v31)
###############################################################################
plumed_build_kernel_path() {
  local plumed_src="${1}" candidate
  for candidate in \
    "${plumed_src}/src/lib/libplumedKernel.so" \
    "${plumed_src}/src/lib/install/libplumedKernel.so" \
    "${plumed_src}/src/lib/libKernel.so"; do
    [[ -f "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

saxs_installed_state_matches() {
  local source_hash="${1}" kernel_hash="${2}" commit="${3}"
  local state="${INSTALL_ROOT}/saxs_updates/installed-state.txt"
  local recorded_source="" recorded_kernel="" recorded_commit="" key value
  [[ -f "${state}" ]] || return 1
  while IFS='=' read -r key value; do
    case "${key}" in
      source_sha256) recorded_source="${value}" ;;
      kernel_sha256) recorded_kernel="${value}" ;;
      plumed_commit) recorded_commit="${value}" ;;
    esac
  done < "${state}"
  [[ "${recorded_source}" == "${source_hash}" \
     && "${recorded_kernel}" == "${kernel_hash}" \
     && "${recorded_commit}" == "${commit}" ]]
}

write_saxs_installed_state() {
  local source_hash="${1}" kernel_hash="${2}" commit="${3}"
  local state_dir="${INSTALL_ROOT}/saxs_updates" state tmp
  state="${state_dir}/installed-state.txt"
  mkdir -p "${state_dir}" || return 1
  tmp="$(mktemp "${state_dir}/.installed-state.XXXXXX")" || return 1
  {
    echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "source_sha256=${source_hash}"
    echo "kernel_sha256=${kernel_hash}"
    echo "plumed_commit=${commit}"
    echo "update_id=${SAXS_UPDATE_ID}"
  } > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  mv -f -- "${tmp}" "${state}"
}

plumed_build_executable_path() {
  local plumed_src="${1}" candidate
  for candidate in \
    "${plumed_src}/src/lib/plumed" \
    "${plumed_src}/src/lib/install/plumed"; do
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

detect_gromacs_plumed_linkage() {
  local candidate output="" saw_runtime=0
  for candidate in \
    "${GMX_ROOT:-}/bin/gmx_mpi" \
    "${GMX_ROOT:-}/lib/libgromacs_mpi.so" \
    "${GMX_ROOT:-}/lib64/libgromacs_mpi.so"; do
    [[ -e "${candidate}" ]] || continue
    output="$(ldd "${candidate}" 2>/dev/null || true)"
    if grep -q 'libplumed' <<<"${output}"; then
      printf '%s\n' "shared"
      return 0
    fi
    if grep -aEq 'PLUMED_KERNEL|libplumedKernel' "${candidate}" 2>/dev/null; then
      saw_runtime=1
    fi
  done
  if [[ "${saw_runtime}" -eq 1 ]]; then
    printf '%s\n' "runtime"
  else
    printf '%s\n' "unknown"
  fi
}

installed_component_version() {
  # installed_component_version <component>
  local component="${1}" value=""
  case "${component}" in
    cuda)
      value="$("${CUDA_HOME}/bin/nvcc" --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | head -n1 || true)"
      ;;
    openmpi)
      value="$("${MPI_ROOT}/bin/mpirun" --version 2>/dev/null | head -n1 || true)"
      ;;
    fftw)
      value="$(readlink -f "${FFTW_ROOT}/lib/libfftw3.so" 2>/dev/null | xargs -r basename || true)"
      ;;
    boost)
      value="$(awk '/^#define BOOST_LIB_VERSION /{gsub(/\"/,"",$3); print $3; exit}' "${BOOST_ROOT}/include/boost/version.hpp" 2>/dev/null || true)"
      ;;
    fmt)
      value="$(awk '/^#define FMT_VERSION /{print $3; exit}' "${FMT_ROOT}/include/fmt/base.h" 2>/dev/null || true)"
      ;;
    spdlog)
      value="$(awk '/^#define SPDLOG_VER_(MAJOR|MINOR|PATCH) /{v[++n]=$3} END{if(n==3) print v[1]"."v[2]"."v[3]}' "${SPDLOG_ROOT}/include/spdlog/version.h" 2>/dev/null || true)"
      ;;
    arrayfire)
      [[ ! -f "${AF_ROOT}/etc/arrayfire_version.txt" ]] \
        || value="$(head -n1 "${AF_ROOT}/etc/arrayfire_version.txt" 2>/dev/null || true)"
      ;;
    plumed)
      value="$("${PLUMED_ROOT}/bin/plumed" --version 2>/dev/null | head -n1 || true)"
      ;;
    gromacs)
      local gmx_bin="${GMX_ROOT}/bin/gmx_mpi"
      [[ -x "${gmx_bin}" ]] || gmx_bin="${GMX_ROOT}/bin/gmx"
      if [[ -x "${gmx_bin}" ]]; then
        value="$("${gmx_bin}" --version 2>/dev/null | awk -F: '/GROMACS version/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' || true)"
      fi
      ;;
  esac
  printf '%s' "${value:-unknown}" | single_line
}

write_installation_reports() {
  # write_installation_reports <last-action>
  local action="${1}" report manifest report_tmp manifest_tmp timestamp host
  local plumed_src commit saxs_hash kernel_hash candidate_hash linkage
  local cuda_v mpi_v fftw_v boost_v fmt_v spdlog_v af_v plumed_v gmx_v

  report="${INSTALL_ROOT}/installation-info.txt"
  manifest="${INSTALL_ROOT}/installation-manifest.json"
  report_tmp="${report}.tmp.$$"
  manifest_tmp="${manifest}.tmp.$$"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  host="$(hostname 2>/dev/null || printf unknown)"
  plumed_src="${SRC}/plumed2"
  commit="$(git -C "${plumed_src}" rev-parse HEAD 2>/dev/null || true)"
  saxs_hash="$(sha256_file "${plumed_src}/src/isdb/SAXS.cpp" 2>/dev/null || true)"
  kernel_hash="$(sha256_file "${PLUMED_ROOT}/lib/libplumedKernel.so" 2>/dev/null || true)"
  candidate_hash="$(sha256_file "${INSTALL_ROOT}/plumed_patch/SAXS.cpp" 2>/dev/null || true)"
  linkage="$(detect_gromacs_plumed_linkage)"
  cuda_v="$(installed_component_version cuda)"
  mpi_v="$(installed_component_version openmpi)"
  fftw_v="$(installed_component_version fftw)"
  boost_v="$(installed_component_version boost)"
  fmt_v="$(installed_component_version fmt)"
  spdlog_v="$(installed_component_version spdlog)"
  af_v="$(installed_component_version arrayfire)"
  plumed_v="$(installed_component_version plumed)"
  gmx_v="$(installed_component_version gromacs)"

  {
    echo "Installation information"
    echo "========================"
    echo "Updated (UTC)       : ${timestamp}"
    echo "Host                : ${host}"
    echo "Installer           : ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "Last action         : ${action}"
    echo "Install root        : ${INSTALL_ROOT}"
    echo "Activation          : ${INSTALL_ROOT}/activate.sh"
    echo "Build logs          : ${LOG_DIR}"
    echo
    echo "PLUMED / SAXS"
    echo "---------------"
    echo "PLUMED prefix       : ${PLUMED_ROOT}"
    echo "PLUMED source       : ${plumed_src}"
    echo "PLUMED version      : ${plumed_v}"
    echo "PLUMED commit       : ${commit:-unknown}"
    echo "PLUMED config       : ${plumed_src}/src/config/config.txt"
    echo "SAXS source         : ${plumed_src}/src/isdb/SAXS.cpp"
    echo "SAXS source SHA-256 : ${saxs_hash:-missing}"
    echo "SAXS candidate      : ${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
    echo "Candidate SHA-256   : ${candidate_hash:-missing}"
    echo "Installed kernel    : ${PLUMED_ROOT}/lib/libplumedKernel.so"
    echo "Kernel SHA-256      : ${kernel_hash:-missing}"
    echo "GROMACS linkage     : ${linkage}"
    echo "Update history      : ${INSTALL_ROOT}/saxs_updates/history.jsonl"
    echo "Update backups      : ${INSTALL_ROOT}/saxs_updates/backups"
    echo
    echo "Installed components"
    echo "--------------------"
    echo "CUDA                : ${CUDA_HOME} (${cuda_v})"
    echo "OpenMPI             : ${MPI_ROOT} (${mpi_v})"
    echo "FFTW                : ${FFTW_ROOT} (${fftw_v})"
    echo "Boost               : ${BOOST_ROOT} (${boost_v})"
    echo "fmt                 : ${FMT_ROOT} (${fmt_v})"
    echo "spdlog              : ${SPDLOG_ROOT} (${spdlog_v})"
    echo "ArrayFire           : ${AF_ROOT} (${af_v})"
    echo "PLUMED              : ${PLUMED_ROOT} (${plumed_v})"
    echo "GROMACS             : ${GMX_ROOT} (${gmx_v})"
    echo
    echo "SAXS-only update command"
    echo "------------------------"
    echo "${SCRIPT_NAME} --dir $(printf '%q' "${DIR}") --name $(printf '%q' "${NAME}") --update-saxs -j ${NPROC}"
  } > "${report_tmp}" || return 1

  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "updated_at_utc": %s,\n' "$(json_string "${timestamp}")"
    printf '  "host": %s,\n' "$(json_string "${host}")"
    printf '  "installer": {"name": %s, "version": %s},\n' "$(json_string "${SCRIPT_NAME}")" "$(json_string "${SCRIPT_VERSION}")"
    printf '  "last_action": %s,\n' "$(json_string "${action}")"
    printf '  "install_root": %s,\n' "$(json_string "${INSTALL_ROOT}")"
    printf '  "activation_script": %s,\n' "$(json_string "${INSTALL_ROOT}/activate.sh")"
    printf '  "plumed": {\n'
    printf '    "prefix": %s,\n' "$(json_string "${PLUMED_ROOT}")"
    printf '    "source": %s,\n' "$(json_string "${plumed_src}")"
    printf '    "version": %s,\n' "$(json_string "${plumed_v}")"
    printf '    "git_commit": %s,\n' "$(json_string "${commit}")"
    printf '    "configuration": %s,\n' "$(json_string "${plumed_src}/src/config/config.txt")"
    printf '    "kernel": %s,\n' "$(json_string "${PLUMED_ROOT}/lib/libplumedKernel.so")"
    printf '    "kernel_sha256": %s\n' "$(json_string "${kernel_hash}")"
    printf '  },\n'
    printf '  "saxs": {\n'
    printf '    "source": %s,\n' "$(json_string "${plumed_src}/src/isdb/SAXS.cpp")"
    printf '    "source_sha256": %s,\n' "$(json_string "${saxs_hash}")"
    printf '    "canonical_candidate": %s,\n' "$(json_string "${INSTALL_ROOT}/plumed_patch/SAXS.cpp")"
    printf '    "candidate_sha256": %s,\n' "$(json_string "${candidate_hash}")"
    printf '    "history": %s,\n' "$(json_string "${INSTALL_ROOT}/saxs_updates/history.jsonl")"
    printf '    "backups": %s\n' "$(json_string "${INSTALL_ROOT}/saxs_updates/backups")"
    printf '  },\n'
    printf '  "gromacs": {"prefix": %s, "version": %s, "plumed_linkage": %s},\n' \
      "$(json_string "${GMX_ROOT}")" "$(json_string "${gmx_v}")" "$(json_string "${linkage}")"
    printf '  "components": {\n'
    printf '    "cuda": {"prefix": %s, "version": %s},\n' "$(json_string "${CUDA_HOME}")" "$(json_string "${cuda_v}")"
    printf '    "openmpi": {"prefix": %s, "version": %s},\n' "$(json_string "${MPI_ROOT}")" "$(json_string "${mpi_v}")"
    printf '    "fftw": {"prefix": %s, "version": %s},\n' "$(json_string "${FFTW_ROOT}")" "$(json_string "${fftw_v}")"
    printf '    "boost": {"prefix": %s, "version": %s},\n' "$(json_string "${BOOST_ROOT}")" "$(json_string "${boost_v}")"
    printf '    "fmt": {"prefix": %s, "version": %s},\n' "$(json_string "${FMT_ROOT}")" "$(json_string "${fmt_v}")"
    printf '    "spdlog": {"prefix": %s, "version": %s},\n' "$(json_string "${SPDLOG_ROOT}")" "$(json_string "${spdlog_v}")"
    printf '    "arrayfire": {"prefix": %s, "version": %s}\n' "$(json_string "${AF_ROOT}")" "$(json_string "${af_v}")"
    printf '  }\n'
    printf '}\n'
  } > "${manifest_tmp}" || return 1

  mv -f -- "${report_tmp}" "${report}" || return 1
  mv -f -- "${manifest_tmp}" "${manifest}" || return 1
  ok "Installation reports updated: ${report}, ${manifest}"
}

setup_saxs_update_environment() {
  local activate="${INSTALL_ROOT}/activate.sh"
  [[ -f "${activate}" ]] || die "Activation script not found: ${activate}"
  # This is the activation file generated for the selected installation. It
  # pins the dependency paths used by that build, avoiding toolchain drift.
  # shellcheck disable=SC1090
  source "${activate}" >/dev/null
  [[ -n "${CUDA_HOME:-}" && -x "${CUDA_HOME}/bin/nvcc" ]] \
    || die "The existing activate.sh does not provide a usable CUDA_HOME/bin/nvcc."
  CUDA_VERSION="$(get_cuda_version "${CUDA_HOME}/bin/nvcc")"
  setup_environment
  export AF_DISABLE_GRAPHICS="${AF_DISABLE_GRAPHICS:-1}"
}

validate_saxs_update_install() {
  local plumed_src="${SRC}/plumed2" config_install tracked_changes linkage prefix_record prefix_ok=0
  [[ -d "${INSTALL_ROOT}" ]] || die "Existing install root not found: ${INSTALL_ROOT}"
  [[ -d "${plumed_src}/.git" ]] || die "Retained PLUMED Git checkout not found: ${plumed_src}"
  [[ -f "${plumed_src}/Makefile" ]] || die "PLUMED checkout is not configured (Makefile missing): ${plumed_src}"
  [[ -f "${plumed_src}/src/config/config.txt" ]] || die "PLUMED configuration record missing: ${plumed_src}/src/config/config.txt"
  [[ -f "${plumed_src}/src/isdb/SAXS.cpp" ]] || die "PLUMED SAXS source missing: ${plumed_src}/src/isdb/SAXS.cpp"
  [[ -x "${PLUMED_ROOT}/bin/plumed" ]] || die "Installed PLUMED executable missing: ${PLUMED_ROOT}/bin/plumed"
  [[ -f "${PLUMED_KERNEL}" ]] || die "Installed PLUMED kernel missing: ${PLUMED_KERNEL}"
  [[ -x "${MPI_ROOT}/bin/mpicxx" ]] || die "Original MPI C++ wrapper missing: ${MPI_ROOT}/bin/mpicxx"

  config_install="${plumed_src}/src/config/ConfigInstall.inc"
  for prefix_record in "${config_install}" "${plumed_src}/config.status" "${plumed_src}/Makefile.conf"; do
    [[ -f "${prefix_record}" ]] || continue
    grep -Fq "${PLUMED_ROOT}" "${prefix_record}" && prefix_ok=1
  done
  [[ "${prefix_ok}" -eq 1 ]] \
    || die "Could not confirm ${PLUMED_ROOT} as the configured PLUMED install prefix; refusing an update that could install elsewhere."
  grep -Eq 'has arrayfire_cuda[[:space:]]+(on|yes)|__PLUMED_HAS_ARRAYFIRE_CUDA' \
    "${plumed_src}/src/config/config.txt" \
    || die "Retained PLUMED configuration does not report ArrayFire CUDA support."
  grep -Eq 'module isdb[[:space:]]+on' "${plumed_src}/src/config/config.txt" \
    || die "Retained PLUMED configuration does not report the ISDB module enabled."

  if [[ "${ALLOW_DIRTY_PLUMED}" -eq 0 ]]; then
    tracked_changes="$(git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null \
      | sed '/^src\/isdb\/SAXS\.cpp$/d; /^$/d' | sort -u)"
    [[ -z "${tracked_changes}" ]] || die "PLUMED has tracked changes outside src/isdb/SAXS.cpp:\n${tracked_changes}\nCommit/stash them, or inspect carefully and rerun with --allow-dirty-plumed."
  fi

  linkage="$(detect_gromacs_plumed_linkage)"
  [[ "${linkage}" != "unknown" ]] \
    || die "Could not verify shared/runtime PLUMED linkage in the installed GROMACS. Rebuilding only PLUMED is unsafe until linkage is confirmed."
}

resolve_saxs_update_candidate() {
  local canonical="${INSTALL_ROOT}/plumed_patch/SAXS.cpp" patch_dir candidate=""
  if [[ -n "${PLUMED_SAXS_CPP}" ]]; then
    candidate="$(abspath "${PLUMED_SAXS_CPP}")"
  else
    patch_dir="${INSTALL_ROOT}/plumed_patch"
    candidate="$(select_saxs_candidate_from_dir "${patch_dir}")"
  fi
  [[ -n "${candidate}" && -f "${candidate}" ]] || die "No SAXS.cpp update candidate found. Place it at ${canonical}, or pass --saxs-cpp /absolute/path/SAXS.cpp."
  printf '%s\n' "${candidate}"
}

print_saxs_update_plan() {
  local candidate="${1}" old_hash="${2}" new_hash="${3}" commit="${4}" kernel_hash="${5}" linkage="${6}"
  section "SAXS-only incremental update plan"
  printf '  %-24s : %s\n' "Install root" "${INSTALL_ROOT}"
  printf '  %-24s : %s\n' "PLUMED source" "${SRC}/plumed2"
  printf '  %-24s : %s\n' "PLUMED commit" "${commit}"
  printf '  %-24s : %s\n' "Configured target" "${SRC}/plumed2/src/isdb/SAXS.cpp"
  printf '  %-24s : %s\n' "Candidate" "${candidate}"
  printf '  %-24s : %s\n' "Current SAXS SHA-256" "${old_hash}"
  printf '  %-24s : %s\n' "New SAXS SHA-256" "${new_hash}"
  printf '  %-24s : %s\n' "Current kernel SHA-256" "${kernel_hash}"
  printf '  %-24s : %s\n' "GROMACS linkage" "${linkage}"
  if [[ "${SAXS_UPDATE_PYTHON_ENABLED}" -eq 1 ]]; then
    printf '  %-24s : %s\n' "PLUMED Python" "enabled (retained)"
    printf '  %-24s : %s\n' "Configured python_bin" "${SAXS_UPDATE_PYTHON_CONFIGURED} -> ${SAXS_UPDATE_PYTHON_RESOLVED}"
    printf '  %-24s : %s\n' "Python build tooling" "${SAXS_UPDATE_PYTHON_BUILD_STATUS}"
    printf '  %-24s : %s\n' "Current build origin" "${SAXS_UPDATE_PYTHON_BUILD_ORIGIN:-unresolved}"
  else
    printf '  %-24s : %s\n' "PLUMED Python" "disabled (retained)"
  fi
  printf '  %-24s : %s\n' "Rollback scope" "full PLUMED prefix + pre-update tracked source state"
  printf '  %-24s : %s\n' "Rootless install" "no sudo/system-prefix writes; managed support stays under install root"
  printf '  %-24s : %s\n' "Parallel jobs" "${NPROC}"
  printf '  %-24s : %s\n' "PLUMED installcheck" "$([[ "${RUN_INSTALLCHECK}" -eq 1 ]] && echo enabled || echo skipped)"
  echo
  echo "  Will run: retained-Python dependency validation when needed, incremental"
  echo "            make -j${NPROC}, build-tree SAXS/kernel checks, complete PLUMED-prefix"
  echo "            snapshot, make install, installed checks, and GROMACS hash check."
  echo "  Will not: clone, fetch, checkout, configure, clean, patch, build, or install GROMACS."
  echo "            It never invokes sudo or a system package manager."
  if [[ "${old_hash}" == "${new_hash}" && "${FORCE}" -eq 0 ]]; then
    echo
    if saxs_installed_state_matches "${new_hash}" "${kernel_hash}" "${commit}"; then
      info "Candidate, recorded installed source, kernel, and PLUMED commit all match; the real run will be a no-op."
    else
      warn "Candidate already matches the retained source, but no matching successful-install record exists; the real run will rebuild and reinstall PLUMED."
    fi
  fi
}

prepare_saxs_update_backup() {
  local candidate="${1}" canonical="${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
  local backup_root="${INSTALL_ROOT}/saxs_updates/backups" lib backup_id
  local prefix_parent prefix_name prefix_size_kb avail_kb safety_kb snapshot
  backup_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  SAXS_UPDATE_ID="${backup_id}"
  SAXS_UPDATE_BACKUP_DIR="${backup_root}/${backup_id}"
  mkdir -p "${SAXS_UPDATE_BACKUP_DIR}/installed-lib"
  cp -- "${SAXS_UPDATE_TARGET}" "${SAXS_UPDATE_BACKUP_DIR}/SAXS.cpp.before"
  cp -- "${candidate}" "${SAXS_UPDATE_BACKUP_DIR}/SAXS.cpp.candidate"
  if [[ -f "${canonical}" ]]; then
    cp -- "${canonical}" "${SAXS_UPDATE_BACKUP_DIR}/SAXS.cpp.previous-canonical"
  fi

  # Preserve the complete pre-update tracked worktree state outside SAXS.cpp.
  # This keeps generated files such as python/plumed.c from contaminating the
  # retained Git tree, and it also preserves explicitly allowed dirty files.
  SAXS_UPDATE_TRACKED_DIRTY_LIST="${SAXS_UPDATE_BACKUP_DIR}/tracked-dirty-before.txt"
  SAXS_UPDATE_TRACKED_MISSING_LIST="${SAXS_UPDATE_BACKUP_DIR}/tracked-missing-before.txt"
  SAXS_UPDATE_TRACKED_DIRTY_ARCHIVE="${SAXS_UPDATE_BACKUP_DIR}/tracked-existing-before.tar"
  git -C "${SRC}/plumed2" diff --name-only HEAD -- 2>/dev/null \
    | sed '/^src\/isdb\/SAXS\.cpp$/d; /^$/d' | sort -u > "${SAXS_UPDATE_TRACKED_DIRTY_LIST}"
  : > "${SAXS_UPDATE_TRACKED_MISSING_LIST}"
  local tracked_existing_list="${SAXS_UPDATE_BACKUP_DIR}/tracked-existing-before.txt" tracked_path
  : > "${tracked_existing_list}"
  while IFS= read -r tracked_path; do
    [[ -n "${tracked_path}" ]] || continue
    if [[ -e "${SRC}/plumed2/${tracked_path}" || -L "${SRC}/plumed2/${tracked_path}" ]]; then
      printf '%s\n' "${tracked_path}" >> "${tracked_existing_list}"
    else
      printf '%s\n' "${tracked_path}" >> "${SAXS_UPDATE_TRACKED_MISSING_LIST}"
    fi
  done < "${SAXS_UPDATE_TRACKED_DIRTY_LIST}"
  if [[ -s "${tracked_existing_list}" ]]; then
    tar -C "${SRC}/plumed2" -cpf "${SAXS_UPDATE_TRACKED_DIRTY_ARCHIVE}" -T "${tracked_existing_list}" \
      || die "Could not snapshot pre-existing tracked PLUMED source changes."
  else
    SAXS_UPDATE_TRACKED_DIRTY_ARCHIVE=""
  fi

  # Keep the v30 shared-library copies for quick inspection/backward-compatible
  # diagnostics, but v31 rollback uses the complete prefix snapshot below.
  shopt -s nullglob
  local plumed_libs=("${PLUMED_ROOT}/lib"/libplumed*.so*)
  shopt -u nullglob
  [[ "${#plumed_libs[@]}" -gt 0 ]] || die "No installed libplumed shared libraries found under ${PLUMED_ROOT}/lib"
  for lib in "${plumed_libs[@]}"; do
    cp -a -- "${lib}" "${SAXS_UPDATE_BACKUP_DIR}/installed-lib/"
  done

  # make install can replace more than libplumed*.so*: executables, headers,
  # static libraries, CMake/pkg-config files, Python modules and data. Snapshot
  # the entire installed PLUMED prefix so rollback removes partial/new files too.
  prefix_parent="$(dirname "${PLUMED_ROOT}")"
  prefix_name="$(basename "${PLUMED_ROOT}")"
  snapshot="${SAXS_UPDATE_BACKUP_DIR}/plumed-prefix.before.tar"
  prefix_size_kb="$(du -sk "${PLUMED_ROOT}" 2>/dev/null | awk '{print $1}')"
  avail_kb="$(df -Pk "${SAXS_UPDATE_BACKUP_DIR}" 2>/dev/null | awk 'NR==2{print $4}')"
  safety_kb=$(( 100 * 1024 ))
  if [[ -n "${prefix_size_kb}" && -n "${avail_kb}" ]]; then
    (( avail_kb > prefix_size_kb + safety_kb )) \
      || die "Insufficient free space for transactional PLUMED snapshot: prefix=${prefix_size_kb} KiB, available=${avail_kb} KiB. Free space or move the installation to a larger user-owned filesystem."
  fi
  tar -C "${prefix_parent}" -cpf "${snapshot}" "${prefix_name}" \
    || die "Could not create complete PLUMED prefix snapshot: ${snapshot}"
  SAXS_UPDATE_PREFIX_SNAPSHOT="${snapshot}"
  SAXS_UPDATE_PREFIX_SNAPSHOT_SHA256="$(sha256_file "${snapshot}")"

  {
    echo "backup_id=${backup_id}"
    echo "created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "plumed_commit=${SAXS_UPDATE_COMMIT}"
    echo "source_before_sha256=${SAXS_UPDATE_OLD_HASH}"
    echo "candidate_sha256=${SAXS_UPDATE_NEW_HASH}"
    echo "kernel_before_sha256=${SAXS_UPDATE_OLD_KERNEL_HASH}"
    echo "candidate_original_path=${candidate}"
    echo "plumed_prefix_snapshot=${snapshot}"
    echo "plumed_prefix_snapshot_sha256=${SAXS_UPDATE_PREFIX_SNAPSHOT_SHA256}"
    echo "plumed_prefix_size_kib=${prefix_size_kb:-unknown}"
    echo "python_enabled=${SAXS_UPDATE_PYTHON_ENABLED}"
    echo "python_configured=${SAXS_UPDATE_PYTHON_CONFIGURED}"
    echo "python_resolved=${SAXS_UPDATE_PYTHON_RESOLVED}"
    echo "python_build_status_before=${SAXS_UPDATE_PYTHON_BUILD_STATUS}"
    echo "python_build_origin_before=${SAXS_UPDATE_PYTHON_BUILD_ORIGIN}"
    echo "python_build_version_before=${SAXS_UPDATE_PYTHON_BUILD_VERSION}"
    echo "tracked_dirty_before_count=$(wc -l < "${SAXS_UPDATE_TRACKED_DIRTY_LIST}" | tr -d ' ')"
    echo "status=prepared"
  } > "${SAXS_UPDATE_BACKUP_DIR}/backup-info.txt"
  ok "Transactional rollback snapshot created: ${SAXS_UPDATE_BACKUP_DIR}"
}


restore_saxs_update_tracked_source_state() {
  # Restore every tracked PLUMED path outside src/isdb/SAXS.cpp to its exact
  # pre-update worktree state. The Git index is intentionally untouched.
  local plumed_src="${SRC}/plumed2" before="${SAXS_UPDATE_TRACKED_DIRTY_LIST}"
  local missing="${SAXS_UPDATE_TRACKED_MISSING_LIST}" archive="${SAXS_UPDATE_TRACKED_DIRTY_ARCHIVE}"
  local after path
  [[ -d "${plumed_src}/.git" && -n "${before}" && -f "${before}" ]] || return 0
  after="${SAXS_UPDATE_BACKUP_DIR}/tracked-dirty-after-build.txt"
  git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null \
    | sed '/^src\/isdb\/SAXS\.cpp$/d; /^$/d' | sort -u > "${after}"

  # Any newly dirtied tracked path was clean before the update: restore it from
  # HEAD. This covers generated Cython/config files without special-casing them.
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if ! grep -Fxq -- "${path}" "${before}"; then
      git -C "${plumed_src}" restore --source=HEAD --worktree -- "${path}" \
        || return 1
    fi
  done < "${after}"

  # Reapply exact pre-existing dirty working-tree bytes/modes, if any.
  if [[ -n "${archive}" && -f "${archive}" ]]; then
    tar -C "${plumed_src}" -xpf "${archive}" || return 1
  fi
  if [[ -n "${missing}" && -f "${missing}" ]]; then
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      rm -f -- "${plumed_src}/${path}" || return 1
    done < "${missing}"
  fi

  # Verify that the set of tracked dirty paths outside SAXS is exactly the same
  # as before. Content for pre-existing files came from the snapshot above.
  git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null \
    | sed '/^src\/isdb\/SAXS\.cpp$/d; /^$/d' | sort -u > "${after}"
  cmp -s -- "${before}" "${after}"
}

restore_failed_saxs_update() {
  [[ "${SAXS_UPDATE_ACTIVE}" -eq 1 && -n "${SAXS_UPDATE_BACKUP_DIR}" ]] || return 0
  local saved lib prefix_snapshot prefix_parent prefix_name restore_stage failed_live
  local restored=0 moved_live=0 snapshot_ok=1 current_snapshot_hash=""
  trap - ERR
  set +e
  warn "Restoring the pre-update SAXS source and complete installed PLUMED prefix."

  saved="${SAXS_UPDATE_BACKUP_DIR}/SAXS.cpp.before"
  [[ -f "${saved}" ]] && cp -- "${saved}" "${SAXS_UPDATE_TARGET}" && touch "${SAXS_UPDATE_TARGET}"
  restore_saxs_update_tracked_source_state \
    || warn "Could not fully restore the retained PLUMED tracked-source state; inspect Git status before retrying."

  prefix_snapshot="${SAXS_UPDATE_BACKUP_DIR}/plumed-prefix.before.tar"
  if [[ -f "${prefix_snapshot}" ]]; then
    if [[ -n "${SAXS_UPDATE_PREFIX_SNAPSHOT_SHA256}" ]]; then
      current_snapshot_hash="$(sha256_file "${prefix_snapshot}" 2>/dev/null || true)"
      if [[ "${current_snapshot_hash}" != "${SAXS_UPDATE_PREFIX_SNAPSHOT_SHA256}" ]]; then
        snapshot_ok=0
        warn "Complete PLUMED prefix snapshot hash mismatch; refusing to restore a possibly corrupted archive."
      fi
    fi
    if [[ "${snapshot_ok}" -eq 1 ]]; then
      prefix_parent="$(dirname "${PLUMED_ROOT}")"
      prefix_name="$(basename "${PLUMED_ROOT}")"
      restore_stage="${INSTALL_ROOT}/.saxs-prefix-restore-${SAXS_UPDATE_ID}-$$"
      failed_live="${INSTALL_ROOT}/.saxs-prefix-failed-${SAXS_UPDATE_ID}-$$"
      rm -rf -- "${restore_stage}" "${failed_live}"
      mkdir -p "${restore_stage}"
      if tar -C "${restore_stage}" -xpf "${prefix_snapshot}" \
         && [[ -d "${restore_stage}/${prefix_name}" ]]; then
        if [[ -e "${PLUMED_ROOT}" || -L "${PLUMED_ROOT}" ]]; then
          if mv -- "${PLUMED_ROOT}" "${failed_live}"; then
            moved_live=1
          else
            warn "Could not move the failed live PLUMED prefix aside; leaving it untouched and skipping complete-prefix activation."
          fi
        else
          moved_live=1
        fi

        if [[ "${moved_live}" -eq 1 ]]; then
          if mv -- "${restore_stage}/${prefix_name}" "${PLUMED_ROOT}"; then
            restored=1
            rm -rf -- "${failed_live}" "${restore_stage}"
          else
            warn "Could not activate the restored PLUMED prefix; attempting to put the failed live prefix back."
            rm -rf -- "${PLUMED_ROOT}"
            if [[ -e "${failed_live}" || -L "${failed_live}" ]]; then
              mv -- "${failed_live}" "${PLUMED_ROOT}" \
                || warn "CRITICAL: could not restore either PLUMED prefix automatically; preserve ${SAXS_UPDATE_BACKUP_DIR} and repair manually."
            fi
            rm -rf -- "${restore_stage}"
          fi
        else
          rm -rf -- "${restore_stage}"
        fi
      else
        warn "Could not extract the complete PLUMED prefix snapshot: ${prefix_snapshot}"
        rm -rf -- "${restore_stage}"
      fi
    fi
  fi

  # Backward-compatible emergency fallback if the complete snapshot could not
  # be restored. This cannot remove files introduced by a partial make install,
  # so v31 reports the degraded rollback state explicitly.
  if [[ "${restored}" -eq 0 ]]; then
    warn "Complete-prefix rollback was unavailable/failed; falling back to saved libplumed shared libraries."
    mkdir -p "${PLUMED_ROOT}/lib"
    shopt -s nullglob
    local saved_libs=("${SAXS_UPDATE_BACKUP_DIR}/installed-lib"/*)
    shopt -u nullglob
    for lib in "${saved_libs[@]}"; do
      cp -a -- "${lib}" "${PLUMED_ROOT}/lib/"
    done
  fi

  echo "status=failed-restored" >> "${SAXS_UPDATE_BACKUP_DIR}/backup-info.txt"
  echo "rollback_complete_prefix=${restored}" >> "${SAXS_UPDATE_BACKUP_DIR}/backup-info.txt"
  if [[ "${restored}" -eq 1 ]]; then
    warn "Complete installed PLUMED prefix restored from ${prefix_snapshot}. The new canonical SAXS candidate was retained for diagnosis/retry."
  else
    warn "Only the emergency shared-library rollback could be completed; inspect ${SAXS_UPDATE_BACKUP_DIR} before reusing the installation."
  fi
  set -e
  SAXS_UPDATE_ACTIVE=0
}

handle_failed_saxs_update() {
  local rc="${1:-1}" note="${2:-operation failed}" line="${3:-unknown}"
  [[ "${SAXS_UPDATE_ACTIVE:-0}" -eq 1 ]] || return 0
  [[ "${SAXS_UPDATE_FAILURE_HANDLED:-0}" -eq 0 ]] || return 0
  SAXS_UPDATE_FAILURE_HANDLED=1
  restore_failed_saxs_update
  set +e
  SAXS_UPDATE_NEW_KERNEL_HASH="$(sha256_file "${PLUMED_KERNEL:-/nonexistent}" 2>/dev/null || true)"
  append_saxs_update_history "failed-restored" "${note} at line ${line} with exit ${rc}"
  set -e
}

append_saxs_update_history() {
  local status="${1}" note="${2:-}" history="${INSTALL_ROOT}/saxs_updates/history.jsonl"
  mkdir -p "$(dirname "${history}")"
  printf '{"timestamp_utc":%s,"status":%s,"update_id":%s,"plumed_commit":%s,"source_before_sha256":%s,"candidate_sha256":%s,"kernel_before_sha256":%s,"kernel_after_sha256":%s,"backup":%s,"prefix_snapshot":%s,"python_enabled":%s,"python_configured":%s,"python_resolved":%s,"python_build_origin":%s,"python_build_version":%s,"note":%s}\n' \
    "$(json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$(json_string "${status}")" \
    "$(json_string "${SAXS_UPDATE_ID}")" \
    "$(json_string "${SAXS_UPDATE_COMMIT}")" \
    "$(json_string "${SAXS_UPDATE_OLD_HASH}")" \
    "$(json_string "${SAXS_UPDATE_NEW_HASH}")" \
    "$(json_string "${SAXS_UPDATE_OLD_KERNEL_HASH}")" \
    "$(json_string "${SAXS_UPDATE_NEW_KERNEL_HASH}")" \
    "$(json_string "${SAXS_UPDATE_BACKUP_DIR}")" \
    "$(json_string "${SAXS_UPDATE_PREFIX_SNAPSHOT}")" \
    "$(json_string "${SAXS_UPDATE_PYTHON_ENABLED}")" \
    "$(json_string "${SAXS_UPDATE_PYTHON_CONFIGURED}")" \
    "$(json_string "${SAXS_UPDATE_PYTHON_RESOLVED}")" \
    "$(json_string "${SAXS_UPDATE_PYTHON_BUILD_ORIGIN}")" \
    "$(json_string "${SAXS_UPDATE_PYTHON_BUILD_VERSION}")" \
    "$(json_string "${note}")" >> "${history}"
}

validate_built_saxs() {
  local plumed_src="${1}" build_kernel build_plumed build_libdir info_out
  build_kernel="$(plumed_build_kernel_path "${plumed_src}")" \
    || die "Incremental build finished but no build-tree PLUMED kernel was found."
  assert_no_missing_libs "${build_kernel}" "Build-tree PLUMED kernel"
  build_plumed="$(plumed_build_executable_path "${plumed_src}")" \
    || die "Incremental build finished but no build-tree plumed executable was found."
  build_libdir="${plumed_src}/src/lib"
  info_out="${SAXS_UPDATE_BACKUP_DIR}/plumed-manual-build-tree.txt"
  info "Build-tree action check uses kernel: ${build_kernel}"
  env -u PLUMED_ROOT -u PLUMED_PREFIX -u PLUMED_KERNEL -u PLUMED_INSTALL_PREFIX \
    LD_LIBRARY_PATH="${build_libdir}:${LD_LIBRARY_PATH:-}" \
    PLUMED_PREPEND_PATH="${build_libdir}" \
    "${build_plumed}" --no-mpi manual --action SAXS > "${info_out}" 2>&1 \
    || die "Build-tree 'plumed manual --action SAXS' failed; see ${info_out}"
  grep -q 'SAXS' "${info_out}" || die "Build-tree PLUMED manual did not contain the SAXS action."
  ok "Build-tree SAXS action and kernel validated."
}

validate_installed_saxs() {
  local info_out="${SAXS_UPDATE_BACKUP_DIR}/plumed-manual-installed.txt"
  [[ -f "${PLUMED_KERNEL}" ]] || die "Installed PLUMED kernel missing after make install: ${PLUMED_KERNEL}"
  assert_no_missing_libs "${PLUMED_KERNEL}" "Installed PLUMED kernel"
  env PLUMED_PREFIX="${PLUMED_ROOT}" \
      PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" \
      PLUMED_KERNEL="${PLUMED_KERNEL}" \
      "${PLUMED_ROOT}/bin/plumed" --is-installed
  env PLUMED_PREFIX="${PLUMED_ROOT}" \
      PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" \
      PLUMED_KERNEL="${PLUMED_KERNEL}" \
      "${PLUMED_ROOT}/bin/plumed" --no-mpi manual --action SAXS > "${info_out}" 2>&1 \
    || die "Installed 'plumed manual --action SAXS' failed; see ${info_out}"
  grep -q 'SAXS' "${info_out}" || die "Installed PLUMED manual did not contain the SAXS action."
  ok "Installed SAXS action and kernel validated."
}

run_saxs_update() {
  local plumed_src candidate canonical old_hash new_hash kernel_hash commit linkage
  local gmx_bin="" gmx_hash_before="" gmx_hash_after=""
  CURRENT_OPERATION="update-saxs"
  plumed_src="${SRC}/plumed2"
  SAXS_UPDATE_TARGET="${plumed_src}/src/isdb/SAXS.cpp"

  [[ -d "${INSTALL_ROOT}" ]] || die "Existing install root not found: ${INSTALL_ROOT}"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/saxs_update_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    info "Logging SAXS update to ${LOG_FILE}"
    command -v flock >/dev/null 2>&1 || die "flock is required for safe SAXS updates."
    exec 9>"${INSTALL_ROOT}/.saxs-update.lock"
    flock -n 9 || die "Another SAXS update appears to be running for ${INSTALL_ROOT}."
  fi

  setup_saxs_update_environment
  validate_saxs_update_install
  inspect_saxs_update_python "${plumed_src}"
  candidate="$(resolve_saxs_update_candidate)"
  canonical="${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
  old_hash="$(sha256_file "${SAXS_UPDATE_TARGET}")"
  new_hash="$(sha256_file "${candidate}")"
  kernel_hash="$(sha256_file "${PLUMED_KERNEL}")"
  commit="$(git -C "${plumed_src}" rev-parse HEAD)"
  linkage="$(detect_gromacs_plumed_linkage)"
  SAXS_UPDATE_SOURCE="${candidate}"
  SAXS_UPDATE_OLD_HASH="${old_hash}"
  SAXS_UPDATE_NEW_HASH="${new_hash}"
  SAXS_UPDATE_OLD_KERNEL_HASH="${kernel_hash}"
  SAXS_UPDATE_COMMIT="${commit}"
  LAST_SAXS_CANDIDATE="${candidate}"

  print_saxs_update_plan "${candidate}" "${old_hash}" "${new_hash}" "${commit}" "${kernel_hash}" "${linkage}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "Dry run complete; no files were changed."
    return 0
  fi

  if [[ "${old_hash}" == "${new_hash}" && "${FORCE}" -eq 0 ]]; then
    if saxs_installed_state_matches "${new_hash}" "${kernel_hash}" "${commit}"; then
      info "No SAXS source or installed-state change detected; nothing was rebuilt or installed."
      write_installation_reports "saxs-update-noop"
      return 0
    fi
    warn "The retained source already has the candidate hash, but its successful installed state is unverified. Rebuilding instead of treating this as a no-op."
  fi

  if [[ -x "${GMX_ROOT}/bin/gmx_mpi" ]]; then
    gmx_bin="${GMX_ROOT}/bin/gmx_mpi"
  elif [[ -x "${GMX_ROOT}/bin/gmx" ]]; then
    gmx_bin="${GMX_ROOT}/bin/gmx"
  fi
  [[ -z "${gmx_bin}" ]] || gmx_hash_before="$(sha256_file "${gmx_bin}")"

  prepare_saxs_update_backup "${candidate}"
  SAXS_UPDATE_ACTIVE=1

  # Preserve the retained PLUMED Python capability. If the current interpreter
  # cannot execute PyPA build (for example because an unrelated namespace
  # package called 'build' shadows it), repair only through install-root-local
  # packages and keep that PYTHONPATH for both make and make install.
  ensure_saxs_update_python_build_module
  {
    echo "python_build_status_after=${SAXS_UPDATE_PYTHON_BUILD_STATUS}"
    echo "python_build_origin_after=${SAXS_UPDATE_PYTHON_BUILD_ORIGIN}"
    echo "python_build_version_after=${SAXS_UPDATE_PYTHON_BUILD_VERSION}"
    echo "python_build_deps_dir=${SAXS_UPDATE_PYTHON_DEPS_DIR}"
    echo "python_pip_dir=${SAXS_UPDATE_PYTHON_PIP_DIR}"
  } >> "${SAXS_UPDATE_BACKUP_DIR}/backup-info.txt"

  mkdir -p "$(dirname "${canonical}")"
  if [[ "$(abspath "${candidate}")" != "$(abspath "${canonical}")" ]]; then
    cp -- "${candidate}" "${canonical}"
    candidate="${canonical}"
    SAXS_UPDATE_SOURCE="${candidate}"
    LAST_SAXS_CANDIDATE="${candidate}"
  fi
  cp -- "${candidate}" "${SAXS_UPDATE_TARGET}"
  touch "${SAXS_UPDATE_TARGET}"
  info "Replaced only: ${SAXS_UPDATE_TARGET}"

  # Guarantee recompilation even on filesystems with coarse timestamp
  # resolution. These are only SAXS build products, not source/configuration.
  rm -f -- \
    "${plumed_src}/src/isdb/SAXS.o" \
    "${plumed_src}/src/isdb/SAXS.cpp.o" \
    "${plumed_src}/src/isdb/deps/SAXS.d" \
    "${plumed_src}/src/isdb/deps/SAXS.cpp.d"

  cd "${plumed_src}"
  info "Running incremental PLUMED build (no clean/configure): make -j${NPROC}"
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX \
    make -j"${NPROC}"
  validate_built_saxs "${plumed_src}"

  info "Installing the rebuilt PLUMED artifacts into the existing prefix: ${PLUMED_ROOT}"
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX \
    make install
  validate_installed_saxs

  if [[ "${RUN_INSTALLCHECK}" -eq 1 ]]; then
    info "Running PLUMED installed regression tests: make installcheck"
    env PATH="${PLUMED_ROOT}/bin:${PATH}" \
        PLUMED_PREFIX="${PLUMED_ROOT}" \
        PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" \
        PLUMED_KERNEL="${PLUMED_KERNEL}" \
        make installcheck
    ok "PLUMED installcheck completed."
  fi

  restore_saxs_update_tracked_source_state \
    || die "The PLUMED build changed tracked source files outside src/isdb/SAXS.cpp and their pre-update state could not be restored."
  ok "Retained PLUMED tracked-source state outside SAXS.cpp was preserved."

  if [[ -n "${gmx_bin}" ]]; then
    gmx_hash_after="$(sha256_file "${gmx_bin}")"
    [[ "${gmx_hash_before}" == "${gmx_hash_after}" ]] \
      || die "Installed GROMACS changed during a SAXS-only update; rolling PLUMED back."
    ok "GROMACS executable was not modified (${gmx_hash_after})."
  fi

  SAXS_UPDATE_NEW_KERNEL_HASH="$(sha256_file "${PLUMED_KERNEL}")"
  {
    echo "kernel_after_sha256=${SAXS_UPDATE_NEW_KERNEL_HASH}"
    echo "gromacs_before_sha256=${gmx_hash_before}"
    echo "gromacs_after_sha256=${gmx_hash_after}"
    echo "installcheck=$([[ "${RUN_INSTALLCHECK}" -eq 1 ]] && echo passed || echo skipped)"
    echo "plumed_prefix_snapshot=${SAXS_UPDATE_PREFIX_SNAPSHOT}"
    echo "plumed_prefix_snapshot_sha256=${SAXS_UPDATE_PREFIX_SNAPSHOT_SHA256}"
    echo "python_build_status_final=${SAXS_UPDATE_PYTHON_BUILD_STATUS}"
    echo "python_build_origin_final=${SAXS_UPDATE_PYTHON_BUILD_ORIGIN}"
    echo "python_build_version_final=${SAXS_UPDATE_PYTHON_BUILD_VERSION}"
    echo "python_build_deps_dir=${SAXS_UPDATE_PYTHON_DEPS_DIR}"
    echo "status=success"
  } >> "${SAXS_UPDATE_BACKUP_DIR}/backup-info.txt"
  write_saxs_installed_state "${SAXS_UPDATE_NEW_HASH}" "${SAXS_UPDATE_NEW_KERNEL_HASH}" "${SAXS_UPDATE_COMMIT}" \
    || warn "Could not write the successful installed-source/kernel state marker; a repeated update will rebuild safely."
  # The live scientific artifacts are now validated. Metadata failures from
  # this point must not roll back a working kernel; report them as warnings.
  SAXS_UPDATE_ACTIVE=0
  append_saxs_update_history "success" "incremental PLUMED SAXS update; GROMACS unchanged" \
    || warn "Could not append SAXS update history."
  printf '%s\n' "${SAXS_UPDATE_ID}" > "${INSTALL_ROOT}/saxs_updates/latest-successful" \
    || warn "Could not update the latest-successful SAXS marker."
  write_installation_reports "saxs-update" \
    || warn "SAXS update succeeded, but installation reports could not be refreshed."

  section "SAXS update completed successfully"
  echo "  PLUMED commit       : ${SAXS_UPDATE_COMMIT}"
  echo "  SAXS SHA-256        : ${SAXS_UPDATE_NEW_HASH}"
  echo "  Kernel SHA-256      : ${SAXS_UPDATE_NEW_KERNEL_HASH}"
  echo "  GROMACS             : unchanged"
  if [[ "${SAXS_UPDATE_PYTHON_ENABLED}" -eq 1 ]]; then
    echo "  PLUMED Python       : retained (${SAXS_UPDATE_PYTHON_RESOLVED})"
    echo "  Python build        : ${SAXS_UPDATE_PYTHON_BUILD_VERSION:-unknown} @ ${SAXS_UPDATE_PYTHON_BUILD_ORIGIN:-unknown}"
  else
    echo "  PLUMED Python       : retained disabled"
  fi
  echo "  Prefix snapshot     : ${SAXS_UPDATE_PREFIX_SNAPSHOT}"
  echo "  Backup              : ${SAXS_UPDATE_BACKUP_DIR}"
  echo "  Log                 : ${LOG_FILE}"
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
  # GROMACS-only uses the normal C++ compiler. The full route prefers the
  # compiler behind the locally built OpenMPI wrapper.
  local wrapper="${MPI_ROOT}/bin/mpicxx" cmd ver
  if is_gromacs_only; then
    if [[ -n "${CXX:-}" ]] && command -v "${CXX}" >/dev/null 2>&1; then
      compiler_version_string "${CXX}"
    elif command -v g++ >/dev/null 2>&1; then
      compiler_version_string g++
    fi
    return 0
  fi
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

  if is_gromacs_only; then
    PLUMED_GROMACS_PATCH="not-used"
  elif [[ "${PLUMED_GROMACS_PATCH}" == "auto" || -z "${PLUMED_GROMACS_PATCH}" ]]; then
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

stage_gromacs_only() {
  resolve_gromacs_selection
  ensure_cmake_for_selected_gromacs
  section "GROMACS ${GROMACS_VERSION} (standalone thread-MPI + CUDA, SIMD=${GMX_SIMD})"

  local gmx_tarball="gromacs-${GROMACS_VERSION}.tar.gz"
  local gmx_src="${SRC}/gromacs-${GROMACS_VERSION}"
  local cc cxx
  cc="${CC:-$(command -v gcc)}"
  cxx="${CXX:-$(command -v g++)}"
  [[ -x "${cc}" ]] || die "C compiler not runnable: ${cc}"
  [[ -x "${cxx}" ]] || die "C++ compiler not runnable: ${cxx}"

  unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_PREFIX PLUMED_KERNEL 2>/dev/null || true
  export PATH="${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${FFTW_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="${FFTW_ROOT}:${CUDA_HOME}:${CMAKE_PREFIX_PATH:-}"

  cd "${SRC}"
  download_first_available "${gmx_tarball}" "${GROMACS_URL}" "${GROMACS_FTP_URL}"
  rm -rf "${gmx_src}"
  tar -xf "${gmx_tarball}"
  cd "${gmx_src}"

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
    -DCMAKE_C_COMPILER="${cc}" \
    -DCMAKE_CXX_COMPILER="${cxx}" \
    -DCMAKE_CUDA_COMPILER="${CUDACXX:-${CUDA_HOME}/bin/nvcc}" \
    -DGMX_MPI=OFF \
    -DGMX_THREAD_MPI=ON \
    -DGMX_OPENMP=ON \
    -DGMX_GPU=CUDA \
    -DGMX_BUILD_OWN_FFTW=OFF \
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
    -DCMAKE_PREFIX_PATH="${FFTW_ROOT};${CUDA_HOME}" \
    -DCMAKE_BUILD_RPATH="${FFTW_ROOT}/lib;${CUDA_HOME}/lib64;${CUDA_HOME}/targets/x86_64-linux/lib" \
    -DCMAKE_INSTALL_RPATH="${FFTW_ROOT}/lib;${CUDA_HOME}/lib64;${CUDA_HOME}/targets/x86_64-linux/lib" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
    "${nvml_args[@]}" \
    "${cuda_cccl_args[@]}" \
    "${cmake_iso[@]}"

  info "GROMACS standalone CUDA/thread-MPI cache entries:"
  grep -Ei "GMX_MPI|GMX_THREAD_MPI|GMX_OPENMP|GMX_GPU|CUDA|FFTWF|NVML" CMakeCache.txt || true

  grep -Eq '^GMX_MPI:BOOL=OFF$' CMakeCache.txt \
    || die "GROMACS-only configuration did not retain GMX_MPI=OFF."
  grep -Eq '^GMX_THREAD_MPI:BOOL=ON$' CMakeCache.txt \
    || die "GROMACS-only configuration did not retain GMX_THREAD_MPI=ON."

  make -j"${NPROC}"
  make install

  [[ -x "${GMX_ROOT}/bin/gmx" ]] || die "gmx not found after standalone GROMACS install."
  [[ ! -e "${GMX_ROOT}/bin/gmx_mpi" ]] \
    || warn "gmx_mpi also exists under the standalone prefix; the supported executable for this route is gmx."
  ok "Standalone thread-MPI GROMACS installed at ${GMX_ROOT}"
  mark_stage_done gromacs
}

stage_gromacs() {
  if is_gromacs_only; then
    stage_gromacs_only
    return 0
  fi
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
  local gmx_name gmx_bin
  gmx_name="$(gmx_executable_name)"
  gmx_bin="${GMX_ROOT}/bin/${gmx_name}"
  if [[ ! -x "${gmx_bin}" ]]; then
    warn "${gmx_name} not found; skipping final GROMACS checks."
    return 0
  fi

  if is_gromacs_only; then
    local version_out
    version_out="$({
      export GROMACS_DIR="${GMX_ROOT}"
      export GMXBIN="${GMX_ROOT}/bin"
      export GMXLDLIB="${GMX_ROOT}/lib"
      export GMXMAN="${GMX_ROOT}/share/man"
      export GMXDATA="${GMX_ROOT}/share/gromacs"
      export PATH="${GMX_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
      export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${FFTW_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
      unset PLUMED_ROOT PLUMED_PREFIX PLUMED_KERNEL AF_ROOT MPI_ROOT 2>/dev/null || true
      "${gmx_bin}" --version
    } 2>&1)"
    printf '%s\n' "${version_out}" | grep -Ei "GROMACS version|MPI library|OpenMP support|GPU support|CUDA" || true
    if ! grep -Eqi 'MPI library:[[:space:]]*thread_mpi|thread-MPI' <<<"${version_out}"; then
      die "Standalone GROMACS does not report the expected thread-MPI runtime."
    fi
    if ldd "${gmx_bin}" 2>/dev/null | grep -Eq 'libmpi\.so|libopen-pal\.so'; then
      die "Standalone gmx unexpectedly links an external MPI library."
    fi
    ok "GROMACS runtime check completed. Use: gmx mdrun -ntmpi <ranks> -ntomp <threads>."
    return 0
  fi

  local plumed_prefix="${INSTALL_ROOT}/plumed"
  (
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

  if stage_done fftw || [[ -e "${FFTW_ROOT}/lib/libfftw3f.so" ]]; then
    _pf_ok_file "${FFTW_ROOT}/lib/libfftw3f.so" "FFTW single-precision library"
  fi

  if is_gromacs_only; then
    local gmx_bin="${GMX_ROOT}/bin/gmx"
    _pf_ok_exe "${gmx_bin}" "GROMACS thread-MPI executable"
    if [[ -x "${gmx_bin}" ]]; then
      assert_no_missing_libs "${gmx_bin}" "GROMACS executable"
      if ldd "${gmx_bin}" 2>/dev/null | grep -Eq 'libmpi\.so|libopen-pal\.so'; then
        warn "Standalone gmx unexpectedly links external MPI"; failures=$((failures + 1))
      else
        ok "No external MPI linkage in standalone gmx"
      fi
      local version_out
      version_out="$("${gmx_bin}" --version 2>&1 || true)"
      if grep -Eqi 'MPI library:[[:space:]]*thread_mpi|thread-MPI' <<<"${version_out}"; then
        ok "GROMACS reports thread-MPI"
      else
        warn "GROMACS version output did not confirm thread-MPI"; failures=$((failures + 1))
      fi
      printf '%s\n' "${version_out}" | grep -Ei 'GROMACS version|MPI library|OpenMP support|GPU support|CUDA' || true
    fi
  else
    if stage_done openmpi || [[ -x "${MPI_ROOT}/bin/mpicc" ]]; then _pf_ok_exe "${MPI_ROOT}/bin/mpicc" "OpenMPI mpicc"; fi
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
      grep -Ei "has arrayfire|has arrayfire_cuda|has fftw|has mpi|module isdb" "${PLUMED_ROOT}/lib/plumed/src/config/config.txt" || true
    fi
  fi

  if [[ "${failures}" -gt 0 ]]; then
    warn "Post-flight found ${failures} missing or inconsistent expected item(s)."
  else
    ok "Post-flight checks completed."
  fi
}

###############################################################################
# Activation script + shell rc integration (requirement #4)
###############################################################################
generate_activate_script() {
  local out="${INSTALL_ROOT}/activate.sh"
  if is_gromacs_only; then
    local direct_gpu_block
    case "${GROMACS_VERSION}" in
      2024*)
        direct_gpu_block='unset GMX_GPU_DD_COMMS GMX_GPU_PME_PP_COMMS GMX_FORCE_UPDATE_DEFAULT_GPU GMX_DISABLE_DIRECT_GPU_COMM 2>/dev/null || true
export GMX_ENABLE_DIRECT_GPU_COMM="${GMX_ENABLE_DIRECT_GPU_COMM:-1}"'
        ;;
      *)
        direct_gpu_block='unset GMX_GPU_DD_COMMS GMX_GPU_PME_PP_COMMS GMX_FORCE_UPDATE_DEFAULT_GPU GMX_ENABLE_DIRECT_GPU_COMM GMX_DISABLE_DIRECT_GPU_COMM 2>/dev/null || true'
        ;;
    esac
    cat > "${out}" <<EOF
#!/usr/bin/env bash
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date).
# Standalone CUDA GROMACS with built-in thread-MPI: source "${out}"

export CUDA_HOME="${CUDA_HOME}"
export CUDA_ROOT="\${CUDA_HOME}"
export CUDACXX="\${CUDA_HOME}/bin/nvcc"
export FFTW_ROOT="${FFTW_ROOT}"
export GMX_ROOT="${GMX_ROOT}"

# Do not inherit a previously activated PLUMED/ArrayFire/external-MPI stack.
unset PLUMED_PREFIX PLUMED_ROOT PLUMED_KERNEL AF_ROOT MPI_ROOT BOOST_ROOT FMT_ROOT SPDLOG_ROOT 2>/dev/null || true

export GROMACS_DIR="\${GMX_ROOT}"
export GMXBIN="\${GMX_ROOT}/bin"
export GMXLDLIB="\${GMX_ROOT}/lib"
export GMXMAN="\${GMX_ROOT}/share/man"
export GMXDATA="\${GMX_ROOT}/share/gromacs"

export PATH="\${GMX_ROOT}/bin:\${CUDA_HOME}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GMX_ROOT}/lib:\${GMX_ROOT}/lib64:\${FFTW_ROOT}/lib:\${CUDA_HOME}/lib64:\${CUDA_HOME}/targets/x86_64-linux/lib:\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\${GMX_ROOT}/lib/pkgconfig:\${GMX_ROOT}/lib64/pkgconfig:\${FFTW_ROOT}/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="\${GMX_ROOT}:\${FFTW_ROOT}:\${CUDA_HOME}:\${CMAKE_PREFIX_PATH:-}"

# GROMACS 2024 uses GMX_ENABLE_DIRECT_GPU_COMM. In GROMACS 2025 direct GPU
# communication is enabled by default on supported setups. The older
# GMX_GPU_DD_COMMS and GMX_GPU_PME_PP_COMMS controls were removed, and
# GMX_FORCE_UPDATE_DEFAULT_GPU is not a supported current variable.
${direct_gpu_block}

echo "Activated '${NAME}': standalone thread-MPI GROMACS, GMX_ROOT=\${GMX_ROOT}, CUDA=\${CUDA_HOME}"
echo "Use 'gmx' (not gmx_mpi). GPU update is automatic when supported; use '-update gpu' to force it for a compatible run."
EOF
  else
    cat > "${out}" <<EOF
#!/usr/bin/env bash
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date).
# Activate the '${NAME}' CUDA/PLUMED/GROMACS build environment: source "${out}"

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

export PLUMED_PREFIX="${PLUMED_ROOT}"
export PLUMED_ROOT="\${PLUMED_PREFIX}/lib/plumed"
export PLUMED_KERNEL="\${PLUMED_PREFIX}/lib/libplumedKernel.so"
export AF_DISABLE_GRAPHICS="\${AF_DISABLE_GRAPHICS:-1}"

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
  fi
  chmod +x "${out}"
  printf '%s\n' "${out}"
}

write_rc_block() {
  # write_rc_block <rcfile>
  local rcfile="${1}"
  local rc_kind="CUDA/PLUMED"
  is_gromacs_only && rc_kind="CUDA/GROMACS-only"
  local start="# >>> ${NAME} ${rc_kind} env (managed by ${SCRIPT_NAME}) >>>"
  local end="# <<< ${NAME} ${rc_kind} env <<<"
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
  printf '  %-22s : %s\n' "Build mode"     "${BUILD_MODE}"
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
  if is_full_stack; then
    printf '  %-22s : %s\n' "PLUMED ref"     "${PLUMED_REF}"
    printf '  %-22s : %s\n' "PLUMED Python"  "$([[ "${PLUMED_DISABLE_PYTHON}" == "1" ]] && echo disabled || echo enabled)"
    printf '  %-22s : %s\n' "PLUMED patch dir" "$(resolve_plumed_patch_dir 2>/dev/null || printf '%s' "${PLUMED_PATCH_DIR}")"
    printf '  %-22s : %s\n' "SAXS override"   "${PLUMED_SAXS_CPP:-auto-detect}"
  else
    printf '  %-22s : %s\n' "PLUMED/ArrayFire" "not built"
  fi
  printf '  %-22s : %s\n' "GROMACS version" "${GROMACS_VERSION}"
  if is_full_stack; then
    printf '  %-22s : %s\n' "GROMACS patch" "${PLUMED_GROMACS_PATCH}"
    printf '  %-22s : %s\n' "GROMACS parallelism" "external MPI"
  else
    printf '  %-22s : %s\n' "GROMACS patch" "not used"
    printf '  %-22s : %s\n' "GROMACS parallelism" "thread-MPI (GMX_MPI=OFF)"
  fi
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
  echo "  Build mode: ${BUILD_MODE}"
  local s
  for s in "${STAGES[@]}"; do
    if stage_done "${s}"; then
      printf '  %-10s : %bdone%b   (%s)\n' "${s}" "${C_GRN}" "${C_RST}" \
        "$(cat "${CKPT_DIR}/${s}.done" 2>/dev/null)"
    else
      printf '  %-10s : %bpending%b\n' "${s}" "${C_YEL}" "${C_RST}"
    fi
  done
  if is_full_stack; then
    local status_src="${INSTALL_ROOT}/src/plumed2" status_saxs status_kernel status_commit
    status_saxs="$(sha256_file "${status_src}/src/isdb/SAXS.cpp" 2>/dev/null || true)"
    status_kernel="$(sha256_file "${INSTALL_ROOT}/plumed/lib/libplumedKernel.so" 2>/dev/null || true)"
    status_commit="$(git -C "${status_src}" rev-parse HEAD 2>/dev/null || true)"
    echo
    echo "  PLUMED/SAXS live state:"
    printf '  %-22s : %s\n' "PLUMED commit" "${status_commit:-missing}"
    printf '  %-22s : %s\n' "SAXS source SHA-256" "${status_saxs:-missing}"
    printf '  %-22s : %s\n' "Kernel SHA-256" "${status_kernel:-missing}"
    printf '  %-22s : %s\n' "Installation info" "${INSTALL_ROOT}/installation-info.txt"
    printf '  %-22s : %s\n' "Manifest" "${INSTALL_ROOT}/installation-manifest.json"
    printf '  %-22s : %s\n' "SAXS update history" "${INSTALL_ROOT}/saxs_updates/history.jsonl"
  fi
}

print_done_banner() {
  section "Build completed successfully"
  echo "  Install root : ${INSTALL_ROOT}"
  echo "  GROMACS      : ${GMX_ROOT}"
  echo "  FFTW         : ${FFTW_ROOT}"
  echo "  CUDA         : ${CUDA_HOME}"
  if is_full_stack; then
    echo "  PLUMED       : ${PLUMED_ROOT}"
    echo "  PLUMED kernel: ${PLUMED_KERNEL}"
    echo "  ArrayFire    : ${AF_ROOT}"
    echo "  fmt          : ${FMT_ROOT}"
    echo "  OpenMPI      : ${MPI_ROOT}"
  else
    echo "  Build mode   : GROMACS-only (thread-MPI; no PLUMED/ArrayFire/OpenMPI/Boost/fmt/spdlog)"
  fi
  echo "  Log file     : ${LOG_FILE}"
  echo
  echo "  Activate this environment with:"
  echo "      source \"${INSTALL_ROOT}/activate.sh\""
  if is_gromacs_only; then
    echo "      gmx --version"
    echo "      gmx mdrun -ntmpi 1 -nb gpu -pme gpu -bonded gpu -update gpu"
  else
    echo "      gmx_mpi --version"
    echo "      gmx_mpi mdrun -plumed plumed.dat"
  fi
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
  configure_build_mode
  validate_args

  # The incremental path deliberately does not auto-detect CUDA or resolve new
  # component versions. It sources the selected installation's activate.sh and
  # reuses the exact dependency/toolchain prefixes recorded there.
  if [[ "${UPDATE_SAXS}" -eq 1 ]]; then
    resolve_paths
    run_saxs_update
    return 0
  fi

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
    printf '%s\n' "${BUILD_MODE}" > "${INSTALL_ROOT}/.installer_build_mode"
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

  resolve_cuda_archs

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
    echo "Would write: ${INSTALL_ROOT}/activate.sh (${BUILD_MODE})"
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
      # A rebuild attempt must not retain a stale success checkpoint if the
      # selected stage fails part-way through.
      rm -f -- "${CKPT_DIR}/${s}.done"
      run_stage "${s}"
    else
      info "Skipping stage '${s}'."
    fi
  done

  # If we only built a subset, PLUMED/GROMACS may not be present yet; guard final checks.
  if is_full_stack; then
    if [[ -x "${PLUMED_ROOT}/bin/plumed" ]]; then
      export PATH="${PLUMED_ROOT}/bin:${PATH}"
      export LD_LIBRARY_PATH="${PLUMED_ROOT}/lib:${LD_LIBRARY_PATH:-}"
      final_checks
    else
      warn "PLUMED not installed in this run; skipping final PLUMED checks."
    fi
  else
    info "GROMACS-only mode: PLUMED final checks are not applicable."
  fi

  local final_gmx_bin="${GMX_ROOT}/bin/$(gmx_executable_name)"
  if [[ -x "${final_gmx_bin}" ]]; then
    final_gromacs_checks
  else
    warn "GROMACS not installed in this run; skipping final GROMACS checks."
  fi

  postflight_stack_checks
  generate_activate_script >/dev/null
  integrate_shell_rc
  if is_full_stack && [[ -x "${PLUMED_ROOT}/bin/plumed" ]]; then
    write_installation_reports "build"
  fi
  print_done_banner
}

on_err() {
  local rc=$?
  echo
  if [[ "${SAXS_UPDATE_ACTIVE:-0}" -eq 1 ]]; then
    handle_failed_saxs_update "${rc}" "operation failed" "${BASH_LINENO[0]}"
  fi
  err "${CURRENT_OPERATION^} failed at line ${BASH_LINENO[0]} (exit ${rc})."
  echo "Log file: ${LOG_FILE:-<not created>}"
  exit "${rc}"
}
trap on_err ERR

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
