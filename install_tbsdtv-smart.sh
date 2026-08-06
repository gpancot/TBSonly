#!/usr/bin/env bash
# install_tbsdtv-smart v18
# Changes from v17/v19:
#   - All messages translated to English
#   - Git output: verbose progress (--progress flag)
#   - Pause after each major step (press Enter to continue)
#   - Removed fallback MISSING_DEFINES hardcoded list
#   - Minimum kernel: 7.0+
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) echo "Usage: $0 [--dry-run]"; exit 0 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TBS_REPO="https://github.com/tbsdtv/linux_media.git"
TBS_BRANCH="latest"
SRC="/usr/src/tbs-drivers"
KVER="$(uname -r)"
KMAJ=$(echo "$KVER" | cut -d. -f1)
KMIN=$(echo "$KVER" | cut -d. -f2)
KBUILD="/lib/modules/${KVER}/build"
KHEADERS_COMMON=$(find /usr/src -maxdepth 1 -name "linux-headers-*-common" | sort -V | tail -1)
BUILD_DIR="$SCRIPT_DIR/tbs-build-tmp"
INSTALL_DIR="/lib/modules/${KVER}/updates/tbs"
LOG="$SCRIPT_DIR/install_tbsdtv-smart.log"

# tuners must be compiled before frontends/saa/tbs so Module.symvers is available
TARGET_DIRS=("dvb-core" "dvb-frontends" "tuners" "pci/saa716x" "pci/tbsecp3" "pci/tbsci" "pci/tbsmod")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG"; exit 1; }
step()  { echo -e "\n${CYAN}>>> $*${NC}" | tee -a "$LOG"; }
pi()    { echo -e "${BLUE}[PATCH]${NC} $*" | tee -a "$LOG"; }
pause() { echo -e "${YELLOW}--- Press Enter to continue ---${NC}"; read -r; }

[[ "$DRY_RUN" -eq 1 ]] && warn "DRY-RUN MODE - no files will be modified"
echo "=== $(date) ===" > "$LOG"
echo "  Kernel: $KVER / DryRun: $DRY_RUN" | tee -a "$LOG"

ker_ge() { [[ "$KMAJ" -gt "$1" ]] || { [[ "$KMAJ" -eq "$1" ]] && [[ "$KMIN" -ge "$2" ]]; }; }

apply_sed() {
    local file="$1" desc="$2" expr="$3"
    [[ -f "$file" ]] || { warn "Patch '$desc': file not found: $file"; return 0; }
    if [[ "$DRY_RUN" -eq 1 ]]; then pi "[DRY-RUN] $desc"; return 0; fi
    pi "Applying: $desc"
    sed -i "$expr" "$file" && pi "  OK" || warn "  sed error: $file"
}

apply_sed_if_match() {
    local file="$1" desc="$2" match="$3" expr="$4"
    [[ -f "$file" ]] || { warn "Patch '$desc': file not found: $file"; return 0; }
    grep -q "$match" "$file" 2>/dev/null || { pi "Skipping (already applied): $desc"; return 0; }
    apply_sed "$file" "$desc" "$expr"
}

apply_python_patch() {
    local file="$1" desc="$2" match="$3" pycode="$4"
    [[ -f "$file" ]] || { warn "Patch '$desc': file not found: $file"; return 0; }
    grep -q "$match" "$file" 2>/dev/null || { pi "Skipping (already applied): $desc"; return 0; }
    if [[ "$DRY_RUN" -eq 1 ]]; then pi "[DRY-RUN] $desc"; return 0; fi
    pi "Applying: $desc"
    python3 -c "$pycode" "$file" && pi "  OK" || warn "  python error: $file"
}

# Load patches from separate file
PATCHES_FILE="$SCRIPT_DIR/kernel-patches.sh"
[[ -f "$PATCHES_FILE" ]] || error "Patches file not found: $PATCHES_FILE"
# shellcheck source=kernel-patches.sh
source "$PATCHES_FILE"

# ===========================================================================
cleanup() {
    info "Cleanup - restoring original files..."
    local h1="$KHEADERS_COMMON/include/media/dvb_frontend.h"
    local h2="$KHEADERS_COMMON/include/uapi/linux/dvb/frontend.h"
    local mf="$SRC/drivers/media/dvb-frontends/Makefile"
    local mf_saa="$SRC/drivers/media/pci/saa716x/Makefile"
    local mf_tbs="$SRC/drivers/media/pci/tbsecp3/Makefile"
    local mf_tuners="$SRC/drivers/media/tuners/Makefile"
    # Kernel headers: always restore (outside TBS tree)
    [[ -f "${h1}.orig" ]]        && mv "${h1}.orig"        "$h1"        && info "  Restored: dvb_frontend.h"
    [[ -f "${h2}.orig" ]]        && mv "${h2}.orig"        "$h2"        && info "  Restored: frontend.h"
    # TBS Makefiles: do NOT restore - they must remain modified for modprobe to work
    # Just remove the .orig backups
    [[ -f "${mf}.orig" ]]        && rm "${mf}.orig"        && info "  Removed backup: dvb-frontends/Makefile.orig"
    [[ -f "${mf_saa}.orig" ]]    && rm "${mf_saa}.orig"    && info "  Removed backup: saa716x/Makefile.orig"
    [[ -f "${mf_tbs}.orig" ]]    && rm "${mf_tbs}.orig"    && info "  Removed backup: tbsecp3/Makefile.orig"
    [[ -f "${mf_tuners}.orig" ]] && rm "${mf_tuners}.orig" && info "  Removed backup: tuners/Makefile.orig"
}
trap cleanup EXIT

step "Checking kernel version (required: 7.0+)"
ker_ge 7 0 || error "Kernel $KVER is too old. Required: 7.0+"
info "Kernel $KVER - OK"

step "Checking build environment"
echo "  Kernel:         $KVER"            | tee -a "$LOG"
echo "  KBuild:         $KBUILD"          | tee -a "$LOG"
echo "  TBS sources:    $SRC"             | tee -a "$LOG"
echo "  Common headers: $KHEADERS_COMMON" | tee -a "$LOG"
echo "  Log:            $LOG"             | tee -a "$LOG"

[[ -d "$KBUILD" ]] || error "Kernel build directory not found: $KBUILD"
[[ -n "$KHEADERS_COMMON" && -d "$KHEADERS_COMMON" ]] || error "linux-headers-*-common not found"
for cmd in git make gcc rsync python3; do
    command -v "$cmd" &>/dev/null || error "Missing dependency: $cmd"
done

H1="$KHEADERS_COMMON/include/media/dvb_frontend.h"
H2="$KHEADERS_COMMON/include/uapi/linux/dvb/frontend.h"
MF="$SRC/drivers/media/dvb-frontends/Makefile"
MF_SAA="$SRC/drivers/media/pci/saa716x/Makefile"
MF_TBS="$SRC/drivers/media/pci/tbsecp3/Makefile"
MF_TUNERS="$SRC/drivers/media/tuners/Makefile"
STALE=0
# Check only kernel headers - TBS Makefiles are not restored after successful run
for f in "${H1}.orig" "${H2}.orig"; do
    [[ -f "$f" ]] && { warn "Leftover from interrupted run: $f"; STALE=1; }
done
if [[ "$STALE" -eq 1 ]]; then
    read -rp "  Restore .orig files and continue? [y/N]: " ANS
    [[ "${ANS,,}" == "y" ]] || error "Aborted. Check .orig files manually."
    cleanup; trap cleanup EXIT
fi
info "Environment OK."
pause

step "Fetching/updating TBS sources -> $SRC"
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ -d "$SRC/.git" ]]; then
        info "Updating existing repository..."
        git -C "$SRC" fetch --progress origin              2>&1 | tee -a "$LOG"
        git -C "$SRC" checkout "$TBS_BRANCH"               2>&1 | tee -a "$LOG"
        git -C "$SRC" pull --progress origin "$TBS_BRANCH" 2>&1 | tee -a "$LOG"
    else
        info "Cloning TBS repository (this may take a few minutes)..."
        git clone --progress --depth=1 --branch "$TBS_BRANCH" "$TBS_REPO" "$SRC" 2>&1 | tee -a "$LOG"
    fi
    info "Sources ready in: $SRC"
else
    info "[DRY-RUN] Skipping git."
fi
pause

# NOTE: apply_kernel_api_patches must run before BUILD_DIR and before overwriting TBS Makefiles
apply_kernel_api_patches
[[ "$DRY_RUN" -eq 1 ]] && { info "Dry-run complete."; exit 0; }
pause

step "Creating isolated build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/include"
rsync -a --info=progress2 "$KHEADERS_COMMON/include/" "$BUILD_DIR/include/" 2>&1 | tee -a "$LOG"
rsync -a "$SRC/include/media/"  "$BUILD_DIR/include/media/"  2>&1 | tee -a "$LOG"
rsync -a "$SRC/include/uapi/"   "$BUILD_DIR/include/uapi/"   2>&1 | tee -a "$LOG"
mkdir -p "$BUILD_DIR/include/media/tuners"
if [[ -d "$SRC/drivers/media/tuners" ]]; then
    find "$SRC/drivers/media/tuners" -name "*.h" \
        -exec cp {} "$BUILD_DIR/include/media/tuners/" \; 2>/dev/null || true
    cp "$SRC/drivers/media/tuners/tuner-i2c.h" "$BUILD_DIR/include/" 2>/dev/null || true
fi
[[ -d "$SRC/drivers/media/usb" ]] && \
    find "$SRC/drivers/media/usb" -name "*.h" \
        -exec cp {} "$BUILD_DIR/include/" \; 2>/dev/null || true
info "Build directory ready."

step "Temporarily patching kernel headers"
cp "$H1" "${H1}.orig" && cp "$SRC/include/media/dvb_frontend.h" "$H1"
info "  Patched: dvb_frontend.h"
cp "$H2" "${H2}.orig" && cp "$SRC/include/uapi/linux/dvb/frontend.h" "$H2"
info "  Patched: frontend.h (uapi)"

step "Detecting missing CONFIG_DVB_* defines"
KERNEL_CONFIG="/boot/config-${KVER}"
MISSING_DEFINES=""
if [[ -f "$KERNEL_CONFIG" ]]; then
    while IFS= read -r cfg; do
        grep -q "^${cfg}=" "$KERNEL_CONFIG" 2>/dev/null && continue
        MISSING_DEFINES+=" -D${cfg}=1"
        info "  Missing: ${cfg}"
    done < <(
        grep -h "obj-\$(CONFIG_DVB" \
            "$SRC/drivers/media/dvb-frontends/Makefile" \
            "$SRC/drivers/media/dvb-core/Makefile" \
            2>/dev/null | grep -oP 'CONFIG_DVB_\w+' | sort -u
    )
    [[ -z "$MISSING_DEFINES" ]] \
        && info "All CONFIG_DVB_* defines present." \
        || info "Added $(echo "$MISSING_DEFINES" | wc -w) missing defines."
else
    warn "Kernel config not found: $KERNEL_CONFIG"
    warn "CONFIG_DVB_* defines will not be verified. Build may fail."
fi

step "Creating minimal Makefile for dvb-frontends"
cp "$MF" "${MF}.orig"
cat > "$MF" << 'MAKEFILE'
ccflags-y += -I$(srctree)/drivers/media/tuners/
cxd2820r-objs := cxd2820r_core.o cxd2820r_c.o cxd2820r_t.o cxd2820r_t2.o
drxd-objs     := drxd_firm.o drxd_hard.o
drxk-objs     := drxk_hard.o
stb0899-objs  := stb0899_drv.o stb0899_algo.o
stv0900-objs  := stv0900_core.o stv0900_sw.o
# TBS-exclusive frontends
obj-m += avl6882.o
obj-m += cxd2878.o
obj-m += gx1133.o
obj-m += gx1503.o
obj-m += m88rs6060.o
obj-m += mn88436.o
obj-m += mn88443x.o
obj-m += mtv23x.o
obj-m += mxl58x.o
obj-m += stid135/
obj-m += stv091x.o
obj-m += tas2101.o
obj-m += tas2971.o
obj-m += tbs_priv.o
# Frontends also present in kernel but TBS has modified versions
obj-m += cx24117.o
obj-m += cxd2820r.o
obj-m += dib9000.o
obj-m += isl6422.o
obj-m += lgs8gl5.o
obj-m += lnbh29.o
obj-m += mb86a16.o
obj-m += s5h1432.o
obj-m += si2168.o
obj-m += si2183.o
obj-m += stb0899.o
obj-m += stv0900.o
MAKEFILE
info "dvb-frontends Makefile ready."

step "Creating minimal Makefile for tuners"
cp "$MF_TUNERS" "${MF_TUNERS}.orig"
cat > "$MF_TUNERS" << 'MAKEFILE'
ccflags-y += -I$(srctree)/drivers/media/dvb-frontends/
# TBS-specific tuners (not in distro kernel or TBS has modified versions)
obj-m += av201x.o
obj-m += si2157.o
obj-m += stv6120.o
obj-m += tda18212.o
MAKEFILE
info "tuners Makefile ready."

step "Creating minimal Makefile for pci/saa716x"
cp "$MF_SAA" "${MF_SAA}.orig"
cat > "$MF_SAA" << 'MAKEFILE'
ccflags-y += -Idrivers/media/tuners
ccflags-y += -Idrivers/media/dvb-core
ccflags-y += -Idrivers/media/dvb-frontends
ccflags-y += -Idrivers/media/dvb-frontends/stid135
saa716x_core-objs := saa716x_pci.o saa716x_i2c.o saa716x_cgu.o saa716x_msi.o \
                     saa716x_dma.o saa716x_vip.o saa716x_aip.o saa716x_phi.o  \
                     saa716x_boot.o saa716x_fgpi.o saa716x_adap.o saa716x_gpio.o \
                     saa716x_greg.o saa716x_rom.o saa716x_spi.o
saa716x_tbs-dvb-objs := saa716x_budget.o tbsci-i2c.o tbs-ci.o
obj-m += saa716x_core.o
obj-m += saa716x_tbs-dvb.o
MAKEFILE
info "saa716x Makefile ready."

step "Creating minimal Makefile for pci/tbsecp3"
cp "$MF_TBS" "${MF_TBS}.orig"
cat > "$MF_TBS" << 'MAKEFILE'
ccflags-y += -Idrivers/media/tuners
ccflags-y += -Idrivers/media/dvb-core
ccflags-y += -Idrivers/media/dvb-frontends
ccflags-y += -Idrivers/media/dvb-frontends/stid135
tbsecp3-objs := tbsecp3-core.o tbsecp3-cards.o tbsecp3-i2c.o tbsecp3-dma.o \
                tbsecp3-dvb.o tbsecp3-ca.o tbsecp3-asi.o tbsecp3-ci.o
obj-m += tbsecp3.o
MAKEFILE
info "tbsecp3 Makefile ready."
pause

step "Compilation"
EXTRA_CFLAGS="-I${BUILD_DIR}/include -I${BUILD_DIR}/include/uapi \
    -I${SRC}/drivers/media/tuners \
    -I${SRC}/drivers/media/dvb-frontends \
    -I${SRC}/drivers/media/dvb-frontends/stid135 \
    -include linux/version.h \
    ${MISSING_DEFINES}"

# IS_REACHABLE(CONFIG_X) = IS_BUILTIN(X) || (IS_MODULE(X) && defined(MODULE))
# IS_MODULE(X) checks CONFIG_X_MODULE=1, not CONFIG_X=m.
# Dynamically detect all CONFIG_* used in IS_REACHABLE, IS_ENABLED
# or manual defined(CONFIG_X_MODULE) guards in TBS headers and add _MODULE=1.
REACHABLE_DEFINES=""
while IFS= read -r cfg; do
    REACHABLE_DEFINES+=" -D${cfg}_MODULE=1"
done < <(
    {
        grep -rh "IS_REACHABLE(CONFIG_" \
            "$SRC/drivers/media/dvb-frontends/" \
            "$SRC/drivers/media/tuners/" \
            2>/dev/null \
        | grep -oP 'IS_REACHABLE\(CONFIG_\w+\)' \
        | grep -oP 'CONFIG_\w+(?=\))'

        grep -rh "IS_ENABLED(CONFIG_" \
            "$SRC/drivers/media/dvb-frontends/" \
            "$SRC/drivers/media/tuners/" \
            2>/dev/null \
        | grep -oP 'IS_ENABLED\(CONFIG_\w+\)' \
        | grep -oP 'CONFIG_\w+(?=\))'

        grep -rh "defined(CONFIG_.*_MODULE)" \
            "$SRC/drivers/media/dvb-frontends/" \
            "$SRC/drivers/media/tuners/" \
            2>/dev/null \
        | grep -oP 'CONFIG_\w+(?=_MODULE)'
    } | sort -u
)
EXTRA_CFLAGS+=" $REACHABLE_DEFINES"
info "Added $(echo "$REACHABLE_DEFINES" | wc -w) _MODULE=1 defines for IS_REACHABLE guards"
info "Added $(echo "$MISSING_DEFINES" | wc -w) missing CONFIG_DVB_* defines"
ERRORS=(); SUCCESS=()

# COMBINED_SYMVERS: each module sees symbols from all previously compiled modules.
# Fixes "undefined symbol" at modpost for modules depending on dvb-core / frontends.
COMBINED_SYMVERS="$BUILD_DIR/Module.symvers"
: > "$COMBINED_SYMVERS"

for subdir in "${TARGET_DIRS[@]}"; do
    target="$SRC/drivers/media/$subdir"
    [[ -d "$target" ]] || { warn "Directory not found: $subdir"; continue; }
    [[ -f "$target/Makefile" ]] || { warn "No Makefile in: $subdir"; continue; }
    info "Compiling: $subdir"
    MODULE_LOG=$(mktemp)
    if make -C "$KBUILD" M="$target" KCFLAGS="$EXTRA_CFLAGS" \
            KBUILD_EXTRA_SYMBOLS="$COMBINED_SYMVERS" modules 2>&1 \
            | tee "$MODULE_LOG" | tee -a "$LOG"; then
        info "  OK: $subdir"; SUCCESS+=("$subdir")
        [[ -f "$target/Module.symvers" ]] && \
            cat "$target/Module.symvers" >> "$COMBINED_SYMVERS"
    else
        warn "  FAILED: $subdir"; ERRORS+=("$subdir")
        echo -e "${RED}  --- Errors in $subdir ---${NC}" | tee -a "$LOG"
        grep -E "^.*error:" "$MODULE_LOG" | sed "s|$SRC/||" | sort -u | head -30 \
            | while read -r line; do echo -e "  ${RED}>>>${NC} $line" | tee -a "$LOG"; done
        echo -e "${RED}  ---${NC}" | tee -a "$LOG"
    fi
    rm -f "$MODULE_LOG"
done

step "Build result"
KO_COUNT=$(find "$SRC/drivers/media" -name "*.ko" 2>/dev/null | wc -l)

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}  ╔════════════════════════════╗"
    echo -e "  ║  PARTIAL BUILD             ║"
    echo -e "  ╚════════════════════════════╝${NC}"
    for e in "${ERRORS[@]}"; do warn "  FAILED: $e"; done
    info "Compiled:"; for s in "${SUCCESS[@]}"; do echo "    OK: $s" | tee -a "$LOG"; done
    info "Modules .ko: $KO_COUNT"
    warn "Next step: add a patch to kernel-patches.sh and run again"
    warn "Log: $LOG"
    exit 1
fi

echo -e "${GREEN}  ╔════════════════════════════╗"
echo -e "  ║  BUILD OK!                 ║"
echo -e "  ╚════════════════════════════╝${NC}"
info "Compiled:"; for s in "${SUCCESS[@]}"; do echo "    OK: $s" | tee -a "$LOG"; done
info "Modules .ko: $KO_COUNT"
find "$SRC/drivers/media" -name "*.ko" 2>/dev/null | sort \
    | while read -r f; do echo "    $(basename "$f")" | tee -a "$LOG"; done
info "Log: $LOG"
pause

step "Module installation"
echo -e "${CYAN}  Install modules for kernel ${KVER}?"
echo -e "  Target: ${INSTALL_DIR}${NC}"
read -rp "  [Y/n]: " ANSWER
if [[ "${ANSWER,,}" == "n" ]]; then
    warn "Installation skipped. Modules are in: $SRC/drivers/media"
    exit 0
fi

info "Installing to: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
find "$SRC/drivers/media" -name "*.ko" | while read -r ko; do
    subpath="${ko#$SRC/drivers/media/}"
    destdir="$INSTALL_DIR/$(dirname "$subpath")"
    mkdir -p "$destdir"
    cp "$ko" "$destdir/"
    echo "  Copied: $(basename "$ko")" | tee -a "$LOG"
done

info "Running depmod -a $KVER"
depmod -a "$KVER" 2>&1 | tee -a "$LOG"

echo -e "${GREEN}  ╔════════════════════════════╗"
echo -e "  ║  INSTALLATION OK!          ║"
echo -e "  ║  Please reboot the system. ║"
echo -e "  ╚════════════════════════════╝${NC}"
info "Directory: $INSTALL_DIR / Log: $LOG"
