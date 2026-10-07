#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_VERSION="8.1-gmx-auto-v36.1-manifest-plumed-patch-reporting"

OPENMPI_VERSION="${OPENMPI_VERSION:-5.0.10}"
FFTW_VERSION="${FFTW_VERSION:-3.3.11}"
BOOST_VERSION="${BOOST_VERSION:-1.85.0}"
FMT_VERSION="${FMT_VERSION:-11.2.0}"
SPDLOG_VERSION="${SPDLOG_VERSION:-1.9.2}"
ARRAYFIRE_VERSION="${ARRAYFIRE_VERSION:-3.9.0}"
PLUMED_REPO="${PLUMED_REPO:-https://github.com/plumed/plumed2.git}"

PLUMED_DISABLE_PYTHON="${PLUMED_DISABLE_PYTHON:-1}"

PLUMED_PATCH_DIR="${PLUMED_PATCH_DIR:-auto}"
PLUMED_SAXS_CPP="${PLUMED_SAXS_CPP:-}"
PLUMED_PATCH_BUNDLE="${PLUMED_PATCH_BUNDLE:-}"
UPDATE_PLUMED_PATCH=0
LAST_PLUMED_PATCH_BUNDLE=""
LAST_PLUMED_PATCH_MANIFEST_SHA256=""

AUTO_REPAIR="${AUTO_REPAIR:-1}"
CUDA_SHIM_DIR="${CUDA_SHIM_DIR:-auto}"

INSTALL_CUDA=0
INSTALL_CMAKE=0
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-}"
CUDA_BOOTSTRAP_VERSION="${CUDA_BOOTSTRAP_VERSION:-auto}"
CUDA_INSTALL_DIR="${CUDA_INSTALL_DIR:-}"
CUDA_RUNFILE_URL="${CUDA_RUNFILE_URL:-}"
CUDA_RUNFILE="${CUDA_RUNFILE:-}"
CUDA_DRIVER_VERSION="${CUDA_DRIVER_VERSION:-auto}"
CMAKE_BOOTSTRAP_VERSION="${CMAKE_BOOTSTRAP_VERSION:-3.31.12}"
CMAKE_INSTALL_DIR="${CMAKE_INSTALL_DIR:-}"
CMAKE_DOWNLOAD_URL="${CMAKE_DOWNLOAD_URL:-}"
CMAKE_ARCHIVE="${CMAKE_ARCHIVE:-}"
CMAKE_ROOT="${CMAKE_ROOT:-}"
TOOLCHAIN_DOWNLOAD_DIR=""
RESOLVED_CUDA_BOOTSTRAP_VERSION=""
RESOLVED_NVIDIA_DRIVER_VERSION=""

CUDA_EXTRA_INCLUDE_DIRS="${CUDA_EXTRA_INCLUDE_DIRS:-}"
CUDA_EXTRA_LIB_DIRS="${CUDA_EXTRA_LIB_DIRS:-}"

GROMACS_VERSION="${GROMACS_VERSION:-auto}"
GROMACS_URL="${GROMACS_URL:-}"
GROMACS_FTP_URL="${GROMACS_FTP_URL:-}"
PLUMED_GROMACS_PATCH="${PLUMED_GROMACS_PATCH:-auto}"
GMX_SIMD="${GMX_SIMD:-AVX2_256}"

MARCH="${MARCH:-native}"

FULL_STAGES=(openmpi fftw boost fmt spdlog arrayfire plumed gromacs)
SYSTEM_MPI_FULL_STAGES=(fftw boost fmt spdlog arrayfire plumed gromacs)
CPU_FULL_STAGES=(fftw plumed gromacs)
GROMACS_ONLY_STAGES=(fftw gromacs)
STAGES=("${FULL_STAGES[@]}")

CUDA_PATH="auto"
DIR=""
NAME=""
WORK_DIR="${WORK_DIR:-}"
WORK_DIR_EXPLICIT=0
WORK_ROOT=""
SPLIT_LAYOUT=0
NPROC="${NPROC:-}"
CUDA_ARCHS="${CUDA_ARCHS:-auto}"
PLUMED_REF="${PLUMED_REF:-master}"
FROM_STAGE=""
ONLY_STAGE=""
FORCE=0
WRITE_BASHRC=0
WRITE_ALIASES=0
DO_STATUS=0
DRY_RUN=0
ASSUME_YES=0
NO_COLOR="${NO_COLOR:-0}"
BUILD_MODE="${BUILD_MODE:-full}"
BUILD_MODE_EXPLICIT=0
ACCELERATOR="${ACCELERATOR:-cuda}"
UPDATE_SAXS=0
ALLOW_DIRTY_PLUMED=0
RUN_INSTALLCHECK=0
FINALIZE_ONLY=0

MPI_PROVIDER="${MPI_PROVIDER:-private}"
MPI_PREFIX="${MPI_PREFIX:-}"
MPI_PROVIDER_EXPLICIT=0
MPI_PREFIX_EXPLICIT=0
MPI_RUNTIME_TIMEOUT="${MPI_RUNTIME_TIMEOUT:-30}"
ARRAYFIRE_FULL_SOURCE_URL="${ARRAYFIRE_FULL_SOURCE_URL:-}"

REQUESTED_CC="${CC:-}"
REQUESTED_CXX="${CXX:-}"
REQUESTED_FC="${FC:-}"
REQUESTED_CUDAHOSTCXX="${CUDAHOSTCXX:-}"
BUILD_CC=""
BUILD_CXX=""
BUILD_FC=""
BUILD_CUDAHOSTCXX=""
PLUMED_PATCH_REJECT_STATUS="none"
PLUMED_PATCH_REJECT_FILES=""

PREFETCH=0
OFFLINE=0
SOURCE_CACHE="${SOURCE_CACHE:-}"
SOURCE_CACHE_MANIFEST=""
SOURCE_CACHE_SHA256=""

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
PATCH_UPDATE_ACTIVE=0
PATCH_UPDATE_BACKUP_DIR=""
PATCH_UPDATE_ID=""
PATCH_UPDATE_BUNDLE=""
PATCH_UPDATE_OLD_BUNDLE=""
PATCH_UPDATE_MANIFEST_SHA256=""
PATCH_UPDATE_COMMIT=""
PATCH_UPDATE_PREFIX_SNAPSHOT=""
PATCH_UPDATE_PREFIX_SNAPSHOT_SHA256=""
PATCH_UPDATE_TARGET_EXISTING_LIST=""
PATCH_UPDATE_TARGET_MISSING_LIST=""
PATCH_UPDATE_TARGET_ARCHIVE=""
PATCH_UPDATE_OTHER_DIRTY_LIST=""
PATCH_UPDATE_OTHER_MISSING_LIST=""
PATCH_UPDATE_OTHER_ARCHIVE=""
PATCH_UPDATE_FAILURE_HANDLED=0

CUDA_HOME=""
CUDA_VERSION=""
INSTALL_ROOT=""
WORK_ROOT=""
SRC=""
LOG_DIR=""
LOG_FILE=""
CKPT_DIR=""
GMX_ROOT=""
ALIAS_NAME=""

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

  if [[ "${PATCH_UPDATE_ACTIVE:-0}" -eq 1 ]] \
     && declare -F handle_failed_plumed_patch_update >/dev/null 2>&1; then
    handle_failed_plumed_patch_update 1 "explicit failure: ${message}" "${BASH_LINENO[0]:-unknown}"
  elif [[ "${SAXS_UPDATE_ACTIVE:-0}" -eq 1 ]] \
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

usage() {
  cat <<'EOF'
Usage: af_plumed_gmx_build.sh --dir <parent-dir> [options]

By default, builds OpenMPI, FFTW, Boost, fmt, spdlog, ArrayFire (CUDA),
PLUMED and a PLUMED-patched external-MPI GROMACS installation into
<parent-dir>/<name>. With --gromacs-only, builds only FFTW and standalone CUDA
GROMACS with built-in thread-MPI. Add --cpu-only to either route for a CUDA-free
login-node/analysis build. Existing CUDA behavior remains the default.

With --update-saxs, reuses the existing configured PLUMED checkout in the
recorded workspace, replaces only src/isdb/SAXS.cpp, preserves the retained
PLUMED Python-wrapper setting, performs an incremental PLUMED build/install,
validates the installed kernel, and leaves GROMACS untouched. If a split
workspace was removed but its durable source cache/provenance is still present,
the PLUMED checkout is reconstructed and reconfigured before the transactional
update. Before make install the complete installed PLUMED prefix is snapshotted
so a failed update can restore the pre-update installation. GROMACS is never
rebuilt by --update-saxs.

Required:
  --dir <path>          Parent directory for the installation. The actual
                        install root is <dir>/<name>.

Build route:
  --gromacs-only       Build only FFTW + standalone GROMACS. Configures
                       GMX_MPI=OFF and GMX_THREAD_MPI=ON, and does not apply a
                       PLUMED patch. CUDA is used by default; combine with
                       --cpu-only for a CPU-only build. Executable: `gmx`.
  --cpu-only           Disable the GPU/CUDA backend. With --gromacs-only this
                       builds FFTW + CPU GROMACS/thread-MPI. With the full route
                       it builds FFTW + CPU PLUMED + PLUMED-patched CPU GROMACS,
                       also with thread-MPI and without OpenMPI/ArrayFire/CUDA.
  --mode <mode>        Explicit route: full or gromacs-only. Default: full.
  --full-stack         Explicitly select the original full PLUMED stack.

Common options:
  --name <name>         Environment name and install subfolder. Also used to
                        build the activation alias. Default: build_<cudaver>.
                        If <dir>/<name> already exists and is non-empty (and is
                        not a previous run of this script), the build aborts and
                        asks for a different --name.
  --work-dir <path>     Optional workspace parent. When set, sources, build
                        trees, checkpoints, and build logs live under
                        <work-dir>/<name>, while installed runtime files stay
                        under <dir>/<name>. Without this option the historical
                        layout is preserved exactly (<dir>/<name>/src, etc.).
                        Intended for durable HOME workspaces with compact PUBLIC
                        runtime installs; also useful with disposable SCRATCH
                        validation workspaces.
  --cuda <path|auto>    CUDA toolkit root (must contain bin/nvcc), or auto.
                       CUDA backend only; incompatible with --cpu-only.
                        Default: auto. Auto mode searches only fast/common places
                        (CUDA_HOME/CUDA_ROOT, PATH, --dir, script/current/home
                        software folders, /mnt/data/software, /usr/local, /opt,
                        /usr/lib) and selects the newest valid CUDA toolkit.
                        Manual --cuda /path still takes precedence.
  --arch <archs>        CUDA compute architecture(s), e.g. auto, 80, 86, 90, or 120.
                       CUDA backend only; incompatible with --cpu-only.
                        Default: auto. In auto mode the script queries visible
                        NVIDIA GPU compute capabilities and converts them to
                        CMake CUDA architectures. For RTX 50-series / Blackwell,
                        auto should resolve to 120; manual override remains
                        possible with --arch 120.
  -j, --jobs <n>        Parallel build jobs. Default: nproc.
  --plumed-ref <ref>    Git branch/tag/commit for PLUMED. Default: master.
  --gromacs-version <v> GROMACS version, or auto. Default: auto.
                        auto selects 2025.4 with GCC/G++ >=11; the CUDA backend
                        additionally requires CUDA >=12.1. Otherwise 2024.6 is
                        used as the compatibility fallback.
  --gromacs-url <url>   Primary GROMACS source tarball URL. Default: official HTTPS
                        for the selected version.
  --gromacs-patch <e>  PLUMED patch engine name, or auto. Default: auto
                        (gromacs-2025.0 for 2025.x, gromacs-2024.3 for 2024.x).
  --gmx-simd <simd>    GROMACS SIMD target. Default: AVX2_256.

MPI provider for CUDA full-stack builds (opt-in; private OpenMPI stays default):
  --use-system-mpi     Reuse an existing OpenMPI-compatible installation instead
                       of building private OpenMPI. Valid only for the CUDA full
                       stack; thread-MPI routes are unchanged.
  --mpi-prefix <path>  Prefix containing bin/mpicc, bin/mpicxx and bin/mpirun.
                       Implies --use-system-mpi. If omitted, the prefix is
                       inferred from mpicc on PATH. Site modules may still need
                       to be loaded before build/activation for transitive UCX,
                       PMIx, UCC, or fabric libraries.

Offline source cache (opt-in; normal online behavior is unchanged):
  --prefetch           Populate the source cache for the selected build route
                       and exit without compiling/installing anything. Run this
                       on a networked login/service node.
  --source-cache <dir> Shared cache directory. With --prefetch or --offline,
                       default: <work-dir>/source_cache when --work-dir is used;
                       otherwise <dir>/source_cache.
  --offline            Disable network source acquisition. All required source
                       archives/Git snapshots must already be present and pass
                       SHA-256 verification in --source-cache. Intended for
                       isolated compute nodes. ArrayFire cache snapshots include
                       the full-source extern dependency payload.
                       If --install-cmake is used, the selected prebuilt CMake
                       archive is also prefetched/used from this cache.

Private toolchain bootstrap (opt-in; default behavior is unchanged):
  --install-cuda       Install a private NVIDIA CUDA Toolkit before the build.
                       The NVIDIA driver is NEVER installed or modified.
  --cuda-version <v>   Toolkit version. Default: auto (currently 12.6.3).
                       12.6.3 has a curated built-in NVIDIA runfile URL; other
                       versions require --cuda-runfile-url or --cuda-runfile.
  --cuda-install-dir <path>
                       Exact CUDA prefix. Default: <toolchain-dir>/cuda-<version>.
  --cuda-runfile-url <url>
                       Official NVIDIA .run installer URL for a custom version.
  --cuda-runfile <file>
                       Existing local NVIDIA .run installer (offline HPC use).
  --cuda-driver-version <v|auto>
                       Driver version used for compatibility checks. Default:
                       auto (nvidia-smi, /proc, or modinfo). Supply it manually
                       on login nodes where the target GPU/driver is not visible.
  --install-cmake      Install a private prebuilt CMake before the build.
  --cmake-version <v>  CMake version. Default: 3.31.12.
  --cmake-install-dir <path>
                       Exact CMake prefix. Default: <toolchain-dir>/cmake-<version>.
  --cmake-url <url>    Override the official Kitware archive URL.
  --cmake-archive <file>
                       Existing local CMake .tar.gz archive (offline HPC use).
  --toolchain-dir <path>
                       Parent for private tools/downloads. Default: <dir>/toolchain.
                       On HPC systems this should normally be inside $HOME.

PLUMED patching:
  --plumed-patch-bundle <path>
                       Manifest-driven PLUMED patch bundle. <path> may be a
                       directory or tar archive containing PATCHFILES.sha256
                       and plumed2/. Every manifest path and SHA-256 is verified
                       before files are applied. The complete validated bundle
                       is retained under the install root for provenance/updates.
  --update-plumed-patch
                       Transactionally update an existing full CUDA PLUMED stack
                       with --plumed-patch-bundle, or with its retained canonical
                       bundle when no new bundle path is supplied. GROMACS is
                       verified unchanged. --name is required.
  --update-saxs       Legacy transactional single-file SAXS.cpp update.
  --plumed-patch-dir <dir>
                       Legacy directory-based SAXS.cpp override.
  --saxs-cpp <path>   Legacy explicit replacement for src/isdb/SAXS.cpp.
  --allow-dirty-plumed
                       Permit unrelated tracked PLUMED source changes during a
                       PLUMED update. The default aborts on such changes.
  --installcheck      Run PLUMED make installcheck after a successful PLUMED
                       source update.

Custom PLUMED patching is disabled in --cpu-only mode.

Auto-repair / HPC compatibility:
  --no-auto-repair     Disable rootless compatibility fixes. By default the script
                        can create a private CUDA shim when nvcc, headers and
                        libraries are split across /usr/bin, /usr/include and
                        /usr/lib/x86_64-linux-gnu.
  --cuda-shim-dir <d>  Directory for an automatically generated CUDA shim.
                        Default: <install-root>/cuda-<version>-shim.

Rootless/HPC invariant:
  The installer never invokes sudo or a system package manager. Installed
  components stay below <install-root>; with --work-dir, build sources,
  checkpoints, logs, and update snapshots stay below the workspace instead.
  Normal temporary build files may use the host TMPDIR. Host
  compiler/CMake/Git/CUDA-driver/toolkit prerequisites may come from HPC
  modules, administrator installations, or user-owned prefixes. ~/.bashrc and
  ~/.bash_aliases are touched only when their explicit options are requested.

Activation / environment export:
  --write-bashrc        Append an activation alias to ~/.bashrc.
  --write-aliases       Append an activation alias to ~/.bash_aliases.
                        (An activate.sh is always written into the install root.)

Checkpoint / finalization control:
  --finalize-only       Do not compile. Re-run final PLUMED/GROMACS validation,
                       post-flight checks, activate.sh generation and reports for
                       an existing installation. --name is required.
  --from <stage>        Build from <stage> onward (earlier stages assumed done).
  --only <stage>        Build only <stage>.
  --force               Ignore checkpoints / rebuild everything; also permits
                        installing into a non-empty directory.
  --status              Print checkpoint status for the resolved install and exit.

Other:
  --dry-run             Resolve everything and print the selected plan without
                        building. With a PLUMED source update, also prints the
                        resolved source/patch transaction without writing.
  --no-color            Disable coloured output.
  -y, --yes             Assume "yes": reuse a non-empty install dir instead of
                        aborting (a lighter-weight alternative to --force that
                        keeps existing checkpoints).
  -h, --help            Show this help.

CUDA full-stack stages (private MPI): openmpi fftw boost fmt spdlog arrayfire plumed gromacs
CUDA full-stack stages (system MPI) : fftw boost fmt spdlog arrayfire plumed gromacs
CPU full-stack stages : fftw plumed gromacs
GROMACS-only stages   : fftw gromacs

Selected environment overrides (export before running):
  OPENMPI_VERSION FFTW_VERSION BOOST_VERSION FMT_VERSION SPDLOG_VERSION ARRAYFIRE_VERSION
  PLUMED_REPO GROMACS_VERSION GROMACS_URL GROMACS_FTP_URL PLUMED_GROMACS_PATCH SOURCE_CACHE
  MPI_PROVIDER MPI_PREFIX MPI_RUNTIME_TIMEOUT ARRAYFIRE_FULL_SOURCE_URL
  GMX_SIMD MARCH ACCELERATOR AUTO_REPAIR CUDA_SHIM_DIR CUDA_EXTRA_INCLUDE_DIRS CUDA_EXTRA_LIB_DIRS

Examples:
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv
  ./af_plumed_gmx_build.sh --dir /shared/public/build --work-dir $HOME/gmx-work --name myenv \
      --source-cache $HOME/gmx-sources --toolchain-dir $HOME/gmx-toolchain
  ./af_plumed_gmx_build.sh --dir $HOME/sw --name plumed_a100 --arch 80 -j 32 --write-bashrc
  ./af_plumed_gmx_build.sh --dir $HOME/software --name patched --plumed-patch-bundle /path/to/patch.tar.gz
  ./af_plumed_gmx_build.sh --dir $HOME/software --name patched --update-plumed-patch --plumed-patch-bundle /path/to/new-patch.tar.gz
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --from gromacs
  mkdir -p $HOME/software/myenv/plumed_patch
  cp /path/to/new/SAXS.cpp $HOME/software/myenv/plumed_patch/SAXS.cpp
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --update-saxs --dry-run
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --update-saxs -j 4
  ./af_plumed_gmx_build.sh --dir $HOME/software --name gmx_gpu --gromacs-only --write-bashrc
  ./af_plumed_gmx_build.sh --dir $HOME/software --name gmx_cpu --gromacs-only --cpu-only
  ./af_plumed_gmx_build.sh --dir $HOME/software --name gmx_plumed_cpu --cpu-only
  ./af_plumed_gmx_build.sh --dir $HOME/software --name gmx_plumed_site_mpi \
      --use-system-mpi --mpi-prefix /path/to/site/openmpi
  ./af_plumed_gmx_build.sh --dir $HOME/software --name gmx_plumed_site_mpi \
      --use-system-mpi --mpi-prefix /path/to/site/openmpi --finalize-only
  ./af_plumed_gmx_build.sh --dir $HOME/builds --name gmx25 --gromacs-only \
      --install-cuda --cuda-version 12.6.3 --install-cmake \
      --toolchain-dir $HOME/software/toolchain --arch 70
  ./af_plumed_gmx_build.sh --dir $HOME/software --name myenv --status
EOF
}

abspath() {
  local p="${1}"

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
is_cpu_only()     { [[ "${ACCELERATOR}" == "cpu" ]]; }
is_cuda_backend() { [[ "${ACCELERATOR}" == "cuda" ]]; }
using_system_mpi() { [[ "${MPI_PROVIDER}" == "system" ]]; }

canonical_executable() {
  local x="${1:-}" p
  [[ -n "${x}" ]] || return 1
  p="$(command -v -- "${x}" 2>/dev/null || true)"
  [[ -n "${p}" ]] || return 1
  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "${p}" 2>/dev/null || printf '%s\n' "${p}"
  else
    printf '%s\n' "${p}"
  fi
}

resolve_build_compilers() {
  local cc_sel cxx_sel fc_sel host_sel
  cc_sel="${REQUESTED_CC:-${CC:-gcc}}"
  cxx_sel="${REQUESTED_CXX:-${CXX:-g++}}"
  BUILD_CC="$(canonical_executable "${cc_sel}" || true)"
  BUILD_CXX="$(canonical_executable "${cxx_sel}" || true)"
  [[ -x "${BUILD_CC}" ]] || die "Selected C compiler is not runnable: ${cc_sel}"
  [[ -x "${BUILD_CXX}" ]] || die "Selected C++ compiler is not runnable: ${cxx_sel}"
  export CC="${BUILD_CC}" CXX="${BUILD_CXX}"

  fc_sel="${REQUESTED_FC:-${FC:-}}"
  if [[ -n "${fc_sel}" ]]; then
    BUILD_FC="$(canonical_executable "${fc_sel}" || true)"
    [[ -x "${BUILD_FC}" ]] || die "Selected Fortran compiler is not runnable: ${fc_sel}"
    export FC="${BUILD_FC}"
  fi

  if is_cuda_backend; then
    host_sel="${REQUESTED_CUDAHOSTCXX:-${CUDAHOSTCXX:-${BUILD_CXX}}}"
    BUILD_CUDAHOSTCXX="$(canonical_executable "${host_sel}" || true)"
    [[ -x "${BUILD_CUDAHOSTCXX}" ]] || die "Selected CUDA host C++ compiler is not runnable: ${host_sel}"
    export CUDAHOSTCXX="${BUILD_CUDAHOSTCXX}"
  else
    BUILD_CUDAHOSTCXX=""
  fi
}

compiler_family() {
  local out base
  out="$("${1}" --version 2>/dev/null | head -n1 || true)"
  base="$(basename -- "${1}")"
  case "${base}:${out}" in
    *[Cc]lang*) printf '%s\n' clang ;;
    *gcc*|*g++*|*GCC*|*GNU*) printf '%s\n' gcc ;;
    *) printf '%s\n' other ;;
  esac
}

gromacs_effective_cxx_compiler() {

  if ! is_cpu_only && ! is_gromacs_only && [[ -x "${MPI_ROOT}/bin/mpicxx" ]]; then
    printf '%s\n' "${MPI_ROOT}/bin/mpicxx"
  else
    printf '%s\n' "${BUILD_CXX}"
  fi
}

validate_gromacs_2025_compiler() {
  [[ "${GROMACS_VERSION}" == 2025* ]] || return 0
  local compiler family ver min
  compiler="$(gromacs_effective_cxx_compiler)"
  family="$(compiler_family "${compiler}")"
  ver="$(compiler_version_string "${compiler}")"
  case "${family}" in
    gcc) min="11" ;;
    clang) min="14" ;;
    *)
      warn "Could not classify compiler '${compiler}' for an early GROMACS 2025 compatibility check; GROMACS CMake will perform the authoritative check."
      return 0
      ;;
  esac
  [[ -n "${ver}" ]] || { warn "Could not determine compiler version for ${compiler}; deferring to GROMACS CMake."; return 0; }
  version_ge "${ver}" "${min}" \
    || die "GROMACS ${GROMACS_VERSION} requires ${family} >=${min}, but ${compiler} reports ${ver}. Select a newer compiler with CC/CXX before rebuilding."
  ok "Compiler compatibility check passed for GROMACS ${GROMACS_VERSION}: ${family} ${ver} (${compiler})."
}

configure_build_mode() {
  case "${ACCELERATOR}" in
    cuda|cpu) ;;
    *) die "Invalid accelerator '${ACCELERATOR}'. Use cuda (default) or --cpu-only." ;;
  esac

  case "${BUILD_MODE}" in
    full)
      if is_cpu_only; then
        STAGES=("${CPU_FULL_STAGES[@]}")
      elif using_system_mpi; then
        STAGES=("${SYSTEM_MPI_FULL_STAGES[@]}")
      else
        STAGES=("${FULL_STAGES[@]}")
      fi
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
  if is_gromacs_only || is_cpu_only; then printf '%s\n' gmx; else printf '%s\n' gmx_mpi; fi
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

resolve_source_cache_path() {
  [[ "${PREFETCH}" -eq 1 || "${OFFLINE}" -eq 1 || -n "${SOURCE_CACHE}" ]] || return 0
  if [[ -z "${SOURCE_CACHE}" ]]; then
    if [[ -n "${WORK_DIR}" ]]; then
      SOURCE_CACHE="${WORK_DIR%/}/source_cache"
    else
      SOURCE_CACHE="${DIR%/}/source_cache"
    fi
  fi
  SOURCE_CACHE="$(abspath "${SOURCE_CACHE}")"
  SOURCE_CACHE_MANIFEST="${SOURCE_CACHE}/manifest.tsv"
  SOURCE_CACHE_SHA256="${SOURCE_CACHE}/SHA256SUMS"
}

source_cache_archive_path() {
  printf '%s\n' "${SOURCE_CACHE}/archives/${1}"
}

source_cache_git_path() {
  printf '%s\n' "${SOURCE_CACHE}/git/${1}.tar.gz"
}

source_cache_relpath() {
  local x="${1}"
  printf '%s\n' "${x#${SOURCE_CACHE}/}"
}

source_cache_copy_archive() {

  local fname="${1}" out="${2}" cached
  [[ "${OFFLINE}" -eq 1 ]] || return 1
  cached="$(source_cache_archive_path "${fname}")"
  [[ -s "${cached}" ]] || die "Offline source cache is missing archive: ${cached}"
  cp -f -- "${cached}" "${out}"
  [[ -s "${out}" ]] || die "Failed to copy cached archive ${cached} -> ${out}"
  info "Offline source: ${cached} -> ${out}"
}

source_cache_extract_git() {

  local component="${1}" key="${2}" dest="${3}" cached parent expected expected_commit actual_commit
  cached="$(source_cache_git_path "${key}")"
  [[ -s "${cached}" ]] || die "Offline source cache is missing Git snapshot: ${cached}"
  parent="$(dirname "${dest}")"
  expected="$(basename "${dest}")"
  mkdir -p "${parent}"
  rm -rf -- "${dest}"
  tar -xzf "${cached}" -C "${parent}"
  [[ -d "${dest}" ]] || die "Cached Git snapshot ${cached} did not extract the expected directory '${expected}'."
  expected_commit="$(awk -F '\t' -v c="${component}" '$1==c && $2=="git" {print $6; exit}' "${SOURCE_CACHE_MANIFEST}" 2>/dev/null || true)"
  actual_commit="$(git -C "${dest}" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "${expected_commit}" && "${actual_commit}" == "${expected_commit}" ]] \
    || die "Cached Git snapshot commit mismatch for ${component}: manifest=${expected_commit:-missing}, extracted=${actual_commit:-missing}"
  info "Offline Git snapshot restored: ${cached} -> ${dest} (commit ${actual_commit})"
}

source_cache_required_files() {
  local us cmake_tag

  printf '%s\n' "archives/fftw-${FFTW_VERSION}.tar.gz"
  printf '%s\n' "archives/gromacs-${GROMACS_VERSION}.tar.gz"

  if is_full_stack; then
    if is_cpu_only; then
      printf '%s\n' "git/plumed2.tar.gz"
    else
      us="${BOOST_VERSION//./_}"
      if ! using_system_mpi; then
        printf '%s\n' "archives/openmpi-${OPENMPI_VERSION}.tar.gz"
      fi
      printf '%s\n' "archives/boost_${us}.tar.gz"
      printf '%s\n' "git/fmt-${FMT_VERSION}.tar.gz"
      printf '%s\n' "git/spdlog-${SPDLOG_VERSION}.tar.gz"
      printf '%s\n' "git/arrayfire-${ARRAYFIRE_VERSION}.tar.gz"
      printf '%s\n' "git/plumed2.tar.gz"
    fi
  fi

  if [[ "${INSTALL_CMAKE}" -eq 1 && -z "${CMAKE_ARCHIVE}" ]]; then
    cmake_tag="$(cmake_platform_tag)"
    printf '%s\n' "archives/cmake-${CMAKE_BOOTSTRAP_VERSION}-${cmake_tag}.tar.gz"
  fi
}

verify_source_cache() {
  [[ "${OFFLINE}" -eq 1 ]] || return 0
  [[ -d "${SOURCE_CACHE}" ]] || die "Offline source cache directory not found: ${SOURCE_CACHE}"
  [[ -s "${SOURCE_CACHE_MANIFEST}" ]] || die "Offline source cache provenance manifest not found: ${SOURCE_CACHE_MANIFEST}"
  [[ -s "${SOURCE_CACHE_SHA256}" ]] || die "Offline source cache checksum manifest not found: ${SOURCE_CACHE_SHA256}"

  local rel cached_ref cached_repo
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    [[ -s "${SOURCE_CACHE}/${rel}" ]] || die "Offline source cache is incomplete; missing ${SOURCE_CACHE}/${rel}"
    grep -Fq "  ${rel}" "${SOURCE_CACHE_SHA256}" \
      || die "Offline source cache has no SHA-256 record for ${rel}"
  done < <(source_cache_required_files)
  grep -Fq "  manifest.tsv" "${SOURCE_CACHE_SHA256}" \
    || die "Offline source cache does not protect manifest.tsv with SHA-256."

  if ! (cd "${SOURCE_CACHE}" && sha256sum -c "$(basename "${SOURCE_CACHE_SHA256}")"); then
    die "Offline source cache SHA-256 verification failed: ${SOURCE_CACHE_SHA256}"
  fi
  ok "Offline source cache SHA-256 verification passed."

  if is_full_stack; then
    cached_ref="$(awk -F '\t' '$1=="plumed" && $2=="git" {print $3; exit}' "${SOURCE_CACHE_MANIFEST}" || true)"
    [[ "${cached_ref}" == "${PLUMED_REF}" ]] \
      || die "Cached PLUMED ref mismatch: requested '${PLUMED_REF}', cache contains '${cached_ref:-missing}'. Re-run --prefetch with the requested ref."
    cached_repo="$(awk -F '\t' '$1=="# plumed_repo" {print $2; exit}' "${SOURCE_CACHE_MANIFEST}" || true)"
    [[ -z "${cached_repo}" || "${cached_repo}" == "${PLUMED_REPO}" ]] \
      || die "Cached PLUMED repository mismatch: requested '${PLUMED_REPO}', cache contains '${cached_repo}'."
    ok "Cached PLUMED provenance matches requested ref '${PLUMED_REF}'."
  fi
}

prefetch_download_first_available() {

  local out="${1}" url
  shift
  mkdir -p "$(dirname "${out}")"
  for url in "$@"; do
    info "Prefetching $(basename "${out}") from ${url}"
    rm -f -- "${out}.part"
    if command -v wget >/dev/null 2>&1; then
      if wget -c -O "${out}.part" "${url}"; then mv "${out}.part" "${out}"; return 0; fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -fL -C - -o "${out}.part" "${url}"; then mv "${out}.part" "${out}"; return 0; fi
    else
      die "Neither wget nor curl is available to prefetch ${url}"
    fi
    rm -f -- "${out}.part"
    warn "Prefetch failed from ${url}; trying the next source if available."
  done
  die "Could not prefetch $(basename "${out}") from any configured source."
}

prefetch_archive() {

  local component="${1}" version="${2}" fname="${3}" out
  shift 3
  out="$(source_cache_archive_path "${fname}")"
  if [[ -s "${out}" ]]; then
    if tar -tf "${out}" >/dev/null 2>&1; then
      info "Reusing valid cached archive: ${out}"
    else
      warn "Cached archive is unreadable; downloading it again: ${out}"
      rm -f -- "${out}"
    fi
  fi
  if [[ ! -s "${out}" ]]; then
    prefetch_download_first_available "${out}" "$@"
  fi
  tar -tf "${out}" >/dev/null 2>&1 || die "Prefetched archive is not readable by tar: ${out}"
  printf '%s\tarchive\t%s\t%s\t%s\t-\n' \
    "${component}" "${version}" "$(source_cache_relpath "${out}")" "$(sha256_file "${out}")" \
    >> "${SOURCE_CACHE_MANIFEST}.body"
  ok "Prefetched ${component} ${version}: ${out}"
}

prefetch_git_snapshot() {

  local component="${1}" key="${2}" url="${3}" ref="${4}" mode="${5}"
  local work_parent work dest out commit status
  work_parent="$(mktemp -d "${SOURCE_CACHE}/.prefetch-git.XXXXXX")"
  work="${work_parent}/${key}"
  out="$(source_cache_git_path "${key}")"
  mkdir -p "$(dirname "${out}")"

  case "${mode}" in
    shallow-branch)
      git clone --branch "${ref}" --depth 1 "${url}" "${work}"
      ;;
    recursive-branch)
      git clone --recursive --branch "${ref}" "${url}" "${work}"
      git -C "${work}" submodule update --init --recursive
      ;;
    recursive-checkout)
      git clone --recursive "${url}" "${work}"
      if [[ "${ref}" != "master" ]]; then
        git -C "${work}" checkout "${ref}"
      fi
      git -C "${work}" submodule update --init --recursive
      ;;
    *)
      rm -rf "${work_parent}"
      die "Unknown prefetch Git mode '${mode}' for ${component}."
      ;;
  esac

  commit="$(git -C "${work}" rev-parse HEAD)"
  status="$(git -C "${work}" status --porcelain --untracked-files=all || true)"
  [[ -z "${status}" ]] || { printf '%s\n' "${status}" >&2; rm -rf "${work_parent}"; die "Prefetched ${component} Git tree is not clean."; }

  rm -f -- "${out}"
  tar -czf "${out}" -C "${work_parent}" "${key}"
  tar -tzf "${out}" >/dev/null 2>&1 || { rm -rf "${work_parent}"; die "Could not validate Git snapshot archive ${out}."; }
  rm -rf "${work_parent}"
  printf '%s\tgit\t%s\t%s\t%s\t%s\n' \
    "${component}" "${ref}" "$(source_cache_relpath "${out}")" "$(sha256_file "${out}")" "${commit}" \
    >> "${SOURCE_CACHE_MANIFEST}.body"
  ok "Prefetched ${component} Git snapshot at commit ${commit}: ${out}"
}

arrayfire_offline_required_dirs() {
  printf '%s\n' \
    af_forge-src \
    af_glad-src \
    af_assets-src \
    af_threads-src \
    af_test_data-src \
    googletest-src \
    span-lite-src \
    spdlog-src
}

validate_arrayfire_full_tree() {

  local root="${1}" d missing=()
  while IFS= read -r d; do
    [[ -d "${root}/extern/${d}" ]] || missing+=("${d}")
  done < <(arrayfire_offline_required_dirs)
  [[ ${#missing[@]} -eq 0 ]] \
    || die "ArrayFire full-source payload is incomplete under ${root}/extern; missing: ${missing[*]}"
  ok "ArrayFire full-source offline dependency payload is complete."
}

prefetch_arrayfire_snapshot() {
  local key="arrayfire-${ARRAYFIRE_VERSION}"
  local work_parent work out commit tracked
  local full_name="arrayfire-full-${ARRAYFIRE_VERSION}.tar.bz2"
  local full_out full_extract full_root
  local -a urls=()

  work_parent="$(mktemp -d "${SOURCE_CACHE}/.prefetch-arrayfire.XXXXXX")"
  work="${work_parent}/${key}"
  out="$(source_cache_git_path "${key}")"
  full_out="$(source_cache_archive_path "${full_name}")"
  full_extract="${work_parent}/full"
  mkdir -p "$(dirname "${out}")" "$(dirname "${full_out}")" "${full_extract}"

  git clone --recursive --branch "v${ARRAYFIRE_VERSION}" \
    https://github.com/arrayfire/arrayfire.git "${work}"
  git -C "${work}" submodule update --init --recursive
  commit="$(git -C "${work}" rev-parse HEAD)"

  if [[ -n "${ARRAYFIRE_FULL_SOURCE_URL}" ]]; then
    urls+=("${ARRAYFIRE_FULL_SOURCE_URL}")
  else
    urls+=(
      "https://github.com/arrayfire/arrayfire/releases/download/v${ARRAYFIRE_VERSION}/${full_name}"
      "https://sourceforge.net/projects/arrayfire.mirror/files/v${ARRAYFIRE_VERSION}/${full_name}/download"
    )
  fi
  if [[ ! -s "${full_out}" ]] || ! tar -tf "${full_out}" >/dev/null 2>&1; then
    rm -f -- "${full_out}"
    prefetch_download_first_available "${full_out}" "${urls[@]}"
  else
    info "Reusing valid cached ArrayFire full-source archive: ${full_out}"
  fi
  tar -tf "${full_out}" >/dev/null 2>&1 \
    || { rm -rf "${work_parent}"; die "ArrayFire full-source archive is unreadable: ${full_out}"; }

  tar -xf "${full_out}" -C "${full_extract}"
  full_root="$(find "${full_extract}" -mindepth 1 -maxdepth 2 -type d -name extern -print -quit | xargs -r dirname)"
  [[ -n "${full_root}" && -d "${full_root}/extern" ]] \
    || { rm -rf "${work_parent}"; die "Could not locate extern/ in ${full_out}."; }
  cp -a "${full_root}/extern/." "${work}/extern/"
  validate_arrayfire_full_tree "${work}"

  tracked="$(git -C "${work}" status --porcelain --untracked-files=no || true)"
  [[ -z "${tracked}" ]] \
    || { printf '%s\n' "${tracked}" >&2; rm -rf "${work_parent}"; die "ArrayFire full-source overlay modified tracked v${ARRAYFIRE_VERSION} sources."; }

  rm -f -- "${out}"
  tar -czf "${out}" -C "${work_parent}" "${key}"
  tar -tzf "${out}" >/dev/null 2>&1 \
    || { rm -rf "${work_parent}"; die "Could not validate composite ArrayFire snapshot ${out}."; }
  rm -rf "${work_parent}"

  printf '%s\tarchive\t%s\t%s\t%s\t-\n' \
    "arrayfire-full" "${ARRAYFIRE_VERSION}" "$(source_cache_relpath "${full_out}")" "$(sha256_file "${full_out}")" \
    >> "${SOURCE_CACHE_MANIFEST}.body"
  printf '%s\tgit\t%s\t%s\t%s\t%s\n' \
    "arrayfire" "v${ARRAYFIRE_VERSION}" "$(source_cache_relpath "${out}")" "$(sha256_file "${out}")" "${commit}" \
    >> "${SOURCE_CACHE_MANIFEST}.body"
  ok "Prefetched composite ArrayFire ${ARRAYFIRE_VERSION} snapshot at commit ${commit}: ${out}"
}

write_source_cache_checksums() {
  local f rel
  : > "${SOURCE_CACHE_SHA256}"
  while IFS= read -r f; do
    [[ -f "${f}" ]] || continue
    rel="$(source_cache_relpath "${f}")"
    printf '%s  %s\n' "$(sha256_file "${f}")" "${rel}" >> "${SOURCE_CACHE_SHA256}"
  done < <( { find "${SOURCE_CACHE}/archives" "${SOURCE_CACHE}/git" -maxdepth 1 -type f 2>/dev/null; printf '%s\n' "${SOURCE_CACHE_MANIFEST}"; } | sort )
}

prefetch_sources() {
  section "Source cache prefetch"
  mkdir -p "${SOURCE_CACHE}/archives" "${SOURCE_CACHE}/git"
  : > "${SOURCE_CACHE_MANIFEST}.body"

  local series us cmake_tag cmake_name plumed_commit

  if is_full_stack && ! is_cpu_only && ! using_system_mpi; then
    series="$(printf '%s' "${OPENMPI_VERSION}" | cut -d. -f1,2)"
    prefetch_archive openmpi "${OPENMPI_VERSION}" "openmpi-${OPENMPI_VERSION}.tar.gz" \
      "https://download.open-mpi.org/release/open-mpi/v${series}/openmpi-${OPENMPI_VERSION}.tar.gz"
  fi

  prefetch_archive fftw "${FFTW_VERSION}" "fftw-${FFTW_VERSION}.tar.gz" \
    "https://www.fftw.org/fftw-${FFTW_VERSION}.tar.gz"

  if is_full_stack && ! is_cpu_only; then
    us="${BOOST_VERSION//./_}"
    prefetch_archive boost "${BOOST_VERSION}" "boost_${us}.tar.gz" \
      "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${us}.tar.gz"

    prefetch_git_snapshot fmt "fmt-${FMT_VERSION}" \
      "https://github.com/fmtlib/fmt.git" "${FMT_VERSION}" shallow-branch
    prefetch_git_snapshot spdlog "spdlog-${SPDLOG_VERSION}" \
      "https://github.com/gabime/spdlog.git" "v${SPDLOG_VERSION}" shallow-branch
    prefetch_arrayfire_snapshot
  fi

  if is_full_stack; then
    prefetch_git_snapshot plumed "plumed2" "${PLUMED_REPO}" "${PLUMED_REF}" recursive-checkout
    plumed_commit="$(tar -xOf "$(source_cache_git_path plumed2)" plumed2/.git/HEAD 2>/dev/null | head -n1 || true)"
    : "${plumed_commit}"
  fi

  prefetch_archive gromacs "${GROMACS_VERSION}" "gromacs-${GROMACS_VERSION}.tar.gz" \
    "${GROMACS_URL}" "${GROMACS_FTP_URL}"

  if [[ "${INSTALL_CMAKE}" -eq 1 ]]; then
    if [[ -n "${CMAKE_ARCHIVE}" ]]; then
      info "--cmake-archive already supplies a local CMake archive; it is not duplicated in the source cache."
    else
      cmake_tag="$(cmake_platform_tag)"
      cmake_name="cmake-${CMAKE_BOOTSTRAP_VERSION}-${cmake_tag}.tar.gz"
      [[ -n "${CMAKE_DOWNLOAD_URL}" ]] || CMAKE_DOWNLOAD_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_BOOTSTRAP_VERSION}/${cmake_name}"
      prefetch_archive cmake "${CMAKE_BOOTSTRAP_VERSION}" "${cmake_name}" "${CMAKE_DOWNLOAD_URL}"
    fi
  fi

  {
    printf '# schema\t2\n'
    printf '# installer\t%s\n' "${SCRIPT_VERSION}"
    printf '# generated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# build_mode\t%s\n' "${BUILD_MODE}"
    printf '# accelerator\t%s\n' "${ACCELERATOR}"
    printf '# gromacs_version\t%s\n' "${GROMACS_VERSION}"
    printf '# plumed_ref\t%s\n' "${PLUMED_REF}"
    printf '# plumed_repo\t%s\n' "${PLUMED_REPO}"
    printf '# mpi_provider\t%s\n' "${MPI_PROVIDER}"
    printf 'component\tkind\tversion_or_ref\tartifact\tsha256\tgit_commit\n'
    [[ -s "${SOURCE_CACHE_MANIFEST}.body" ]] && cat "${SOURCE_CACHE_MANIFEST}.body"
  } > "${SOURCE_CACHE_MANIFEST}"
  rm -f -- "${SOURCE_CACHE_MANIFEST}.body"

  write_source_cache_checksums
  (cd "${SOURCE_CACHE}" && sha256sum -c "$(basename "${SOURCE_CACHE_SHA256}")") \
    || die "Newly generated source cache failed its own SHA-256 verification."
  ok "Source cache ready: ${SOURCE_CACHE}"
  info "Manifest : ${SOURCE_CACHE_MANIFEST}"
  info "Checksums: ${SOURCE_CACHE_SHA256}"
}

prepare_offline_cmake_archive() {
  [[ "${OFFLINE}" -eq 1 && "${INSTALL_CMAKE}" -eq 1 && -z "${CMAKE_ARCHIVE}" ]] || return 0
  local tag fname
  tag="$(cmake_platform_tag)"
  fname="cmake-${CMAKE_BOOTSTRAP_VERSION}-${tag}.tar.gz"
  CMAKE_ARCHIVE="$(source_cache_archive_path "${fname}")"
  [[ -s "${CMAKE_ARCHIVE}" ]] || die "Offline CMake archive missing from source cache: ${CMAKE_ARCHIVE}"
}

download() {
  local url="${1}" fname
  fname="$(basename "${url}")"
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_copy_archive "${fname}" "${fname}"
    return 0
  fi
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

download_to() {

  local url="${1}" out="${2}" fname
  mkdir -p "$(dirname "${out}")"
  if [[ "${OFFLINE}" -eq 1 ]]; then
    fname="$(basename "${url}")"
    source_cache_copy_archive "${fname}" "${out}"
    return 0
  fi
  if [[ -s "${out}" ]]; then
    info "Using cached download: ${out}"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -c -O "${out}" "${url}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL -C - -o "${out}" "${url}"
  else
    die "Neither wget nor curl is available to fetch ${url}"
  fi
  [[ -s "${out}" ]] || die "Download produced an empty file: ${out}"
}

download_first_available() {

  local fname="${1}" url
  shift
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_copy_archive "${fname}" "${fname}"
    return 0
  fi
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --gromacs-only) BUILD_MODE="gromacs-only"; BUILD_MODE_EXPLICIT=1; shift ;;
      --cpu-only)     ACCELERATOR="cpu"; shift ;;
      --full-stack)   BUILD_MODE="full"; BUILD_MODE_EXPLICIT=1; shift ;;
      --mode)         BUILD_MODE="${2:?--mode requires full or gromacs-only}"; BUILD_MODE_EXPLICIT=1; shift 2 ;;
      --mode=*)       BUILD_MODE="${1#*=}"; BUILD_MODE_EXPLICIT=1; shift ;;
      --cuda)         CUDA_PATH="${2:?--cuda requires a path}"; shift 2 ;;
      --cuda=*)       CUDA_PATH="${1#*=}"; shift ;;
      --dir)          DIR="${2:?--dir requires a path}"; shift 2 ;;
      --dir=*)        DIR="${1#*=}"; shift ;;
      --work-dir)     WORK_DIR="${2:?--work-dir requires a path}"; WORK_DIR_EXPLICIT=1; shift 2 ;;
      --work-dir=*)   WORK_DIR="${1#*=}"; WORK_DIR_EXPLICIT=1; shift ;;
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
      --use-system-mpi) MPI_PROVIDER="system"; MPI_PROVIDER_EXPLICIT=1; shift ;;
      --mpi-prefix)   MPI_PREFIX="${2:?--mpi-prefix requires a path}"; MPI_PROVIDER="system"; MPI_PROVIDER_EXPLICIT=1; MPI_PREFIX_EXPLICIT=1; shift 2 ;;
      --mpi-prefix=*) MPI_PREFIX="${1#*=}"; MPI_PROVIDER="system"; MPI_PROVIDER_EXPLICIT=1; MPI_PREFIX_EXPLICIT=1; shift ;;
      --prefetch)     PREFETCH=1; CURRENT_OPERATION="prefetch"; shift ;;
      --offline)      OFFLINE=1; shift ;;
      --source-cache) SOURCE_CACHE="${2:?--source-cache requires a path}"; shift 2 ;;
      --source-cache=*) SOURCE_CACHE="${1#*=}"; shift ;;
      --install-cuda) INSTALL_CUDA=1; shift ;;
      --cuda-version) CUDA_BOOTSTRAP_VERSION="${2:?--cuda-version requires a value}"; shift 2 ;;
      --cuda-version=*) CUDA_BOOTSTRAP_VERSION="${1#*=}"; shift ;;
      --cuda-install-dir) CUDA_INSTALL_DIR="${2:?--cuda-install-dir requires a path}"; shift 2 ;;
      --cuda-install-dir=*) CUDA_INSTALL_DIR="${1#*=}"; shift ;;
      --cuda-runfile-url) CUDA_RUNFILE_URL="${2:?--cuda-runfile-url requires a URL}"; shift 2 ;;
      --cuda-runfile-url=*) CUDA_RUNFILE_URL="${1#*=}"; shift ;;
      --cuda-runfile) CUDA_RUNFILE="${2:?--cuda-runfile requires a file}"; shift 2 ;;
      --cuda-runfile=*) CUDA_RUNFILE="${1#*=}"; shift ;;
      --cuda-driver-version) CUDA_DRIVER_VERSION="${2:?--cuda-driver-version requires a value}"; shift 2 ;;
      --cuda-driver-version=*) CUDA_DRIVER_VERSION="${1#*=}"; shift ;;
      --install-cmake) INSTALL_CMAKE=1; shift ;;
      --cmake-version) CMAKE_BOOTSTRAP_VERSION="${2:?--cmake-version requires a value}"; shift 2 ;;
      --cmake-version=*) CMAKE_BOOTSTRAP_VERSION="${1#*=}"; shift ;;
      --cmake-install-dir) CMAKE_INSTALL_DIR="${2:?--cmake-install-dir requires a path}"; shift 2 ;;
      --cmake-install-dir=*) CMAKE_INSTALL_DIR="${1#*=}"; shift ;;
      --cmake-url) CMAKE_DOWNLOAD_URL="${2:?--cmake-url requires a URL}"; shift 2 ;;
      --cmake-url=*) CMAKE_DOWNLOAD_URL="${1#*=}"; shift ;;
      --cmake-archive) CMAKE_ARCHIVE="${2:?--cmake-archive requires a file}"; shift 2 ;;
      --cmake-archive=*) CMAKE_ARCHIVE="${1#*=}"; shift ;;
      --toolchain-dir) TOOLCHAIN_DIR="${2:?--toolchain-dir requires a path}"; shift 2 ;;
      --toolchain-dir=*) TOOLCHAIN_DIR="${1#*=}"; shift ;;
      --plumed-patch-dir) PLUMED_PATCH_DIR="${2:?--plumed-patch-dir requires a path}"; shift 2 ;;
      --plumed-patch-dir=*) PLUMED_PATCH_DIR="${1#*=}"; shift ;;
      --saxs-cpp)     PLUMED_SAXS_CPP="${2:?--saxs-cpp requires a file}"; shift 2 ;;
      --saxs-cpp=*)   PLUMED_SAXS_CPP="${1#*=}"; shift ;;
      --plumed-patch-bundle) PLUMED_PATCH_BUNDLE="${2:?--plumed-patch-bundle requires a path}"; shift 2 ;;
      --plumed-patch-bundle=*) PLUMED_PATCH_BUNDLE="${1#*=}"; shift ;;
      --update-plumed-patch) UPDATE_PLUMED_PATCH=1; CURRENT_OPERATION="update-plumed-patch"; shift ;;
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
      --finalize-only) FINALIZE_ONLY=1; CURRENT_OPERATION="finalize"; shift ;;
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

  case "${MPI_PROVIDER}" in
    private|system) ;;
    *) die "Invalid MPI provider '${MPI_PROVIDER}'. Use the default private provider or --use-system-mpi." ;;
  esac
  [[ "${MPI_RUNTIME_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] \
    || die "MPI_RUNTIME_TIMEOUT must be a positive integer number of seconds (got: ${MPI_RUNTIME_TIMEOUT})."
  if using_system_mpi; then
    is_full_stack || die "--use-system-mpi is only valid for the full PLUMED/GROMACS route. GROMACS-only uses built-in thread-MPI."
    is_cuda_backend || die "--use-system-mpi is not used by --cpu-only; the CPU full-stack route uses built-in thread-MPI."
  fi

  if [[ "${FINALIZE_ONLY}" -eq 1 ]]; then
    [[ -n "${NAME}" ]] || die "--finalize-only requires --name to select an existing installation explicitly."
    [[ "${PREFETCH}" -eq 0 && "${UPDATE_SAXS}" -eq 0 && "${UPDATE_PLUMED_PATCH}" -eq 0 && "${DO_STATUS}" -eq 0 ]] \
      || die "--finalize-only cannot be combined with --prefetch, PLUMED source-update routes, or --status."
    [[ -z "${FROM_STAGE}" && -z "${ONLY_STAGE}" && "${FORCE}" -eq 0 ]] \
      || die "--finalize-only cannot be combined with --from, --only, or --force."
    [[ "${INSTALL_CUDA}" -eq 0 && "${INSTALL_CMAKE}" -eq 0 ]] \
      || die "--finalize-only validates an existing installation; do not combine it with --install-cuda/--install-cmake."
    [[ "${DRY_RUN}" -eq 0 ]] || die "--finalize-only is already non-building and cannot be combined with --dry-run."
  fi

  [[ ! ( "${PREFETCH}" -eq 1 && "${OFFLINE}" -eq 1 ) ]] \
    || die "--prefetch and --offline are mutually exclusive."
  if [[ "${PREFETCH}" -eq 1 ]]; then
    [[ "${UPDATE_SAXS}" -eq 0 && "${UPDATE_PLUMED_PATCH}" -eq 0 && "${DO_STATUS}" -eq 0 ]] \
      || die "--prefetch cannot be combined with PLUMED source-update routes or --status."
    [[ -z "${FROM_STAGE}" && -z "${ONLY_STAGE}" ]] \
      || die "--prefetch creates a complete cache for the selected build route; do not combine it with --from/--only."
    [[ "${WRITE_BASHRC}" -eq 0 && "${WRITE_ALIASES}" -eq 0 ]] \
      || die "--prefetch does not modify shell aliases; omit --write-bashrc/--write-aliases."
  fi
  if [[ "${OFFLINE}" -eq 1 ]]; then
    [[ "${UPDATE_SAXS}" -eq 0 && "${UPDATE_PLUMED_PATCH}" -eq 0 ]] || die "--offline is not used by PLUMED source-update routes; they reuse an existing or reconstructed source tree."
    [[ "${INSTALL_CUDA}" -eq 0 ]] \
      || die "Offline source cache does not provision a CUDA toolkit. Load/provide the site CUDA toolkit or use --cuda-runfile explicitly in a normal online run."
    if is_full_stack; then
      [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]] \
        || die "--offline currently requires PLUMED_DISABLE_PYTHON=1 (the default), so PLUMED cannot attempt a network pip/bootstrap operation."
    fi
  fi

  case "${ACCELERATOR}" in
    cuda|cpu) ;;
    *) die "Invalid accelerator '${ACCELERATOR}'. Use the default CUDA backend or pass --cpu-only." ;;
  esac

  if is_cpu_only; then
    [[ "${UPDATE_SAXS}" -eq 0 && "${UPDATE_PLUMED_PATCH}" -eq 0 ]] \
      || die "PLUMED source-update routes are intentionally unsupported with --cpu-only."
    [[ "${INSTALL_CUDA}" -eq 0 ]] \
      || die "--install-cuda is incompatible with --cpu-only."
    [[ "${CUDA_PATH}" == "auto" ]] \
      || die "--cuda is incompatible with --cpu-only."
    [[ "${CUDA_BOOTSTRAP_VERSION}" == "auto" ]] \
      || die "--cuda-version is incompatible with --cpu-only."
    [[ -z "${CUDA_INSTALL_DIR}${CUDA_RUNFILE_URL}${CUDA_RUNFILE}" ]] \
      || die "CUDA installation/runfile options are incompatible with --cpu-only."
    [[ "${CUDA_DRIVER_VERSION}" == "auto" ]] \
      || die "--cuda-driver-version is incompatible with --cpu-only."
    [[ "${CUDA_ARCHS}" == "auto" ]] \
      || die "--arch is incompatible with --cpu-only."
    [[ "${CUDA_SHIM_DIR}" == "auto" ]] \
      || die "--cuda-shim-dir is incompatible with --cpu-only."
    if is_full_stack; then
      [[ -z "${PLUMED_SAXS_CPP}" ]] \
        || die "--saxs-cpp is intentionally unsupported with --cpu-only; CPU PLUMED uses upstream SAXS sources only."
      [[ "${PLUMED_PATCH_DIR}" == "auto" ]] \
        || die "--plumed-patch-dir is intentionally unsupported with --cpu-only; CPU PLUMED uses upstream SAXS sources only."
      [[ -z "${PLUMED_PATCH_BUNDLE}" ]] \
        || die "--plumed-patch-bundle is intentionally unsupported with --cpu-only."
    fi
  fi

  if [[ "${UPDATE_PLUMED_PATCH}" -eq 1 ]]; then
    [[ "${INSTALL_CUDA}" -eq 0 && "${INSTALL_CMAKE}" -eq 0 ]] || die "--update-plumed-patch reuses the existing installation toolchain; do not combine it with --install-cuda/--install-cmake."
    [[ -n "${NAME}" ]] || die "--update-plumed-patch requires --name."
    is_full_stack || die "--update-plumed-patch is only valid for a full PLUMED/GROMACS installation."
    [[ -z "${FROM_STAGE}" && -z "${ONLY_STAGE}" ]] || die "--update-plumed-patch cannot be combined with --from or --only."
    [[ "${WRITE_BASHRC}" -eq 0 && "${WRITE_ALIASES}" -eq 0 ]] || die "--update-plumed-patch does not modify shell activation aliases."
    [[ "${DO_STATUS}" -eq 0 ]] || die "--update-plumed-patch and --status are separate operations."
    [[ "${UPDATE_SAXS}" -eq 0 ]] || die "Use only one of --update-plumed-patch or --update-saxs."
    [[ -z "${PLUMED_SAXS_CPP}" ]] || die "--saxs-cpp is not used with --update-plumed-patch; supply the manifest bundle instead."
    [[ "${PLUMED_PATCH_DIR}" == "auto" ]] || die "--plumed-patch-dir is not used with --update-plumed-patch."
  fi

  if [[ "${UPDATE_SAXS}" -eq 1 ]]; then
    [[ "${INSTALL_CUDA}" -eq 0 && "${INSTALL_CMAKE}" -eq 0 ]] \
      || die "--update-saxs reuses the existing installation toolchain; do not combine it with --install-cuda/--install-cmake."
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
  elif [[ "${UPDATE_PLUMED_PATCH}" -eq 0 ]]; then
    [[ "${ALLOW_DIRTY_PLUMED}" -eq 0 ]] || die "--allow-dirty-plumed is only valid with a PLUMED source-update route."
    [[ "${RUN_INSTALLCHECK}" -eq 0 ]] || die "--installcheck is only valid with a PLUMED source-update route."
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
  if [[ "${DO_STATUS}" -eq 1 && ( "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ) ]]; then
    die "--status is read-only and cannot be combined with --install-cuda/--install-cmake."
  fi
  if [[ -n "${NAME}" && "${NAME}" == */* ]]; then
    die "--name must be a single folder component (no '/'). Use --dir for the parent path."
  fi
  if is_full_stack && [[ -n "${PLUMED_SAXS_CPP}" && ! -f "${PLUMED_SAXS_CPP}" ]]; then
    die "--saxs-cpp file not found: ${PLUMED_SAXS_CPP}"
  fi
  if [[ -n "${PLUMED_PATCH_BUNDLE}" && ! -e "${PLUMED_PATCH_BUNDLE}" ]]; then
    die "--plumed-patch-bundle path not found: ${PLUMED_PATCH_BUNDLE}"
  fi
  if [[ -n "${PLUMED_PATCH_BUNDLE}" ]]; then
    [[ -z "${PLUMED_SAXS_CPP}" ]] || die "Use either --plumed-patch-bundle or --saxs-cpp, not both."
    [[ "${PLUMED_PATCH_DIR}" == "auto" ]] || die "Use either --plumed-patch-bundle or --plumed-patch-dir, not both."
  fi
  if is_gromacs_only; then
    [[ -n "${PLUMED_SAXS_CPP}" ]] && warn "--saxs-cpp is ignored in --gromacs-only mode."
    [[ -n "${PLUMED_PATCH_BUNDLE}" ]] && warn "--plumed-patch-bundle is ignored in --gromacs-only mode."
    [[ "${PLUMED_PATCH_DIR}" != "auto" ]] && warn "--plumed-patch-dir is ignored in --gromacs-only mode."
  fi
  if is_full_stack && ! is_cpu_only && [[ -n "${PLUMED_PATCH_BUNDLE}" ]]; then
    prepare_plumed_patch_bundle_input "${PLUMED_PATCH_BUNDLE}"
    info "Validated PLUMED patch bundle: ${PLUMED_PATCH_FILE_COUNT} files, manifest ${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}."
    cleanup_prepared_plumed_patch_bundle
  fi

  if [[ "${INSTALL_CUDA}" -eq 1 ]]; then
    [[ "${CUDA_PATH}" == "auto" ]] \
      || die "--install-cuda uses --cuda-install-dir for its destination; do not combine it with an explicit --cuda path."
    [[ -z "${CUDA_RUNFILE_URL}" || -z "${CUDA_RUNFILE}" ]] \
      || die "Use only one of --cuda-runfile-url or --cuda-runfile."
  else
    if is_cuda_backend; then
      [[ "${CUDA_BOOTSTRAP_VERSION}" == "auto" ]] \
        || warn "--cuda-version has no effect unless --install-cuda is used."
    fi
    [[ -z "${CUDA_INSTALL_DIR}${CUDA_RUNFILE_URL}${CUDA_RUNFILE}" ]] \
      || die "--cuda-install-dir/--cuda-runfile-url/--cuda-runfile require --install-cuda."
  fi

  if [[ "${INSTALL_CMAKE}" -eq 0 ]]; then
    [[ "${CMAKE_BOOTSTRAP_VERSION}" == "3.31.12" ]] \
      || warn "--cmake-version has no effect unless --install-cmake is used."
    [[ -z "${CMAKE_INSTALL_DIR}${CMAKE_DOWNLOAD_URL}${CMAKE_ARCHIVE}" ]] \
      || die "--cmake-install-dir/--cmake-url/--cmake-archive require --install-cmake."
  fi
  [[ -z "${CUDA_RUNFILE}" || -f "${CUDA_RUNFILE}" ]] \
    || die "CUDA runfile not found: ${CUDA_RUNFILE}"
  [[ -z "${CMAKE_ARCHIVE}" || -f "${CMAKE_ARCHIVE}" ]] \
    || die "CMake archive not found: ${CMAKE_ARCHIVE}"

  return 0
}

cuda_bootstrap_catalog_runfile_url() {

  case "${1}" in
    12.6.3)
      printf '%s\n' 'https://developer.download.nvidia.com/compute/cuda/12.6.3/local_installers/cuda_12.6.3_560.35.05_linux.run'
      ;;
    *) return 1 ;;
  esac
}

cuda_bootstrap_default_version() {

  printf '%s\n' '12.6.3'
}

detect_nvidia_driver_version() {
  local v=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null \
      | awk 'NF{print $1; exit}' || true)"
  fi
  if [[ -z "${v}" && -r /proc/driver/nvidia/version ]]; then
    v="$(grep -oE 'Kernel Module[[:space:]]+[0-9]+([.][0-9]+)+' /proc/driver/nvidia/version 2>/dev/null \
      | grep -oE '[0-9]+([.][0-9]+)+' | head -n1 || true)"
  fi
  if [[ -z "${v}" ]] && command -v modinfo >/dev/null 2>&1; then
    v="$(modinfo -F version nvidia 2>/dev/null | head -n1 || true)"
  fi
  printf '%s\n' "${v}"
}

cuda_driver_minimum_for_toolkit() {

  case "${1%%.*}" in
    11) printf '%s\n' '450.80.02' ;;
    12) printf '%s\n' '525.60.13' ;;
    13) printf '%s\n' '580.00' ;;
    *) return 1 ;;
  esac
}

visible_cuda_archs_for_bootstrap() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null \
    | while IFS= read -r cap; do _normalize_cuda_arch_token "${cap}"; done \
    | awk 'NF && !seen[$0]++' | sort -n | paste -sd';' -
}

validate_cuda_bootstrap_compatibility() {
  local toolkit="${1}" driver="${2}" min_driver archs arch major
  major="${toolkit%%.*}"
  min_driver="$(cuda_driver_minimum_for_toolkit "${toolkit}" || true)"
  [[ -n "${min_driver}" ]] \
    || die "No built-in driver-compatibility rule for CUDA ${toolkit}. Supported toolkit major families are 11, 12 and 13."
  version_ge "${driver}" "${min_driver}" \
    || die "NVIDIA driver ${driver} is too old for CUDA ${toolkit}; need at least ${min_driver} for CUDA ${major}.x. Choose an older toolkit or ask the administrator to update the driver."

  if (( major >= 13 )); then
    archs=""
    if [[ "${CUDA_ARCHS:-auto}" != "auto" ]]; then
      archs="${CUDA_ARCHS//,/;}"
      archs="${archs//[[:space:]]/}"
    else
      archs="$(visible_cuda_archs_for_bootstrap || true)"
    fi
    if [[ -n "${archs}" ]]; then
      IFS=';' read -r -a _cuda_bootstrap_arch_items <<< "${archs}"
      for arch in "${_cuda_bootstrap_arch_items[@]}"; do
        arch="$(_normalize_cuda_arch_token "${arch}")"
        [[ -n "${arch}" ]] || continue
        if (( 10#${arch} < 75 )); then
          die "CUDA ${toolkit} cannot target compute capability ${arch}; CUDA 13 removed offline compilation/library support for pre-Turing GPUs. Use CUDA 12.x."
        fi
      done
    else
      warn "CUDA ${toolkit} is 13.x but GPU architecture is not visible. On a GPU-less/login node pass --arch explicitly; CUDA 13 requires Turing (75) or newer."
    fi
  fi
}

cmake_platform_tag() {
  local machine
  [[ "$(uname -s)" == "Linux" ]] \
    || die "Private prebuilt CMake bootstrap currently supports Linux only."
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) printf '%s\n' 'linux-x86_64' ;;
    aarch64|arm64) printf '%s\n' 'linux-aarch64' ;;
    *) die "No prebuilt CMake bootstrap mapping for architecture '${machine}'. Install CMake manually or put it on PATH." ;;
  esac
}

resolve_toolchain_bootstrap() {
  [[ "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ]] || return 0

  DIR="$(abspath "${DIR}")"
  if [[ -z "${TOOLCHAIN_DIR}" ]]; then
    if [[ -n "${WORK_DIR}" ]]; then
      TOOLCHAIN_DIR="$(abspath "${WORK_DIR}")/toolchain"
    else
      TOOLCHAIN_DIR="${DIR%/}/toolchain"
    fi
  else
    TOOLCHAIN_DIR="$(abspath "${TOOLCHAIN_DIR}")"
  fi
  TOOLCHAIN_DOWNLOAD_DIR="${TOOLCHAIN_DIR}/downloads"

  if [[ "${INSTALL_CMAKE}" -eq 1 ]]; then
    [[ "${CMAKE_BOOTSTRAP_VERSION}" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] \
      || die "Invalid --cmake-version '${CMAKE_BOOTSTRAP_VERSION}'."
    if [[ -z "${CMAKE_INSTALL_DIR}" ]]; then
      CMAKE_INSTALL_DIR="${TOOLCHAIN_DIR}/cmake-${CMAKE_BOOTSTRAP_VERSION}"
    else
      CMAKE_INSTALL_DIR="$(abspath "${CMAKE_INSTALL_DIR}")"
    fi
    case "${GROMACS_VERSION}" in
      2025*) version_ge "${CMAKE_BOOTSTRAP_VERSION}" "3.28" \
               || die "Requested CMake ${CMAKE_BOOTSTRAP_VERSION} is too old for GROMACS ${GROMACS_VERSION}; use CMake 3.28+." ;;
      2024*) version_ge "${CMAKE_BOOTSTRAP_VERSION}" "3.18.4" \
               || die "Requested CMake ${CMAKE_BOOTSTRAP_VERSION} is too old for GROMACS ${GROMACS_VERSION}; use CMake 3.18.4+." ;;
    esac
    if [[ -z "${CMAKE_DOWNLOAD_URL}" && -z "${CMAKE_ARCHIVE}" ]]; then
      local cmake_tag
      cmake_tag="$(cmake_platform_tag)"
      CMAKE_DOWNLOAD_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_BOOTSTRAP_VERSION}/cmake-${CMAKE_BOOTSTRAP_VERSION}-${cmake_tag}.tar.gz"
    fi
  fi

  if [[ "${INSTALL_CUDA}" -eq 1 ]]; then
    if [[ "${CUDA_BOOTSTRAP_VERSION}" == "auto" ]]; then
      RESOLVED_CUDA_BOOTSTRAP_VERSION="$(cuda_bootstrap_default_version)"
    else
      RESOLVED_CUDA_BOOTSTRAP_VERSION="${CUDA_BOOTSTRAP_VERSION}"
    fi
    [[ "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] \
      || die "Invalid --cuda-version '${RESOLVED_CUDA_BOOTSTRAP_VERSION}'. Expected e.g. 12.6.3."
    if [[ "${GROMACS_VERSION}" == 2025* ]]; then
      version_ge "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" "12.1" \
        || die "Requested CUDA ${RESOLVED_CUDA_BOOTSTRAP_VERSION} is too old for GROMACS ${GROMACS_VERSION}; CUDA 12.1+ is required."
    fi

    if [[ -z "${CUDA_INSTALL_DIR}" ]]; then
      CUDA_INSTALL_DIR="${TOOLCHAIN_DIR}/cuda-${RESOLVED_CUDA_BOOTSTRAP_VERSION}"
    else
      CUDA_INSTALL_DIR="$(abspath "${CUDA_INSTALL_DIR}")"
    fi

    if [[ -z "${CUDA_RUNFILE_URL}" && -z "${CUDA_RUNFILE}" ]]; then
      CUDA_RUNFILE_URL="$(cuda_bootstrap_catalog_runfile_url "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" || true)"
      [[ -n "${CUDA_RUNFILE_URL}" ]] \
        || die "CUDA ${RESOLVED_CUDA_BOOTSTRAP_VERSION} is not in the curated runfile catalog. Provide --cuda-runfile-url <official-NVIDIA-url> or --cuda-runfile <local-file>."
    fi

    if [[ "${CUDA_DRIVER_VERSION}" == "auto" ]]; then
      RESOLVED_NVIDIA_DRIVER_VERSION="$(detect_nvidia_driver_version)"
    else
      RESOLVED_NVIDIA_DRIVER_VERSION="${CUDA_DRIVER_VERSION}"
    fi
    [[ "${RESOLVED_NVIDIA_DRIVER_VERSION}" =~ ^[0-9]+([.][0-9]+)+$ ]] \
      || die "Could not determine an NVIDIA driver version. On a GPU-less/login node pass --cuda-driver-version <version> from the target machine."
    validate_cuda_bootstrap_compatibility "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" "${RESOLVED_NVIDIA_DRIVER_VERSION}"
  fi
}

toolchain_bootstrap_preflight() {
  [[ "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ]] || return 0
  section "Private toolchain bootstrap preflight"

  local missing=() c
  for c in bash awk grep find; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if [[ "${INSTALL_CMAKE}" -eq 1 ]]; then
    for c in tar; do command -v "${c}" >/dev/null 2>&1 || missing+=("${c}"); done
    if [[ -z "${CMAKE_ARCHIVE}" && "${CMAKE_DOWNLOAD_URL}" == https://github.com/Kitware/CMake/releases/download/* ]]; then
      command -v sha256sum >/dev/null 2>&1 || missing+=("sha256sum")
    fi
  fi
  if [[ -z "${CUDA_RUNFILE:-}" && -z "${CMAKE_ARCHIVE:-}" ]]; then
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      missing+=("wget-or-curl")
    fi
  elif [[ -z "${CUDA_RUNFILE:-}" && "${INSTALL_CUDA}" -eq 1 ]]; then
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      missing+=("wget-or-curl")
    fi
  elif [[ -z "${CMAKE_ARCHIVE:-}" && "${INSTALL_CMAKE}" -eq 1 ]]; then
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      missing+=("wget-or-curl")
    fi
  fi
  [[ ${#missing[@]} -eq 0 ]] \
    || die "Missing tools required for private toolchain bootstrap: ${missing[*]}"
  ok "Bootstrap helper tools present."

  local probe="${TOOLCHAIN_DIR}"
  while [[ ! -e "${probe}" && "${probe}" != "/" ]]; do probe="$(dirname "${probe}")"; done
  [[ -w "${probe}" ]] \
    || die "No write permission for ${probe}; cannot create private toolchain under ${TOOLCHAIN_DIR}."
  ok "Private toolchain parent is writable via ${probe}."

  local avail_kb avail_gb need_gb=2
  [[ "${INSTALL_CUDA}" -eq 0 ]] || need_gb=12
  avail_kb="$(df -Pk "${probe}" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "${avail_kb}" ]]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < need_gb )); then
      die "Only ~${avail_gb} GB free at ${probe}; private toolchain bootstrap needs at least ~${need_gb} GB headroom."
    fi
    ok "~${avail_gb} GB free at ${probe}."
  fi

  if [[ "${INSTALL_CUDA}" -eq 1 ]]; then
    ok "CUDA driver compatibility check passed: driver ${RESOLVED_NVIDIA_DRIVER_VERSION}, toolkit ${RESOLVED_CUDA_BOOTSTRAP_VERSION}."
    info "CUDA bootstrap is toolkit-only; the NVIDIA driver is not an install target."
  fi
}

print_toolchain_bootstrap_plan() {
  [[ "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ]] || return 0
  section "Private toolchain bootstrap plan"
  printf '  %-24s : %s\n' "Toolchain parent" "${TOOLCHAIN_DIR}"
  printf '  %-24s : %s\n' "Download cache" "${TOOLCHAIN_DOWNLOAD_DIR}"
  if [[ "${INSTALL_CMAKE}" -eq 1 ]]; then
    printf '  %-24s : %s\n' "CMake" "${CMAKE_BOOTSTRAP_VERSION} -> ${CMAKE_INSTALL_DIR}"
    printf '  %-24s : %s\n' "CMake source" "${CMAKE_ARCHIVE:-${CMAKE_DOWNLOAD_URL}}"
  else
    printf '  %-24s : %s\n' "CMake bootstrap" "disabled"
  fi
if [[ "${INSTALL_CUDA}" -eq 1 ]]; then
    printf '  %-24s : %s\n' "CUDA Toolkit" "${RESOLVED_CUDA_BOOTSTRAP_VERSION} -> ${CUDA_INSTALL_DIR}"
    printf '  %-24s : %s\n' "CUDA source" "${CUDA_RUNFILE:-${CUDA_RUNFILE_URL}}"
    printf '  %-24s : %s\n' "NVIDIA driver" "${RESOLVED_NVIDIA_DRIVER_VERSION} (existing; never modified)"
    printf '  %-24s : %s\n' "Driver installation" "DISABLED (--toolkit only)"
  else
    printf '  %-24s : %s\n' "CUDA bootstrap" "disabled"
  fi
}

install_private_cmake() {
  [[ "${INSTALL_CMAKE}" -eq 1 ]] || return 0
  section "Private CMake ${CMAKE_BOOTSTRAP_VERSION} bootstrap"

  if [[ -x "${CMAKE_INSTALL_DIR}/bin/cmake" ]]; then
    local existing
    existing="$(${CMAKE_INSTALL_DIR}/bin/cmake --version 2>/dev/null | head -n1 | awk '{print $3}' || true)"
    if [[ "${existing}" == "${CMAKE_BOOTSTRAP_VERSION}" ]]; then
      ok "Reusing private CMake ${existing} at ${CMAKE_INSTALL_DIR}."
      CMAKE_ROOT="${CMAKE_INSTALL_DIR}"
      export CMAKE_ROOT
      export PATH="${CMAKE_ROOT}/bin:${PATH}"
      return 0
    fi
    die "CMake prefix ${CMAKE_INSTALL_DIR} contains version '${existing:-unknown}', not ${CMAKE_BOOTSTRAP_VERSION}. Choose a different --cmake-install-dir."
  fi
  if [[ -e "${CMAKE_INSTALL_DIR}" && -n "$(ls -A "${CMAKE_INSTALL_DIR}" 2>/dev/null)" ]]; then
    die "CMake install directory is non-empty but has no matching cmake executable: ${CMAKE_INSTALL_DIR}"
  fi

  mkdir -p "${TOOLCHAIN_DOWNLOAD_DIR}" "$(dirname "${CMAKE_INSTALL_DIR}")"
  local archive checksum_file archive_name tmp top installed
  if [[ -n "${CMAKE_ARCHIVE}" ]]; then
    archive="$(abspath "${CMAKE_ARCHIVE}")"
    info "Using local CMake archive: ${archive}"
  else
    archive_name="$(basename "${CMAKE_DOWNLOAD_URL}")"
    archive="${TOOLCHAIN_DOWNLOAD_DIR}/${archive_name}"
    download_to "${CMAKE_DOWNLOAD_URL}" "${archive}"
    if [[ "${CMAKE_DOWNLOAD_URL}" == https://github.com/Kitware/CMake/releases/download/v${CMAKE_BOOTSTRAP_VERSION}/* ]]; then
      checksum_file="${TOOLCHAIN_DOWNLOAD_DIR}/cmake-${CMAKE_BOOTSTRAP_VERSION}-SHA-256.txt"
      download_to "https://github.com/Kitware/CMake/releases/download/v${CMAKE_BOOTSTRAP_VERSION}/cmake-${CMAKE_BOOTSTRAP_VERSION}-SHA-256.txt" "${checksum_file}"
      grep -F " ${archive_name}" "${checksum_file}" | (cd "${TOOLCHAIN_DOWNLOAD_DIR}" && sha256sum -c -) \
        || die "CMake archive SHA-256 verification failed: ${archive}"
      ok "CMake archive SHA-256 verified against Kitware release metadata."
    else
      warn "Custom CMake URL supplied; automatic Kitware SHA-256 manifest verification is skipped."
    fi
  fi

  tmp="$(mktemp -d "${TOOLCHAIN_DIR}/.cmake-install.XXXXXX")"
  tar -xzf "${archive}" -C "${tmp}"
  top="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "${top}" && -x "${top}/bin/cmake" ]] \
    || { rm -rf "${tmp}"; die "CMake archive did not contain the expected prebuilt install tree."; }
  rm -rf "${CMAKE_INSTALL_DIR}"
  mv "${top}" "${CMAKE_INSTALL_DIR}"
  rm -rf "${tmp}"

  installed="$(${CMAKE_INSTALL_DIR}/bin/cmake --version | head -n1 | awk '{print $3}')"
  [[ "${installed}" == "${CMAKE_BOOTSTRAP_VERSION}" ]] \
    || die "Private CMake version verification failed: requested ${CMAKE_BOOTSTRAP_VERSION}, got ${installed}."
  CMAKE_ROOT="${CMAKE_INSTALL_DIR}"
  export CMAKE_ROOT
  export PATH="${CMAKE_ROOT}/bin:${PATH}"
  ok "Private CMake ${installed} installed at ${CMAKE_ROOT}."
}

install_private_cuda() {
  [[ "${INSTALL_CUDA}" -eq 1 ]] || return 0
  section "Private CUDA Toolkit ${RESOLVED_CUDA_BOOTSTRAP_VERSION} bootstrap (NO DRIVER)"

  if [[ -x "${CUDA_INSTALL_DIR}/bin/nvcc" ]]; then
    local existing
    existing="$(get_cuda_version "${CUDA_INSTALL_DIR}/bin/nvcc" || true)"
    if [[ "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" == "${existing}"* || "${existing}" == "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" ]]; then
      ok "Reusing private CUDA ${existing} at ${CUDA_INSTALL_DIR}."
      CUDA_PATH="${CUDA_INSTALL_DIR}"
      return 0
    fi
    die "CUDA prefix ${CUDA_INSTALL_DIR} contains toolkit '${existing:-unknown}', not ${RESOLVED_CUDA_BOOTSTRAP_VERSION}. Choose a different --cuda-install-dir."
  fi
  if [[ -e "${CUDA_INSTALL_DIR}" && -n "$(ls -A "${CUDA_INSTALL_DIR}" 2>/dev/null)" ]]; then
    die "CUDA install directory is non-empty but has no matching nvcc: ${CUDA_INSTALL_DIR}"
  fi

  mkdir -p "${TOOLCHAIN_DOWNLOAD_DIR}" "$(dirname "${CUDA_INSTALL_DIR}")"
  local runfile runfile_name tmp driver_before driver_after installed
  if [[ -n "${CUDA_RUNFILE}" ]]; then
    runfile="$(abspath "${CUDA_RUNFILE}")"
    info "Using local NVIDIA CUDA runfile: ${runfile}"
  else
    runfile_name="$(basename "${CUDA_RUNFILE_URL}")"
    runfile="${TOOLCHAIN_DOWNLOAD_DIR}/${runfile_name}"
    download_to "${CUDA_RUNFILE_URL}" "${runfile}"
  fi
  chmod u+x "${runfile}" 2>/dev/null || true

  driver_before="$(detect_nvidia_driver_version)"
  [[ -n "${driver_before}" ]] || driver_before="${RESOLVED_NVIDIA_DRIVER_VERSION}"
  tmp="$(mktemp -d "${TOOLCHAIN_DIR}/.cuda-install.XXXXXX")"
  mkdir -p "${CUDA_INSTALL_DIR}"

  bash "${runfile}" \
    --silent \
    --toolkit \
    --toolkitpath="${CUDA_INSTALL_DIR}" \
    --defaultroot="${CUDA_INSTALL_DIR}" \
    --no-man-page \
    --tmpdir="${tmp}"
  rm -rf "${tmp}"

  [[ -x "${CUDA_INSTALL_DIR}/bin/nvcc" ]] \
    || die "CUDA installer completed but nvcc is missing: ${CUDA_INSTALL_DIR}/bin/nvcc"
  installed="$(get_cuda_version "${CUDA_INSTALL_DIR}/bin/nvcc")"
  [[ "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" == "${installed}"* || "${installed}" == "${RESOLVED_CUDA_BOOTSTRAP_VERSION}" ]] \
    || die "CUDA toolkit version verification failed: requested ${RESOLVED_CUDA_BOOTSTRAP_VERSION}, got ${installed}."

  driver_after="$(detect_nvidia_driver_version)"
  if [[ -n "${driver_before}" && -n "${driver_after}" && "${driver_before}" != "${driver_after}" ]]; then
    die "NVIDIA driver version changed unexpectedly during toolkit-only installation (${driver_before} -> ${driver_after})."
  fi
  ok "NVIDIA driver remained unchanged (${driver_after:-${driver_before}})."
  ok "Private CUDA Toolkit ${installed} installed at ${CUDA_INSTALL_DIR}."
  CUDA_PATH="${CUDA_INSTALL_DIR}"
}

check_work_dir() {
  [[ "${SPLIT_LAYOUT}" -eq 1 ]] || return 0
  local marker="${WORK_ROOT}/.installer_install_root" recorded=""
  if [[ -s "${marker}" ]]; then
    recorded="$(head -n1 "${marker}" 2>/dev/null || true)"
    [[ -z "${recorded}" || "$(abspath "${recorded}")" == "$(abspath "${INSTALL_ROOT}")" || "${FORCE}" -eq 1 ]] \
      || die "Workspace ${WORK_ROOT} belongs to a different installation (${recorded}), not ${INSTALL_ROOT}. Choose another --work-dir/--name or pass --force only after inspection."
  elif [[ -d "${WORK_ROOT}" && -n "$(ls -A "${WORK_ROOT}" 2>/dev/null)" ]]; then
    if [[ "${FORCE}" -eq 1 || -n "${FROM_STAGE}" || -n "${ONLY_STAGE}" || "${ASSUME_YES}" -eq 1 ]]; then
      warn "Reusing non-empty split workspace without ownership marker: ${WORK_ROOT}"
    else
      die "Workspace already exists and is non-empty but is not marked as belonging to this installation:\n    ${WORK_ROOT}\nChoose another --work-dir/--name, or inspect it and rerun with --yes/--force."
    fi
  fi
}

persist_workspace_profile() {
  [[ "${SPLIT_LAYOUT}" -eq 1 ]] || return 0
  mkdir -p "${WORK_ROOT}"
  printf '%s\n' "${INSTALL_ROOT}" > "${WORK_ROOT}/.installer_install_root"
  printf '%s\n' "${SCRIPT_VERSION}" > "${WORK_ROOT}/.installer_version"
}

get_cuda_version() {

  local nvcc="${1}"
  "${nvcc}" --version 2>/dev/null \
    | grep -oE 'release [0-9]+\.[0-9]+' | head -n1 | awk '{print $2}'
}

_cuda_maybe_add_candidate() {

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

    _cuda_maybe_add_candidate candidates "${CUDA_HOME:-}"
    _cuda_maybe_add_candidate candidates "${CUDA_ROOT:-}"
    if command -v nvcc >/dev/null 2>&1; then
      nvcc_path="$(command -v nvcc)"
      _cuda_maybe_add_candidate candidates "$(dirname "$(dirname "${nvcc_path}")")"
    fi

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

  export CUDA_HOME
  export CUDA_ROOT="${CUDA_HOME}"
  export CUDACXX="${CUDA_HOME}/bin/nvcc"
  export PATH="${CUDA_HOME}/bin:${PATH}"
  export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
}

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

resolve_paths() {
  DIR="$(abspath "${DIR}")"
  if [[ -z "${NAME}" ]]; then
    if is_cpu_only; then
      NAME="build_cpu"
    else
      NAME="build_${CUDA_VERSION}"
    fi
  fi

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
  if [[ -n "${WORK_DIR}" ]]; then
    WORK_DIR="$(abspath "${WORK_DIR}")"
    WORK_ROOT="${WORK_DIR%/}/${NAME}"
    SPLIT_LAYOUT=1
  else
    WORK_ROOT="${INSTALL_ROOT}"
    SPLIT_LAYOUT=0
  fi
  SRC="${WORK_ROOT}/src"
  LOG_DIR="${WORK_ROOT}/build_logs"
  CKPT_DIR="${WORK_ROOT}/.checkpoints"

  if [[ "${NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    ALIAS_NAME="${NAME}"
  else
    ALIAS_NAME="$(printf '%s' "${NAME}" | sed 's/[^A-Za-z0-9_]/_/g')"
    [[ "${ALIAS_NAME}" =~ ^[A-Za-z_] ]] || ALIAS_NAME="env_${ALIAS_NAME}"
  fi
}

persist_install_profile() {
  mkdir -p "${INSTALL_ROOT}"
  printf '%s\n' "${BUILD_MODE}" > "${INSTALL_ROOT}/.installer_build_mode"
  printf '%s\n' "${ACCELERATOR}" > "${INSTALL_ROOT}/.installer_accelerator"
  printf '%s\n' "${MPI_PROVIDER}" > "${INSTALL_ROOT}/.installer_mpi_provider"
  printf '%s\n' "${MPI_ROOT:-}" > "${INSTALL_ROOT}/.installer_mpi_prefix"
  printf '%s\n' "$([[ "${OFFLINE}" -eq 1 ]] && echo offline || echo online)" > "${INSTALL_ROOT}/.installer_source_mode"
  printf '%s\n' "${SOURCE_CACHE:-}" > "${INSTALL_ROOT}/.installer_source_cache"
  printf '%s\n' "${WORK_DIR:-}" > "${INSTALL_ROOT}/.installer_work_parent"
  printf '%s\n' "${WORK_ROOT:-${INSTALL_ROOT}}" > "${INSTALL_ROOT}/.installer_work_root"
  printf '%s\n' "${PLUMED_REF:-}" > "${INSTALL_ROOT}/.installer_plumed_ref"
  printf '%s\n' "${GROMACS_VERSION:-}" > "${INSTALL_ROOT}/.installer_gromacs_version"
  printf '%s\n' "${PLUMED_DISABLE_PYTHON:-1}" > "${INSTALL_ROOT}/.installer_plumed_disable_python"
}

load_persisted_install_profile() {
  local f value
  f="${INSTALL_ROOT}/.installer_build_mode"
  if [[ -s "${f}" ]]; then BUILD_MODE="$(head -n1 "${f}")"; fi
  f="${INSTALL_ROOT}/.installer_accelerator"
  if [[ -s "${f}" ]]; then ACCELERATOR="$(head -n1 "${f}")"; fi
  f="${INSTALL_ROOT}/.installer_mpi_provider"
  if [[ -s "${f}" ]]; then
    value="$(head -n1 "${f}")"
    [[ "${value}" == "private" || "${value}" == "system" ]] && MPI_PROVIDER="${value}"
  fi
  f="${INSTALL_ROOT}/.installer_mpi_prefix"
  if [[ -s "${f}" && "${MPI_PREFIX_EXPLICIT}" -eq 0 ]]; then MPI_PREFIX="$(head -n1 "${f}")"; fi
  f="${INSTALL_ROOT}/.installer_source_cache"
  if [[ -s "${f}" && -z "${SOURCE_CACHE}" ]]; then SOURCE_CACHE="$(head -n1 "${f}")"; fi
  f="${INSTALL_ROOT}/.installer_work_parent"
  if [[ -s "${f}" ]]; then
    value="$(head -n1 "${f}")"
    if [[ "${WORK_DIR_EXPLICIT}" -eq 1 && -n "${value}" && "$(abspath "${WORK_DIR}")" != "$(abspath "${value}")" ]]; then
      die "Requested --work-dir differs from the workspace recorded for this installation: requested=$(abspath "${WORK_DIR}"), recorded=$(abspath "${value}")."
    fi
    if [[ "${WORK_DIR_EXPLICIT}" -eq 0 ]]; then WORK_DIR="${value}"; fi
  fi
  f="${INSTALL_ROOT}/.installer_plumed_ref"
  if [[ -s "${f}" ]]; then PLUMED_REF="$(head -n1 "${f}")"; fi
  f="${INSTALL_ROOT}/.installer_gromacs_version"
  if [[ -s "${f}" && "${GROMACS_VERSION}" == "auto" ]]; then GROMACS_VERSION="$(head -n1 "${f}")"; fi
  f="${INSTALL_ROOT}/.installer_plumed_disable_python"
  if [[ -s "${f}" ]]; then PLUMED_DISABLE_PYTHON="$(head -n1 "${f}")"; fi
  configure_build_mode
}

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

check_install_dir() {
  local mode_marker="${INSTALL_ROOT}/.installer_build_mode"
  local accel_marker="${INSTALL_ROOT}/.installer_accelerator"
  if [[ -f "${mode_marker}" ]]; then
    local existing_mode
    existing_mode="$(head -n1 "${mode_marker}" 2>/dev/null || true)"
    if [[ -n "${existing_mode}" && "${existing_mode}" != "${BUILD_MODE}" && "${FORCE}" -ne 1 ]]; then
      die "Install root was created in build mode '${existing_mode}', but '${BUILD_MODE}' was requested:
    ${INSTALL_ROOT}
Use a new --name, or pass --force to replace/rebuild the selected route."
    fi
  elif [[ -d "${CKPT_DIR}" ]] && is_gromacs_only && [[ "${FORCE}" -ne 1 ]]; then
    die "Existing checkpointed install has no build-mode marker and is assumed to be a legacy full-stack environment. Use a new --name for --gromacs-only, or pass --force."
  fi

  if [[ -f "${accel_marker}" ]]; then
    local existing_accel
    existing_accel="$(head -n1 "${accel_marker}" 2>/dev/null || true)"
    if [[ -n "${existing_accel}" && "${existing_accel}" != "${ACCELERATOR}" ]]; then
      die "Install root was created with accelerator/backend '${existing_accel}', but '${ACCELERATOR}' was requested:
    ${INSTALL_ROOT}
Backend changes are not allowed in-place, even with --force; use a new --name to prevent stale CPU/GPU artifacts from mixing."
    fi
  elif [[ -d "${CKPT_DIR}" ]] && is_cpu_only; then

    die "Existing checkpointed install has no accelerator marker and is conservatively assumed to be a legacy CUDA build. Use a new --name for --cpu-only; backend conversion in-place is intentionally refused."
  fi

  if [[ -d "${INSTALL_ROOT}" ]] && [[ -n "$(ls -A "${INSTALL_ROOT}" 2>/dev/null)" ]]; then
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

version_ge() {

  [[ "$(printf '%s\n%s\n' "${2}" "${1}" | sort -V | head -n1)" == "${2}" ]]
}

path_list_to_array() {

  local list="${1:-}" item
  [[ -n "${list}" ]] || return 0
  IFS=':' read -r -a _path_items <<< "${list}"
  for item in "${_path_items[@]}"; do
    [[ -n "${item}" && -d "${item}" ]] && printf '%s
' "$(abspath "${item}")"
  done
}

first_existing_file() {

  local name="${1}" d
  shift
  for d in "$@"; do
    [[ -f "${d}/${name}" ]] && { printf '%s
' "${d}/${name}"; return 0; }
  done
  return 1
}

first_existing_library() {

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

      if [[ "${base}" =~ ^(lib[^.]+)\.so\. ]]; then
        stem="${BASH_REMATCH[1]}.so"
        [[ -e "${shim}/lib64/${stem}" ]] || ln -sfn "${base}" "${shim}/lib64/${stem}"
      fi
    done
    shopt -u nullglob
  done < <(cuda_candidate_lib_dirs | unique_lines)

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

probe_private_openmpi_libnsl() {

  is_full_stack && is_cuda_backend && ! using_system_mpi || return 0
  [[ -x "${BUILD_CC:-}" ]] || return 0
  local tmp src exe
  tmp="$(mktemp -d 2>/dev/null || mktemp -d -t af_nsl_probe)"
  src="${tmp}/nsl_probe.c"
  exe="${tmp}/nsl_probe"
  printf '%s\n' 'int main(void){return 0;}' > "${src}"
  if "${BUILD_CC}" "${src}" -lnsl -o "${exe}" >/dev/null 2>&1; then
    ok "Optional libnsl linker probe passed for private OpenMPI."
  else
    warn "Optional '-lnsl' linker probe failed. This is not universally required, but some private OpenMPI configurations can fail late when libnsl development files are absent. If the site provides a supported MPI, consider --use-system-mpi instead of adding ad-hoc linker symlinks."
  fi
  rm -rf "${tmp}"
}

preflight() {
  section "Preflight checks"

  _pf_fail() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then warn "$1"; else die "$1"; fi
  }

  local missing=()
  local c required_tools=(tar make pkg-config gcc g++ awk sed grep find)
  if [[ "${INSTALL_CMAKE}" -eq 0 ]]; then required_tools+=(cmake); fi
  if is_full_stack; then required_tools+=(git); fi
  for c in "${required_tools[@]}"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if [[ "${OFFLINE}" -eq 0 ]] && ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    missing+=("wget-or-curl")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    _pf_fail "Missing required tools: ${missing[*]}
On HPC, try 'module load' for the relevant compilers/cmake/git, or ask your admin."
  else
    ok "Required tools present."
  fi
  [[ -x "${BUILD_CC:-}" ]] || _pf_fail "Resolved C compiler is not runnable: ${BUILD_CC:-unset}"
  [[ -x "${BUILD_CXX:-}" ]] || _pf_fail "Resolved C++ compiler is not runnable: ${BUILD_CXX:-unset}"
  [[ ! -x "${BUILD_CC:-}" ]] || ok "C compiler: ${BUILD_CC} ($(${BUILD_CC} --version 2>/dev/null | head -n1 || true))"
  [[ ! -x "${BUILD_CXX:-}" ]] || ok "C++ compiler: ${BUILD_CXX} ($(${BUILD_CXX} --version 2>/dev/null | head -n1 || true))"

  probe_private_openmpi_libnsl

  if is_full_stack && is_cuda_backend && using_system_mpi; then
    validate_system_mpi_selection
  fi

  if [[ "${INSTALL_CMAKE}" -eq 1 && "${DRY_RUN}" -eq 1 && ! -x "${CMAKE_INSTALL_DIR}/bin/cmake" ]]; then
    info "Private CMake ${CMAKE_BOOTSTRAP_VERSION} is scheduled at ${CMAKE_INSTALL_DIR}; system CMake is not required for this run."
  fi

  if command -v cmake >/dev/null 2>&1; then
    local cmake_ver cmake_min cmake_msg
    cmake_ver="$(cmake --version | head -n1 | awk '{print $3}')"
    cmake_min="3.16"
    cmake_msg="3.16+ is recommended for the configured build route."
    if should_run gromacs; then
      case "${GROMACS_VERSION}" in
        2025*) cmake_min="3.28"; cmake_msg="GROMACS ${GROMACS_VERSION} needs CMake 3.28+." ;;
        2024*) cmake_min="3.18.4"; cmake_msg="GROMACS ${GROMACS_VERSION} needs CMake 3.18.4+." ;;
        auto)  cmake_min="3.18.4"; cmake_msg="GROMACS auto mode needs CMake 3.18.4+ for the 2024 fallback; 2025.4 will additionally require 3.28+ if selected." ;;
      esac
    fi
    if ! version_ge "${cmake_ver}" "${cmake_min}"; then
      _pf_fail "CMake ${cmake_ver} detected; ${cmake_msg}"
    else
      ok "CMake ${cmake_ver}."
    fi
  fi

  if is_cpu_only; then
    ok "CPU-only backend: CUDA/nvcc/NVIDIA driver/architecture checks are not required."
  else
    if [[ "${INSTALL_CUDA}" -eq 1 && "${DRY_RUN}" -eq 1 && ! -x "${CUDA_HOME}/bin/nvcc" ]]; then
      info "Private CUDA ${CUDA_VERSION} is scheduled at ${CUDA_HOME}; nvcc is not expected during --dry-run."
    elif "${CUDA_HOME}/bin/nvcc" --version >/dev/null 2>&1; then
      ok "CUDA ${CUDA_VERSION} at ${CUDA_HOME}."
      export CUDACXX="${CUDA_HOME}/bin/nvcc"
    else
      _pf_fail "nvcc at ${CUDA_HOME}/bin/nvcc is not runnable."
    fi

    local hot_missing=() h l
    if [[ "${INSTALL_CUDA}" -eq 1 && "${DRY_RUN}" -eq 1 && ! -x "${CUDA_HOME}/bin/nvcc" ]]; then
      info "CUDA headers/libraries will be validated after the requested toolkit bootstrap."
    else
      while IFS= read -r h; do
        [[ -e "${CUDA_HOME}/include/${h}" || -e "${CUDA_HOME}/targets/x86_64-linux/include/${h}" ]] || hot_missing+=("${h}")
      done < <(cuda_required_headers)
      while IFS= read -r l; do
        [[ -e "${CUDA_HOME}/lib64/${l}" || -e "${CUDA_HOME}/targets/x86_64-linux/lib/${l}" ]] || hot_missing+=("${l}")
      done < <(cuda_required_libraries)
      if [[ ${#hot_missing[@]} -gt 0 ]]; then
        _pf_fail "Missing hot CUDA headers/libraries: ${hot_missing[*]}"
      else
        ok "Hot CUDA headers/libraries present."
      fi
    fi
  fi

  if is_gromacs_only; then
    if is_cpu_only; then
      ok "CPU GROMACS-only mode: PLUMED/ArrayFire/OpenMPI/CUDA dependencies are not required."
    else
      ok "GROMACS-only mode: PLUMED/Python/ArrayFire development dependencies are not required."
    fi
  elif is_cpu_only; then
    ok "CPU PLUMED route: OpenMPI/ArrayFire/CUDA development dependencies are not required."
    if [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]]; then
      ok "PLUMED Python wrapper disabled; Python.h/pip/venv are not required."
    fi
  elif [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]]; then
    ok "PLUMED Python wrapper disabled; Python.h/pip/venv are not required."
  fi

  if is_full_stack && [[ "${PLUMED_DISABLE_PYTHON}" != "1" ]] && command -v python3 >/dev/null 2>&1; then
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

  local install_probe="${INSTALL_ROOT}" work_probe="${WORK_ROOT}"
  while [[ ! -e "${install_probe}" && "${install_probe}" != "/" ]]; do install_probe="$(dirname "${install_probe}")"; done
  if [[ ! -w "${install_probe}" ]]; then
    _pf_fail "No write permission for ${install_probe} (needed to create ${INSTALL_ROOT}).
Choose a user-owned --dir or ask the HPC administrator to provide a writable location. This installer does not require or invoke sudo."
  else
    ok "Write permission for installation parent ${install_probe}."
  fi

  if [[ "${SPLIT_LAYOUT}" -eq 1 ]]; then
    while [[ ! -e "${work_probe}" && "${work_probe}" != "/" ]]; do work_probe="$(dirname "${work_probe}")"; done
    if [[ ! -w "${work_probe}" ]]; then
      _pf_fail "No write permission for ${work_probe} (needed to create workspace ${WORK_ROOT}). Choose a writable --work-dir."
    else
      ok "Write permission for workspace parent ${work_probe}."
    fi
  else
    work_probe="${install_probe}"
  fi

  local avail_kb avail_gb runtime_warn_gb work_warn_gb
  runtime_warn_gb=2
  is_full_stack && runtime_warn_gb=4
  work_warn_gb=6
  is_full_stack && ! is_cpu_only && work_warn_gb=20

  avail_kb="$(df -Pk "${install_probe}" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "${avail_kb}" ]]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ "${SPLIT_LAYOUT}" -eq 1 ]]; then
      if (( avail_gb < runtime_warn_gb )); then
        warn "Only ~${avail_gb} GB free at installation parent ${install_probe}; split layout keeps build sources elsewhere, but the selected runtime install should still have ~${runtime_warn_gb} GB headroom."
      else
        ok "~${avail_gb} GB free at installation parent ${install_probe} (runtime-only split layout)."
      fi
    elif (( avail_gb < 20 )); then
      if is_gromacs_only || is_cpu_only; then
        warn "Only ~${avail_gb} GB free at ${install_probe}; the selected lightweight legacy-layout build still needs several GB for sources and compilation."
      else
        warn "Only ~${avail_gb} GB free at ${install_probe}; the full CUDA legacy-layout build can need 15-25 GB."
      fi
    else
      ok "~${avail_gb} GB free at ${install_probe}."
    fi
  fi

  if [[ "${SPLIT_LAYOUT}" -eq 1 ]]; then
    avail_kb="$(df -Pk "${work_probe}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${avail_kb}" ]]; then
      avail_gb=$(( avail_kb / 1024 / 1024 ))
      if (( avail_gb < work_warn_gb )); then
        warn "Only ~${avail_gb} GB free at workspace parent ${work_probe}; the selected build may need ~${work_warn_gb} GB or more while compiling."
      else
        ok "~${avail_gb} GB free at workspace parent ${work_probe} for sources/builds."
      fi
    fi
  fi
}

resolve_system_mpi_root() {
  using_system_mpi || return 0
  local mpicc_path prefix
  if [[ -n "${MPI_PREFIX}" ]]; then
    prefix="$(abspath "${MPI_PREFIX}")"
  else
    mpicc_path="$(command -v mpicc 2>/dev/null || true)"
    [[ -n "${mpicc_path}" ]] || die "--use-system-mpi requested but mpicc is not on PATH. Load the site MPI module or pass --mpi-prefix."
    prefix="$(cd "$(dirname "${mpicc_path}")/.." && pwd -P)"
  fi
  [[ -x "${prefix}/bin/mpicc" ]] || die "System MPI prefix does not provide bin/mpicc: ${prefix}"
  [[ -x "${prefix}/bin/mpicxx" ]] || die "System MPI prefix does not provide bin/mpicxx: ${prefix}"
  [[ -x "${prefix}/bin/mpirun" ]] || die "System MPI prefix does not provide bin/mpirun: ${prefix}"
  MPI_PREFIX="${prefix}"
  export MPI_ROOT="${prefix}"
}

setup_environment() {
  if using_system_mpi; then
    resolve_system_mpi_root
  else
    export MPI_ROOT="${INSTALL_ROOT}/openmpi"
  fi
  export FFTW_ROOT="${INSTALL_ROOT}/fftw"
  export BOOST_ROOT="${INSTALL_ROOT}/boost"
  export FMT_ROOT="${INSTALL_ROOT}/fmt"
  export SPDLOG_ROOT="${INSTALL_ROOT}/spdlog"
  export AF_ROOT="${INSTALL_ROOT}/arrayfire"
  export GMX_ROOT="${INSTALL_ROOT}/gromacs"

  unset PKG_CONFIG_LIBDIR 2>/dev/null || true

  if is_cpu_only; then

    CUDA_HOME=""
    CUDA_VERSION="not-used"
    export -n CUDA_HOME 2>/dev/null || true
    unset CUDA_ROOT CUDACXX CUDAHOSTCXX 2>/dev/null || true
  elif [[ -x "${CUDA_HOME}/bin/nvcc" ]]; then
    export CUDACXX="${CUDA_HOME}/bin/nvcc"
  fi

  if is_gromacs_only; then
    unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_PREFIX PLUMED_KERNEL 2>/dev/null || true
    if is_cpu_only; then
      export PATH="${GMX_ROOT}/bin:${PATH}"
      export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
      export PKG_CONFIG_PATH="${GMX_ROOT}/lib/pkgconfig:${GMX_ROOT}/lib64/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
      export CMAKE_PREFIX_PATH="${GMX_ROOT}:${FFTW_ROOT}:${CMAKE_PREFIX_PATH:-}"
    else
      export PATH="${GMX_ROOT}/bin:${CUDA_HOME}/bin:${PATH}"
      export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${FFTW_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"
      export PKG_CONFIG_PATH="${GMX_ROOT}/lib/pkgconfig:${GMX_ROOT}/lib64/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
      export CMAKE_PREFIX_PATH="${GMX_ROOT}:${FFTW_ROOT}:${CUDA_HOME}:${CMAKE_PREFIX_PATH:-}"
    fi
    return 0
  fi

  unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"

  if is_cpu_only; then
    export PATH="${GMX_ROOT}/bin:${PLUMED_ROOT}/bin:${PATH}"
    export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${PLUMED_ROOT}/lib:${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
    export PKG_CONFIG_PATH="${GMX_ROOT}/lib/pkgconfig:${GMX_ROOT}/lib64/pkgconfig:${PLUMED_ROOT}/lib/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CMAKE_PREFIX_PATH="${GMX_ROOT}:${PLUMED_ROOT}:${FFTW_ROOT}:${CMAKE_PREFIX_PATH:-}"
    return 0
  fi

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

mpi_wrapper_matches_compiler() {
  local wrapper="${1}" expected="${2}" expected_real command_line tok tok_real
  expected_real="$(canonical_executable "${expected}" || true)"
  [[ -n "${expected_real}" ]] || return 1
  command_line="$("${wrapper}" --showme:command 2>/dev/null || true)"
  [[ -n "${command_line}" ]] || return 1
  for tok in ${command_line}; do
    tok_real="$(canonical_executable "${tok}" || true)"
    [[ -n "${tok_real}" && "${tok_real}" == "${expected_real}" ]] && return 0
  done
  return 1
}

validate_openmpi_compiler_provenance() {

  local mode="${1:-reuse}" cc_cmd cxx_cmd
  cc_cmd="$("${MPI_ROOT}/bin/mpicc" --showme:command 2>/dev/null || true)"
  cxx_cmd="$("${MPI_ROOT}/bin/mpicxx" --showme:command 2>/dev/null || true)"
  [[ -n "${cc_cmd}" && -n "${cxx_cmd}" ]] || die "MPI compiler wrappers do not report their underlying commands."
  info "MPI mpicc compiler : ${cc_cmd}"
  info "MPI mpicxx compiler: ${cxx_cmd}"

  if [[ "${mode}" == "strict" || -n "${REQUESTED_CC}" ]]; then
    mpi_wrapper_matches_compiler "${MPI_ROOT}/bin/mpicc" "${BUILD_CC}" \
      || die "MPI mpicc does not use the selected C compiler (${BUILD_CC}). Reported command: ${cc_cmd}"
  fi
  if [[ "${mode}" == "strict" || -n "${REQUESTED_CXX}" ]]; then
    mpi_wrapper_matches_compiler "${MPI_ROOT}/bin/mpicxx" "${BUILD_CXX}" \
      || die "MPI mpicxx does not use the selected C++ compiler (${BUILD_CXX}). Reported command: ${cxx_cmd}"
  fi

  if [[ "${mode}" == "strict" || -n "${REQUESTED_CC}${REQUESTED_CXX}" ]]; then
    ok "MPI wrapper compiler provenance matches the requested/selected toolchain."
  else
    ok "Reusing the selected MPI wrapper toolchain (no explicit CC/CXX override requested for this run)."
  fi
}

validate_system_mpi_selection() {
  using_system_mpi || return 0
  section "External/system MPI validation"
  resolve_system_mpi_root
  "${MPI_ROOT}/bin/mpicc" --showme >/dev/null 2>&1 \
    || die "Selected system MPI mpicc wrapper is not functional: ${MPI_ROOT}/bin/mpicc"
  "${MPI_ROOT}/bin/mpicxx" --showme >/dev/null 2>&1 \
    || die "Selected system MPI mpicxx wrapper is not functional: ${MPI_ROOT}/bin/mpicxx"
  "${MPI_ROOT}/bin/mpirun" --version >/dev/null 2>&1 \
    || die "Selected system MPI launcher is not functional: ${MPI_ROOT}/bin/mpirun"
  validate_openmpi_compiler_provenance reuse
  ok "Using external/system MPI at ${MPI_ROOT}; no private OpenMPI will be built."
}

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
  if [[ -n "${BUILD_FC}" ]]; then
    env CC="${BUILD_CC}" CXX="${BUILD_CXX}" FC="${BUILD_FC}" \
      ./configure --prefix="${MPI_ROOT}" --with-cuda="${CUDA_HOME}"
  else
    env CC="${BUILD_CC}" CXX="${BUILD_CXX}" \
      ./configure --prefix="${MPI_ROOT}" --with-cuda="${CUDA_HOME}"
  fi
  make -j"${NPROC}"
  make install
  "${MPI_ROOT}/bin/mpicc" --showme >/dev/null
  "${MPI_ROOT}/bin/mpicxx" --showme >/dev/null
  validate_openmpi_compiler_provenance strict
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
  CC="${BUILD_CC}" ../configure --prefix="${FFTW_ROOT}" --enable-float --enable-shared \
    --enable-sse2 --enable-avx --enable-avx2 --enable-avx512 \
    CFLAGS="-O3 -march=${MARCH}"
  make -j"${NPROC}"
  make install
  cd ..

  mkdir -p build-double && cd build-double
  CC="${BUILD_CC}" ../configure --prefix="${FFTW_ROOT}" --enable-shared \
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
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_extract_git fmt "fmt-${FMT_VERSION}" "${SRC}/fmt-${FMT_VERSION}"
  else
    git clone --branch "${FMT_VERSION}" --depth 1 \
      https://github.com/fmtlib/fmt.git "fmt-${FMT_VERSION}"
  fi
  cd "fmt-${FMT_VERSION}"
rm -rf build_cuda && mkdir -p build_cuda && cd build_cuda
  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${FMT_ROOT}" \
    -DCMAKE_C_COMPILER="${BUILD_CC}" \
    -DCMAKE_CXX_COMPILER="${BUILD_CXX}" \
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
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_extract_git spdlog "spdlog-${SPDLOG_VERSION}" "${SRC}/spdlog-${SPDLOG_VERSION}"
  else
    git clone --branch "v${SPDLOG_VERSION}" --depth 1 \
      https://github.com/gabime/spdlog.git "spdlog-${SPDLOG_VERSION}"
  fi
  cd "spdlog-${SPDLOG_VERSION}"
  rm -rf build_cuda && mkdir -p build_cuda && cd build_cuda
  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${SPDLOG_ROOT}" \
    -DCMAKE_C_COMPILER="${BUILD_CC}" \
    -DCMAKE_CXX_COMPILER="${BUILD_CXX}" \
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

patch_arrayfire_offline_fetchcontent() {
  local af_deps_cmake="${1}/CMakeModules/AFconfigure_deps_vars.cmake"
  [[ -f "${af_deps_cmake}" ]] || die "ArrayFire dependency helper missing: ${af_deps_cmake}"
  python3 - "${af_deps_cmake}" <<'PYEOF_AF_OFFLINE'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "AF_LOCAL_OFFLINE_SOURCE"
if marker in text:
    raise SystemExit(0)

start_token = "macro(af_dep_check_and_populate dep_prefix)"
start = text.find(start_token)
if start < 0:
    raise SystemExit("Could not find af_dep_check_and_populate()")
end = text.find("endmacro()", start)
if end < 0:
    raise SystemExit("Could not find endmacro() for af_dep_check_and_populate()")
end += len("endmacro()")
original = text[start:end]
first_newline = original.find("\n")
if first_newline < 0:
    raise SystemExit("Malformed af_dep_check_and_populate() macro")
macro_header = original[:first_newline + 1]
macro_body = original[first_newline + 1:]
if not macro_body.rstrip().endswith("endmacro()"):
    raise SystemExit("Unexpected macro structure")
body_without_end = macro_body.rstrip()[:-len("endmacro()")].rstrip() + "\n"
guarded = macro_header + '''\
  set(AF_LOCAL_OFFLINE_SOURCE
      "${ArrayFire_SOURCE_DIR}/extern/${dep_prefix}-src")
  if(IS_DIRECTORY "${AF_LOCAL_OFFLINE_SOURCE}")
    message(STATUS
      "Using pre-populated offline source for ${dep_prefix}: ${AF_LOCAL_OFFLINE_SOURCE}")
    set(${dep_prefix}_SOURCE_DIR "${AF_LOCAL_OFFLINE_SOURCE}")
    set(${dep_prefix}_BINARY_DIR
        "${ArrayFire_BINARY_DIR}/extern/${dep_prefix}-build")
    set(${dep_prefix}_POPULATED TRUE)
  else()
''' + body_without_end + '''\
  endif()
  unset(AF_LOCAL_OFFLINE_SOURCE)
endmacro()'''
text = text[:start] + guarded + text[end:]
path.write_text(text)
PYEOF_AF_OFFLINE
  grep -q 'AF_LOCAL_OFFLINE_SOURCE' "${af_deps_cmake}" \
    || die "ArrayFire offline FetchContent patch was not applied."
  ok "ArrayFire offline dependency population patched to reuse pre-populated extern sources."
}

stage_arrayfire() {
  section "ArrayFire ${ARRAYFIRE_VERSION} (CUDA backend, arch=${CUDA_ARCHS})"
  cd "${SRC}"
  rm -rf "arrayfire-${ARRAYFIRE_VERSION}"
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_extract_git arrayfire "arrayfire-${ARRAYFIRE_VERSION}" "${SRC}/arrayfire-${ARRAYFIRE_VERSION}"
  else
    git clone --recursive --branch "v${ARRAYFIRE_VERSION}" \
      https://github.com/arrayfire/arrayfire.git "arrayfire-${ARRAYFIRE_VERSION}"
  fi
  cd "arrayfire-${ARRAYFIRE_VERSION}"
  if [[ "${OFFLINE}" -eq 0 ]]; then git submodule update --init --recursive; fi

  if [[ "${OFFLINE}" -eq 1 ]]; then
    validate_arrayfire_full_tree "${SRC}/arrayfire-${ARRAYFIRE_VERSION}"
    patch_arrayfire_offline_fetchcontent "${SRC}/arrayfire-${ARRAYFIRE_VERSION}"
  fi

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
    lines = text.splitlines(True)
    insert_at = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#include'):
            insert_at = i + 1
    lines.insert(insert_at, '\n' + macro + '\n')
    text = ''.join(lines)

text = re.sub(r'(?<![A-Za-z0-9_])(?:std::|::)?isnan\s*\(', 'AF_CUDA_MATH_ISNAN(', text)

text = text.replace('#    define AF_CUDA_MATH_ISNAN(x) AF_CUDA_MATH_ISNAN(x)', '#    define AF_CUDA_MATH_ISNAN(x) isnan(x)')
text = text.replace('#    define AF_CUDA_MATH_ISNAN(x) std::AF_CUDA_MATH_ISNAN(x)', '#    define AF_CUDA_MATH_ISNAN(x) std::isnan(x)')

path.write_text(text)
PYEOF
    fi
  fi

  local af_thrust_utils="src/backend/cuda/thrust_utils.hpp"
  if [[ -f "${af_thrust_utils}" ]]; then
    if grep -q 'thrust/system/cuda/detail/par.h' "${af_thrust_utils}"; then
      info "Patching ArrayFire thrust_utils.hpp for CUDA 13/CCCL Thrust header layout."
      sed -i 's#<thrust/system/cuda/detail/par.h>#<thrust/system/cuda/execution_policy.h>#' "${af_thrust_utils}"
    fi
  fi

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

  local af_thrust_policy="src/backend/cuda/ThrustArrayFirePolicy.hpp"
  if [[ -f "${af_thrust_policy}" ]]; then
    if grep -q 'thrust::pair' "${af_thrust_policy}" \
       && ! grep -q '#include <thrust/pair.h>' "${af_thrust_policy}"; then
      info "Patching ArrayFire ThrustArrayFirePolicy.hpp to include <thrust/pair.h> for CUDA 13/CCCL."
      sed -i '/#include <thrust\/memory.h>/a #include <thrust/pair.h>' "${af_thrust_policy}"
    fi
  fi

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
  local offline_af_args=()
  if [[ "${OFFLINE}" -eq 1 ]]; then
    offline_af_args+=("-DAF_BUILD_EXAMPLES=OFF" "-DBUILD_TESTING=OFF")
  fi
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
    -DCMAKE_C_COMPILER="${BUILD_CC}" \
    -DCMAKE_CXX_COMPILER="${BUILD_CXX}" \
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
    "${offline_af_args[@]}" \
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

ensure_python_build_module() {
  if command -v python3 >/dev/null 2>&1 \
     && python3 - <<'PYEOF' >/dev/null 2>&1
import build.__main__
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
import build.__main__
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

    local cmd="$1"
    rm -rf "${pybuild_target}"
    mkdir -p "${pybuild_target}"

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

  local pybuild_env="${INSTALL_ROOT}/pybuild"
  rm -rf "${pybuild_env}"
  if python3 -m venv "${pybuild_env}" >/dev/null 2>&1; then
    "${pybuild_env}/bin/python" -m pip install --upgrade pip setuptools wheel build \
      || die "Could not install Python build tooling into ${pybuild_env}."
    "${pybuild_env}/bin/python" - <<'PYEOF'
import build.__main__
PYEOF
    export PATH="${pybuild_env}/bin:${PATH}"
    ok "Using private Python build environment: ${pybuild_env}"
    return 0
  fi

  die "Could not provide the Python 'build' module without root privileges. Manual fallback: install a user Python with pip, then rerun from the plumed stage."
}

saxs_update_python_can_build() {
  local py="${1}"
  "${py}" - <<'PYEOF' >/dev/null 2>&1
import build.__main__
PYEOF
  "${py}" -m build --version >/dev/null 2>&1
}

saxs_update_python_details() {

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

  "${resolved}" - <<'PYEOF' >/dev/null 2>&1 || die "Python headers are missing for retained PLUMED python_bin: ${resolved}. Provide the matching Python development headers/environment; retained Python support will not be disabled automatically."
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

plumed_patch_canonical_dir() {
  printf '%s\n' "${INSTALL_ROOT}/plumed_patch_bundle/current"
}

prepare_plumed_patch_bundle_input() {
  local input="${1}" tmp_root="" resolved=""
  input="$(abspath "${input}")"
  if [[ -d "${input}" ]]; then
    if [[ -f "${input}/PATCHFILES.sha256" && -d "${input}/plumed2" ]]; then
      resolved="${input}"
    else
      resolved="$(python3 - "${input}" <<'PYD'
import os,sys
root=os.path.abspath(sys.argv[1]); found=[]
for base,dirs,files in os.walk(root):
    depth=os.path.relpath(base,root).count(os.sep)
    if depth>1:
        dirs[:]=[]
        continue
    if 'PATCHFILES.sha256' in files and os.path.isdir(os.path.join(base,'plumed2')):
        found.append(base)
if len(found)!=1:
    raise SystemExit(f'expected exactly one patch root, found {len(found)}')
print(found[0])
PYD
)" || die "Patch directory must contain exactly one PATCHFILES.sha256 + plumed2 payload root: ${input}"
    fi
  elif [[ -f "${input}" ]]; then
    tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/plumed-patch.XXXXXX")"
    resolved="$(python3 - "${input}" "${tmp_root}" <<'PYI'
import os,sys,tarfile
archive,out=sys.argv[1:]
with tarfile.open(archive,'r:*') as t:
    for m in t.getmembers():
        n=m.name.replace('\\','/')
        if n.startswith('/') or any(x=='..' for x in n.split('/')):
            raise SystemExit('unsafe archive path: '+m.name)
        if m.issym() or m.islnk() or not (m.isfile() or m.isdir()):
            raise SystemExit('unsupported archive member: '+m.name)
    try:
        t.extractall(out,filter='fully_trusted')
    except TypeError:
        t.extractall(out)
roots=[]
for root,dirs,files in os.walk(out):
    if 'PATCHFILES.sha256' in files and os.path.isdir(os.path.join(root,'plumed2')):
        roots.append(root)
if len(roots)!=1:
    raise SystemExit(f'expected exactly one patch root, found {len(roots)}')
print(roots[0])
PYI
)" || { rm -rf -- "${tmp_root}"; die "Could not safely extract PLUMED patch bundle: ${input}"; }
  else
    die "PLUMED patch bundle not found: ${input}"
  fi
  validate_plumed_patch_bundle_root "${resolved}"
  PLUMED_PATCH_PREPARED_ROOT="${resolved}"
  PLUMED_PATCH_PREPARED_TMP="${tmp_root}"
}

validate_plumed_patch_bundle_root() {
  local root="${1}" result
  result="$(python3 - "${root}" <<'PYV'
import hashlib,os,re,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
manifest=root/'PATCHFILES.sha256'
payload=root/'plumed2'
if not manifest.is_file() or not payload.is_dir(): raise SystemExit('missing PATCHFILES.sha256 or plumed2')
entries=[]; seen=set()
for i,line in enumerate(manifest.read_text().splitlines(),1):
    m=re.fullmatch(r'([0-9a-fA-F]{64})  (plumed2/.+)',line)
    if not m: raise SystemExit(f'malformed manifest line {i}')
    h=m.group(1).lower(); rel=m.group(2).replace('\\','/')
    parts=rel.split('/')
    if rel.startswith('/') or any(x in ('','.','..') for x in parts): raise SystemExit(f'unsafe manifest path: {rel}')
    if any(c.isspace() for c in rel): raise SystemExit(f'whitespace not allowed in manifest path: {rel}')
    target=parts[1:]
    if '.git' in target: raise SystemExit(f'git metadata path not allowed: {rel}')
    if target and target[0].startswith('-'): raise SystemExit(f'unsafe target path: {rel}')
    if rel in seen: raise SystemExit(f'duplicate manifest path: {rel}')
    seen.add(rel); entries.append((h,rel))
actual=[]
for base,dirs,files in os.walk(payload,followlinks=False):
    for d in dirs:
        p=Path(base)/d
        if p.is_symlink(): raise SystemExit(f'symlink not allowed: {p.relative_to(root)}')
    for f in files:
        p=Path(base)/f
        if p.is_symlink() or not p.is_file(): raise SystemExit(f'non-regular payload: {p.relative_to(root)}')
        actual.append(p.relative_to(root).as_posix())
if set(actual)!=seen:
    missing=sorted(seen-set(actual)); extra=sorted(set(actual)-seen)
    raise SystemExit('payload/manifest mismatch; missing='+','.join(missing)+' extra='+','.join(extra))
for h,rel in entries:
    p=root/rel
    got=hashlib.sha256(p.read_bytes()).hexdigest()
    if got!=h: raise SystemExit(f'hash mismatch: {rel}')
manifest_hash=hashlib.sha256(manifest.read_bytes()).hexdigest()
print(f'{len(entries)} {manifest_hash}')
PYV
)" || die "PLUMED patch bundle validation failed: ${root}"
  PLUMED_PATCH_FILE_COUNT="${result%% *}"
  PLUMED_PATCH_VALIDATED_MANIFEST_SHA256="${result#* }"
  [[ "${PLUMED_PATCH_FILE_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "PLUMED patch manifest is empty."
}


cleanup_prepared_plumed_patch_bundle() {
  [[ -z "${PLUMED_PATCH_PREPARED_TMP:-}" ]] || rm -rf -- "${PLUMED_PATCH_PREPARED_TMP}"
  PLUMED_PATCH_PREPARED_TMP=""
}

copy_plumed_patch_bundle_atomic() {
  local source_root="${1}" canonical tmp
  canonical="$(plumed_patch_canonical_dir)"
  tmp="${canonical}.tmp.$$"
  rm -rf -- "${tmp}"
  mkdir -p "${tmp}/plumed2"
  cp -p -- "${source_root}/PATCHFILES.sha256" "${tmp}/PATCHFILES.sha256"
  cp -a -- "${source_root}/plumed2/." "${tmp}/plumed2/"
  validate_plumed_patch_bundle_root "${tmp}"
  rm -rf -- "${canonical}.previous.$$"
  if [[ -e "${canonical}" ]]; then mv -- "${canonical}" "${canonical}.previous.$$"; fi
  if mv -- "${tmp}" "${canonical}"; then
    rm -rf -- "${canonical}.previous.$$"
  else
    rm -rf -- "${tmp}"
    [[ ! -e "${canonical}.previous.$$" ]] || mv -- "${canonical}.previous.$$" "${canonical}"
    die "Could not activate canonical PLUMED patch bundle."
  fi
  validate_plumed_patch_bundle_root "${canonical}"
  LAST_PLUMED_PATCH_BUNDLE="${canonical}"
  LAST_PLUMED_PATCH_MANIFEST_SHA256="${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}"
}

plumed_patch_target_list() {
  local root="${1}"
  awk '{p=$2; sub(/^plumed2\//,"",p); print p}' "${root}/PATCHFILES.sha256"
}

apply_plumed_patch_bundle_root_to_tree() {
  local root="${1}" plumed_src="${2}" result
  validate_plumed_patch_bundle_root "${root}"
  result="$(python3 - "${root}" "${plumed_src}" <<'PYA'
import hashlib,os,shutil,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve(); tree=Path(sys.argv[2]).resolve()
if not tree.is_dir(): raise SystemExit('PLUMED source tree missing')
entries=[]
for line in (root/'PATCHFILES.sha256').read_text().splitlines():
    h,rel=line.split('  ',1); entries.append((h.lower(),rel))
for h,rel in entries:
    target_rel=Path(rel[len('plumed2/'):])
    cur=tree
    for part in target_rel.parts[:-1]:
        cur=cur/part
        if cur.exists() and cur.is_symlink(): raise SystemExit(f'symlinked destination parent: {target_rel}')
    dst=tree/target_rel
    dst.parent.mkdir(parents=True,exist_ok=True)
    if dst.exists() and (dst.is_symlink() or not dst.is_file()): raise SystemExit(f'unsafe destination: {target_rel}')
    src=root/rel
    shutil.copy2(src,dst)
    os.utime(dst,None)
    got=hashlib.sha256(dst.read_bytes()).hexdigest()
    if got!=h: raise SystemExit(f'destination hash mismatch: {target_rel}')
print(len(entries))
PYA
)" || die "Could not apply PLUMED patch payload safely."
  [[ "${result}" == "${PLUMED_PATCH_FILE_COUNT}" ]] || die "PLUMED patch application count mismatch."
  ok "PLUMED patch payload applied and verified (${result} files, manifest ${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256})."
}


plumed_patch_tree_matches() {
  local root="${1}" plumed_src="${2}" expected rel dst
  while read -r expected rel; do
    [[ -n "${expected}" && -n "${rel}" ]] || continue
    rel="${rel#plumed2/}"
    dst="${plumed_src}/${rel}"
    [[ -f "${dst}" && "$(sha256_file "${dst}")" == "${expected}" ]] || return 1
  done < "${root}/PATCHFILES.sha256"
  return 0
}

persist_and_apply_plumed_patch_bundle() {
  local input="${1}" plumed_src="${2}" canonical
  prepare_plumed_patch_bundle_input "${input}"
  copy_plumed_patch_bundle_atomic "${PLUMED_PATCH_PREPARED_ROOT}"
  cleanup_prepared_plumed_patch_bundle
  canonical="$(plumed_patch_canonical_dir)"
  apply_plumed_patch_bundle_root_to_tree "${canonical}" "${plumed_src}"
  if [[ -f "${canonical}/plumed2/src/isdb/SAXS.cpp" ]]; then
    LAST_SAXS_CANDIDATE="${canonical}/plumed2/src/isdb/SAXS.cpp"
  fi
}

resolve_plumed_patch_dir() {
  if [[ "${PLUMED_PATCH_DIR}" == "auto" || -z "${PLUMED_PATCH_DIR}" ]]; then

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
  local plumed_src="${1}"
  local patch_dir candidate target backup_dir canonical timestamp
  if [[ -n "${PLUMED_PATCH_BUNDLE}" ]]; then
    persist_and_apply_plumed_patch_bundle "${PLUMED_PATCH_BUNDLE}" "${plumed_src}"
    return 0
  fi

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

    canonical="${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
    mkdir -p "$(dirname "${canonical}")"
    if [[ "$(abspath "${candidate}")" != "$(abspath "${canonical}")" ]]; then
      [[ ! -f "${canonical}" ]] || cp -- "${canonical}" "${backup_dir}/SAXS.cpp.previous-canonical"
      cp -- "${candidate}" "${canonical}"
    fi
    candidate="${canonical}"
    cp -- "${candidate}" "${target}"
    local candidate_hash target_hash
    candidate_hash="$(sha256_file "${candidate}")"
    target_hash="$(sha256_file "${target}")"
    [[ -n "${candidate_hash}" && "${candidate_hash}" == "${target_hash}" ]] \
      || die "Fresh-build SAXS.cpp hash mismatch after applying override: candidate=${candidate_hash:-missing}, target=${target_hash:-missing}"
    LAST_SAXS_CANDIDATE="${candidate}"
    ok "Fresh-build SAXS.cpp override hash verified: ${candidate_hash}"
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

stage_plumed_cpu() {
  section "PLUMED (CPU-only + FFTW, no MPI/ArrayFire/CUDA, ref=${PLUMED_REF})"
  unset PLUMED_PREFIX PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"
  mkdir -p "${PLUMED_ROOT}"

  local cc cxx
  cc="${CC:-$(command -v gcc)}"
  cxx="${CXX:-$(command -v g++)}"
  [[ -x "${cc}" ]] || die "C compiler not runnable: ${cc}"
  [[ -x "${cxx}" ]] || die "C++ compiler not runnable: ${cxx}"

  export LD_LIBRARY_PATH="${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
  unset PKG_CONFIG_LIBDIR 2>/dev/null || true
  export PKG_CONFIG_PATH="${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  local plumed_python_config=()
  if [[ "${PLUMED_DISABLE_PYTHON}" == "1" ]]; then
    plumed_python_config=(--disable-python)
  else
    ensure_python_build_module
  fi

  local plumed_src="${SRC}/plumed2"
  cd "${SRC}"
  rm -rf "${plumed_src}"
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_extract_git plumed "plumed2" "${plumed_src}"
  else
    git clone --recursive "${PLUMED_REPO}" "${plumed_src}"
  fi
  cd "${plumed_src}"
  if [[ "${OFFLINE}" -eq 0 && "${PLUMED_REF}" != "master" ]]; then
    git checkout "${PLUMED_REF}"
    git submodule update --init --recursive
  fi
  info "PLUMED commit: $(git rev-parse HEAD)"
  make distclean 2>/dev/null || true

  info "CPU PLUMED profile: local/custom SAXS.cpp overrides are intentionally disabled; using upstream PLUMED sources."

  local plumed_cppflags="-I${FFTW_ROOT}/include"
  local plumed_ldflags="-L${FFTW_ROOT}/lib -Wl,-rpath,${FFTW_ROOT}/lib"
  local configure_log="${plumed_src}/configure_plumed_cpu.log"

  ./configure \
    --prefix="${PLUMED_ROOT}" \
    CC="${cc}" \
    CXX="${cxx}" \
    CFLAGS="-O3 -Wno-error" \
    CXXFLAGS="-O3 -Wno-error" \
    --enable-modules=all \
    --disable-basic-warnings \
    --enable-asmjit \
    --enable-fftw \
    --disable-mpi \
    --disable-af_cuda \
    --disable-af_cpu \
    --disable-af_ocl \
    "${plumed_python_config[@]}" \
    --verbose \
    CPPFLAGS="${plumed_cppflags}" \
    LDFLAGS="${plumed_ldflags}" \
    2>&1 | tee "${configure_log}"

  info "Requested CPU PLUMED features after configure:"
  grep -E "has arrayfire|has arrayfire_cuda|has fftw|has mpi|module isdb|__PLUMED_HAS_ARRAYFIRE|__PLUMED_HAS_MPI" \
    src/config/config.txt src/config/config.h "${configure_log}" 2>/dev/null || true

  if grep -R -Eq '(^|[[:space:]])#define[[:space:]]+__PLUMED_HAS_ARRAYFIRE|has arrayfire(_cuda)?[[:space:]]+(on|yes)' \
       src/config "${configure_log}" config.log 2>/dev/null; then
    die "CPU PLUMED unexpectedly enabled ArrayFire; refusing a non-lightweight build."
  fi
  if grep -R -Eq '(^|[[:space:]])#define[[:space:]]+__PLUMED_HAS_MPI|has mpi[[:space:]]+(on|yes)' \
       src/config "${configure_log}" config.log 2>/dev/null; then
    die "CPU PLUMED unexpectedly enabled external MPI; refusing the login-node profile."
  fi
  grep -Eq 'module isdb[[:space:]]+on' src/config/config.txt \
    || die "CPU PLUMED configuration does not report the ISDB module enabled."

  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make -j"${NPROC}"
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make install
  [[ -x "${PLUMED_ROOT}/bin/plumed" ]] || die "CPU PLUMED executable not found after install."
  [[ -f "${PLUMED_KERNEL}" ]] || die "CPU PLUMED kernel not found after install: ${PLUMED_KERNEL}"
  ok "CPU-only PLUMED installed at ${PLUMED_ROOT}"
  mark_stage_done plumed
}

configure_plumed_cuda_tree() {

  local plumed_src="${1}"
  [[ -d "${plumed_src}" ]] || die "PLUMED source directory not found: ${plumed_src}"

  unset PLUMED_PREFIX PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"
  mkdir -p "${PLUMED_ROOT}" "${LOG_DIR}/plumed_probes"
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

  local af_libdir="${AF_ROOT}/lib"
  [[ -d "${af_libdir}" ]] || af_libdir="${AF_ROOT}/lib64"
  [[ -d "${af_libdir}" ]] || die "ArrayFire library directory not found under ${AF_ROOT}"
  [[ -f "${af_libdir}/libafcuda.so" ]] || die "ArrayFire CUDA library not found: ${af_libdir}/libafcuda.so"

  local plumed_probe_dir="${LOG_DIR}/plumed_probes"
  local af_probe_src="${plumed_probe_dir}/arrayfire_link_probe.cpp"
  local af_probe_bin="${plumed_probe_dir}/arrayfire_link_probe.exe"
  cat > "${af_probe_src}" <<'EOF_AF_LINK_PROBE'
#include <arrayfire.h>
int main() {
    (void)&af_is_double;
    return 0;
}
EOF_AF_LINK_PROBE

  local plumed_cppflags="-I${AF_ROOT}/include -I${FFTW_ROOT}/include -I${CUDA_HOME}/include -I${CUDA_HOME}/targets/x86_64-linux/include"
  local plumed_ldflags="-L${af_libdir} -Wl,-rpath,${af_libdir} -L${FFTW_ROOT}/lib -Wl,-rpath,${FFTW_ROOT}/lib -L${FMT_ROOT}/lib -Wl,-rpath,${FMT_ROOT}/lib -L${FMT_ROOT}/lib64 -Wl,-rpath,${FMT_ROOT}/lib64 -L${MPI_ROOT}/lib -Wl,-rpath,${MPI_ROOT}/lib -L${CUDA_HOME}/lib64 -Wl,-rpath,${CUDA_HOME}/lib64 -L${CUDA_HOME}/targets/x86_64-linux/lib -Wl,-rpath,${CUDA_HOME}/targets/x86_64-linux/lib"
  local arrayfire_libs="" candidate_libs
  local af_link_log="${plumed_probe_dir}/arrayfire_link_probe.log"
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
    die "Cannot link a test program against ArrayFire; refusing to configure PLUMED without ArrayFire support."
  fi
  ok "PLUMED ArrayFire link probe passed with LIBS='${arrayfire_libs}'."

  export LIBRARY_PATH="${af_libdir}:${FFTW_ROOT}/lib:${FMT_ROOT}/lib:${FMT_ROOT}/lib64:${MPI_ROOT}/lib:${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib:${LIBRARY_PATH:-}"
  local plumed_configure_log="${plumed_probe_dir}/configure_plumed_arrayfire.log"

  cd "${plumed_src}"
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
  [[ "${plumed_af_ok}" -eq 1 ]] || die "PLUMED configured without __PLUMED_HAS_ARRAYFIRE; stopping instead of using a useless SAXS build."
  [[ "${plumed_af_cuda_ok}" -eq 1 ]] || die "PLUMED configured without __PLUMED_HAS_ARRAYFIRE_CUDA; stopping instead of using a useless SAXS build."
  ok "PLUMED configure enabled ArrayFire and ArrayFire-CUDA."
}

stage_plumed() {
  if is_cpu_only; then
    stage_plumed_cpu
    return 0
  fi
  section "PLUMED (FFTW + ArrayFire CUDA + ISDB/SAXS, ref=${PLUMED_REF})"
  unset PLUMED_PREFIX PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_KERNEL 2>/dev/null || true
  PLUMED_ROOT="${INSTALL_ROOT}/plumed"
  PLUMED_INSTALL_PREFIX="${PLUMED_ROOT}"
  PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so"
  mkdir -p "${PLUMED_ROOT}" "${SRC}"

  local plumed_src="${SRC}/plumed2"
  cd "${SRC}"
  rm -rf "${plumed_src}"
  if [[ "${OFFLINE}" -eq 1 ]]; then
    source_cache_extract_git plumed "plumed2" "${plumed_src}"
  else
    git clone --recursive "${PLUMED_REPO}" "${plumed_src}"
  fi
  cd "${plumed_src}"
  if [[ "${OFFLINE}" -eq 0 && "${PLUMED_REF}" != "master" ]]; then
    git checkout "${PLUMED_REF}"
    git submodule update --init --recursive
  fi
  info "PLUMED commit: $(git rev-parse HEAD)"
  make distclean 2>/dev/null || true
  apply_plumed_local_patches "${plumed_src}"
  configure_plumed_cuda_tree "${plumed_src}"

  cd "${plumed_src}"

  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make -j"${NPROC}"
  if [[ -f "$(plumed_patch_canonical_dir)/PATCHFILES.sha256" ]]; then
    plumed_patch_tree_matches "$(plumed_patch_canonical_dir)" "${plumed_src}" || die "PLUMED patch targets changed during the build."
  fi
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make install
  ok "PLUMED installed at ${PLUMED_ROOT}"
  mark_stage_done plumed
}

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
    "${GMX_ROOT:-}/bin/gmx" \
    "${GMX_ROOT:-}/lib/libgromacs_mpi.so" \
    "${GMX_ROOT:-}/lib64/libgromacs_mpi.so" \
    "${GMX_ROOT:-}/lib/libgromacs.so" \
    "${GMX_ROOT:-}/lib64/libgromacs.so"; do
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

  local component="${1}" value=""
  case "${component}" in
    cuda)
      if is_cpu_only; then value="not-used"; else value="$("${CUDA_HOME}/bin/nvcc" --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | head -n1 || true)"; fi
      ;;
    openmpi)
      if is_cpu_only || is_gromacs_only; then value="not-built"; else value="$("${MPI_ROOT}/bin/mpirun" --version 2>/dev/null | head -n1 || true)"; fi
      ;;
    fftw)
      value="$(readlink -f "${FFTW_ROOT}/lib/libfftw3.so" 2>/dev/null | xargs -r basename || true)"
      ;;
    boost)
      if is_cpu_only || is_gromacs_only; then value="not-built"; else value="$(awk '/^#define BOOST_LIB_VERSION /{gsub(/\"/,"",$3); print $3; exit}' "${BOOST_ROOT}/include/boost/version.hpp" 2>/dev/null || true)"; fi
      ;;
    fmt)
      if is_cpu_only || is_gromacs_only; then value="not-built"; else value="$(awk '/^#define FMT_VERSION /{print $3; exit}' "${FMT_ROOT}/include/fmt/base.h" 2>/dev/null || true)"; fi
      ;;
    spdlog)
      if is_cpu_only || is_gromacs_only; then value="not-built"; else value="$(awk '/^#define SPDLOG_VER_(MAJOR|MINOR|PATCH) /{v[++n]=$3} END{if(n==3) print v[1]"."v[2]"."v[3]}' "${SPDLOG_ROOT}/include/spdlog/version.h" 2>/dev/null || true)"; fi
      ;;
    arrayfire)
      if is_cpu_only || is_gromacs_only; then
        value="not-built"
      else
        [[ ! -f "${AF_ROOT}/etc/arrayfire_version.txt" ]] \
          || value="$(head -n1 "${AF_ROOT}/etc/arrayfire_version.txt" 2>/dev/null || true)"
      fi
      ;;
    plumed)
      if ! is_full_stack || [[ -z "${PLUMED_ROOT:-}" || ! -x "${PLUMED_ROOT}/bin/plumed" ]]; then
        value="not-built"
      else
        value="$("${PLUMED_ROOT}/bin/plumed" --no-mpi info --long-version 2>/dev/null | head -n1 || true)"
      fi
      ;;
    gromacs)
      local gmx_bin="${GMX_ROOT}/bin/gmx_mpi" gmx_out=""
      [[ -x "${gmx_bin}" ]] || gmx_bin="${GMX_ROOT}/bin/gmx"
      if [[ -x "${gmx_bin}" ]]; then
        if is_full_stack && ! is_cpu_only; then
          gmx_out="$(mpi_run_one "${gmx_bin}" --version 2>/dev/null || true)"
        else
          gmx_out="$("${gmx_bin}" --version 2>/dev/null || true)"
        fi
        value="$(printf '%s\n' "${gmx_out}" | awk -F: '/GROMACS version/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' || true)"
      fi
      ;;
  esac
  printf '%s' "${value:-unknown}" | single_line
}

write_installation_reports() {

  local action="${1}" report manifest report_tmp manifest_tmp timestamp host
  local has_plumed=0 plumed_prefix="" plumed_src="" commit saxs_hash kernel_hash candidate_hash linkage
  local cuda_v mpi_v fftw_v boost_v fmt_v spdlog_v af_v plumed_v gmx_v
  local plumed_dirty plumed_diff_hash plumed_untracked mpi_cc_cmd mpi_cxx_cmd cc_v cxx_v
  local plumed_config_path="" saxs_source_path="" kernel_path=""
  local patch_bundle_dir="" patch_manifest_hash="" patch_file_count=""
  local report_source_mode="online" report_source_cache="" report_mpi_provider="${MPI_PROVIDER}"

  report="${INSTALL_ROOT}/installation-info.txt"
  manifest="${INSTALL_ROOT}/installation-manifest.json"
  report_tmp="${report}.tmp.$$"
  manifest_tmp="${manifest}.tmp.$$"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  host="$(hostname 2>/dev/null || printf unknown)"
  if is_full_stack && [[ -n "${PLUMED_ROOT:-}" ]]; then
    has_plumed=1
    plumed_prefix="${PLUMED_ROOT}"
    plumed_src="${SRC}/plumed2"
    commit="$(git -C "${plumed_src}" rev-parse HEAD 2>/dev/null || true)"
    saxs_hash="$(sha256_file "${plumed_src}/src/isdb/SAXS.cpp" 2>/dev/null || true)"
    kernel_hash="$(sha256_file "${plumed_prefix}/lib/libplumedKernel.so" 2>/dev/null || true)"
    candidate_hash="$(sha256_file "${INSTALL_ROOT}/plumed_patch/SAXS.cpp" 2>/dev/null || true)"
    patch_bundle_dir="${INSTALL_ROOT}/plumed_patch_bundle/current"
    if [[ -f "${patch_bundle_dir}/PATCHFILES.sha256" && -d "${patch_bundle_dir}/plumed2" ]]; then
      validate_plumed_patch_bundle_root "${patch_bundle_dir}"
      patch_manifest_hash="${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}"
      patch_file_count="${PLUMED_PATCH_FILE_COUNT}"
      candidate_hash="$(sha256_file "${patch_bundle_dir}/plumed2/src/isdb/SAXS.cpp" 2>/dev/null || true)"
    fi
    plumed_config_path="${plumed_src}/src/config/config.txt"
    saxs_source_path="${plumed_src}/src/isdb/SAXS.cpp"
    kernel_path="${plumed_prefix}/lib/libplumedKernel.so"
    linkage="$(detect_gromacs_plumed_linkage)"

    if [[ -z "${commit}" && -s "${INSTALL_ROOT}/.installer_plumed_commit" ]]; then
      commit="$(head -n1 "${INSTALL_ROOT}/.installer_plumed_commit" 2>/dev/null || true)"
    fi
    if [[ -z "${saxs_hash}" && -s "${INSTALL_ROOT}/.installer_saxs_sha256" ]]; then
      saxs_hash="$(head -n1 "${INSTALL_ROOT}/.installer_saxs_sha256" 2>/dev/null || true)"
    fi
    if [[ ! -f "${plumed_config_path}" && -f "${plumed_prefix}/lib/plumed/src/config/config.txt" ]]; then
      plumed_config_path="${plumed_prefix}/lib/plumed/src/config/config.txt"
    fi
    if [[ ! -f "${saxs_source_path}" && -f "${patch_bundle_dir}/plumed2/src/isdb/SAXS.cpp" ]]; then
      saxs_source_path="${patch_bundle_dir}/plumed2/src/isdb/SAXS.cpp"
    elif [[ ! -f "${saxs_source_path}" && -f "${INSTALL_ROOT}/saxs_updates/current/SAXS.cpp" ]]; then
      saxs_source_path="${INSTALL_ROOT}/saxs_updates/current/SAXS.cpp"
    elif [[ ! -f "${saxs_source_path}" && -f "${INSTALL_ROOT}/plumed_patch/SAXS.cpp" ]]; then
      saxs_source_path="${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
    fi
  else
    commit=""; saxs_hash=""; kernel_hash=""; candidate_hash=""; linkage="none"
  fi
  if [[ -s "${INSTALL_ROOT}/.installer_source_mode" ]]; then
    report_source_mode="$(head -n1 "${INSTALL_ROOT}/.installer_source_mode" 2>/dev/null || printf online)"
  elif [[ "${OFFLINE}" -eq 1 ]]; then
    report_source_mode="offline"
  fi
  if [[ -s "${INSTALL_ROOT}/.installer_source_cache" ]]; then
    report_source_cache="$(head -n1 "${INSTALL_ROOT}/.installer_source_cache" 2>/dev/null || true)"
  else
    report_source_cache="${SOURCE_CACHE:-}"
  fi
  if is_cpu_only || is_gromacs_only; then report_mpi_provider="thread-mpi"; fi
  cuda_v="$(installed_component_version cuda)"
  mpi_v="$(installed_component_version openmpi)"
  fftw_v="$(installed_component_version fftw)"
  boost_v="$(installed_component_version boost)"
  fmt_v="$(installed_component_version fmt)"
  spdlog_v="$(installed_component_version spdlog)"
  af_v="$(installed_component_version arrayfire)"
  plumed_v="$(installed_component_version plumed)"
  gmx_v="$(installed_component_version gromacs)"
  if [[ -f "${INSTALL_ROOT}/.plumed_patch_reject_status" ]]; then
    PLUMED_PATCH_REJECT_STATUS="$(head -n1 "${INSTALL_ROOT}/.plumed_patch_reject_status" 2>/dev/null || printf none)"
  fi
  if [[ -f "${INSTALL_ROOT}/.plumed_patch_reject_files" ]]; then
    PLUMED_PATCH_REJECT_FILES="$(head -n1 "${INSTALL_ROOT}/.plumed_patch_reject_files" 2>/dev/null || true)"
  fi
  if [[ "${has_plumed}" -eq 1 ]]; then
    plumed_dirty="$(git -C "${plumed_src}" status --porcelain --untracked-files=no 2>/dev/null || true)"
    plumed_untracked="$(git -C "${plumed_src}" status --porcelain --untracked-files=normal 2>/dev/null | awk '$1=="??"{print $2}' | paste -sd ';' - || true)"
  else
    plumed_dirty=""; plumed_untracked=""
  fi
  if [[ "${has_plumed}" -eq 1 && -d "${plumed_src}/.git" ]]; then
    plumed_diff_hash="$(git -C "${plumed_src}" diff --binary 2>/dev/null | sha256sum | awk '{print $1}' || true)"
  else
    plumed_diff_hash=""
  fi
  if is_full_stack && ! is_cpu_only; then
    mpi_cc_cmd="$([[ -x "${MPI_ROOT}/bin/mpicc" ]] && "${MPI_ROOT}/bin/mpicc" --showme:command 2>/dev/null || true)"
    mpi_cxx_cmd="$([[ -x "${MPI_ROOT}/bin/mpicxx" ]] && "${MPI_ROOT}/bin/mpicxx" --showme:command 2>/dev/null || true)"
  else
    mpi_cc_cmd=""; mpi_cxx_cmd=""
  fi
  cc_v="$(compiler_version_string "${BUILD_CC:-${CC:-gcc}}" 2>/dev/null || true)"
  cxx_v="$(compiler_version_string "${BUILD_CXX:-${CXX:-g++}}" 2>/dev/null || true)"

  {
    echo "Installation information"
    echo "========================"
    echo "Updated (UTC)       : ${timestamp}"
    echo "Host                : ${host}"
    echo "Installer           : ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "Last action         : ${action}"
    echo "Accelerator/backend : ${ACCELERATOR}"
    echo "Install root        : ${INSTALL_ROOT}"
    echo "Workspace layout    : $([[ "${SPLIT_LAYOUT}" -eq 1 ]] && echo split || echo legacy)"
    echo "Work root           : ${WORK_ROOT}"
    echo "Activation          : ${INSTALL_ROOT}/activate.sh"
    echo "Build logs          : ${LOG_DIR}"
    echo
    echo "PLUMED / SAXS"
    echo "---------------"
    echo "PLUMED prefix       : ${plumed_prefix:-not-built}"
    echo "PLUMED source       : ${plumed_src:-not-built}"
    echo "PLUMED version      : ${plumed_v}"
    echo "PLUMED commit       : ${commit:-unknown}"
    echo "PLUMED tracked dirty: $([[ -n "${plumed_dirty}" ]] && echo yes || echo no)"
    echo "PLUMED diff SHA-256 : ${plumed_diff_hash:-missing}"
    echo "PLUMED untracked    : ${plumed_untracked:-none}"
    echo "PLUMED config       : ${plumed_config_path:-not-built}"
    echo "Patch bundle        : ${patch_bundle_dir:-not-used}"
    echo "Patch manifest SHA  : ${patch_manifest_hash:-not-used}"
    echo "Patch file count    : ${patch_file_count:-not-used}"
    echo "SAXS source         : ${saxs_source_path:-not-built}"
    echo "SAXS source SHA-256 : ${saxs_hash:-missing}"
    if ! is_full_stack; then
      echo "SAXS candidate      : not-applicable (GROMACS-only route)"
      echo "Candidate SHA-256   : not-applicable"
    elif is_cpu_only; then
      echo "SAXS candidate      : upstream-only CPU profile (custom SAXS disabled)"
      echo "Candidate SHA-256   : not-applicable"
    else
      if [[ -n "${patch_manifest_hash}" ]]; then
        echo "SAXS candidate      : ${patch_bundle_dir}/plumed2/src/isdb/SAXS.cpp"
      else
        echo "SAXS candidate      : ${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
      fi
      echo "Candidate SHA-256   : ${candidate_hash:-missing}"
    fi
    echo "Installed kernel    : ${kernel_path:-not-built}"
    echo "Kernel SHA-256      : ${kernel_hash:-missing}"
    echo "GROMACS linkage     : ${linkage}"
    echo "Patch reject status : ${PLUMED_PATCH_REJECT_STATUS}"
    echo "Patch reject files  : ${PLUMED_PATCH_REJECT_FILES:-none}"
    echo "Source mode         : ${report_source_mode}"
    echo "Source cache        : ${report_source_cache:-not-used}"
    if [[ "${has_plumed}" -eq 1 && -n "${patch_manifest_hash}" ]]; then
      echo "PLUMED patch history: ${INSTALL_ROOT}/plumed_patch_updates/history.jsonl"
      echo "PLUMED patch backups: ${INSTALL_ROOT}/plumed_patch_updates/backups"
      echo "SAXS update history : not-applicable (manifest-managed installation)"
      echo "SAXS update backups : not-applicable (manifest-managed installation)"
    elif [[ "${has_plumed}" -eq 1 ]]; then
      echo "PLUMED patch history: not-applicable"
      echo "PLUMED patch backups: not-applicable"
      echo "SAXS update history : ${INSTALL_ROOT}/saxs_updates/history.jsonl"
      echo "SAXS update backups : ${INSTALL_ROOT}/saxs_updates/backups"
    else
      echo "PLUMED patch history: not-applicable"
      echo "PLUMED patch backups: not-applicable"
      echo "SAXS update history : not-applicable"
      echo "SAXS update backups : not-applicable"
    fi
    echo
    echo "Toolchain"
    echo "---------"
    echo "C compiler          : ${BUILD_CC:-unknown} (${cc_v:-unknown})"
    echo "C++ compiler        : ${BUILD_CXX:-unknown} (${cxx_v:-unknown})"
    echo "CUDA host C++       : ${BUILD_CUDAHOSTCXX:-not-applicable}"
    echo "MPI C wrapper       : ${mpi_cc_cmd:-not-built}"
    echo "MPI C++ wrapper     : ${mpi_cxx_cmd:-not-built}"
    echo
    echo "Installed components"
    echo "--------------------"
    if is_cpu_only; then
      echo "CUDA                : not used"
      echo "MPI                 : not built (thread-MPI route)"
    elif is_gromacs_only; then
      echo "CUDA                : ${CUDA_HOME} (${cuda_v})"
      echo "MPI                 : not built (GROMACS thread-MPI)"
    else
      echo "CUDA                : ${CUDA_HOME} (${cuda_v})"
      echo "MPI provider        : ${MPI_PROVIDER}"
      echo "MPI                 : ${MPI_ROOT} (${mpi_v})"
    fi
    echo "FFTW                : ${FFTW_ROOT} (${fftw_v})"
    echo "Boost               : ${BOOST_ROOT} (${boost_v})"
    echo "fmt                 : ${FMT_ROOT} (${fmt_v})"
    echo "spdlog              : ${SPDLOG_ROOT} (${spdlog_v})"
    echo "ArrayFire           : ${AF_ROOT} (${af_v})"
    echo "PLUMED              : ${plumed_prefix:-not-built} (${plumed_v})"
    echo "GROMACS             : ${GMX_ROOT} (${gmx_v})"
    echo
    echo "PLUMED manifest patch update command"
    echo "------------------------------------"
    if ! is_full_stack || is_cpu_only; then
      echo "not-applicable"
    elif [[ -n "${patch_manifest_hash}" ]]; then
      if [[ "${SPLIT_LAYOUT}" -eq 1 ]]; then
        echo "${SCRIPT_NAME} --dir $(printf '%q' "${DIR}") --name $(printf '%q' "${NAME}") --work-dir $(printf '%q' "${WORK_DIR}") --update-plumed-patch -j ${NPROC}"
      else
        echo "${SCRIPT_NAME} --dir $(printf '%q' "${DIR}") --name $(printf '%q' "${NAME}") --update-plumed-patch -j ${NPROC}"
      fi
    else
      echo "no manifest-driven patch recorded"
    fi
    echo
    echo "SAXS-only update command"
    echo "------------------------"
    if ! is_full_stack; then
      echo "not-applicable for GROMACS-only route"
    elif is_cpu_only; then
      echo "unsupported for CPU profile: custom SAXS development/update remains CUDA/ArrayFire-only pending separate validation"
    elif [[ -n "${patch_manifest_hash}" ]]; then
      echo "disabled for manifest-managed installation; use --update-plumed-patch"
    else
      if [[ "${SPLIT_LAYOUT}" -eq 1 ]]; then
        echo "${SCRIPT_NAME} --dir $(printf '%q' "${DIR}") --name $(printf '%q' "${NAME}") --work-dir $(printf '%q' "${WORK_DIR}") --update-saxs -j ${NPROC}"
      else
        echo "${SCRIPT_NAME} --dir $(printf '%q' "${DIR}") --name $(printf '%q' "${NAME}") --update-saxs -j ${NPROC}"
      fi
    fi
  } > "${report_tmp}" || return 1

  {
    printf '{\n'
    printf '  "schema_version": 4,\n'
    printf '  "updated_at_utc": %s,\n' "$(json_string "${timestamp}")"
    printf '  "host": %s,\n' "$(json_string "${host}")"
    printf '  "installer": {"name": %s, "version": %s},\n' "$(json_string "${SCRIPT_NAME}")" "$(json_string "${SCRIPT_VERSION}")"
    printf '  "last_action": %s,\n' "$(json_string "${action}")"
    printf '  "accelerator": %s,\n' "$(json_string "${ACCELERATOR}")"
    printf '  "install_root": %s,\n' "$(json_string "${INSTALL_ROOT}")"
    printf '  "workspace": {"layout": %s, "parent": %s, "root": %s, "sources": %s, "logs": %s, "checkpoints": %s},\n' \
      "$(json_string "$([[ "${SPLIT_LAYOUT}" -eq 1 ]] && echo split || echo legacy)")" \
      "$(json_string "${WORK_DIR}")" "$(json_string "${WORK_ROOT}")" "$(json_string "${SRC}")" \
      "$(json_string "${LOG_DIR}")" "$(json_string "${CKPT_DIR}")"
    printf '  "activation_script": %s,\n' "$(json_string "${INSTALL_ROOT}/activate.sh")"
    printf '  "plumed": {\n'
    printf '    "prefix": %s,\n' "$(json_string "${plumed_prefix}")"
    printf '    "source": %s,\n' "$(json_string "${plumed_src}")"
    printf '    "version": %s,\n' "$(json_string "${plumed_v}")"
    printf '    "git_commit": %s,\n' "$(json_string "${commit}")"
    printf '    "tracked_dirty": %s,\n' "$([[ -n "${plumed_dirty}" ]] && printf true || printf false)"
    printf '    "tracked_diff_sha256": %s,\n' "$(json_string "${plumed_diff_hash}")"
    printf '    "untracked_files": %s,\n' "$(json_string "${plumed_untracked}")"
    printf '    "patch_reject_status": %s,\n' "$(json_string "${PLUMED_PATCH_REJECT_STATUS}")"
    printf '    "patch_reject_files": %s,\n' "$(json_string "${PLUMED_PATCH_REJECT_FILES}")"
    printf '    "configuration": %s,\n' "$(json_string "${plumed_config_path}")"
    printf '    "kernel": %s,\n' "$(json_string "${kernel_path}")"
    printf '    "kernel_sha256": %s,\n' "$(json_string "${kernel_hash}")"
    printf '    "manifest_patch": {"bundle": %s, "manifest_sha256": %s, "file_count": %s, "update_history": %s, "backups": %s}\n' \
      "$(json_string "${patch_bundle_dir}")" "$(json_string "${patch_manifest_hash}")" "$(json_string "${patch_file_count}")" \
      "$(json_string "$([[ -n "${patch_manifest_hash}" ]] && echo "${INSTALL_ROOT}/plumed_patch_updates/history.jsonl" || true)")" \
      "$(json_string "$([[ -n "${patch_manifest_hash}" ]] && echo "${INSTALL_ROOT}/plumed_patch_updates/backups" || true)")"
    printf '  },\n'
    printf '  "saxs": {\n'
    printf '    "source": %s,\n' "$(json_string "${saxs_source_path}")"
    printf '    "source_sha256": %s,\n' "$(json_string "${saxs_hash}")"
    if ! is_full_stack; then
      printf '    "canonical_candidate": %s,\n' "$(json_string "not-applicable-gromacs-only")"
      printf '    "candidate_sha256": %s,\n' "$(json_string "")"
    elif is_cpu_only; then
      printf '    "canonical_candidate": %s,\n' "$(json_string "not-applicable-upstream-only")"
      printf '    "candidate_sha256": %s,\n' "$(json_string "")"
    else
      if [[ -n "${patch_manifest_hash}" ]]; then
        printf '    "canonical_candidate": %s,\n' "$(json_string "${patch_bundle_dir}/plumed2/src/isdb/SAXS.cpp")"
      else
        printf '    "canonical_candidate": %s,\n' "$(json_string "${INSTALL_ROOT}/plumed_patch/SAXS.cpp")"
      fi
      printf '    "candidate_sha256": %s,\n' "$(json_string "${candidate_hash}")"
    fi
    printf '    "history": %s,\n' "$(json_string "$([[ "${has_plumed}" -eq 1 && -z "${patch_manifest_hash}" ]] && echo "${INSTALL_ROOT}/saxs_updates/history.jsonl" || true)")"
    printf '    "backups": %s\n' "$(json_string "$([[ "${has_plumed}" -eq 1 && -z "${patch_manifest_hash}" ]] && echo "${INSTALL_ROOT}/saxs_updates/backups" || true)")"
    printf '  },\n'
    printf '  "gromacs": {"prefix": %s, "version": %s, "plumed_linkage": %s},\n' \
      "$(json_string "${GMX_ROOT}")" "$(json_string "${gmx_v}")" "$(json_string "${linkage}")"
    printf '  "source_acquisition": {"mode": %s, "cache": %s},\n' \
      "$(json_string "${report_source_mode}")" "$(json_string "${report_source_cache}")"
    printf '  "toolchain": {"cc": %s, "cc_version": %s, "cxx": %s, "cxx_version": %s, "cuda_host_cxx": %s, "mpi_provider": %s, "mpi_cc_command": %s, "mpi_cxx_command": %s},\n' \
      "$(json_string "${BUILD_CC}")" "$(json_string "${cc_v}")" "$(json_string "${BUILD_CXX}")" "$(json_string "${cxx_v}")" \
      "$(json_string "${BUILD_CUDAHOSTCXX}")" "$(json_string "${report_mpi_provider}")" "$(json_string "${mpi_cc_cmd}")" "$(json_string "${mpi_cxx_cmd}")"
    printf '  "components": {\n'
    if is_cpu_only; then
      printf '    "cuda": {"prefix": %s, "version": %s},\n' "$(json_string "")" "$(json_string "not-used")"
      printf '    "mpi": {"provider": %s, "prefix": %s, "version": %s},\n' "$(json_string "thread-mpi")" "$(json_string "")" "$(json_string "not-built")"
    elif is_gromacs_only; then
      printf '    "cuda": {"prefix": %s, "version": %s},\n' "$(json_string "${CUDA_HOME}")" "$(json_string "${cuda_v}")"
      printf '    "mpi": {"provider": %s, "prefix": %s, "version": %s},\n' "$(json_string "thread-mpi")" "$(json_string "")" "$(json_string "not-built")"
    else
      printf '    "cuda": {"prefix": %s, "version": %s},\n' "$(json_string "${CUDA_HOME}")" "$(json_string "${cuda_v}")"
      printf '    "mpi": {"provider": %s, "prefix": %s, "version": %s},\n' "$(json_string "${MPI_PROVIDER}")" "$(json_string "${MPI_ROOT}")" "$(json_string "${mpi_v}")"
    fi
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

persist_postbuild_provenance() {

  mkdir -p "${INSTALL_ROOT}"
  printf '%s\n' "${WORK_DIR:-}" > "${INSTALL_ROOT}/.installer_work_parent"
  printf '%s\n' "${WORK_ROOT:-${INSTALL_ROOT}}" > "${INSTALL_ROOT}/.installer_work_root"
  printf '%s\n' "${PLUMED_REF:-}" > "${INSTALL_ROOT}/.installer_plumed_ref"
  printf '%s\n' "${GROMACS_VERSION:-}" > "${INSTALL_ROOT}/.installer_gromacs_version"

  if is_full_stack && [[ -d "${SRC}/plumed2/.git" ]]; then
    local commit="" saxs_src="${SRC}/plumed2/src/isdb/SAXS.cpp" keep_dir
    commit="$(git -C "${SRC}/plumed2" rev-parse HEAD 2>/dev/null || true)"
    [[ -z "${commit}" ]] || printf '%s\n' "${commit}" > "${INSTALL_ROOT}/.installer_plumed_commit"
    if ! is_cpu_only && [[ -f "${saxs_src}" ]]; then
      keep_dir="${INSTALL_ROOT}/saxs_updates/current"
      mkdir -p "${keep_dir}"
      cp -f -- "${saxs_src}" "${keep_dir}/SAXS.cpp"
      printf '%s\n' "$(sha256_file "${saxs_src}")" > "${INSTALL_ROOT}/.installer_saxs_sha256"
    fi
    local patch_current="${INSTALL_ROOT}/plumed_patch_bundle/current"
    if [[ -f "${patch_current}/PATCHFILES.sha256" && -d "${patch_current}/plumed2" ]]; then
      validate_plumed_patch_bundle_root "${patch_current}"
      printf '%s\n' "${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}" > "${INSTALL_ROOT}/.installer_plumed_patch_manifest_sha256"
      printf '%s\n' "${PLUMED_PATCH_FILE_COUNT}" > "${INSTALL_ROOT}/.installer_plumed_patch_file_count"
      if [[ -f "${PLUMED_KERNEL:-}" && -n "${commit}" ]]; then
        write_plumed_patch_installed_state "${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}" "$(sha256_file "${PLUMED_KERNEL}")" "${commit}" \
          || warn "Could not write the PLUMED patch installed-state marker."
      fi
    fi
  fi
}

verify_cached_file_sha256() {

  local rel="${1}" expected actual
  [[ -s "${SOURCE_CACHE_SHA256}" ]] || die "Source-cache checksum manifest missing: ${SOURCE_CACHE_SHA256}"
  expected="$(awk -v r="${rel}" '$2==r {print $1; exit}' "${SOURCE_CACHE_SHA256}" 2>/dev/null || true)"
  [[ -n "${expected}" ]] || die "No SHA-256 record for ${rel} in ${SOURCE_CACHE_SHA256}."
  actual="$(sha256_file "${SOURCE_CACHE}/${rel}")"
  [[ "${actual}" == "${expected}" ]] || die "Cached file SHA-256 mismatch for ${rel}: expected ${expected}, got ${actual}."
}

ensure_plumed_update_worktree() {
  local plumed_src="${SRC}/plumed2"
  if [[ -d "${plumed_src}/.git" && -f "${plumed_src}/Makefile" && -f "${plumed_src}/src/config/config.txt" ]]; then
    return 0
  fi

  [[ "${SPLIT_LAYOUT}" -eq 1 ]] \
    || die "Configured PLUMED worktree is missing: ${plumed_src}. Legacy-layout updates require the retained configured source tree."
  [[ "${DRY_RUN}" -eq 0 ]] \
    || die "The recorded split workspace is missing. A real PLUMED source update can reconstruct it from the recorded source cache; dry-run will not create the workspace."
  [[ -n "${SOURCE_CACHE}" ]] \
    || die "Split workspace is missing and no source cache is recorded. Cannot reconstruct PLUMED safely."

  SOURCE_CACHE="$(abspath "${SOURCE_CACHE}")"
  SOURCE_CACHE_MANIFEST="${SOURCE_CACHE}/manifest.tsv"
  SOURCE_CACHE_SHA256="${SOURCE_CACHE}/SHA256SUMS"
  [[ -s "${SOURCE_CACHE_MANIFEST}" ]] || die "Cannot reconstruct PLUMED: cache manifest missing at ${SOURCE_CACHE_MANIFEST}."
  [[ -s "${SOURCE_CACHE}/git/plumed2.tar.gz" ]] || die "Cannot reconstruct PLUMED: cached snapshot missing at ${SOURCE_CACHE}/git/plumed2.tar.gz."
  verify_cached_file_sha256 "git/plumed2.tar.gz"

  section "Reconstructing missing PLUMED workspace"
  mkdir -p "${SRC}" "${LOG_DIR}"
  source_cache_extract_git plumed "plumed2" "${plumed_src}"

  local expected_commit="" actual_commit="" saved_saxs="" expected_saxs="" actual_saxs=""
  if [[ -s "${INSTALL_ROOT}/.installer_plumed_commit" ]]; then
    expected_commit="$(head -n1 "${INSTALL_ROOT}/.installer_plumed_commit")"
  fi
  actual_commit="$(git -C "${plumed_src}" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "${expected_commit}" ]] \
    || die "Recorded PLUMED commit is missing; refusing to reconstruct a scientific update workspace ambiguously."
  [[ "${actual_commit}" == "${expected_commit}" ]] \
    || die "Reconstructed PLUMED commit mismatch: recorded=${expected_commit}, cache=${actual_commit}."

  local patch_current="${INSTALL_ROOT}/plumed_patch_bundle/current" recorded_patch_hash="" current_patch_hash=""
  if [[ -f "${patch_current}/PATCHFILES.sha256" && -d "${patch_current}/plumed2" ]]; then
    validate_plumed_patch_bundle_root "${patch_current}"
    current_patch_hash="${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}"
    recorded_patch_hash="$(head -n1 "${INSTALL_ROOT}/.installer_plumed_patch_manifest_sha256" 2>/dev/null || true)"
    [[ -z "${recorded_patch_hash}" || "${recorded_patch_hash}" == "${current_patch_hash}" ]] || die "Preserved PLUMED patch manifest does not match the recorded installed state; refusing reconstruction."
    apply_plumed_patch_bundle_root_to_tree "${patch_current}" "${plumed_src}"
    actual_saxs="$(sha256_file "${plumed_src}/src/isdb/SAXS.cpp" 2>/dev/null || true)"
  else
    if [[ -s "${INSTALL_ROOT}/saxs_updates/current/SAXS.cpp" ]]; then
      saved_saxs="${INSTALL_ROOT}/saxs_updates/current/SAXS.cpp"
    elif [[ -s "${INSTALL_ROOT}/plumed_patch/SAXS.cpp" ]]; then
      saved_saxs="${INSTALL_ROOT}/plumed_patch/SAXS.cpp"
    else
      die "No preserved PLUMED patch or SAXS source is available to reconstruct the workspace."
    fi
    expected_saxs="$(head -n1 "${INSTALL_ROOT}/.installer_saxs_sha256" 2>/dev/null || true)"
    actual_saxs="$(sha256_file "${saved_saxs}")"
    [[ -z "${expected_saxs}" || "${actual_saxs}" == "${expected_saxs}" ]] || die "Preserved SAXS source hash does not match the recorded installed state; refusing reconstruction."
    cp -f -- "${saved_saxs}" "${plumed_src}/src/isdb/SAXS.cpp"
  fi

  cd "${plumed_src}"
  make distclean 2>/dev/null || true
  configure_plumed_cuda_tree "${plumed_src}"
  [[ -f "${plumed_src}/Makefile" && -f "${plumed_src}/src/config/config.txt" ]] \
    || die "PLUMED workspace reconstruction did not produce a configured tree."
  ok "Reconstructed configured PLUMED workspace at ${plumed_src} (commit ${actual_commit})."
}

validate_split_runtime_independence() {
  [[ "${SPLIT_LAYOUT}" -eq 1 ]] || return 0
  section "Split-layout runtime independence"
  local x out bad=0
  local -a targets=()
  [[ -x "${GMX_ROOT}/bin/gmx" ]] && targets+=("${GMX_ROOT}/bin/gmx")
  [[ -x "${GMX_ROOT}/bin/gmx_mpi" ]] && targets+=("${GMX_ROOT}/bin/gmx_mpi")
  [[ -f "${PLUMED_KERNEL:-}" ]] && targets+=("${PLUMED_KERNEL}")
  [[ -f "${AF_ROOT:-}/lib/libafcuda.so" ]] && targets+=("${AF_ROOT}/lib/libafcuda.so")
  [[ -f "${AF_ROOT:-}/lib64/libafcuda.so" ]] && targets+=("${AF_ROOT}/lib64/libafcuda.so")

  for x in "${targets[@]}"; do
    out="$(ldd "${x}" 2>/dev/null || true)"
    if grep -Fq "${WORK_ROOT}" <<<"${out}"; then
      err "Runtime linkage still resolves through workspace ${WORK_ROOT}: ${x}"
      bad=1
    fi
    if command -v readelf >/dev/null 2>&1; then
      out="$(readelf -d "${x}" 2>/dev/null || true)"
      if grep -Fq "${WORK_ROOT}" <<<"${out}"; then
        err "RPATH/RUNPATH contains workspace ${WORK_ROOT}: ${x}"
        bad=1
      fi
    fi
  done
  [[ "${bad}" -eq 0 ]] || die "Split-layout runtime independence check failed; installed runtime must not depend on the build workspace."
  ok "Critical runtime binaries/libraries do not resolve through the build workspace."
}

setup_saxs_update_environment() {
  local activate="${INSTALL_ROOT}/activate.sh"
  if [[ -f "${INSTALL_ROOT}/.installer_accelerator" ]] \
     && [[ "$(head -n1 "${INSTALL_ROOT}/.installer_accelerator" 2>/dev/null || true)" == "cpu" ]]; then
    die "This is a CPU-only installation. Custom PLUMED source-update workflows are supported only for the validated CUDA/ArrayFire profile."
  fi
  [[ -f "${activate}" ]] || die "Activation script not found: ${activate}"
  load_persisted_install_profile
  resolve_paths

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

  shopt -s nullglob
  local plumed_libs=("${PLUMED_ROOT}/lib"/libplumed*.so*)
  shopt -u nullglob
  [[ "${#plumed_libs[@]}" -gt 0 ]] || die "No installed libplumed shared libraries found under ${PLUMED_ROOT}/lib"
  for lib in "${plumed_libs[@]}"; do
    cp -a -- "${lib}" "${SAXS_UPDATE_BACKUP_DIR}/installed-lib/"
  done

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

  local plumed_src="${SRC}/plumed2" before="${SAXS_UPDATE_TRACKED_DIRTY_LIST}"
  local missing="${SAXS_UPDATE_TRACKED_MISSING_LIST}" archive="${SAXS_UPDATE_TRACKED_DIRTY_ARCHIVE}"
  local after path
  [[ -d "${plumed_src}/.git" && -n "${before}" && -f "${before}" ]] || return 0
  after="${SAXS_UPDATE_BACKUP_DIR}/tracked-dirty-after-build.txt"
  git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null \
    | sed '/^src\/isdb\/SAXS\.cpp$/d; /^$/d' | sort -u > "${after}"

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if ! grep -Fxq -- "${path}" "${before}"; then
      git -C "${plumed_src}" restore --source=HEAD --worktree -- "${path}" \
        || return 1
    fi
  done < "${after}"

  if [[ -n "${archive}" && -f "${archive}" ]]; then
    tar -C "${plumed_src}" -xpf "${archive}" || return 1
  fi
  if [[ -n "${missing}" && -f "${missing}" ]]; then
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      rm -f -- "${plumed_src}/${path}" || return 1
    done < "${missing}"
  fi

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

plumed_patch_update_managed_target_list() {
  [[ -z "${PATCH_UPDATE_BUNDLE:-}" ]] || plumed_patch_target_list "${PATCH_UPDATE_BUNDLE}"
  if [[ -n "${PATCH_UPDATE_OLD_BUNDLE:-}" && -f "${PATCH_UPDATE_OLD_BUNDLE}/PATCHFILES.sha256" ]]; then
    plumed_patch_target_list "${PATCH_UPDATE_OLD_BUNDLE}"
  fi
}

plumed_patch_removed_target_list() {
  local old_root="${1}" new_root="${2}" old_list new_list
  [[ -n "${old_root}" && -f "${old_root}/PATCHFILES.sha256" ]] || return 0
  old_list="$(mktemp "${TMPDIR:-/tmp}/plumed-old-targets.XXXXXX")"
  new_list="$(mktemp "${TMPDIR:-/tmp}/plumed-new-targets.XXXXXX")"
  plumed_patch_target_list "${old_root}" | sort -u > "${old_list}"
  plumed_patch_target_list "${new_root}" | sort -u > "${new_list}"
  comm -23 "${old_list}" "${new_list}"
  rm -f -- "${old_list}" "${new_list}"
}

reconcile_removed_plumed_patch_targets() {
  local old_root="${1}" new_root="${2}" plumed_src="${3}" rel
  [[ -n "${old_root}" && -f "${old_root}/PATCHFILES.sha256" ]] || return 0
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if git -C "${plumed_src}" ls-files --error-unmatch -- "${rel}" >/dev/null 2>&1; then
      git -C "${plumed_src}" restore --source=HEAD --worktree -- "${rel}" || die "Could not restore removed patch target to upstream state: ${rel}"
    else
      rm -f -- "${plumed_src}/${rel}" || die "Could not remove obsolete patch-added file: ${rel}"
    fi
  done < <(plumed_patch_removed_target_list "${old_root}" "${new_root}")
}

verify_removed_plumed_patch_targets_reconciled() {
  local old_root="${1}" new_root="${2}" plumed_src="${3}" rel
  [[ -n "${old_root}" && -f "${old_root}/PATCHFILES.sha256" ]] || return 0
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if git -C "${plumed_src}" ls-files --error-unmatch -- "${rel}" >/dev/null 2>&1; then
      git -C "${plumed_src}" diff --quiet HEAD -- "${rel}" || return 1
    else
      [[ ! -e "${plumed_src}/${rel}" && ! -L "${plumed_src}/${rel}" ]] || return 1
    fi
  done < <(plumed_patch_removed_target_list "${old_root}" "${new_root}")
}

plumed_patch_installed_state_matches() {
  local manifest_hash="${1}" kernel_hash="${2}" commit="${3}"
  local state="${INSTALL_ROOT}/plumed_patch_updates/installed-state.txt" key value recorded_manifest="" recorded_kernel="" recorded_commit=""
  [[ -f "${state}" ]] || return 1
  while IFS='=' read -r key value; do
    case "${key}" in
      manifest_sha256) recorded_manifest="${value}" ;;
      kernel_sha256) recorded_kernel="${value}" ;;
      plumed_commit) recorded_commit="${value}" ;;
    esac
  done < "${state}"
  [[ "${recorded_manifest}" == "${manifest_hash}" && "${recorded_kernel}" == "${kernel_hash}" && "${recorded_commit}" == "${commit}" ]]
}

write_plumed_patch_installed_state() {
  local manifest_hash="${1}" kernel_hash="${2}" commit="${3}"
  local state_dir="${INSTALL_ROOT}/plumed_patch_updates" state tmp
  state="${state_dir}/installed-state.txt"
  mkdir -p "${state_dir}" || return 1
  tmp="$(mktemp "${state_dir}/.installed-state.XXXXXX")" || return 1
  {
    echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "manifest_sha256=${manifest_hash}"
    echo "kernel_sha256=${kernel_hash}"
    echo "plumed_commit=${commit}"
    echo "update_id=${PATCH_UPDATE_ID}"
  } > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  mv -f -- "${tmp}" "${state}"
}

prepare_plumed_patch_update_candidate() {
  local canonical
  canonical="$(plumed_patch_canonical_dir)"
  PATCH_UPDATE_OLD_BUNDLE=""
  if [[ -f "${canonical}/PATCHFILES.sha256" && -d "${canonical}/plumed2" ]]; then
    validate_plumed_patch_bundle_root "${canonical}"
    PATCH_UPDATE_OLD_BUNDLE="${canonical}"
  fi
  if [[ -n "${PLUMED_PATCH_BUNDLE}" ]]; then
    prepare_plumed_patch_bundle_input "${PLUMED_PATCH_BUNDLE}"
    PATCH_UPDATE_BUNDLE="${PLUMED_PATCH_PREPARED_ROOT}"
  else
    [[ -f "${canonical}/PATCHFILES.sha256" && -d "${canonical}/plumed2" ]] || die "No installed PLUMED patch bundle is available. Pass --plumed-patch-bundle <archive-or-directory>."
    validate_plumed_patch_bundle_root "${canonical}"
    PATCH_UPDATE_BUNDLE="${canonical}"
  fi
  validate_plumed_patch_bundle_root "${PATCH_UPDATE_BUNDLE}"
  PATCH_UPDATE_MANIFEST_SHA256="${PLUMED_PATCH_VALIDATED_MANIFEST_SHA256}"
}

validate_plumed_patch_update_install() {
  local root="${1}" plumed_src="${SRC}/plumed2" config_install prefix_record prefix_ok=0 linkage targets dirty all_dirty
  [[ -d "${INSTALL_ROOT}" ]] || die "Existing install root not found: ${INSTALL_ROOT}"
  [[ -d "${plumed_src}/.git" ]] || die "Configured PLUMED Git checkout not found: ${plumed_src}"
  [[ -f "${plumed_src}/Makefile" ]] || die "PLUMED checkout is not configured: ${plumed_src}"
  [[ -f "${plumed_src}/src/config/config.txt" ]] || die "PLUMED configuration record missing."
  [[ -x "${PLUMED_ROOT}/bin/plumed" ]] || die "Installed PLUMED executable missing: ${PLUMED_ROOT}/bin/plumed"
  [[ -f "${PLUMED_KERNEL}" ]] || die "Installed PLUMED kernel missing: ${PLUMED_KERNEL}"
  [[ -x "${MPI_ROOT}/bin/mpicxx" ]] || die "MPI C++ wrapper missing: ${MPI_ROOT}/bin/mpicxx"
  config_install="${plumed_src}/src/config/ConfigInstall.inc"
  for prefix_record in "${config_install}" "${plumed_src}/config.status" "${plumed_src}/Makefile.conf"; do
    [[ -f "${prefix_record}" ]] || continue
    grep -Fq "${PLUMED_ROOT}" "${prefix_record}" && prefix_ok=1
  done
  [[ "${prefix_ok}" -eq 1 ]] || die "Could not confirm ${PLUMED_ROOT} as the configured PLUMED install prefix."
  grep -Eq 'has arrayfire_cuda[[:space:]]+(on|yes)|__PLUMED_HAS_ARRAYFIRE_CUDA' "${plumed_src}/src/config/config.txt" || die "Retained PLUMED configuration does not report ArrayFire CUDA support."
  grep -Eq 'module isdb[[:space:]]+on' "${plumed_src}/src/config/config.txt" || die "Retained PLUMED configuration does not report ISDB enabled."
  targets="$(mktemp "${TMPDIR:-/tmp}/plumed-patch-targets.XXXXXX")"
  plumed_patch_update_managed_target_list | sort -u > "${targets}"
  if [[ "${ALLOW_DIRTY_PLUMED}" -eq 0 ]]; then
    all_dirty="$(mktemp "${TMPDIR:-/tmp}/plumed-patch-dirty.XXXXXX")"
    git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null | sed '/^$/d' | sort -u > "${all_dirty}"
    dirty="$(grep -Fvx -f "${targets}" "${all_dirty}" 2>/dev/null || true)"
    rm -f -- "${all_dirty}"
    [[ -z "${dirty}" ]] || { rm -f -- "${targets}"; die "PLUMED has tracked changes outside the patch manifest:\n${dirty}"; }
  fi
  rm -f -- "${targets}"
  linkage="$(detect_gromacs_plumed_linkage)"
  [[ "${linkage}" != "unknown" ]] || die "Could not verify installed GROMACS/PLUMED shared/runtime linkage."
}

prepare_plumed_patch_update_backup() {
  local root="${1}" plumed_src="${SRC}/plumed2" backup_root="${INSTALL_ROOT}/plumed_patch_updates/backups"
  local target rel prefix_parent prefix_name prefix_size_kb avail_kb safety_kb snapshot tracked_path
  PATCH_UPDATE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  PATCH_UPDATE_BACKUP_DIR="${backup_root}/${PATCH_UPDATE_ID}"
  mkdir -p "${PATCH_UPDATE_BACKUP_DIR}"
  PATCH_UPDATE_TARGET_EXISTING_LIST="${PATCH_UPDATE_BACKUP_DIR}/targets-existing-before.txt"
  PATCH_UPDATE_TARGET_MISSING_LIST="${PATCH_UPDATE_BACKUP_DIR}/targets-missing-before.txt"
  PATCH_UPDATE_TARGET_ARCHIVE="${PATCH_UPDATE_BACKUP_DIR}/targets-existing-before.tar"
  : > "${PATCH_UPDATE_TARGET_EXISTING_LIST}"
  : > "${PATCH_UPDATE_TARGET_MISSING_LIST}"
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if [[ -e "${plumed_src}/${rel}" || -L "${plumed_src}/${rel}" ]]; then
      printf '%s\n' "${rel}" >> "${PATCH_UPDATE_TARGET_EXISTING_LIST}"
    else
      printf '%s\n' "${rel}" >> "${PATCH_UPDATE_TARGET_MISSING_LIST}"
    fi
  done < <(plumed_patch_update_managed_target_list | sort -u)
  if [[ -s "${PATCH_UPDATE_TARGET_EXISTING_LIST}" ]]; then
    tar -C "${plumed_src}" --verbatim-files-from -cpf "${PATCH_UPDATE_TARGET_ARCHIVE}" -T "${PATCH_UPDATE_TARGET_EXISTING_LIST}" || die "Could not snapshot existing PLUMED patch targets."
  else
    PATCH_UPDATE_TARGET_ARCHIVE=""
  fi
  PATCH_UPDATE_OTHER_DIRTY_LIST="${PATCH_UPDATE_BACKUP_DIR}/other-dirty-before.txt"
  PATCH_UPDATE_OTHER_MISSING_LIST="${PATCH_UPDATE_BACKUP_DIR}/other-missing-before.txt"
  PATCH_UPDATE_OTHER_ARCHIVE="${PATCH_UPDATE_BACKUP_DIR}/other-existing-before.tar"
  local target_set="${PATCH_UPDATE_BACKUP_DIR}/target-set.txt" other_existing="${PATCH_UPDATE_BACKUP_DIR}/other-existing-before.txt" all_dirty="${PATCH_UPDATE_BACKUP_DIR}/all-dirty-before.txt"
  plumed_patch_update_managed_target_list | sort -u > "${target_set}"
  git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null | sed '/^$/d' | sort -u > "${all_dirty}"
  grep -Fvx -f "${target_set}" "${all_dirty}" 2>/dev/null > "${PATCH_UPDATE_OTHER_DIRTY_LIST}" || true
  : > "${PATCH_UPDATE_OTHER_MISSING_LIST}"
  : > "${other_existing}"
  while IFS= read -r tracked_path; do
    [[ -n "${tracked_path}" ]] || continue
    if [[ -e "${plumed_src}/${tracked_path}" || -L "${plumed_src}/${tracked_path}" ]]; then
      printf '%s\n' "${tracked_path}" >> "${other_existing}"
    else
      printf '%s\n' "${tracked_path}" >> "${PATCH_UPDATE_OTHER_MISSING_LIST}"
    fi
  done < "${PATCH_UPDATE_OTHER_DIRTY_LIST}"
  if [[ -s "${other_existing}" ]]; then
    tar -C "${plumed_src}" --verbatim-files-from -cpf "${PATCH_UPDATE_OTHER_ARCHIVE}" -T "${other_existing}" || die "Could not snapshot pre-existing PLUMED tracked changes."
  else
    PATCH_UPDATE_OTHER_ARCHIVE=""
  fi
  cp -p -- "${root}/PATCHFILES.sha256" "${PATCH_UPDATE_BACKUP_DIR}/PATCHFILES.candidate.sha256"
  prefix_parent="$(dirname "${PLUMED_ROOT}")"
  prefix_name="$(basename "${PLUMED_ROOT}")"
  snapshot="${PATCH_UPDATE_BACKUP_DIR}/plumed-prefix.before.tar"
  prefix_size_kb="$(du -sk "${PLUMED_ROOT}" 2>/dev/null | awk '{print $1}')"
  avail_kb="$(df -Pk "${PATCH_UPDATE_BACKUP_DIR}" 2>/dev/null | awk 'NR==2{print $4}')"
  safety_kb=$((100*1024))
  if [[ -n "${prefix_size_kb}" && -n "${avail_kb}" ]]; then
    (( avail_kb > prefix_size_kb + safety_kb )) || die "Insufficient free space for transactional PLUMED prefix snapshot."
  fi
  tar -C "${prefix_parent}" -cpf "${snapshot}" "${prefix_name}" || die "Could not create complete PLUMED prefix snapshot."
  PATCH_UPDATE_PREFIX_SNAPSHOT="${snapshot}"
  PATCH_UPDATE_PREFIX_SNAPSHOT_SHA256="$(sha256_file "${snapshot}")"
  {
    echo "backup_id=${PATCH_UPDATE_ID}"
    echo "created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "plumed_commit=${PATCH_UPDATE_COMMIT}"
    echo "manifest_sha256=${PATCH_UPDATE_MANIFEST_SHA256}"
    echo "patch_files=$(wc -l < "${root}/PATCHFILES.sha256" | tr -d ' ')"
    echo "prefix_snapshot_sha256=${PATCH_UPDATE_PREFIX_SNAPSHOT_SHA256}"
    echo "status=prepared"
  } > "${PATCH_UPDATE_BACKUP_DIR}/backup-info.txt"
  ok "Transactional PLUMED patch rollback snapshot created: ${PATCH_UPDATE_BACKUP_DIR}"
}

restore_plumed_patch_other_state() {
  local root="${1}" plumed_src="${SRC}/plumed2" target_set after path
  [[ -d "${plumed_src}/.git" ]] || return 0
  target_set="${PATCH_UPDATE_BACKUP_DIR}/target-set.txt"
  after="${PATCH_UPDATE_BACKUP_DIR}/other-dirty-after-build.txt"
  git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null | sed '/^$/d' | sort -u > "${after}.all"
  grep -Fvx -f "${target_set}" "${after}.all" 2>/dev/null > "${after}" || true
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if ! grep -Fxq -- "${path}" "${PATCH_UPDATE_OTHER_DIRTY_LIST}"; then
      git -C "${plumed_src}" restore --source=HEAD --worktree -- "${path}" || return 1
    fi
  done < "${after}"
  if [[ -n "${PATCH_UPDATE_OTHER_ARCHIVE}" && -f "${PATCH_UPDATE_OTHER_ARCHIVE}" ]]; then
    tar -C "${plumed_src}" -xpf "${PATCH_UPDATE_OTHER_ARCHIVE}" || return 1
  fi
  if [[ -f "${PATCH_UPDATE_OTHER_MISSING_LIST}" ]]; then
    while IFS= read -r path; do [[ -z "${path}" ]] || rm -f -- "${plumed_src}/${path}" || return 1; done < "${PATCH_UPDATE_OTHER_MISSING_LIST}"
  fi
  git -C "${plumed_src}" diff --name-only HEAD -- 2>/dev/null | sed '/^$/d' | sort -u > "${after}.all"
  grep -Fvx -f "${target_set}" "${after}.all" 2>/dev/null > "${after}" || true
  cmp -s -- "${PATCH_UPDATE_OTHER_DIRTY_LIST}" "${after}"
}

restore_plumed_patch_targets() {
  local plumed_src="${SRC}/plumed2" path
  while IFS= read -r path; do [[ -z "${path}" ]] || rm -f -- "${plumed_src}/${path}"; done < "${PATCH_UPDATE_TARGET_MISSING_LIST}"
  if [[ -n "${PATCH_UPDATE_TARGET_ARCHIVE}" && -f "${PATCH_UPDATE_TARGET_ARCHIVE}" ]]; then
    tar -C "${plumed_src}" -xpf "${PATCH_UPDATE_TARGET_ARCHIVE}" || return 1
  fi
}

restore_failed_plumed_patch_update() {
  [[ "${PATCH_UPDATE_ACTIVE}" -eq 1 && -n "${PATCH_UPDATE_BACKUP_DIR}" ]] || return 0
  local prefix_snapshot prefix_parent prefix_name restore_stage failed_live current_hash restored=0
  trap - ERR
  set +e
  restore_plumed_patch_targets || warn "Could not fully restore PLUMED patch target files."
  restore_plumed_patch_other_state "${PATCH_UPDATE_BUNDLE}" || warn "Could not fully restore unrelated PLUMED tracked-source state."
  prefix_snapshot="${PATCH_UPDATE_PREFIX_SNAPSHOT}"
  if [[ -f "${prefix_snapshot}" ]]; then
    current_hash="$(sha256_file "${prefix_snapshot}" 2>/dev/null || true)"
    if [[ "${current_hash}" == "${PATCH_UPDATE_PREFIX_SNAPSHOT_SHA256}" ]]; then
      prefix_parent="$(dirname "${PLUMED_ROOT}")"; prefix_name="$(basename "${PLUMED_ROOT}")"
      restore_stage="${INSTALL_ROOT}/.plumed-patch-restore-${PATCH_UPDATE_ID}-$$"
      failed_live="${INSTALL_ROOT}/.plumed-patch-failed-${PATCH_UPDATE_ID}-$$"
      rm -rf -- "${restore_stage}" "${failed_live}"; mkdir -p "${restore_stage}"
      if tar -C "${restore_stage}" -xpf "${prefix_snapshot}" && [[ -d "${restore_stage}/${prefix_name}" ]]; then
        if [[ -e "${PLUMED_ROOT}" || -L "${PLUMED_ROOT}" ]]; then mv -- "${PLUMED_ROOT}" "${failed_live}"; fi
        if mv -- "${restore_stage}/${prefix_name}" "${PLUMED_ROOT}"; then restored=1; rm -rf -- "${failed_live}" "${restore_stage}"; else [[ ! -e "${failed_live}" ]] || mv -- "${failed_live}" "${PLUMED_ROOT}"; fi
      fi
    fi
  fi
  echo "status=failed-restored" >> "${PATCH_UPDATE_BACKUP_DIR}/backup-info.txt"
  echo "rollback_complete_prefix=${restored}" >> "${PATCH_UPDATE_BACKUP_DIR}/backup-info.txt"
  cleanup_prepared_plumed_patch_bundle
  set -e
  PATCH_UPDATE_ACTIVE=0
  warn "PLUMED patch update failed and rollback was attempted from ${PATCH_UPDATE_BACKUP_DIR}."
}

handle_failed_plumed_patch_update() {
  local rc="${1:-1}" note="${2:-operation failed}" line="${3:-unknown}"
  [[ "${PATCH_UPDATE_ACTIVE:-0}" -eq 1 ]] || return 0
  [[ "${PATCH_UPDATE_FAILURE_HANDLED:-0}" -eq 0 ]] || return 0
  PATCH_UPDATE_FAILURE_HANDLED=1
  restore_failed_plumed_patch_update
  set +e
  append_plumed_patch_update_history "failed-restored" "${note} at line ${line} with exit ${rc}"
  set -e
}

append_plumed_patch_update_history() {
  local status="${1}" note="${2:-}" history="${INSTALL_ROOT}/plumed_patch_updates/history.jsonl"
  mkdir -p "$(dirname "${history}")"
  printf '{"timestamp_utc":%s,"status":%s,"update_id":%s,"plumed_commit":%s,"manifest_sha256":%s,"backup":%s,"note":%s}\n' \
    "$(json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$(json_string "${status}")" \
    "$(json_string "${PATCH_UPDATE_ID}")" \
    "$(json_string "${PATCH_UPDATE_COMMIT}")" \
    "$(json_string "${PATCH_UPDATE_MANIFEST_SHA256}")" \
    "$(json_string "${PATCH_UPDATE_BACKUP_DIR}")" \
    "$(json_string "${note}")" >> "${history}"
}

validate_built_plumed_patch() {
  local root="${1}" plumed_src="${2}" build_kernel build_plumed build_libdir info_out
  build_kernel="$(plumed_build_kernel_path "${plumed_src}")" || die "No build-tree PLUMED kernel found after patch build."
  assert_no_missing_libs "${build_kernel}" "Build-tree PLUMED kernel"
  if grep -qE '  plumed2/src/isdb/SAXS\.cpp$' "${root}/PATCHFILES.sha256"; then
    build_plumed="$(plumed_build_executable_path "${plumed_src}")" || die "No build-tree plumed executable found."
    build_libdir="${plumed_src}/src/lib"
    info_out="${PATCH_UPDATE_BACKUP_DIR}/plumed-manual-build-tree.txt"
    env -u PLUMED_ROOT -u PLUMED_PREFIX -u PLUMED_KERNEL -u PLUMED_INSTALL_PREFIX LD_LIBRARY_PATH="${build_libdir}:${LD_LIBRARY_PATH:-}" PLUMED_PREPEND_PATH="${build_libdir}" "${build_plumed}" --no-mpi manual --action SAXS > "${info_out}" 2>&1 || die "Build-tree SAXS action validation failed."
    grep -q 'SAXS' "${info_out}" || die "Build-tree PLUMED does not expose SAXS after patch build."
  fi
  ok "Build-tree PLUMED patch validation passed."
}

validate_installed_plumed_patch() {
  local root="${1}" info_out
  [[ -f "${PLUMED_KERNEL}" ]] || die "Installed PLUMED kernel missing after patch install."
  assert_no_missing_libs "${PLUMED_KERNEL}" "Installed PLUMED kernel"
  env PLUMED_PREFIX="${PLUMED_ROOT}" PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" PLUMED_KERNEL="${PLUMED_KERNEL}" "${PLUMED_ROOT}/bin/plumed" --is-installed
  if grep -qE '  plumed2/src/isdb/SAXS\.cpp$' "${root}/PATCHFILES.sha256"; then
    info_out="${PATCH_UPDATE_BACKUP_DIR}/plumed-manual-installed.txt"
    env PLUMED_PREFIX="${PLUMED_ROOT}" PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" PLUMED_KERNEL="${PLUMED_KERNEL}" "${PLUMED_ROOT}/bin/plumed" --no-mpi manual --action SAXS > "${info_out}" 2>&1 || die "Installed SAXS action validation failed."
    grep -q 'SAXS' "${info_out}" || die "Installed PLUMED does not expose SAXS after patch install."
  fi
  ok "Installed PLUMED patch validation passed."
}

print_plumed_patch_update_plan() {
  local root="${1}" commit="${2}" linkage="${3}" count
  count="$(wc -l < "${root}/PATCHFILES.sha256" | tr -d ' ')"
  section "PLUMED manifest patch update plan"
  printf '  %-24s : %s\n' "Install root" "${INSTALL_ROOT}"
  printf '  %-24s : %s\n' "PLUMED source" "${SRC}/plumed2"
  printf '  %-24s : %s\n' "PLUMED commit" "${commit}"
  printf '  %-24s : %s\n' "Patch files" "${count}"
  printf '  %-24s : %s\n' "Manifest SHA-256" "${PATCH_UPDATE_MANIFEST_SHA256}"
  printf '  %-24s : %s\n' "GROMACS linkage" "${linkage}"
  printf '  %-24s : %s\n' "Parallel jobs" "${NPROC}"
  printf '  %-24s : %s\n' "PLUMED installcheck" "$([[ "${RUN_INSTALLCHECK}" -eq 1 ]] && echo enabled || echo skipped)"
  printf '  %-24s : %s\n' "Rollback scope" "all patch targets + unrelated tracked state + complete PLUMED prefix"
}

run_plumed_patch_update() {
  local plumed_src linkage gmx_bin="" gmx_hash_before="" gmx_hash_after="" canonical current_recorded=""
  CURRENT_OPERATION="update-plumed-patch"
  [[ -d "${INSTALL_ROOT}" ]] || die "Existing install root not found: ${INSTALL_ROOT}"
  load_persisted_install_profile
  resolve_paths
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/plumed_patch_update_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    command -v flock >/dev/null 2>&1 || die "flock is required for safe PLUMED patch updates."
    exec 9>"${INSTALL_ROOT}/.plumed-patch-update.lock"
    flock -n 9 || die "Another PLUMED patch update appears to be running for ${INSTALL_ROOT}."
  fi
  setup_saxs_update_environment
  ensure_plumed_update_worktree
  plumed_src="${SRC}/plumed2"
  prepare_plumed_patch_update_candidate
  validate_plumed_patch_update_install "${PATCH_UPDATE_BUNDLE}"
  inspect_saxs_update_python "${plumed_src}"
  PATCH_UPDATE_COMMIT="$(git -C "${plumed_src}" rev-parse HEAD)"
  linkage="$(detect_gromacs_plumed_linkage)"
  print_plumed_patch_update_plan "${PATCH_UPDATE_BUNDLE}" "${PATCH_UPDATE_COMMIT}" "${linkage}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then cleanup_prepared_plumed_patch_bundle; info "Dry run complete; no files were changed."; return 0; fi
  current_recorded="$(head -n1 "${INSTALL_ROOT}/.installer_plumed_patch_manifest_sha256" 2>/dev/null || true)"
  local current_kernel_hash="$(sha256_file "${PLUMED_KERNEL}" 2>/dev/null || true)"
  if [[ "${FORCE}" -eq 0 && "${current_recorded}" == "${PATCH_UPDATE_MANIFEST_SHA256}" ]] \
     && plumed_patch_tree_matches "${PATCH_UPDATE_BUNDLE}" "${plumed_src}" \
     && plumed_patch_installed_state_matches "${PATCH_UPDATE_MANIFEST_SHA256}" "${current_kernel_hash}" "${PATCH_UPDATE_COMMIT}"; then
    info "Patch manifest, retained targets, and installed kernel state already match; nothing was rebuilt."
    cleanup_prepared_plumed_patch_bundle
    persist_postbuild_provenance
    write_installation_reports "plumed-patch-update-noop"
    return 0
  fi
  if [[ -x "${GMX_ROOT}/bin/gmx_mpi" ]]; then gmx_bin="${GMX_ROOT}/bin/gmx_mpi"; elif [[ -x "${GMX_ROOT}/bin/gmx" ]]; then gmx_bin="${GMX_ROOT}/bin/gmx"; fi
  [[ -z "${gmx_bin}" ]] || gmx_hash_before="$(sha256_file "${gmx_bin}")"
  prepare_plumed_patch_update_backup "${PATCH_UPDATE_BUNDLE}"
  PATCH_UPDATE_ACTIVE=1
  ensure_saxs_update_python_build_module
  reconcile_removed_plumed_patch_targets "${PATCH_UPDATE_OLD_BUNDLE}" "${PATCH_UPDATE_BUNDLE}" "${plumed_src}"
  apply_plumed_patch_bundle_root_to_tree "${PATCH_UPDATE_BUNDLE}" "${plumed_src}"
  verify_removed_plumed_patch_targets_reconciled "${PATCH_UPDATE_OLD_BUNDLE}" "${PATCH_UPDATE_BUNDLE}" "${plumed_src}" || die "Obsolete targets from the previous PLUMED patch bundle were not reconciled correctly."
  cd "${plumed_src}"
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make -B -j"${NPROC}"
  plumed_patch_tree_matches "${PATCH_UPDATE_BUNDLE}" "${plumed_src}" || die "PLUMED patch targets changed during the build."
  verify_removed_plumed_patch_targets_reconciled "${PATCH_UPDATE_OLD_BUNDLE}" "${PATCH_UPDATE_BUNDLE}" "${plumed_src}" || die "Obsolete PLUMED patch targets reappeared during the build."
  validate_built_plumed_patch "${PATCH_UPDATE_BUNDLE}" "${plumed_src}"
  env -u PLUMED_ROOT -u PLUMED_INSTALL_PREFIX -u PLUMED_KERNEL -u PLUMED_PREFIX make install
  validate_installed_plumed_patch "${PATCH_UPDATE_BUNDLE}"
  if [[ "${RUN_INSTALLCHECK}" -eq 1 ]]; then
    env PATH="${PLUMED_ROOT}/bin:${PATH}" PLUMED_PREFIX="${PLUMED_ROOT}" PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" PLUMED_KERNEL="${PLUMED_KERNEL}" make installcheck
    ok "PLUMED installcheck completed."
  fi
  restore_plumed_patch_other_state "${PATCH_UPDATE_BUNDLE}" || die "Could not restore unrelated retained PLUMED tracked-source state."
  if [[ -n "${gmx_bin}" ]]; then
    gmx_hash_after="$(sha256_file "${gmx_bin}")"
    [[ "${gmx_hash_before}" == "${gmx_hash_after}" ]] || die "Installed GROMACS changed during PLUMED patch update."
    ok "GROMACS executable was not modified (${gmx_hash_after})."
  fi
  canonical="$(plumed_patch_canonical_dir)"
  if [[ "$(abspath "${PATCH_UPDATE_BUNDLE}")" != "$(abspath "${canonical}")" ]]; then copy_plumed_patch_bundle_atomic "${PATCH_UPDATE_BUNDLE}"; fi
  cleanup_prepared_plumed_patch_bundle
  printf '%s\n' "${PATCH_UPDATE_MANIFEST_SHA256}" > "${INSTALL_ROOT}/.installer_plumed_patch_manifest_sha256"
  printf '%s\n' "$(wc -l < "${canonical}/PATCHFILES.sha256" | tr -d ' ')" > "${INSTALL_ROOT}/.installer_plumed_patch_file_count"
  local final_kernel_hash="$(sha256_file "${PLUMED_KERNEL}")"
  write_plumed_patch_installed_state "${PATCH_UPDATE_MANIFEST_SHA256}" "${final_kernel_hash}" "${PATCH_UPDATE_COMMIT}" \
    || warn "Could not write the PLUMED patch installed-state marker; a repeated update will rebuild safely."
  echo "status=success" >> "${PATCH_UPDATE_BACKUP_DIR}/backup-info.txt"
  PATCH_UPDATE_ACTIVE=0
  persist_postbuild_provenance
  append_plumed_patch_update_history "success" "manifest-driven PLUMED patch update; GROMACS unchanged"
  write_installation_reports "plumed-patch-update"
  section "PLUMED patch update completed successfully"
  echo "  PLUMED commit       : ${PATCH_UPDATE_COMMIT}"
  echo "  Manifest SHA-256    : ${PATCH_UPDATE_MANIFEST_SHA256}"
  echo "  Patch files         : $(wc -l < "${canonical}/PATCHFILES.sha256" | tr -d ' ')"
  echo "  GROMACS             : unchanged"
  echo "  Backup              : ${PATCH_UPDATE_BACKUP_DIR}"
  echo "  Log                 : ${LOG_FILE}"
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

  [[ -d "${INSTALL_ROOT}" ]] || die "Existing install root not found: ${INSTALL_ROOT}"
  load_persisted_install_profile
  resolve_paths
  if [[ -f "${INSTALL_ROOT}/plumed_patch_bundle/current/PATCHFILES.sha256" ]]; then
    die "This installation is managed by a manifest-driven PLUMED patch bundle. Use --update-plumed-patch with an updated bundle instead of --update-saxs."
  fi
  plumed_src="${SRC}/plumed2"
  SAXS_UPDATE_TARGET="${plumed_src}/src/isdb/SAXS.cpp"

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
  ensure_plumed_update_worktree
  plumed_src="${SRC}/plumed2"
  SAXS_UPDATE_TARGET="${plumed_src}/src/isdb/SAXS.cpp"
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
      persist_postbuild_provenance
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
  persist_postbuild_provenance \
    || warn "Could not refresh durable workspace/SAXS provenance after the successful update."

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

  local cmd="${1}" out ver
  out="$(${cmd} --version 2>/dev/null | head -n1 || true)"
  ver="$(printf '%s\n' "${out}" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
  printf '%s\n' "${ver}"
}

mpi_cxx_compiler_version_string() {

  local wrapper="${MPI_ROOT}/bin/mpicxx" cmd ver
  if is_gromacs_only || is_cpu_only; then
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

  local ver major reason=""
  if [[ "${GROMACS_VERSION}" == "auto" ]]; then
    ver="$(mpi_cxx_compiler_version_string || true)"
    major="${ver%%.*}"

    if [[ -n "${ver}" && "${major}" =~ ^[0-9]+$ && "${major}" -lt 11 ]]; then
      reason="GCC/G++ ${ver} is older than 11"
    elif is_cuda_backend && ! version_ge "${CUDA_VERSION}" "12.1"; then
      reason="CUDA ${CUDA_VERSION} is older than 12.1"
    fi

    if [[ -n "${reason}" ]]; then
      GROMACS_VERSION="2024.6"
      info "${reason}; selecting GROMACS ${GROMACS_VERSION} fallback."
    else
      GROMACS_VERSION="2025.4"
      if is_cpu_only; then
        if [[ -n "${ver}" ]]; then
          info "Detected GCC/G++ ${ver}; selecting CPU GROMACS ${GROMACS_VERSION}."
        else
          warn "Could not determine compiler version; defaulting CPU profile to GROMACS ${GROMACS_VERSION}."
        fi
      elif [[ -n "${ver}" ]]; then
        info "Detected GCC/G++ ${ver} and CUDA ${CUDA_VERSION}; selecting GROMACS ${GROMACS_VERSION}."
      else
        warn "Could not determine compiler version, but CUDA ${CUDA_VERSION} is >=12.1; defaulting to GROMACS ${GROMACS_VERSION}."
      fi
    fi
  fi

  if [[ "${PREFETCH}" -eq 0 ]] && is_cuda_backend && [[ "${GROMACS_VERSION}" == 2025* ]] && ! version_ge "${CUDA_VERSION}" "12.1"; then
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

gromacs_cmakelists_has_expected_plumed_state() {
  local f="${1}" manage_count manage_line applied_line link_count
  [[ -f "${f}" ]] || return 1
  manage_count="$(grep -Ec '^[[:space:]]*gmx_manage_plumed\(\)[[:space:]]*$' "${f}" || true)"
  manage_line="$(grep -n -m1 -E '^[[:space:]]*gmx_manage_plumed\(\)[[:space:]]*$' "${f}" | cut -d: -f1 || true)"
  applied_line="$(grep -n -m1 -E '^[[:space:]]*add_subdirectory\(applied_forces\)' "${f}" | cut -d: -f1 || true)"
  link_count="$(grep -Ec '^[[:space:]]*target_link_libraries\(libgromacs[[:space:]]+PRIVATE[[:space:]]+plumedgmx\)' "${f}" || true)"
  [[ "${manage_count}" -eq 1 && "${link_count}" -ge 1 && -n "${manage_line}" && -n "${applied_line}" && "${manage_line}" -lt "${applied_line}" ]]
}

inspect_plumed_patch_rejects() {
  local tree="${1}" rej rel
  local -a rejects=() unknown=()
  mapfile -t rejects < <(find "${tree}" -type f -name '*.rej' -print 2>/dev/null | sort)
  if [[ ${#rejects[@]} -eq 0 ]]; then
    PLUMED_PATCH_REJECT_STATUS="none"
    PLUMED_PATCH_REJECT_FILES=""
    printf '%s\n' "${PLUMED_PATCH_REJECT_STATUS}" > "${INSTALL_ROOT}/.plumed_patch_reject_status"
    : > "${INSTALL_ROOT}/.plumed_patch_reject_files"
    return 0
  fi
  for rej in "${rejects[@]}"; do
    rel="${rej#${tree}/}"
    if [[ "${rel}" == "src/gromacs/CMakeLists.txt.rej" ]] \
       && gromacs_cmakelists_has_expected_plumed_state "${tree}/src/gromacs/CMakeLists.txt"; then
      ok "PLUMED patch reject '${rel}' is acceptable: the requested GROMACS CMake PLUMED state is already present."
    else
      unknown+=("${rel}")
    fi
  done
  PLUMED_PATCH_REJECT_FILES="$(printf '%s;' "${rejects[@]#${tree}/}" | sed 's/;$//')"
  if [[ ${#unknown[@]} -gt 0 ]]; then
    PLUMED_PATCH_REJECT_STATUS="unresolved"
    printf '%s\n' "${PLUMED_PATCH_REJECT_STATUS}" > "${INSTALL_ROOT}/.plumed_patch_reject_status"
    printf '%s\n' "${PLUMED_PATCH_REJECT_FILES}" > "${INSTALL_ROOT}/.plumed_patch_reject_files"
    die "PLUMED patch left unresolved reject file(s): ${unknown[*]}. Inspect the patch before compiling GROMACS."
  fi
  PLUMED_PATCH_REJECT_STATUS="accepted-already-applied"
  printf '%s\n' "${PLUMED_PATCH_REJECT_STATUS}" > "${INSTALL_ROOT}/.plumed_patch_reject_status"
  printf '%s\n' "${PLUMED_PATCH_REJECT_FILES}" > "${INSTALL_ROOT}/.plumed_patch_reject_files"
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
  inspect_plumed_patch_rejects "$(pwd -P)"
}

stage_gromacs_only_cpu() {
  resolve_gromacs_selection
  ensure_cmake_for_selected_gromacs
  validate_gromacs_2025_compiler
  section "GROMACS ${GROMACS_VERSION} (standalone CPU + thread-MPI, SIMD=${GMX_SIMD})"

  local gmx_tarball="gromacs-${GROMACS_VERSION}.tar.gz"
  local gmx_src="${SRC}/gromacs-${GROMACS_VERSION}"
  local cc cxx
  cc="${CC:-$(command -v gcc)}"
  cxx="${CXX:-$(command -v g++)}"
  [[ -x "${cc}" ]] || die "C compiler not runnable: ${cc}"
  [[ -x "${cxx}" ]] || die "C++ compiler not runnable: ${cxx}"

  unset PLUMED_ROOT PLUMED_INSTALL_PREFIX PLUMED_PREFIX PLUMED_KERNEL CUDACXX CUDAHOSTCXX CUDA_ROOT 2>/dev/null || true
  export LD_LIBRARY_PATH="${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="${FFTW_ROOT}:${CMAKE_PREFIX_PATH:-}"

  cd "${SRC}"
  download_first_available "${gmx_tarball}" "${GROMACS_URL}" "${GROMACS_FTP_URL}"
  rm -rf "${gmx_src}"
  tar -xf "${gmx_tarball}"
  cd "${gmx_src}"
  rm -rf build && mkdir -p build && cd build

  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${GMX_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${cc}" \
    -DCMAKE_CXX_COMPILER="${cxx}" \
    -DGMX_MPI=OFF \
    -DGMX_THREAD_MPI=ON \
    -DGMX_OPENMP=ON \
    -DGMX_GPU=OFF \
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
    -DCMAKE_PREFIX_PATH="${FFTW_ROOT}" \
    -DCMAKE_BUILD_RPATH="${FFTW_ROOT}/lib" \
-DCMAKE_INSTALL_RPATH="${FFTW_ROOT}/lib" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
    "${cmake_iso[@]}"

  grep -Eq '^GMX_MPI:BOOL=OFF$' CMakeCache.txt || die "CPU GROMACS did not retain GMX_MPI=OFF."
  grep -Eq '^GMX_THREAD_MPI:BOOL=ON$' CMakeCache.txt || die "CPU GROMACS did not retain GMX_THREAD_MPI=ON."
  grep -Eq '^GMX_GPU:STRING=OFF$' CMakeCache.txt || die "CPU GROMACS did not retain GMX_GPU=OFF."

  make -j"${NPROC}"
  make install
  [[ -x "${GMX_ROOT}/bin/gmx" ]] || die "gmx not found after CPU GROMACS install."
  if ldd "${GMX_ROOT}/bin/gmx" 2>/dev/null | grep -Eqi 'libmpi|open-pal|cuda|cudart|cufft|nvidia'; then
    die "CPU GROMACS unexpectedly links external MPI or CUDA/NVIDIA libraries."
  fi
  ok "Standalone CPU/thread-MPI GROMACS installed at ${GMX_ROOT}"
  mark_stage_done gromacs
}

stage_gromacs_only() {
  if is_cpu_only; then
    stage_gromacs_only_cpu
    return 0
  fi
  resolve_gromacs_selection
  ensure_cmake_for_selected_gromacs
  validate_gromacs_2025_compiler
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

stage_gromacs_plumed_cpu() {
  resolve_gromacs_selection
  ensure_cmake_for_selected_gromacs
  validate_gromacs_2025_compiler
  section "GROMACS ${GROMACS_VERSION} (CPU + PLUMED patch + thread-MPI, SIMD=${GMX_SIMD})"

  local plumed_prefix="${INSTALL_ROOT}/plumed"
  local plumed_runtime_root="${plumed_prefix}/lib/plumed"
  local plumed_kernel="${plumed_prefix}/lib/libplumedKernel.so"
  local gmx_tarball="gromacs-${GROMACS_VERSION}.tar.gz"
  local gmx_src="${SRC}/gromacs-${GROMACS_VERSION}"
  local cc cxx
  cc="${CC:-$(command -v gcc)}"
  cxx="${CXX:-$(command -v g++)}"
  [[ -x "${cc}" ]] || die "C compiler not runnable: ${cc}"
  [[ -x "${cxx}" ]] || die "C++ compiler not runnable: ${cxx}"
  [[ -x "${plumed_prefix}/bin/plumed" ]] || die "PLUMED executable not found at ${plumed_prefix}/bin/plumed."
  [[ -f "${plumed_kernel}" ]] || die "PLUMED kernel not found at ${plumed_kernel}."

  export PATH="${plumed_prefix}/bin:${PATH}"
  export LD_LIBRARY_PATH="${plumed_prefix}/lib:${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${plumed_prefix}/lib/pkgconfig:${FFTW_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="${plumed_prefix}:${FFTW_ROOT}:${CMAKE_PREFIX_PATH:-}"
  unset CUDACXX CUDAHOSTCXX CUDA_ROOT 2>/dev/null || true

  cd "${SRC}"
  download_first_available "${gmx_tarball}" "${GROMACS_URL}" "${GROMACS_FTP_URL}"
  rm -rf "${gmx_src}"
  tar -xf "${gmx_tarball}"
  cd "${gmx_src}"
  info "Patching CPU GROMACS with PLUMED engine '${PLUMED_GROMACS_PATCH}'."
  (
    export PLUMED_PREFIX="${plumed_prefix}"
    export PLUMED_ROOT="${plumed_runtime_root}"
    export PLUMED_KERNEL="${plumed_kernel}"
    patch_gromacs_with_plumed "${PLUMED_GROMACS_PATCH}"
  )

  rm -rf build && mkdir -p build && cd build
  mapfile -t cmake_iso < <(cmake_common_isolation_args)
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="${GMX_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${cc}" \
    -DCMAKE_CXX_COMPILER="${cxx}" \
    -DGMX_MPI=OFF \
    -DGMX_THREAD_MPI=ON \
    -DGMX_OPENMP=ON \
    -DGMX_GPU=OFF \
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
    -DCMAKE_PREFIX_PATH="${plumed_prefix};${FFTW_ROOT}" \
    -DCMAKE_BUILD_RPATH="${plumed_prefix}/lib;${FFTW_ROOT}/lib" \
    -DCMAKE_INSTALL_RPATH="${plumed_prefix}/lib;${FFTW_ROOT}/lib" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
    "${cmake_iso[@]}"

  grep -Eq '^GMX_MPI:BOOL=OFF$' CMakeCache.txt || die "CPU PLUMED/GROMACS did not retain GMX_MPI=OFF."
  grep -Eq '^GMX_THREAD_MPI:BOOL=ON$' CMakeCache.txt || die "CPU PLUMED/GROMACS did not retain GMX_THREAD_MPI=ON."
  grep -Eq '^GMX_GPU:STRING=OFF$' CMakeCache.txt || die "CPU PLUMED/GROMACS did not retain GMX_GPU=OFF."

  make -j"${NPROC}"
  make install
  [[ -x "${GMX_ROOT}/bin/gmx" ]] || die "gmx not found after CPU PLUMED-patched GROMACS install."
  if ldd "${GMX_ROOT}/bin/gmx" 2>/dev/null | grep -Eqi 'libmpi|open-pal|cuda|cudart|cufft|nvidia'; then
    die "CPU PLUMED-patched GROMACS unexpectedly links external MPI or CUDA/NVIDIA libraries."
  fi
  if ! env PLUMED_PREFIX="${plumed_prefix}" PLUMED_ROOT="${plumed_runtime_root}" PLUMED_KERNEL="${plumed_kernel}" \
       "${GMX_ROOT}/bin/gmx" mdrun -h 2>&1 | grep -q -- '-plumed'; then
    die "CPU GROMACS mdrun help does not expose the PLUMED option after patching."
  fi
  ok "CPU/thread-MPI PLUMED-patched GROMACS installed at ${GMX_ROOT}"
  mark_stage_done gromacs
}

mpi_include_dirs() {
  [[ -x "${MPI_ROOT}/bin/mpicxx" ]] || return 1
  "${MPI_ROOT}/bin/mpicxx" --showme:incdirs 2>/dev/null \
    | tr ' ' '\n' | sed '/^$/d' | awk '!seen[$0]++'
}

compose_external_mpi_cuda_flags() {
  local flags="" d
  [[ -z "${CUDAFLAGS:-}" ]] || flags+="${CUDAFLAGS} "
  [[ -z "${CMAKE_CUDA_FLAGS:-}" ]] || flags+="${CMAKE_CUDA_FLAGS} "
  while IFS= read -r d; do
    [[ -d "${d}" ]] || continue
    case " ${flags} " in
      *" -I${d} "*) ;;
      *) flags+="-I${d} " ;;
    esac
  done < <(mpi_include_dirs || true)
  if [[ -d "${CUDA_HOME}/include/cccl" ]]; then
    case " ${flags} " in
      *" -I${CUDA_HOME}/include/cccl "*) ;;
      *) flags+="-I${CUDA_HOME}/include/cccl " ;;
    esac
  fi
  printf '%s\n' "${flags% }"
}

cuda_mpi_header_probe() {
  local probe_dir="${LOG_DIR}/cuda_mpi_probe" src obj log d
  local -a inc_args=()
  mkdir -p "${probe_dir}"
  src="${probe_dir}/cuda_mpi_probe.cu"
  obj="${probe_dir}/cuda_mpi_probe.o"
  log="${probe_dir}/cuda_mpi_probe.log"
  cat > "${src}" <<'EOF_CUDA_MPI_PROBE'
#include <mpi.h>
#include <cuda_runtime.h>
__global__ void probe_kernel() {}
int main() { return MPI_SUCCESS == 0 ? 0 : 0; }
EOF_CUDA_MPI_PROBE
  while IFS= read -r d; do
    [[ -d "${d}" ]] && inc_args+=("-I${d}")
  done < <(mpi_include_dirs || true)
  [[ ${#inc_args[@]} -gt 0 ]] || die "Selected MPI did not report any include directories via mpicxx --showme:incdirs."
  if ! "${CUDACXX:-${CUDA_HOME}/bin/nvcc}" -std=c++17 \
       -ccbin "${BUILD_CUDAHOSTCXX:-${BUILD_CXX}}" \
       "${inc_args[@]}" -c "${src}" -o "${obj}" >"${log}" 2>&1; then
    warn "CUDA + MPI header probe failed. Compiler output:"
    tail -n 120 "${log}" || true
    die "CUDA compilation cannot include mpi.h from the selected MPI installation. See ${log}"
  fi
  ok "CUDA + MPI header probe passed."
}

stage_gromacs() {
  if is_cpu_only && ! is_gromacs_only; then
    stage_gromacs_plumed_cpu
    return 0
  fi
  if is_gromacs_only; then
    stage_gromacs_only
    return 0
  fi
  resolve_gromacs_selection
  ensure_cmake_for_selected_gromacs
  validate_gromacs_2025_compiler
  validate_openmpi_compiler_provenance
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

  local gmx_cuda_flags
  local cuda_flag_args=()
  gmx_cuda_flags="$(compose_external_mpi_cuda_flags)"
  if [[ -n "${gmx_cuda_flags}" ]]; then
    cuda_flag_args+=("-DCMAKE_CUDA_FLAGS=${gmx_cuda_flags}")
    info "GROMACS CUDA flags include external-MPI headers: ${gmx_cuda_flags}"
  fi
  cuda_mpi_header_probe

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
    "${cuda_flag_args[@]}" \
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

mpi_run_one() {

  [[ -x "${MPI_ROOT}/bin/mpirun" ]] || return 127
  if command -v timeout >/dev/null 2>&1; then
    timeout "${MPI_RUNTIME_TIMEOUT}" "${MPI_ROOT}/bin/mpirun" -np 1 "$@"
  else
    "${MPI_ROOT}/bin/mpirun" -np 1 "$@"
  fi
}

final_checks() {
  section "Final PLUMED checks"
  command -v plumed >/dev/null 2>&1 || die "plumed not found on PATH after build."

  plumed --no-mpi --is-installed
  if is_cpu_only; then
    if plumed --no-mpi config has mpi >/dev/null 2>&1; then
      die "CPU-only PLUMED unexpectedly reports MPI support."
    else
      ok "CPU-only PLUMED correctly reports no external MPI support."
    fi
  else
    plumed --no-mpi config has mpi >/dev/null 2>&1 \
      || die "PLUMED configuration does not report MPI support."
    plumed --no-mpi config has arrayfire >/dev/null 2>&1 \
      || die "PLUMED configuration does not report ArrayFire support."
    plumed --no-mpi config has arrayfire_cuda >/dev/null 2>&1 \
      || die "PLUMED configuration does not report ArrayFire-CUDA support."
    plumed --no-mpi config module isdb >/dev/null 2>&1 \
      || die "PLUMED configuration does not report the ISDB module."
    ok "PLUMED configuration reports MPI, ArrayFire, ArrayFire-CUDA and ISDB."

    local plumed_mpi_out=""
    if plumed_mpi_out="$(mpi_run_one "${PLUMED_ROOT}/bin/plumed" --has-mpi 2>&1)"; then
      [[ -z "${plumed_mpi_out}" ]] || printf '%s\n' "${plumed_mpi_out}"
      ok "PLUMED MPI runtime check completed through mpirun -np 1."
    else
      [[ -z "${plumed_mpi_out}" ]] || printf '%s\n' "${plumed_mpi_out}" >&2
      warn "PLUMED MPI runtime check did not complete within ${MPI_RUNTIME_TIMEOUT}s or launcher returned an error. Build-time MPI support is present; rerun --finalize-only in the target MPI runtime environment."
    fi

    local saxs_manual="${LOG_DIR}/plumed-manual-saxs-final.txt"
    if plumed --no-mpi manual --action SAXS >"${saxs_manual}" 2>&1 \
       && grep -q 'SAXS' "${saxs_manual}"; then
      ok "Installed PLUMED recognizes the SAXS action."
    else
      tail -n 80 "${saxs_manual}" 2>/dev/null || true
      die "Installed PLUMED SAXS action validation failed."
    fi
  fi
  plumed --no-mpi --has-dlopen >/dev/null 2>&1 || true

  [[ -f "${PLUMED_KERNEL}" ]] || die "PLUMED kernel not found: ${PLUMED_KERNEL}"
  info "PLUMED kernel link check:"
  assert_no_missing_libs "${PLUMED_KERNEL}" "PLUMED kernel"
  if is_cpu_only && ldd "${PLUMED_KERNEL}" 2>/dev/null | grep -Eqi 'libmpi|open-pal|arrayfire|afcuda|cuda|cudart|cufft|nvidia'; then
    die "CPU-only PLUMED kernel unexpectedly links MPI/ArrayFire/CUDA/NVIDIA libraries."
  fi
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

  if is_cpu_only; then
    local version_out
    if is_gromacs_only; then
      version_out="$({
        export GROMACS_DIR="${GMX_ROOT}"
        export GMXBIN="${GMX_ROOT}/bin"
        export GMXLDLIB="${GMX_ROOT}/lib"
        export GMXMAN="${GMX_ROOT}/share/man"
        export GMXDATA="${GMX_ROOT}/share/gromacs"
        export PATH="${GMX_ROOT}/bin:${PATH}"
        export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
        unset PLUMED_ROOT PLUMED_PREFIX PLUMED_KERNEL AF_ROOT MPI_ROOT CUDA_HOME CUDA_ROOT CUDACXX CUDAHOSTCXX 2>/dev/null || true
        "${gmx_bin}" --version
      } 2>&1)"
    else
      local plumed_prefix="${INSTALL_ROOT}/plumed"
      version_out="$({
        export GROMACS_DIR="${GMX_ROOT}"
        export GMXBIN="${GMX_ROOT}/bin"
        export GMXLDLIB="${GMX_ROOT}/lib"
        export GMXMAN="${GMX_ROOT}/share/man"
        export GMXDATA="${GMX_ROOT}/share/gromacs"
        export PATH="${GMX_ROOT}/bin:${plumed_prefix}/bin:${PATH}"
        export LD_LIBRARY_PATH="${GMX_ROOT}/lib:${GMX_ROOT}/lib64:${plumed_prefix}/lib:${FFTW_ROOT}/lib:${LD_LIBRARY_PATH:-}"
        export PLUMED_PREFIX="${plumed_prefix}"
        export PLUMED_ROOT="${PLUMED_PREFIX}/lib/plumed"
        export PLUMED_KERNEL="${PLUMED_PREFIX}/lib/libplumedKernel.so"
        unset AF_ROOT MPI_ROOT CUDA_HOME CUDA_ROOT CUDACXX CUDAHOSTCXX 2>/dev/null || true
        "${gmx_bin}" --version
      } 2>&1)"
    fi
    printf '%s
' "${version_out}" | grep -Ei "GROMACS version|MPI library|OpenMP support|GPU support|CUDA" || true
    if ! grep -Eqi 'MPI library:[[:space:]]*thread_mpi|thread-MPI' <<<"${version_out}"; then
      die "CPU GROMACS does not report the expected thread-MPI runtime."
    fi
    if ldd "${gmx_bin}" 2>/dev/null | grep -Eqi 'libmpi|open-pal|cuda|cudart|cufft|nvidia'; then
      die "CPU gmx unexpectedly links external MPI or CUDA/NVIDIA libraries."
    fi
    if ! is_gromacs_only; then
      local plumed_prefix="${INSTALL_ROOT}/plumed"
      if ! env PLUMED_PREFIX="${plumed_prefix}" \
               PLUMED_ROOT="${plumed_prefix}/lib/plumed" \
               PLUMED_KERNEL="${plumed_prefix}/lib/libplumedKernel.so" \
               "${gmx_bin}" mdrun -h 2>&1 | grep -q -- '-plumed'; then
        die "CPU PLUMED-patched GROMACS does not expose the -plumed mdrun option."
      fi
      ok "CPU PLUMED-patched GROMACS runtime check completed (thread-MPI, no CUDA)."
    else
      ok "CPU standalone GROMACS runtime check completed (thread-MPI, no CUDA)."
    fi
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
    printf '%s
' "${version_out}" | grep -Ei "GROMACS version|MPI library|OpenMP support|GPU support|CUDA" || true
    if ! grep -Eqi 'MPI library:[[:space:]]*thread_mpi|thread-MPI' <<<"${version_out}"; then
      die "Standalone GROMACS does not report the expected thread-MPI runtime."
    fi
    if ldd "${gmx_bin}" 2>/dev/null | grep -Eq 'libmpi\.so|libopen-pal\.so'; then
      die "Standalone gmx unexpectedly links an external MPI library."
    fi
    ok "GROMACS runtime check completed. Use: gmx mdrun -ntmpi <ranks> -ntomp <threads>."
    return 0
  fi

  local plumed_prefix="${INSTALL_ROOT}/plumed" version_out="" help_out="${LOG_DIR}/gmx-mdrun-help-final.txt"
  if version_out="$({
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
    mpi_run_one "${gmx_bin}" --version
  } 2>&1)"; then
    printf '%s\n' "${version_out}" | grep -Ei "GROMACS version|MPI|GPU|CUDA|PLUMED" || true
    ok "GROMACS MPI runtime/version check completed through mpirun -np 1."
  else
    printf '%s\n' "${version_out}" >&2
    warn "GROMACS MPI runtime/version check did not complete within ${MPI_RUNTIME_TIMEOUT}s or launcher returned an error. The installed files are retained; rerun --finalize-only in the target MPI runtime environment."
  fi

  if mpi_run_one "${gmx_bin}" mdrun -h >"${help_out}" 2>&1; then
    if grep -q -- '-plumed' "${help_out}"; then
      ok "GROMACS mdrun exposes the PLUMED option through the MPI launcher."
    else
      tail -n 80 "${help_out}" 2>/dev/null || true
      die "GROMACS mdrun help completed but did not expose -plumed; the PLUMED patch is not usable."
    fi
  else
    warn "MPI-launched GROMACS mdrun help check did not complete; inspect ${help_out} and rerun --finalize-only when the site MPI runtime is available."
  fi
  ok "GROMACS installation checks completed. Use: gmx_mpi mdrun -plumed plumed.dat"
}

postflight_stack_checks() {
  section "Post-flight stack sanity checks"
  local failures=0
  _pf_ok_file() { if [[ -e "$1" ]]; then ok "$2"; else warn "$2 missing: $1"; failures=$((failures + 1)); fi; }
  _pf_ok_exe()  { if [[ -x "$1" ]]; then ok "$2"; else warn "$2 missing/not executable: $1"; failures=$((failures + 1)); fi; }

  if stage_done fftw || [[ -e "${FFTW_ROOT}/lib/libfftw3f.so" ]]; then
    _pf_ok_file "${FFTW_ROOT}/lib/libfftw3f.so" "FFTW single-precision library"
  fi

  if is_cpu_only; then
    local gmx_bin="${GMX_ROOT}/bin/gmx"
    if is_full_stack; then
      _pf_ok_exe "${PLUMED_ROOT}/bin/plumed" "CPU PLUMED executable"
      _pf_ok_file "${PLUMED_ROOT}/lib/libplumedKernel.so" "CPU PLUMED kernel"
      if [[ -f "${PLUMED_ROOT}/lib/libplumedKernel.so" ]] \
         && ldd "${PLUMED_ROOT}/lib/libplumedKernel.so" 2>/dev/null | grep -Eqi 'libmpi|open-pal|arrayfire|afcuda|cuda|cudart|cufft|nvidia'; then
        warn "CPU PLUMED kernel unexpectedly links GPU/MPI libraries"; failures=$((failures + 1))
      else
        ok "CPU PLUMED kernel has no external MPI/CUDA/ArrayFire linkage"
      fi
    fi
    _pf_ok_exe "${gmx_bin}" "CPU GROMACS thread-MPI executable"
    if [[ -x "${gmx_bin}" ]]; then
      assert_no_missing_libs "${gmx_bin}" "GROMACS executable"
      if ldd "${gmx_bin}" 2>/dev/null | grep -Eqi 'libmpi|open-pal|cuda|cudart|cufft|nvidia'; then
        warn "CPU gmx unexpectedly links external MPI/CUDA libraries"; failures=$((failures + 1))
      else
        ok "CPU gmx has no external MPI/CUDA linkage"
      fi
      local version_out
      version_out="$("${gmx_bin}" --version 2>&1 || true)"
      if grep -Eqi 'MPI library:[[:space:]]*thread_mpi|thread-MPI' <<<"${version_out}"; then
        ok "CPU GROMACS reports thread-MPI"
      else
        warn "CPU GROMACS version output did not confirm thread-MPI"; failures=$((failures + 1))
      fi
      if is_full_stack; then
        if env PLUMED_PREFIX="${PLUMED_ROOT}" PLUMED_ROOT="${PLUMED_ROOT}/lib/plumed" PLUMED_KERNEL="${PLUMED_ROOT}/lib/libplumedKernel.so" \
             "${gmx_bin}" mdrun -h 2>&1 | grep -q -- '-plumed'; then
          ok "CPU GROMACS exposes the PLUMED mdrun option"
        else
          warn "CPU GROMACS does not expose the PLUMED mdrun option"; failures=$((failures + 1))
        fi
      fi
    fi
  elif is_gromacs_only; then
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
      printf '%s
' "${version_out}" | grep -Ei 'GROMACS version|MPI library|OpenMP support|GPU support|CUDA' || true
    fi
  else
    if stage_done openmpi || [[ -x "${MPI_ROOT}/bin/mpicc" ]]; then _pf_ok_exe "${MPI_ROOT}/bin/mpicc" "MPI mpicc"; fi
    local af_pf_lib=""
    if [[ -e "${AF_ROOT}/lib/libafcuda.so" ]]; then
      af_pf_lib="${AF_ROOT}/lib/libafcuda.so"
    elif [[ -e "${AF_ROOT}/lib64/libafcuda.so" ]]; then
      af_pf_lib="${AF_ROOT}/lib64/libafcuda.so"
    else
      af_pf_lib="$(find "${AF_ROOT}" -maxdepth 3 -name 'libafcuda.so*' -print 2>/dev/null | sort | head -n1 || true)"
    fi
    if stage_done arrayfire || [[ -n "${af_pf_lib}" ]]; then
      if [[ -n "${af_pf_lib}" ]]; then _pf_ok_file "${af_pf_lib}" "ArrayFire CUDA library"; else warn "ArrayFire CUDA library missing under ${AF_ROOT}/lib or ${AF_ROOT}/lib64"; failures=$((failures + 1)); fi
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

  if [[ "${failures}" -gt 0 ]]; then warn "Post-flight found ${failures} missing or inconsistent expected item(s)."; else ok "Post-flight checks completed."; fi
}

generate_activate_script() {
  local out="${INSTALL_ROOT}/activate.sh"
  local cmake_activation_block=""

  if [[ "${SPLIT_LAYOUT}" -eq 0 && -n "${CMAKE_ROOT:-}" && -x "${CMAKE_ROOT}/bin/cmake" ]]; then
    cmake_activation_block="export CMAKE_ROOT=\"${CMAKE_ROOT}\"
export PATH=\"\${CMAKE_ROOT}/bin:\${PATH}\""
  fi

  if is_cpu_only; then
    if is_gromacs_only; then
      cat > "${out}" <<EOF

${cmake_activation_block}
export FFTW_ROOT="${FFTW_ROOT}"
export GMX_ROOT="${GMX_ROOT}"

unset CUDA_HOME CUDA_ROOT CUDACXX CUDAHOSTCXX PLUMED_PREFIX PLUMED_ROOT PLUMED_KERNEL AF_ROOT MPI_ROOT BOOST_ROOT FMT_ROOT SPDLOG_ROOT 2>/dev/null || true

export GROMACS_DIR="\${GMX_ROOT}"
export GMXBIN="\${GMX_ROOT}/bin"
export GMXLDLIB="\${GMX_ROOT}/lib"
export GMXMAN="\${GMX_ROOT}/share/man"
export GMXDATA="\${GMX_ROOT}/share/gromacs"
export PATH="\${GMX_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GMX_ROOT}/lib:\${GMX_ROOT}/lib64:\${FFTW_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\${GMX_ROOT}/lib/pkgconfig:\${GMX_ROOT}/lib64/pkgconfig:\${FFTW_ROOT}/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="\${GMX_ROOT}:\${FFTW_ROOT}:\${CMAKE_PREFIX_PATH:-}"

unset GMX_GPU_DD_COMMS GMX_GPU_PME_PP_COMMS GMX_FORCE_UPDATE_DEFAULT_GPU GMX_ENABLE_DIRECT_GPU_COMM GMX_DISABLE_DIRECT_GPU_COMM 2>/dev/null || true

echo "Activated '${NAME}': CPU-only standalone thread-MPI GROMACS, GMX_ROOT=\${GMX_ROOT}"
echo "Use 'gmx' (not gmx_mpi). This build has no GPU/CUDA support."
EOF
    else
      cat > "${out}" <<EOF

${cmake_activation_block}
export FFTW_ROOT="${FFTW_ROOT}"
export GMX_ROOT="${GMX_ROOT}"
export PLUMED_PREFIX="${PLUMED_ROOT}"
export PLUMED_ROOT="\${PLUMED_PREFIX}/lib/plumed"
export PLUMED_KERNEL="\${PLUMED_PREFIX}/lib/libplumedKernel.so"

unset CUDA_HOME CUDA_ROOT CUDACXX CUDAHOSTCXX AF_ROOT MPI_ROOT BOOST_ROOT FMT_ROOT SPDLOG_ROOT 2>/dev/null || true

export GROMACS_DIR="\${GMX_ROOT}"
export GMXBIN="\${GMX_ROOT}/bin"
export GMXLDLIB="\${GMX_ROOT}/lib"
export GMXMAN="\${GMX_ROOT}/share/man"
export GMXDATA="\${GMX_ROOT}/share/gromacs"
export PATH="\${GMX_ROOT}/bin:\${PLUMED_PREFIX}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GMX_ROOT}/lib:\${GMX_ROOT}/lib64:\${PLUMED_PREFIX}/lib:\${FFTW_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\${GMX_ROOT}/lib/pkgconfig:\${GMX_ROOT}/lib64/pkgconfig:\${PLUMED_PREFIX}/lib/pkgconfig:\${FFTW_ROOT}/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="\${GMX_ROOT}:\${PLUMED_PREFIX}:\${FFTW_ROOT}:\${CMAKE_PREFIX_PATH:-}"

unset GMX_GPU_DD_COMMS GMX_GPU_PME_PP_COMMS GMX_FORCE_UPDATE_DEFAULT_GPU GMX_ENABLE_DIRECT_GPU_COMM GMX_DISABLE_DIRECT_GPU_COMM 2>/dev/null || true

echo "Activated '${NAME}': CPU-only PLUMED + thread-MPI GROMACS, GMX_ROOT=\${GMX_ROOT}, PLUMED_PREFIX=\${PLUMED_PREFIX}"
echo "Use 'gmx'. Custom SAXS update support remains intentionally outside this CPU profile."
EOF
    fi
  elif is_gromacs_only; then
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

export CUDA_HOME="${CUDA_HOME}"
export CUDA_ROOT="\${CUDA_HOME}"
export CUDACXX="\${CUDA_HOME}/bin/nvcc"
${cmake_activation_block}
export FFTW_ROOT="${FFTW_ROOT}"
export GMX_ROOT="${GMX_ROOT}"
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
${direct_gpu_block}
echo "Activated '${NAME}': standalone thread-MPI GROMACS, GMX_ROOT=\${GMX_ROOT}, CUDA=\${CUDA_HOME}"
echo "Use 'gmx' (not gmx_mpi). GPU update is automatic when supported; use '-update gpu' to force it for a compatible run."
EOF
  else
    cat > "${out}" <<EOF

export CUDA_HOME="${CUDA_HOME}"
export CUDA_ROOT="\${CUDA_HOME}"
export CUDACXX="\${CUDA_HOME}/bin/nvcc"
${cmake_activation_block}
export MPI_PROVIDER="${MPI_PROVIDER}"
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
echo "Activated '${NAME}': GMX_ROOT=\${GMX_ROOT}, PLUMED_PREFIX=\${PLUMED_PREFIX}, CUDA=\${CUDA_HOME}, MPI=\${MPI_PROVIDER}"
if [[ "\${MPI_PROVIDER}" == "system" ]]; then
  echo "External/system MPI is reused from \${MPI_ROOT}. Load the same site MPI/module environment used for the build if that MPI has transitive runtime dependencies outside its prefix."
fi
EOF
  fi
  chmod +x "${out}"
  printf '%s
' "${out}"
}

write_rc_block() {
  local rcfile="${1}"
  local rc_kind
  if is_cpu_only; then
    rc_kind="CPU/PLUMED"
    is_gromacs_only && rc_kind="CPU/GROMACS-only"
  else
    rc_kind="CUDA/PLUMED"
    is_gromacs_only && rc_kind="CUDA/GROMACS-only"
  fi
  local start="# >>> ${NAME} ${rc_kind} env (managed by ${SCRIPT_NAME}) >>>"
  local end="# <<< ${NAME} ${rc_kind} env <<<"
  touch "${rcfile}"

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

print_config() {
  section "Build configuration"
  printf '  %-22s : %s
' "Script version" "${SCRIPT_VERSION}"
  printf '  %-22s : %s
' "Script dir"     "${SCRIPT_DIR}"
  printf '  %-22s : %s
' "Build mode"     "${BUILD_MODE}"
  printf '  %-22s : %s
' "Accelerator"    "${ACCELERATOR}"
  if is_cpu_only; then
    printf '  %-22s : %s
' "CUDA toolkit"   "not used"
    printf '  %-22s : %s
' "CUDA compiler"  "not applicable"
  elif [[ "${PREFETCH}" -eq 1 && "${CUDA_VERSION}" == "not-required-for-prefetch" ]]; then
    printf '  %-22s : %s
' "CUDA toolkit"   "not required for source prefetch"
    printf '  %-22s : %s
' "CUDA compiler"  "not required for source prefetch"
  else
    printf '  %-22s : %s
' "CUDA toolkit"   "${CUDA_HOME} (v${CUDA_VERSION})"
    printf '  %-22s : %s
' "CUDA compiler"  "${CUDACXX:-${CUDA_HOME}/bin/nvcc}"
  fi
  printf '  %-22s : %s
' "Parent dir"     "${DIR}"
  printf '  %-22s : %s
' "Env name"       "${NAME}"
  printf '  %-22s : %s
' "Install root"   "${INSTALL_ROOT}"
  printf '  %-22s : %s
' "Workspace layout" "$([[ "${SPLIT_LAYOUT}" -eq 1 ]] && echo split || echo legacy)"
  printf '  %-22s : %s
' "Work root"      "${WORK_ROOT}"
  printf '  %-22s : %s
' "Sources"        "${SRC}"
  printf '  %-22s : %s
' "Checkpoints"    "${CKPT_DIR}"
  printf '  %-22s : %s
' "Activation alias" "${ALIAS_NAME}"
  if is_cpu_only; then
    printf '  %-22s : %s
' "CUDA arch(s)"   "not applicable"
  else
    printf '  %-22s : %s
' "CUDA arch(s)"   "${CUDA_ARCHS}"
  fi
  printf '  %-22s : %s
' "Parallel jobs"  "${NPROC}"
  if [[ "${PREFETCH}" -eq 1 || "${OFFLINE}" -eq 1 ]]; then
    printf '  %-22s : %s
' "Source cache" "${SOURCE_CACHE}"
    printf '  %-22s : %s
' "Source mode" "$([[ "${PREFETCH}" -eq 1 ]] && echo prefetch || echo offline)"
  fi
  printf '  %-22s : %s
' "C compiler"      "${BUILD_CC:-${CC:-auto}}"
  printf '  %-22s : %s
' "C++ compiler"    "${BUILD_CXX:-${CXX:-auto}}"
  if is_cuda_backend; then
    printf '  %-22s : %s
' "CUDA host C++" "${BUILD_CUDAHOSTCXX:-${CUDAHOSTCXX:-auto}}"
  fi
  if is_full_stack && ! is_cpu_only; then
    printf '  %-22s : %s
' "MPI provider" "${MPI_PROVIDER}"
    printf '  %-22s : %s
' "MPI prefix" "${MPI_ROOT}"
  elif is_gromacs_only || is_cpu_only; then
    printf '  %-22s : %s
' "MPI mode" "GROMACS thread-MPI"
  fi
  if is_full_stack; then
    printf '  %-22s : %s
' "PLUMED ref"     "${PLUMED_REF}"
    printf '  %-22s : %s
' "PLUMED Python"  "$([[ "${PLUMED_DISABLE_PYTHON}" == "1" ]] && echo disabled || echo enabled)"
    if is_cpu_only; then
      printf '  %-22s : %s
' "PLUMED ArrayFire" "disabled/not built"
      printf '  %-22s : %s
' "SAXS override" "disabled; upstream PLUMED only (CPU bookmark)"
    else
      printf '  %-22s : %s
' "PLUMED patch bundle" "${PLUMED_PATCH_BUNDLE:-not-selected}"
      printf '  %-22s : %s
' "PLUMED patch dir" "$(resolve_plumed_patch_dir 2>/dev/null || printf '%s' "${PLUMED_PATCH_DIR}")"
      printf '  %-22s : %s
' "SAXS override"   "${PLUMED_SAXS_CPP:-auto-detect}"
    fi
  else
    printf '  %-22s : %s
' "PLUMED/ArrayFire" "not built"
  fi
  printf '  %-22s : %s
' "GROMACS version" "${GROMACS_VERSION}"
  if is_full_stack; then
    printf '  %-22s : %s
' "GROMACS patch" "${PLUMED_GROMACS_PATCH}"
    if is_cpu_only; then
      printf '  %-22s : %s
' "GROMACS parallelism" "thread-MPI (GMX_MPI=OFF)"
    else
      printf '  %-22s : %s
' "GROMACS parallelism" "external MPI"
    fi
  else
    printf '  %-22s : %s
' "GROMACS patch" "not used"
    printf '  %-22s : %s
' "GROMACS parallelism" "thread-MPI (GMX_MPI=OFF)"
  fi
  printf '  %-22s : %s
' "GROMACS GPU" "$([[ "${ACCELERATOR}" == cpu ]] && echo OFF || echo CUDA)"
  printf '  %-22s : %s
' "GROMACS SIMD" "${GMX_SIMD}"
  if is_cpu_only; then
    printf '  %-22s : %s
' "CUDA auto repair" "not applicable"
  else
    printf '  %-22s : %s
' "Auto repair"    "${AUTO_REPAIR}"
    printf '  %-22s : %s
' "CUDA shim dir"  "${CUDA_SHIM_DIR}"
  fi
  printf '  %-22s : %s
' "FFTW -march"    "${MARCH}"
  if [[ "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ]]; then
    printf '  %-22s : %s
' "Toolchain parent" "${TOOLCHAIN_DIR}"
    if [[ "${INSTALL_CUDA}" -eq 1 ]]; then printf '  %-22s : %s
' "Private CUDA" "${RESOLVED_CUDA_BOOTSTRAP_VERSION} at ${CUDA_INSTALL_DIR}"; fi
    if [[ "${INSTALL_CMAKE}" -eq 1 ]]; then printf '  %-22s : %s
' "Private CMake" "${CMAKE_BOOTSTRAP_VERSION} at ${CMAKE_INSTALL_DIR}"; fi
  fi
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
  echo "  Build mode : ${BUILD_MODE}"
  echo "  Accelerator: ${ACCELERATOR}"
  echo "  Work root  : ${WORK_ROOT}"
  if [[ -f "${INSTALL_ROOT}/.installer_accelerator" ]]; then
    echo "  Recorded   : $(head -n1 "${INSTALL_ROOT}/.installer_accelerator" 2>/dev/null || true)"
  fi
  local s
  for s in "${STAGES[@]}"; do
    if stage_done "${s}"; then
      printf '  %-10s : %bdone%b   (%s)
' "${s}" "${C_GRN}" "${C_RST}" "$(cat "${CKPT_DIR}/${s}.done" 2>/dev/null)"
    else
      printf '  %-10s : %bpending%b
' "${s}" "${C_YEL}" "${C_RST}"
    fi
  done
  if is_full_stack; then
    local status_src="${SRC}/plumed2" status_saxs status_kernel status_commit
    status_saxs="$(sha256_file "${status_src}/src/isdb/SAXS.cpp" 2>/dev/null || true)"
    status_kernel="$(sha256_file "${INSTALL_ROOT}/plumed/lib/libplumedKernel.so" 2>/dev/null || true)"
    status_commit="$(git -C "${status_src}" rev-parse HEAD 2>/dev/null || true)"
    echo
    echo "  PLUMED/SAXS live state:"
    printf '  %-22s : %s
' "PLUMED commit" "${status_commit:-missing}"
    printf '  %-22s : %s
' "SAXS source SHA-256" "${status_saxs:-missing}"
    printf '  %-22s : %s
' "Kernel SHA-256" "${status_kernel:-missing}"
    if [[ -s "${INSTALL_ROOT}/.installer_plumed_patch_manifest_sha256" ]]; then
      printf '  %-22s : %s
' "Patch manifest SHA" "$(head -n1 "${INSTALL_ROOT}/.installer_plumed_patch_manifest_sha256")"
      printf '  %-22s : %s
' "Patch file count" "$(head -n1 "${INSTALL_ROOT}/.installer_plumed_patch_file_count" 2>/dev/null || true)"
    fi
    if is_cpu_only; then
      printf '  %-22s : %s
' "SAXS update support" "intentionally disabled for CPU profile"
    else
      printf '  %-22s : %s
' "SAXS update history" "${INSTALL_ROOT}/saxs_updates/history.jsonl"
    fi
  fi
  echo
  printf '  %-22s : %s
' "Installation info" "${INSTALL_ROOT}/installation-info.txt"
  printf '  %-22s : %s
' "Manifest" "${INSTALL_ROOT}/installation-manifest.json"
}

finalize_installation() {

  local action="${1:-build}"

  if is_full_stack; then
    if [[ -x "${PLUMED_ROOT}/bin/plumed" ]]; then
      export PATH="${PLUMED_ROOT}/bin:${PATH}"
      export LD_LIBRARY_PATH="${PLUMED_ROOT}/lib:${LD_LIBRARY_PATH:-}"
      final_checks
    else
      warn "PLUMED not installed; skipping final PLUMED checks."
    fi
  else
    info "GROMACS-only mode: PLUMED final checks are not applicable."
  fi

  local final_gmx_bin="${GMX_ROOT}/bin/$(gmx_executable_name)"
  if [[ -x "${final_gmx_bin}" ]]; then
    final_gromacs_checks
  else
    warn "GROMACS not installed; skipping final GROMACS checks."
  fi

  postflight_stack_checks
  validate_split_runtime_independence
  generate_activate_script >/dev/null
  integrate_shell_rc
  persist_postbuild_provenance
  write_installation_reports "${action}"
  print_done_banner
}

print_done_banner() {
  section "Build completed successfully"
  echo "  Install root : ${INSTALL_ROOT}"
  echo "  Work root    : ${WORK_ROOT}"
  echo "  GROMACS      : ${GMX_ROOT}"
  echo "  FFTW         : ${FFTW_ROOT}"
  echo "  Accelerator  : ${ACCELERATOR}"
  if is_cpu_only; then
    echo "  CUDA         : not used"
  else
    echo "  CUDA         : ${CUDA_HOME}"
  fi
  [[ -z "${CMAKE_ROOT:-}" ]] || echo "  CMake        : ${CMAKE_ROOT}"
  if is_full_stack; then
    echo "  PLUMED       : ${PLUMED_ROOT}"
    echo "  PLUMED kernel: ${PLUMED_KERNEL}"
    if is_cpu_only; then
      echo "  ArrayFire    : not built"
      echo "  OpenMPI      : not built (thread-MPI GROMACS)"
      echo "  SAXS update  : custom CPU development/update intentionally unsupported"
    else
      echo "  ArrayFire    : ${AF_ROOT}"
      echo "  fmt          : ${FMT_ROOT}"
      echo "  MPI          : ${MPI_ROOT} (${MPI_PROVIDER})"
    fi
  else
    if is_cpu_only; then
      echo "  Build mode   : CPU GROMACS-only (thread-MPI; no CUDA/PLUMED/ArrayFire/OpenMPI)"
    else
      echo "  Build mode   : GROMACS-only (thread-MPI; no PLUMED/ArrayFire/OpenMPI/Boost/fmt/spdlog)"
    fi
  fi
  echo "  Log file     : ${LOG_FILE}"
  echo
  echo "  Activate this environment with:"
  echo "      source \"${INSTALL_ROOT}/activate.sh\""
  if is_cpu_only; then
    echo "      gmx --version"
    if is_full_stack; then echo "      gmx mdrun -h | grep -i plumed"; fi
  elif is_gromacs_only; then
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

main() {
  setup_colors
  parse_args "$@"
  setup_colors
  configure_build_mode
  validate_args
  resolve_source_cache_path
  prepare_offline_cmake_archive

  if [[ "${UPDATE_PLUMED_PATCH}" -eq 1 ]]; then
    resolve_paths
    run_plumed_patch_update
    return 0
  fi

  if [[ "${UPDATE_SAXS}" -eq 1 ]]; then
    resolve_paths
    run_saxs_update
    return 0
  fi

  if [[ "${FINALIZE_ONLY}" -eq 1 ]]; then

    resolve_paths
    [[ -d "${INSTALL_ROOT}" ]] || die "Existing installation not found for --finalize-only: ${INSTALL_ROOT}"
    load_persisted_install_profile
    resolve_paths
    conda deactivate 2>/dev/null || true
    resolve_build_compilers
    if is_cpu_only; then
      CUDA_HOME=""
      CUDA_VERSION="not-used"
      CUDA_ARCHS="not-applicable"
    else
      detect_cuda
      resolve_cuda_archs
    fi
    if [[ "${GROMACS_VERSION}" == "auto" ]]; then
      local existing_gmx_src=""
      existing_gmx_src="$(find "${SRC}" -maxdepth 1 -type d -name 'gromacs-*' -print 2>/dev/null | sort | head -n1 || true)"
      if [[ -n "${existing_gmx_src}" ]]; then
        GROMACS_VERSION="${existing_gmx_src##*/gromacs-}"
      fi
    fi
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/finalize_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    info "Finalization-only log: ${LOG_FILE}"
    setup_environment
    if is_full_stack && is_cuda_backend && using_system_mpi; then
      validate_system_mpi_selection
    fi
    finalize_installation "finalize-only"
    return 0
  fi

  if [[ "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ]]; then
    resolve_toolchain_bootstrap
    print_toolchain_bootstrap_plan
    toolchain_bootstrap_preflight
  fi

  if is_cpu_only; then
    CUDA_HOME=""
    CUDA_VERSION="not-used"
    CUDA_ARCHS="not-applicable"
  elif [[ "${INSTALL_CUDA}" -eq 1 ]]; then
    CUDA_HOME="${CUDA_INSTALL_DIR}"
    CUDA_VERSION="${RESOLVED_CUDA_BOOTSTRAP_VERSION}"
    CUDA_PATH="${CUDA_INSTALL_DIR}"
    export CUDA_HOME
    export CUDA_ROOT="${CUDA_HOME}"
    export CUDACXX="${CUDA_HOME}/bin/nvcc"
  elif [[ "${PREFETCH}" -eq 1 && "${GROMACS_VERSION}" != "auto" ]]; then

    CUDA_HOME=""
    CUDA_VERSION="not-required-for-prefetch"
    CUDA_ARCHS="not-required-for-prefetch"
    unset CUDA_ROOT CUDACXX 2>/dev/null || true
  else

    detect_cuda
  fi
  resolve_paths

  if [[ "${DO_STATUS}" -eq 1 ]]; then
    if [[ -d "${INSTALL_ROOT}" ]]; then load_persisted_install_profile; resolve_paths; fi
    print_status
    exit 0
  fi

  resolve_build_compilers

  if [[ "${PREFETCH}" -eq 1 ]]; then

    if is_cuda_backend; then CUDA_ARCHS="not-required-for-prefetch"; else CUDA_ARCHS="not-applicable"; fi

    if using_system_mpi; then
      MPI_ROOT="${MPI_PREFIX:-not-required-for-prefetch}"
    else
      MPI_ROOT="${INSTALL_ROOT}/openmpi"
    fi
    resolve_gromacs_selection
    validate_gromacs_2025_compiler
    print_config
    section "Source cache plan"
    source_cache_required_files | sed 's/^/  /'
    if is_full_stack && ! is_cpu_only; then
      printf '  %s\n' "archives/arrayfire-full-${ARRAYFIRE_VERSION}.tar.bz2  (prefetch input/provenance; extern payload is embedded in the composite ArrayFire snapshot)"
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      info "Prefetch dry run complete; no cache files were written."
      return 0
    fi
    prefetch_sources
    return 0
  fi

  if [[ "${OFFLINE}" -eq 1 ]]; then

    setup_environment
    resolve_gromacs_selection
    verify_source_cache
  fi

  check_install_dir
  check_work_dir

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${INSTALL_ROOT}" "${WORK_ROOT}" "${SRC}" "${LOG_DIR}" "${CKPT_DIR}"
    persist_workspace_profile
    LOG_FILE="${LOG_DIR}/build_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    info "Logging to ${LOG_FILE}"

    conda deactivate 2>/dev/null || true

    resolve_build_compilers

    install_private_cmake
    if is_cuda_backend; then
      install_private_cuda
      if [[ "${INSTALL_CUDA}" -eq 1 ]]; then detect_cuda; fi
    fi
    if [[ -n "${CMAKE_ROOT:-}" && -x "${CMAKE_ROOT}/bin/cmake" ]]; then
      export PATH="${CMAKE_ROOT}/bin:${PATH}"
    fi

    if is_cuda_backend; then
      ensure_cuda_development_layout
    fi
  else
    if [[ "${INSTALL_CUDA}" -eq 1 || "${INSTALL_CMAKE}" -eq 1 ]]; then
      info "Dry run: private toolchain directories/downloads will not be created."
    fi
    if is_cuda_backend && [[ "${INSTALL_CUDA}" -eq 0 ]] && needs_cuda_shim; then
      warn "CUDA appears to use a split/non-standard layout. A real run will create a private CUDA shim under the install root."
    fi
  fi

  if is_cuda_backend; then
    resolve_cuda_archs
  else
    CUDA_ARCHS="not-applicable"
  fi

  setup_environment
  if should_run gromacs; then
    resolve_gromacs_selection
    validate_gromacs_2025_compiler
  fi

  print_config

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    preflight
    print_plan
    section "Activation script preview (not written in --dry-run)"
    echo "Would write: ${INSTALL_ROOT}/activate.sh (${BUILD_MODE}, accelerator=${ACCELERATOR})"
    echo "Would add alias '${ALIAS_NAME}' to:"
    [[ "${WRITE_BASHRC}" -eq 1 ]]  && echo "  ${HOME}/.bashrc"
    [[ "${WRITE_ALIASES}" -eq 1 ]] && echo "  ${HOME}/.bash_aliases"
    [[ "${WRITE_BASHRC}" -eq 0 && "${WRITE_ALIASES}" -eq 0 ]] && echo "  (no shell rc requested; use --write-bashrc/--write-aliases)"
    echo
    info "Dry run complete; nothing was built or written."
    exit 0
  fi

  preflight
  setup_environment
  persist_install_profile
  print_plan

  local s
  for s in "${STAGES[@]}"; do
    if should_run "${s}"; then
      rm -f -- "${CKPT_DIR}/${s}.done"
      run_stage "${s}"
    else
      info "Skipping stage '${s}'."
    fi
  done

  finalize_installation "build"
}

on_err() {
  local rc=$?
  echo
  if [[ "${PATCH_UPDATE_ACTIVE:-0}" -eq 1 ]]; then
    handle_failed_plumed_patch_update "${rc}" "operation failed" "${BASH_LINENO[0]}"
  elif [[ "${UPDATE_PLUMED_PATCH:-0}" -eq 1 ]]; then
    cleanup_prepared_plumed_patch_bundle
  elif [[ "${SAXS_UPDATE_ACTIVE:-0}" -eq 1 ]]; then
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
