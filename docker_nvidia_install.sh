/bin/bash -c '
set -euo pipefail

cat > /tmp/install_nvidia_h100.sh <<'"'"'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo " NVIDIA H100 Full Driver + CUDA Setup"
echo " Ubuntu 22.04"
echo " NVIDIA 595.91.07"
echo "=============================================="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

echo "[1/10] Updating package lists..."
apt-get update

echo "[2/10] Installing NVIDIA driver and kernel components..."
apt-get install -y \
    nvidia-driver-595-server \
    nvidia-kernel-common-595-server \
    nvidia-firmware-595-server-595.91.07 \
    libnvidia-compute-595 \
    nvidia-utils-595

echo "[3/10] Installing NVIDIA Fabric Manager for H100/NVSwitch..."
apt-get install -y \
    nvidia-fabricmanager-595

echo "[4/10] Installing CUDA runtime..."
apt-get install -y \
    cuda-cudart-13-2

echo "[5/10] Rebuilding linker cache..."
ldconfig

echo "[6/10] Enabling NVIDIA services..."
systemctl enable nvidia-fabricmanager || true

echo "[7/10] Starting NVIDIA Fabric Manager..."
systemctl restart nvidia-fabricmanager || true

sleep 5

echo "[8/10] Checking NVIDIA driver..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi is unavailable."
    exit 1
fi

nvidia-smi -L

echo
echo "Driver version:"
nvidia-smi --query-gpu=driver_version --format=csv,noheader | sort -u

echo
echo "[9/10] Checking CUDA libraries..."

if ! ldconfig -p | grep -q "libcuda.so.1"; then
    echo "ERROR: libcuda.so.1 is unavailable."
    exit 1
fi

echo "libcuda.so.1:"
ldconfig -p | grep "libcuda.so.1"

echo
echo "[10/10] Testing CUDA Driver API..."

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
    echo_count="${count.value}"
    echo "WARNING: Expected 8 GPUs, detected ${echo_count}."

PY

echo
echo "=============================================="
echo " Fabric Manager status"
echo "=============================================="

systemctl --no-pager --full status nvidia-fabricmanager || true

echo
echo "=============================================="
echo " Fabric state"
echo "=============================================="

nvidia-smi -q -i 0 | grep -A12 -i "Fabric" || true

echo
echo "=============================================="
echo " CUDA libraries"
echo "=============================================="

ldconfig -p | grep -E "libcuda|libcudart" || true

echo
echo "=============================================="
echo " FINAL GPU CHECK"
echo "=============================================="

nvidia-smi -L

echo
echo "=============================================="
echo " NVIDIA H100 setup completed"
echo "=============================================="
SCRIPT

chmod +x /tmp/install_nvidia_h100.sh
/tmp/install_nvidia_h100.sh
'
