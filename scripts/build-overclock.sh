#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Albus (Moto Z2 Play) Overclocked Recovery Builder
# Kernel: SaaSD3v/android_kernel_motorola_msm8996
# ============================================================

# Overclock values (configurable via environment)
readonly GPU_MHZ="${GPU_MHZ:-700}"
readonly CPU_MHZ="${CPU_MHZ:-2300}"

# Stock frequencies
readonly STOCK_GPU_HZ=650000000
readonly STOCK_CPU_KHZ=2208000
readonly STOCK_CPU_HZ=2208000000

# Target frequencies
readonly TARGET_GPU_HZ=$((GPU_MHZ * 1000000))
readonly TARGET_CPU_KHZ=$((CPU_MHZ * 1000))
readonly TARGET_CPU_HZ=$((CPU_MHZ * 1000000))

# Repository settings
readonly KERNEL_REPO="https://github.com/SaaSD3v/android_kernel_motorola_msm8996.git"
readonly KERNEL_COMMIT="516086ce0637a9e820793695a4dd8e3ff43e055b"

readonly TOOLCHAIN_TAG="android-8.1.0_r52"
readonly AARCH64_TOOLCHAIN_REPO="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"
readonly AARCH64_TOOLCHAIN_TAG_OBJECT="01a44495e0d50ba06b0b43ebc94a00bdaa4240bb"
readonly AARCH64_TOOLCHAIN_COMMIT="7a28c220c2e9001825328dca6188ef0077a80a88"
readonly ARM_TOOLCHAIN_REPO="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9"
readonly ARM_TOOLCHAIN_TAG_OBJECT="8467f03d870283b5b494b9b0b52b3cb19eb8f2df"
readonly ARM_TOOLCHAIN_COMMIT="c348b64ea1e2015a576485aa787dc70dda9ef396"

readonly DTBTOOL_REPO="https://github.com/LineageOS/android_device_motorola_potter.git"
readonly DTBTOOL_COMMIT="ad60ebfd1f623cc55b962b98d5b57758124edb74"

readonly TWRP_FILE="twrp-3.5.0_9-0-albus.img"
readonly TWRP_PAGE="https://dl.twrp.me/albus/${TWRP_FILE}.html"
readonly TWRP_URL="https://dl.twrp.me/albus/${TWRP_FILE}"
readonly TWRP_SHA256="4c42bfee165ea99e2663284a3634135786e157bd6cc492fcbe0d9bd3430e9261"
readonly TWRP_SIZE=18933760

readonly MAGISK_VERSION="30.7"
readonly MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VERSION}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISK_APK_SHA256="e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5"
readonly MAGISKBOOT_SHA256="a18ecbd7981179494b7d281453d6c4e25b5c719e7d2ef7f6eba3c6be3043c58e"

readonly RECOVERY_PARTITION_SIZE=21073920

# ============================================================
# Helper functions
# ============================================================

note() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  local value _
  read -r value _ < <(sha256sum "$1")
  printf '%s' "$value"
}

check_sha256() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(sha256_of "$file")"
  [[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for $file: expected $expected, got $actual"
}

check_size() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(stat -c '%s' "$file")"
  [[ "$actual" == "$expected" ]] || die "size mismatch for $file: expected $expected, got $actual"
}

read_u32_le() {
  od -An -tu4 -j "$2" -N4 "$1" | tr -d '[:space:]'
}

clone_commit() {
  local repo="$1"
  local commit="$2"
  local destination="$3"

  git init --quiet "$destination"
  git -C "$destination" remote add origin "$repo"
  git -C "$destination" fetch --quiet --depth=1 origin "$commit"
  git -C "$destination" checkout --quiet --detach FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] \
    || die "failed to checkout $commit from $repo"
}

clone_tag() {
  local repo="$1"
  local tag="$2"
  local expected_tag_object="$3"
  local expected_commit="$4"
  local destination="$5"

  git -c advice.detachedHead=false clone --quiet --depth=1 --branch "$tag" "$repo" "$destination"
  [[ "$(git -C "$destination" rev-parse "refs/tags/$tag")" == "$expected_tag_object" ]] \
    || die "unexpected tag object for $repo tag $tag"
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$expected_commit" ]] \
    || die "unexpected commit for $repo tag $tag"
}

# ============================================================
# Setup working directory
# ============================================================

TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
WORK_DIR="$(mktemp -d "${TEMP_ROOT}/albus-overclock.XXXXXX")"
readonly WORK_DIR
readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ARTIFACT_DIR="${ROOT_DIR}/artifacts"

mkdir -p "$ARTIFACT_DIR" "${WORK_DIR}/tools"

note "=== OVERCLOCK BUILD: GPU=${GPU_MHZ} MHz, CPU=${CPU_MHZ} MHz ==="

# ============================================================
# 1. Clone kernel source, toolchains, dtbtool
# ============================================================
note "Clone kernel and toolchains"
clone_commit "$KERNEL_REPO" "$KERNEL_COMMIT" "${WORK_DIR}/kernel"
clone_tag "$AARCH64_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$AARCH64_TOOLCHAIN_TAG_OBJECT" "$AARCH64_TOOLCHAIN_COMMIT" "${WORK_DIR}/aarch64-toolchain"
clone_tag "$ARM_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$ARM_TOOLCHAIN_TAG_OBJECT" "$ARM_TOOLCHAIN_COMMIT" "${WORK_DIR}/arm-toolchain"
clone_commit "$DTBTOOL_REPO" "$DTBTOOL_COMMIT" "${WORK_DIR}/dtbtool"

# ============================================================
# 2. PATCH: Increase CPU max_rate + freq table in clock-cpu-8953.c
# ============================================================
note "Patch CPU clock driver: 2208 MHz -> ${CPU_MHZ} MHz"

CLOCK_CPU_FILE="${WORK_DIR}/kernel/drivers/clk/msm/clock-cpu-8953.c"
[[ -f "$CLOCK_CPU_FILE" ]] || die "clock-cpu-8953.c not found: $CLOCK_CPU_FILE"

# Increase max_rate from 2.2 GHz to 2.5 GHz to allow overclock
# Patch BOTH the PLL max_rate AND the VDD_MX FMAX
sed -i 's/\.max_rate = 2208000000UL/.max_rate = 2500000000UL/g' "$CLOCK_CPU_FILE"

# Increase VDD_MX limit from 2.4 GHz to 2.6 GHz
sed -i 's/VDD_MX_HF_FMAX_MAP1(SVS, 2400000000UL)/VDD_MX_HF_FMAX_MAP1(SVS, 2600000000UL)/g' "$CLOCK_CPU_FILE"

# CRITICAL: Patch the hardcoded frequency table apcs_clk_freq_tbl_8953[]
# The cpufreq driver maps DTS entries to this table. If 2300 MHz isn't here,
# cpufreq caps at the highest entry that IS in this table (2150.4 MHz).
sed -i "s/${STOCK_CPU_HZ}/${TARGET_CPU_HZ}/g" "$CLOCK_CPU_FILE"
note "Patched apcs_clk_freq_tbl_8953[]: $(grep -c "${TARGET_CPU_HZ}" "$CLOCK_CPU_FILE") occurrence(s) of ${TARGET_CPU_HZ} Hz"

# Verify patches
grep -q "2500000000UL" "$CLOCK_CPU_FILE" || die "CPU max_rate patch failed"
grep -q "2600000000UL" "$CLOCK_CPU_FILE" || die "VDD_MX patch failed"
note "CPU driver patched successfully"

# ============================================================
# 2b. PATCH cpufreq driver to not reject overclocked frequencies
# ============================================================
note "Patch qcom-cpufreq.c: bypass clk_round_rate for OC freqs"

CPUFREQ_FILE="${WORK_DIR}/kernel/drivers/cpufreq/qcom-cpufreq.c"
[[ -f "$CPUFREQ_FILE" ]] || die "qcom-cpufreq.c not found: $CPUFREQ_FILE"

# The cpufreq driver calls clk_round_rate() which may reject frequencies
# above stock max. Patch: use raw DTS value instead of clk_round_rate result.
# Original: f = clk_round_rate(cpu_clk[cpu], data[i] * 1000);
# Patched:  f = data[i] * 1000;  (bypass round_rate)
sed -i 's/f = clk_round_rate(cpu_clk\[cpu\], data\[i\] \* 1000);/f = data[i] * 1000; \/\* OC: bypass round_rate *\//g' "$CPUFREQ_FILE"

# Verify
if grep -q "OC: bypass round_rate" "$CPUFREQ_FILE"; then
  note "cpufreq driver patched successfully"
else
  die "Failed to patch cpufreq driver"
fi

# ============================================================
# 2c. PATCH GPU clock driver: add 700 MHz to freq table
# ============================================================
note "Patch GPU clock driver: add ${GPU_MHZ} MHz to gfx3d freq table"

GPU_CLOCK_FILE="${WORK_DIR}/kernel/drivers/clk/msm/clock-gpu-cobalt.c"
[[ -f "$GPU_CLOCK_FILE" ]] || die "clock-gpu-cobalt.c not found: $GPU_CLOCK_FILE"

# Add 700 MHz entry to ftbl_gfx3d_clk_src[] (PLL at 1400 MHz, even divider /2)
# Original last entry: F_SLEW( 650000000, 1300000000, gpu_pll0_pll_out_even, 1, 0, 0),\n\tF_END
# New: add 700 MHz line before F_END
sed -i '/F_SLEW( 650000000, 1300000000, gpu_pll0_pll_out_even,    1, 0, 0),/a\\tF_SLEW( 700000000, 1400000000, gpu_pll0_pll_out_even,    1, 0, 0),' "$GPU_CLOCK_FILE"

# Raise GPU PLL NOMINAL ceiling from 1300000500 to 1500000000 to allow 1400 MHz PLL output
sed -i 's/VDD_GPU_PLL_FMAX_MAP3(MIN, 252000000, LOWER, 504000000,\t\t\t\tNOMINAL, 1300000500)/VDD_GPU_PLL_FMAX_MAP3(MIN, 252000000, LOWER, 504000000,\t\t\t\tNOMINAL, 1500000000)/g' "$GPU_CLOCK_FILE"

# Verify
if grep -q "700000000.*gpu_pll0_pll_out_even" "$GPU_CLOCK_FILE"; then
  note "GPU clock driver patched: 700 MHz entry added"
else
  die "Failed to patch GPU clock driver freq table"
fi

if grep -q "1500000000" "$GPU_CLOCK_FILE"; then
  note "GPU PLL NOMINAL ceiling raised to 1500 MHz"
else
  die "Failed to raise GPU PLL NOMINAL ceiling"
fi

# ============================================================
# 2d. PATCH KGSL driver: bypass clk_round_rate for GPU freqs
# ============================================================
note "Patch kgsl_pwrctrl.c: bypass clk_round_rate for GPU OC freqs"

KGSL_FILE="${WORK_DIR}/kernel/drivers/gpu/msm/kgsl_pwrctrl.c"
[[ -f "$KGSL_FILE" ]] || die "kgsl_pwrctrl.c not found: $KGSL_FILE"

# The KGSL driver calls clk_round_rate() on each GPU power level freq.
# If the GPU clock driver rejects 700 MHz, it rounds down to 650 MHz.
# Patch: use raw DTS value instead of clk_round_rate result.
sed -i 's/freq = clk_round_rate(pwr->grp_clks\[0\], freq);/freq = freq; \/\* OC: bypass GPU round_rate *\//g' "$KGSL_FILE"

# Verify
if grep -q "OC: bypass GPU round_rate" "$KGSL_FILE"; then
  note "KGSL driver patched successfully"
else
  die "Failed to patch KGSL driver"
fi

# ============================================================
# 3. PATCH the DTS files BEFORE compilation
# ============================================================
note "Patch DTS: GPU ${STOCK_GPU_HZ} Hz -> ${TARGET_GPU_HZ} Hz, CPU ${STOCK_CPU_HZ} Hz -> ${TARGET_CPU_HZ} Hz"

GPU_DTS="${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953-gpu.dtsi"
CPU_DTS="${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953.dtsi"

[[ -f "$GPU_DTS" ]] || die "GPU DTS not found: $GPU_DTS"
[[ -f "$CPU_DTS" ]] || die "CPU DTS not found: $CPU_DTS"

# Patch GPU: replace stock GPU freq with target in ALL msm8953* DTS files
# The chip reads speed-bin OPP from efuse — must patch ALL bins, not just speed7
note "Patch GPU freq across ALL msm8953* DTS files"
GPU_TOTAL=0
for dtsi in "${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953"*.dtsi; do
  [[ -f "$dtsi" ]] || continue
  count=$(grep -c "${STOCK_GPU_HZ}" "$dtsi" 2>/dev/null || true)
  if [[ "$count" -gt 0 ]]; then
    sed -i "s/${STOCK_GPU_HZ}/${TARGET_GPU_HZ}/g" "$dtsi"
    note "GPU patched in $(basename "$dtsi"): $count occurrence(s)"
    GPU_TOTAL=$((GPU_TOTAL + count))
  fi
done
[[ "$GPU_TOTAL" -gt 0 ]] || die "Stock GPU freq $STOCK_GPU_HZ not found in any DTS file"
note "Total GPU patches: $GPU_TOTAL"

# Patch CPU speed-bin tables (Hz) — these are what the clock driver actually reads
grep -q "$STOCK_CPU_HZ" "$CPU_DTS" || die "Stock CPU freq $STOCK_CPU_HZ Hz not found in $CPU_DTS"
sed -i "s/${STOCK_CPU_HZ}/${TARGET_CPU_HZ}/g" "$CPU_DTS"
note "CPU speed-bin patched: $(grep -c "$TARGET_CPU_HZ" "$CPU_DTS") occurrence(s) of $TARGET_CPU_HZ Hz in msm8953.dtsi"

# Also patch cpufreq-table (KHz) as fallback
if grep -q "$STOCK_CPU_KHZ" "$CPU_DTS"; then
  sed -i "s/< ${STOCK_CPU_KHZ} >/< ${TARGET_CPU_KHZ} >/g" "$CPU_DTS"
  note "CPU cpufreq-table patched: $(grep -c "$TARGET_CPU_KHZ" "$CPU_DTS") occurrence(s) of $TARGET_CPU_KHZ KHz in msm8953.dtsi"
fi

# Also patch any other speed-bin DTS files for CPU
for dtsi in "${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953"*.dtsi; do
  [[ -f "$dtsi" ]] || continue
  [[ "$dtsi" == "$CPU_DTS" ]] && continue
  if grep -q "$STOCK_CPU_HZ" "$dtsi"; then
    sed -i "s/${STOCK_CPU_HZ}/${TARGET_CPU_HZ}/g" "$dtsi"
    note "CPU patched in $(basename "$dtsi"): $(grep -c "$TARGET_CPU_HZ" "$dtsi") occurrence(s)"
  fi
done

# ============================================================
# 4. Build kernel
# ============================================================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="${WORK_DIR}/aarch64-toolchain/bin/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="${WORK_DIR}/arm-toolchain/bin/arm-linux-androideabi-"
export PATH="${WORK_DIR}/aarch64-toolchain/bin:${WORK_DIR}/arm-toolchain/bin:${PATH}"

readonly MAKE_ARGS=(
  -C "${WORK_DIR}/kernel"
  "O=${WORK_DIR}/kernel-out"
  "ARCH=$ARCH"
  "SUBARCH=$SUBARCH"
  "CROSS_COMPILE=$CROSS_COMPILE"
  "CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32"
)

note "Configure kernel"
make "${MAKE_ARGS[@]}" albus_defconfig

readonly KERNEL_CONFIG="${WORK_DIR}/kernel-out/.config"
"${WORK_DIR}/kernel/scripts/config" --file "$KERNEL_CONFIG" --enable RD_LZMA
make "${MAKE_ARGS[@]}" olddefconfig

note "Build Image.gz and device trees"
make \
  --jobs="${JOBS:-$(nproc)}" \
  "${MAKE_ARGS[@]}" \
  KCFLAGS=-mno-android \
  Image.gz \
  dtbs

readonly KERNEL_IMAGE="${WORK_DIR}/kernel-out/arch/arm64/boot/Image.gz"
[[ -s "$KERNEL_IMAGE" ]] || die "Image.gz was not produced"

# ============================================================
# 5. Build QCDT v3 Motorola image
# ============================================================
note "Build QCDT v3 image"
cc \
  -O2 \
  -Wall \
  "${WORK_DIR}/dtbtool/dtbtool/dtbtool.c" \
  -o "${WORK_DIR}/tools/dtbTool_custom"

"${WORK_DIR}/tools/dtbTool_custom" \
  --force-v3 \
  --motorola 1 \
  -o "${WORK_DIR}/dt.img" \
  -s 2048 \
  -p "${WORK_DIR}/kernel-out/scripts/dtc/" \
  "${WORK_DIR}/kernel-out/arch/arm64/boot/"

[[ "$(dd if="${WORK_DIR}/dt.img" bs=1 count=4 status=none)" == "QCDT" ]] \
  || die "dt.img does not contain the QCDT magic"

# Verify compiled DTBs contain overclocked frequencies
note "Verify compiled DTBs contain overclocked frequencies"
GPU_HZ_BYTES=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( (TARGET_GPU_HZ >> 24) & 0xFF )) $(( (TARGET_GPU_HZ >> 16) & 0xFF )) $(( (TARGET_GPU_HZ >> 8) & 0xFF )) $(( TARGET_GPU_HZ & 0xFF )))
CPU_HZ_BYTES=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( (TARGET_CPU_HZ >> 24) & 0xFF )) $(( (TARGET_CPU_HZ >> 16) & 0xFF )) $(( (TARGET_CPU_HZ >> 8) & 0xFF )) $(( TARGET_CPU_HZ & 0xFF )))

GPU_IN_DT=$(python3 -c "
import sys
with open('${WORK_DIR}/dt.img', 'rb') as f:
    data = f.read()
import struct
target = struct.pack('>I', ${TARGET_GPU_HZ})
stock = struct.pack('>I', ${STOCK_GPU_HZ})
print(f'GPU {${TARGET_GPU_HZ}} Hz: {data.count(target)} occurrence(s)')
print(f'GPU {${STOCK_GPU_HZ}} Hz (stock): {data.count(stock)} occurrence(s)')
" 2>&1) || true
note "$GPU_IN_DT"

CPU_IN_DT=$(python3 -c "
import sys
with open('${WORK_DIR}/dt.img', 'rb') as f:
    data = f.read()
import struct
target_hz = struct.pack('>I', ${TARGET_CPU_HZ})
stock_hz = struct.pack('>I', ${STOCK_CPU_HZ})
print(f'CPU {${TARGET_CPU_HZ}} Hz: {data.count(target_hz)} occurrence(s)')
print(f'CPU ${STOCK_CPU_HZ} Hz (stock): {data.count(stock_hz)} occurrence(s)')
" 2>&1) || true
note "$CPU_IN_DT"

# ============================================================
# 6. Binary-patch DTBs inside QCDT image
# ============================================================
note "Binary-patch QCDT image for overclock frequencies"
python3 - "${WORK_DIR}/dt.img" "$TARGET_GPU_HZ" "$STOCK_GPU_HZ" "$TARGET_CPU_HZ" "$STOCK_CPU_HZ" "$TARGET_CPU_KHZ" "$STOCK_CPU_KHZ" <<'PYEOF'
import sys, struct

path = sys.argv[1]
target_gpu  = int(sys.argv[2])
stock_gpu   = int(sys.argv[3])
target_cpu_hz = int(sys.argv[4])
stock_cpu_hz  = int(sys.argv[5])
target_cpu_khz = int(sys.argv[6])
stock_cpu_khz  = int(sys.argv[7])

with open(path, 'rb') as f:
    data = bytearray(f.read())

gpu_old = struct.pack('>I', stock_gpu)
gpu_new = struct.pack('>I', target_gpu)
cpu_hz_old = struct.pack('>I', stock_cpu_hz)
cpu_hz_new = struct.pack('>I', target_cpu_hz)
cpu_khz_old = struct.pack('>I', stock_cpu_khz)
cpu_khz_new = struct.pack('>I', target_cpu_khz)

gpu_count = data.count(gpu_old)
cpu_hz_count = data.count(cpu_hz_old)
cpu_khz_count = data.count(cpu_khz_old)

if gpu_count == 0:
    print(f"WARNING: stock GPU freq {stock_gpu} Hz not found in DT image")
else:
    data = data.replace(gpu_old, gpu_new)
    print(f"GPU: {gpu_count} occurrence(s) of {stock_gpu} -> {target_gpu} Hz")

if cpu_hz_count > 0:
    data = data.replace(cpu_hz_old, cpu_hz_new)
    print(f"CPU (Hz): {cpu_hz_count} occurrence(s) of {stock_cpu_hz} -> {target_cpu_hz} Hz")
else:
    print(f"INFO: stock CPU freq {stock_cpu_hz} Hz not found as big-endian u32 (expected if DTS source was patched before compilation)")

if cpu_khz_count > 0:
    data = data.replace(cpu_khz_old, cpu_khz_new)
    print(f"CPU (KHz): {cpu_khz_count} occurrence(s) of {stock_cpu_khz} -> {target_cpu_khz} KHz")
else:
    print(f"INFO: stock CPU freq {stock_cpu_khz} KHz not found as big-endian u32 (expected if DTS source was patched before compilation)")

with open(path, 'wb') as f:
    f.write(data)

total = gpu_count + cpu_hz_count + cpu_khz_count
print(f"Total patches applied in DT image: {total}")
PYEOF

# ============================================================
# 7. Download magiskboot and TWRP
# ============================================================
note "Download magiskboot"
readonly MAGISK_APK="${WORK_DIR}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISKBOOT="${WORK_DIR}/tools/magiskboot"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
  "$MAGISK_URL" --output "$MAGISK_APK"
check_sha256 "$MAGISK_APK_SHA256" "$MAGISK_APK"
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$MAGISKBOOT"
check_sha256 "$MAGISKBOOT_SHA256" "$MAGISKBOOT"
chmod 0755 "$MAGISKBOOT"

note "Download TWRP base"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
  --user-agent "Mozilla/5.0" --referer "$TWRP_PAGE" \
  "$TWRP_URL" --output "${WORK_DIR}/${TWRP_FILE}"
check_sha256 "$TWRP_SHA256" "${WORK_DIR}/${TWRP_FILE}"
check_size "$TWRP_SIZE" "${WORK_DIR}/${TWRP_FILE}"

# ============================================================
# 8. Unpack TWRP, replace kernel+DT, repack
# ============================================================
note "Unpack TWRP"
readonly REPACK_DIR="${WORK_DIR}/repack"
mkdir "$REPACK_DIR"
(cd "$REPACK_DIR" && "$MAGISKBOOT" unpack -n "${WORK_DIR}/${TWRP_FILE}")

[[ -f "${REPACK_DIR}/kernel" ]] || die "kernel not extracted"
[[ -f "${REPACK_DIR}/ramdisk.cpio" ]] || die "ramdisk not extracted"
[[ -f "${REPACK_DIR}/extra" ]] || die "DT not extracted"

note "Replace kernel and DT with overclocked versions"
cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "${WORK_DIR}/dt.img" "${REPACK_DIR}/extra"

note "Repack recovery.img"
(cd "$REPACK_DIR" && "$MAGISKBOOT" repack -n "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img")
[[ -s "${ARTIFACT_DIR}/recovery.img" ]] || die "recovery.img was not produced"

# ============================================================
# 9. Verify
# ============================================================
note "Verify"
readonly VERIFY_DIR="${WORK_DIR}/verify"
mkdir "$VERIFY_DIR"
(cd "$VERIFY_DIR" && "$MAGISKBOOT" unpack -n "${ARTIFACT_DIR}/recovery.img")

cmp -s "$KERNEL_IMAGE" "${VERIFY_DIR}/kernel" \
  || die "kernel mismatch"
cmp -s "${WORK_DIR}/dt.img" "${VERIFY_DIR}/extra" \
  || die "DT mismatch"

FINAL_SIZE="$(stat -c '%s' "${ARTIFACT_DIR}/recovery.img")"
(( FINAL_SIZE <= RECOVERY_PARTITION_SIZE )) \
  || die "recovery.img too large: ${FINAL_SIZE} > ${RECOVERY_PARTITION_SIZE}"

# ============================================================
# 10. Prepare artifacts
# ============================================================
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
cp "${WORK_DIR}/dt.img" "${ARTIFACT_DIR}/dt.img"

FINAL_SHA256="$(sha256_of "${ARTIFACT_DIR}/recovery.img")"

{
  printf 'kernel_repository=%s\n' "$KERNEL_REPO"
  printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
  printf 'twrp_base=%s\n' "$TWRP_FILE"
  printf 'recovery_size=%s\n' "$FINAL_SIZE"
  printf 'recovery_sha256=%s\n' "$FINAL_SHA256"
  printf 'overclock_gpu_mhz=%s\n' "$GPU_MHZ"
  printf 'overclock_cpu_mhz=%s\n' "$CPU_MHZ"
  printf 'gpu_dts_change=%s -> %s Hz\n' "$STOCK_GPU_HZ" "$TARGET_GPU_HZ"
  printf 'cpu_dts_change=%s -> %s Hz (speed-bin)\n' "$STOCK_CPU_HZ" "$TARGET_CPU_HZ"
  printf 'cpu_cpufreq_change=%s -> %s KHz (cpufreq-table)\n' "$STOCK_CPU_KHZ" "$TARGET_CPU_KHZ"
  printf 'cpu_max_rate_patched=yes\n'
  printf 'vdd_mx_patched=yes\n'
  printf 'gpu_freq_table_patched=yes\n'
  printf 'gpu_pll_nominal_patched=yes\n'
  printf 'kgsl_round_rate_bypassed=yes\n'
} > "${ARTIFACT_DIR}/build-info.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum recovery.img Image.gz dt.img build-info.txt > SHA256SUMS
)

note "=== OVERCLOCK BUILD COMPLETE ==="
printf 'recovery.img: %s bytes\n' "$FINAL_SIZE"
printf 'SHA-256: %s\n' "$FINAL_SHA256"
printf 'GPU: %s MHz (stock: 650)\n' "$GPU_MHZ"
printf 'CPU: %s MHz (stock: 2208)\n' "$CPU_MHZ"
printf 'CPU max_rate: 2500 MHz (patched)\n'
printf 'VDD_MX: 2600 MHz (patched)\n'
