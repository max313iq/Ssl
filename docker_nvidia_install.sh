#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo " NVIDIA H100 / CUDA 13.2 Setup & Repair"
echo " Ubuntu 22.04"
echo " NVIDIA Driver: 595.91.07"
echo "=============================================="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

echo
echo "[1/9] Updating package lists..."
apt-get update

echo
echo "[2/9] Installing NVIDIA 595 userspace components..."
apt-get install -y \
    libnvidia-compute-595 \
    nvidia-utils-595 \
    nvidia-fabricmanager-595

echo
echo "[3/9] Installing CUDA runtime..."
apt-get install -y cuda-cudart-13-2

echo
echo "[4/9] Rebuilding dynamic linker cache..."
ldconfig

echo
echo "[5/9] Enabling NVIDIA Fabric Manager..."
systemctl enable nvidia-fabricmanager

echo
echo "[6/9] Starting NVIDIA Fabric Manager..."
systemctl restart nvidia-fabricmanager

sleep 3

echo
echo "[7/9] Checking NVIDIA utilities..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi was not installed correctly."
    exit 1
fi

if ! ldconfig -p | grep -q 'libcuda.so.1'; then
    echo "ERROR: libcuda.so.1 is not available to the dynamic linker."
    exit 1
fi

echo
echo "nvidia-smi:"
nvidia-smi -L

echo
echo "[8/9] Checking Fabric Manager..."
systemctl --no-pager --full status nvidia-fabricmanager || true

echo
echo "[9/9] Testing CUDA Driver API..."
python3 - <<'PY'
import ctypes
import sys

print("Loading libcuda.so.1...")

try:
    cuda = ctypes.CDLL("libcuda.so.1")
except OSError as e:
    print("ERROR:", e)
    sys.exit(1)

cuInit = cuda.cuInit
cuInit.argtypes = [ctypes.c_uint]
cuInit.restype = ctypes.c_int

cuDeviceGetCount = cuda.cuDeviceGetCount
cuDeviceGetCount.argtypes = [ctypes.POINTER(ctypes.c_int)]
cuDeviceGetCount.restype = ctypes.c_int

result = cuInit(0)
print("cuInit:", result)

if result != 0:
    print("ERROR: CUDA initialization failed.")
    sys.exit(1)

count = ctypes.c_int()

result = cuDeviceGetCount(ctypes.byref(count))
print("cuDeviceGetCount:", result)
print("GPU count:", count.value)

if result != 0:
    print("ERROR: Could not enumerate CUDA devices.")
    sys.exit(1)

if count.value != 8:
    print("WARNING: Expected 8 GPUs, detected", count.value)
else:
    print("SUCCESS: All 8 H100 GPUs detected.")

PY

echo
echo "=============================================="
echo " NVIDIA/CUDA setup completed"
echo "=============================================="

echo
echo "Driver:"
nvidia-smi --query-gpu=driver_version --format=csv,noheader | sort -u

echo
echo "GPUs:"
nvidia-smi -L

echo
echo "Fabric:"
nvidia-smi -q -i 0 | grep -A12 -i "Fabric" || true

echo
echo "CUDA libraries:"
ldconfig -p | grep -E 'libcuda|libcudart'

echo
echo "Fabric Manager:"
systemctl is-active nvidia-fabricmanager

echo
echo "Done."
