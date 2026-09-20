"""Runs inside the frozen app before anything else is imported.

PyInstaller's bootloader leaves a few environment details that matter for a long-running,
windowed process: a writable place for the scientific stack's temporary files, and thread
limits that keep a background refresh from monopolising every core on the machine.
"""
import os
import sys

# Keep BLAS from spawning one thread per core; the refresh runs behind a visible window.
for var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
            "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ.setdefault(var, "4")

# joblib writes to a temp folder; on a sandboxed install the default can be read-only.
os.environ.setdefault("JOBLIB_MULTIPROCESSING", "0")

# A frozen GUI app has no stdout on Windows; give libraries something safe to write to.
if sys.stdout is None or sys.stderr is None:
    devnull = open(os.devnull, "w")  # noqa: SIM115
    sys.stdout = sys.stdout or devnull
    sys.stderr = sys.stderr or devnull
