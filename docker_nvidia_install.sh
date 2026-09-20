#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=============================================="
echo " NVIDIA H100 / Azure NVIDIA 595 Repair"
echo " Ubuntu 22.04"
echo " 8x H100 80GB"
echo "=============================================="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

echo
echo "[1/11] Updating APT..."
apt-get update

echo
echo "[2/11] Checking for held NVIDIA packages..."
apt-mark showhold || true

echo
echo "[3/11] Fixing any interrupted package configuration..."
dpkg --configure -a || true
apt-get -f install -y

echo
echo "[4/11] Installing matching NVIDIA 595 SERVER userspace..."

apt-get install -y \
    libnvidia-compute-595-server \
    nvidia-compute-utils-595-server \
    nvidia-utils-595-server \
    libnvidia-decode-595-server \
    libnvidia-encode-595-server \
    libnvidia-fbc1-595-server \
    libnvidia-gl-595-server \
    nvidia-driver-595-server

echo
echo "[5/11] Installing matching NVIDIA kernel components..."

apt-get install -y \
    nvidia-kernel-common-595-server \
    nvidia-kernel-source-595-open \
    nvidia-firmware-595-server-595.91.07

echo
echo "[6/11] Installing NVIDIA Fabric Manager..."

apt-get install -y \
    nvidia-fabricmanager-595

echo
echo "[7/11] Installing CUDA runtime..."

apt-get install -y \
    cuda-cudart-13-2

echo
echo "[8/11] Rebuilding linker cache..."

ldconfig

echo
echo "[9/11] Enabling NVIDIA Fabric Manager..."

systemctl enable nvidia-fabricmanager

echo
echo "Starting NVIDIA Fabric Manager..."

systemctl restart nvidia-fabricmanager

sleep 5

echo
echo "[10/11] Verifying NVIDIA userspace..."

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi is still unavailable."
    exit 1
fi

if ! ldconfig -p | grep -q "libcuda.so.1"; then
    echo "ERROR: libcuda.so.1 is still unavailable."
    exit 1
fi

echo
echo "nvidia-smi:"
nvidia-smi

echo
echo "[11/11] Testing CUDA Driver API..."

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
    print("ERROR: CUDA device enumeration failed.")
    sys.exit(1)

if count.value == 8:
    print("SUCCESS: All 8 H100 GPUs detected.")
else:
    print("WARNING: Expected 8 GPUs, detected", count.value)

PY

echo
echo "=============================================="
echo " NVIDIA GPU LIST"
echo "=============================================="

nvidia-smi -L

echo
echo "=============================================="
echo " DRIVER VERSION"
echo "=============================================="

nvidia-smi --query-gpu=driver_version --format=csv,noheader | sort -u

echo
echo "=============================================="
echo " FABRIC MANAGER"
echo "=============================================="

systemctl --no-pager --full status nvidia-fabricmanager || true

echo
echo "=============================================="
echo " FABRIC STATE"
echo "=============================================="

nvidia-smi -q -i 0 | grep -A12 -i "Fabric" || true

echo
echo "=============================================="
echo " CUDA LIBRARIES"
echo "=============================================="

ldconfig -p | grep -E "libcuda|libcudart" || true

echo
echo "=============================================="
echo " FINAL RESULT"
echo "=============================================="

echo "NVIDIA:"
nvidia-smi -L

echo
echo "CUDA:"
python3 - <<'PY'
import ctypes

cuda = ctypes.CDLL("libcuda.so.1")

cuInit = cuda.cuInit
cuInit.argtypes = [ctypes.c_uint]
cuInit.restype = ctypes.c_int

cuDeviceGetCount = cuda.cuDeviceGetCount
cuDeviceGetCount.argtypes = [ctypes.POINTER(ctypes.c_int)]
cuDeviceGetCount.restype = ctypes.c_int

r = cuInit(0)
count = ctypes.c_int()

if r == 0:
    r = cuDeviceGetCount(ctypes.byref(count))

print("CUDA result:", r)
print("GPU count:", count.value)

PY

echo
echo "=============================================="
echo " SETUP COMPLETE"
echo "=============================================="
