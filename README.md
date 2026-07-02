# AF/PLUMED/GROMACS CUDA build script

`af_plumed_gmx_build.sh` builds a self-contained user-space software stack for PLUMED-driven molecular dynamics with GROMACS, with particular support for the PLUMED ISDB/SAXS module and CUDA acceleration.

The script installs everything under a user-selected directory and does not require root privileges.

## What it builds

The full stack includes:

- OpenMPI
- FFTW, single and double precision
- Boost, without Boost.Python
- fmt
- spdlog
- ArrayFire with CUDA backend
- PLUMED with ISDB/SAXS, FFTW, MPI, and ArrayFire CUDA support
- PLUMED-patched GROMACS

By default, PLUMED's optional Python wrapper is disabled, because it is not required for `plumed driver` or `gmx_mpi mdrun -plumed` and often requires system Python development headers.

## Main features

- Checkpoint-based build: failed or interrupted builds can resume from a specific stage.
- CUDA auto-detection, with optional `--cuda <path>` override.
- Rootless CUDA auto-repair for split CUDA installations, such as systems with `nvcc` in `/usr/bin`, headers in `/usr/include`, and libraries in `/usr/lib/x86_64-linux-gnu`.
- Automatic GROMACS branch selection:
  - GROMACS 2025.4 with `gromacs-2025.0` PLUMED patch when GCC/G++ and CUDA are new enough.
  - GROMACS 2024.6 with `gromacs-2024.3` PLUMED patch as fallback for older CUDA or compiler setups.
- Optional local `SAXS.cpp` replacement before PLUMED is compiled.
- Post-flight sanity checks for MPI, FFTW, ArrayFire, PLUMED, PLUMED patch files, GROMACS, and runtime library resolution.

## Basic usage

```bash
chmod +x af_plumed_gmx_build.sh

./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --arch 80 \
  -j 8 \
  --write-bashrc
```

This installs the stack into:

```text
$HOME/software/plumed_gmx_cuda
```

After the build:

```bash
source "$HOME/software/plumed_gmx_cuda/activate.sh"

which plumed
plumed --version

which gmx_mpi
gmx_mpi --version
```

If `--write-bashrc` was used, a shell alias with the same name as the environment is also added. In a new shell, this should work:

```bash
plumed_gmx_cuda
```

This is equivalent to sourcing `activate.sh`.

## Recommended HPC workflow

Do not run a full build on a login node unless your HPC policy explicitly allows it. Request an interactive compute-node allocation first.

Generic Slurm example:

```bash
salloc \
  -p <partition> \
  --ntasks=1 \
  --cpus-per-task=8 \
  --mem=32G \
  --gres=gpu:1

srun --pty bash
```

Then run the build from the compute-node shell:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --arch 80 \
  -j 8 \
  --write-bashrc
```

Match `-j` to the number of CPU cores requested. On memory-limited nodes, use a slightly smaller value than the requested core count.

## CUDA architecture examples

Use `--arch` to select the GPU compute capability:

| GPU family | Suggested `--arch` |
|---|---:|
| V100 | 70 |
| A100 | 80 |
| RTX 30xx / RTX 3090 | 86 |
| RTX 40xx / L40S | 89 |
| H100 | 90 |

Multiple architectures can be passed as a semicolon-separated string:

```bash
--arch "80;86;90"
```

## Dry run

Use `--dry-run` to check configuration, paths, CUDA detection, preflight tests, and planned stages without building anything:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --arch 80 \
  -j 8 \
  --dry-run
```

## Checkpoint and resume options

The build stages are:

```text
openmpi fftw boost fmt spdlog arrayfire plumed gromacs
```

Check status:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --status
```

Resume from a stage:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --from arrayfire
```

Build only one stage:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --only plumed
```

Force a full rebuild:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --force
```

## PLUMED/SAXS development patching

The script can replace PLUMED's upstream `src/isdb/SAXS.cpp` before compiling PLUMED. This is useful for testing local SAXS changes before pushing them to a repository.

### Default patch folder

By default, the script looks for a `plumed_patch` folder next to the installer script:

```text
project_folder/
├── af_plumed_gmx_build.sh
└── plumed_patch/
    └── SAXS.cpp
```

or:

```text
project_folder/
├── af_plumed_gmx_build.sh
└── plumed_patch/
    └── src/
        └── isdb/
            └── SAXS.cpp
```

During the PLUMED stage, the replacement file is copied over:

```text
<install-root>/src/plumed2/src/isdb/SAXS.cpp
```

This happens immediately after cloning PLUMED and before PLUMED is compiled, so a fresh build only compiles PLUMED once.

### Explicit patch directory

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --plumed-patch-dir /path/to/plumed_patch
```

### Explicit SAXS.cpp file

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --saxs-cpp /path/to/SAXS.cpp
```

`--saxs-cpp` has priority over `--plumed-patch-dir`.

### Rebuild PLUMED after modifying SAXS.cpp

If the stack is already installed and you only changed `SAXS.cpp`, rebuild only PLUMED:

```bash
cp /path/to/new/SAXS.cpp ./plumed_patch/SAXS.cpp

./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --only plumed
```

In most cases, GROMACS does not need to be rebuilt after changing only `SAXS.cpp`, because GROMACS uses the installed PLUMED kernel. Rebuild GROMACS only if you changed the PLUMED-GROMACS interface.

## GROMACS version selection

Default behavior is automatic:

```text
GCC/G++ >= 11 and CUDA >= 12.1  -> GROMACS 2025.4 + gromacs-2025.0 patch
otherwise                       -> GROMACS 2024.6 + gromacs-2024.3 patch
```

You can force a version:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --gromacs-version 2024.6 \
  --gromacs-patch gromacs-2024.3
```

## Useful environment overrides

Component versions can be overridden by exporting variables before running the script:

```bash
export PLUMED_REF=master
export ARRAYFIRE_VERSION=3.9.0
export BOOST_VERSION=1.85.0
```

For heterogeneous HPC clusters, avoid CPU-specific binaries by setting a portable FFTW target:

```bash
export MARCH=x86-64-v3
```

Then run the installer normally.

## Post-install test

Activate the environment:

```bash
source "$HOME/software/plumed_gmx_cuda/activate.sh"
```

Check executables:

```bash
which plumed
plumed --version

which gmx_mpi
gmx_mpi --version
```

Check that GROMACS accepts PLUMED input:

```bash
gmx_mpi mdrun -h | grep -i plumed
```

A production run usually looks like:

```bash
gmx_mpi mdrun -s topol.tpr -plumed plumed.dat
```


## Running PLUMED-driven GROMACS jobs with Slurm

A batch job should load the installed stack by sourcing the generated activation script:

```bash
source /path/to/install-root/activate.sh
```

This is preferred over manually editing `PATH`, `LD_LIBRARY_PATH`, `PKG_CONFIG_PATH`, or sourcing GROMACS `GMXRC`. The activation script already exposes `gmx_mpi`, `plumed`, `PLUMED_KERNEL`, MPI, FFTW, ArrayFire, CUDA, and the required runtime libraries.

### Minimal production command

Inside an activated environment, a typical PLUMED-driven production command is:

```bash
gmx_mpi mdrun \
  -v \
  -deffnm production \
  -pin on \
  -ntomp "$SLURM_CPUS_PER_TASK" \
  -dlb yes \
  -nb gpu \
  -bonded gpu \
  -pme gpu \
  -plumed plumed.dat
```

For restartable jobs, add a checkpoint and a `-maxh` value slightly smaller than the Slurm wall time:

```bash
gmx_mpi mdrun \
  -v \
  -deffnm production \
  -pin on \
  -ntomp "$SLURM_CPUS_PER_TASK" \
  -dlb yes \
  -nb gpu \
  -bonded gpu \
  -pme gpu \
  -plumed plumed.dat \
  -cpi production.cpt \
  -maxh 23.5
```

### Generic Slurm template

```bash
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

set -Eeuo pipefail

ENV_ROOT="${ENV_ROOT:-/path/to/plumed_gmx_cuda}"
DEFFNM="${DEFFNM:-production}"
PLUMED_INPUT="${PLUMED_INPUT:-plumed.dat}"
RESTART_CPT="${RESTART_CPT:-}"
MAXH="${MAXH:-}"
GPU_ID="${GPU_ID:-}"
NOMP="${SLURM_CPUS_PER_TASK:-1}"

source "${ENV_ROOT}/activate.sh"

export AF_DISABLE_GRAPHICS="${AF_DISABLE_GRAPHICS:-1}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-${NOMP}}"
export OMP_PROC_BIND="${OMP_PROC_BIND:-true}"
export OMP_PLACES="${OMP_PLACES:-cores}"

MDRUN="$(command -v gmx_mpi)"

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

"${MDRUN}" "${args[@]}"
```

The repository can also include a copy of this as an example file such as `RUN_plumed_gmx_template.sh`.

### Slurm/GPU tips

- Request GPU resources explicitly, for example `--gres=gpu:1` or the equivalent syntax used by your cluster.
- Under Slurm, `CUDA_VISIBLE_DEVICES` usually remaps allocated GPUs to local IDs. For one GPU, it is often best to omit `-gpu_id` and let GROMACS choose the visible GPU.
- Keep `--cpus-per-task`, `OMP_NUM_THREADS`, and GROMACS `-ntomp` consistent.
- For a single GPU job, `--ntasks=1` with multiple OpenMP threads is a simple and robust starting point.
- For multi-GPU jobs, tune `--ntasks`, `--cpus-per-task`, PME settings, and GPU mapping for your system. Do not blindly reuse a single-GPU script.
- Set `AF_DISABLE_GRAPHICS=1` on headless nodes. The activation script already sets this by default, but it is safe to set it again in the job script.
- Print diagnostics at the start of each job: `hostname`, `CUDA_VISIBLE_DEVICES`, `which gmx_mpi`, `gmx_mpi --version`, and `PLUMED_KERNEL`.
- Prefer `-maxh` values slightly below the Slurm wall time so GROMACS can checkpoint and exit cleanly.

## Troubleshooting

### Missing CUDA headers or libraries

The script tries to repair split CUDA installations automatically by creating a private CUDA shim inside the install root. If this fails, either load a fuller CUDA module or provide extra search paths:

```bash
export CUDA_EXTRA_INCLUDE_DIRS=/path/to/cuda/include
export CUDA_EXTRA_LIB_DIRS=/path/to/cuda/lib64
```

Then rerun from the failed stage.

### PLUMED Python errors

The script disables the optional PLUMED Python wrapper by default. This avoids failures caused by missing `Python.h`, `pip`, or `venv`. The core PLUMED executable, PLUMED kernel, GROMACS integration, and `plumed driver` do not require the Python wrapper.

### ArrayFire compiler issue with GCC 13

The script applies a narrow compatibility patch for ArrayFire 3.9.0 when needed:

```text
::isnan -> std::isnan
```

No manual action is normally required.

### Re-running after failure

Use the checkpoint system. For example, if the build failed in PLUMED:

```bash
./af_plumed_gmx_build.sh \
  --dir "$HOME/software" \
  --name plumed_gmx_cuda \
  --from plumed
```

If the cause was a bad partial build folder, use `--from <stage>` or `--force` as appropriate.

## Files created by the script

Inside the install root, the main directories are:

```text
activate.sh
build_logs/
src/
.checkpoints/
openmpi/
fftw/
boost/
fmt/
spdlog/
arrayfire/
plumed/
gromacs/
```

`activate.sh` is the safest way to load the environment:

```bash
source /path/to/install-root/activate.sh
```

## Notes

- The script is intended to be run as a normal user.
- It does not install system packages.
- It does not modify files outside the chosen install root, except when `--write-bashrc` or `--write-aliases` is requested.
- Heavy builds should be performed on compute nodes or workstations, not on restricted login nodes.
