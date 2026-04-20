#!/bin/bash
# hibernate-fix — diagnose and configure S4 hibernation on Arch Linux
# https://github.com/mokosak/hibernation-fix
set -euo pipefail

VERSION="0.1.0"
BACKUP_ROOT="/var/backups/hibernate-fix"

# ─── output helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
    C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=; C_GRN=; C_YLW=; C_BLU=; C_BLD=; C_RST=
fi
info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }
hdr()   { printf '\n%s── %s ──%s\n' "$C_BLD" "$*" "$C_RST"; }

# ─── args ────────────────────────────────────────────────────────────────────
MODE="dry-run"
SWAP_SIZE=""
CONFIGURE_GPU=1
ENABLE_NVIDIA_MODESET=0
ASSUME_YES=0

usage() {
    cat <<EOF
hibernate-fix $VERSION — configure S4 hibernation on Arch Linux

USAGE
    sudo ./hibernate-fix.sh [OPTIONS]

OPTIONS
    --dry-run              Show what would be changed (default)
    --apply                Apply the changes
    --revert               Restore the most recent backup
    --swap-size SIZE       Swapfile size (e.g. 16G). Default: total RAM
    --no-gpu               Skip GPU-specific configuration
    --nvidia-drm-modeset   Add nvidia-drm.modeset=1 to cmdline (NVIDIA only)
    --yes                  Don't prompt for confirmation on --apply
    -h, --help             This help

SUPPORTED
    Distros:      Arch family (mkinitcpio)
    Bootloaders:  systemd-boot, GRUB, Limine
    Filesystems:  btrfs, ext4
    Encryption:   LUKS (via encrypt hook) or plain
    GPUs:         Intel, AMD, NVIDIA (incl. hybrid)

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --apply) MODE="apply" ;;
        --revert) MODE="revert" ;;
        --swap-size) SWAP_SIZE="$2"; shift ;;
        --no-gpu) CONFIGURE_GPU=0 ;;
        --nvidia-drm-modeset) ENABLE_NVIDIA_MODESET=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done

# ─── preflight ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must run as root. Try: sudo $0 $*"
[[ -f /etc/arch-release ]] || warn "Not Arch Linux — mkinitcpio assumptions may not hold."
command -v mkinitcpio >/dev/null || die "mkinitcpio not found. Only mkinitcpio-based systems are supported."

# ─── revert mode ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "revert" ]]; then
    hdr "Revert"
    latest="$(ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | head -1 || true)"
    [[ -n "$latest" ]] || die "No backups found under $BACKUP_ROOT"
    info "Restoring from: $latest"
    manifest="$latest/manifest"
    [[ -f "$manifest" ]] || die "Backup manifest missing: $manifest"
    while IFS='|' read -r orig rel; do
        [[ -n "$orig" ]] || continue
        if [[ -f "$latest/$rel" ]]; then
            cp -a "$latest/$rel" "$orig"
            ok "Restored $orig"
        fi
    done < "$manifest"
    info "Regenerating initramfs..."
    mkinitcpio -P
    ok "Revert complete. Reboot to take effect."
    exit 0
fi

# ─── detection ───────────────────────────────────────────────────────────────
hdr "Detecting system"

# bootloader
detect_bootloader() {
    if command -v bootctl >/dev/null 2>&1; then
        local bl; bl="$(bootctl status 2>/dev/null | awk -F': *' '/Product:/ {print tolower($2); exit}')"
        case "$bl" in
            systemd-boot*) echo systemd-boot; return ;;
            grub*)         echo grub; return ;;
            limine*)       echo limine; return ;;
        esac
    fi
    [[ -f /boot/loader/loader.conf ]]   && { echo systemd-boot; return; }
    [[ -f /boot/grub/grub.cfg ]]        && { echo grub; return; }
    [[ -f /boot/limine/limine.conf ]]   && { echo limine; return; }
    [[ -f /boot/limine.conf ]]          && { echo limine; return; }
    echo unknown
}
BOOTLOADER="$(detect_bootloader)"
info "Bootloader:   $BOOTLOADER"
[[ "$BOOTLOADER" == "unknown" ]] && die "Could not detect bootloader. Supported: systemd-boot, GRUB, Limine."

# filesystem
ROOT_FS="$(findmnt -no FSTYPE /)"
ROOT_SRC="$(findmnt -no SOURCE /)"
info "Root FS:      $ROOT_FS ($ROOT_SRC)"
case "$ROOT_FS" in
    btrfs|ext4) ;;
    *) die "Unsupported root filesystem: $ROOT_FS (supported: btrfs, ext4)" ;;
esac

# LUKS
LUKS=0
LUKS_HOOK=""
ROOT_SRC_DEV="${ROOT_SRC%%\[*}"   # strip btrfs subvol suffix, e.g. /dev/mapper/root[/@] → /dev/mapper/root
if [[ "$ROOT_SRC_DEV" == /dev/mapper/* ]]; then
    if cryptsetup status "$(basename "$ROOT_SRC_DEV")" 2>/dev/null | grep -q 'type:.*LUKS'; then
        LUKS=1
        # detect which encrypt hook is active
        if grep -qE '^\s*HOOKS=.*\bsd-encrypt\b' /etc/mkinitcpio.conf; then
            LUKS_HOOK=sd-encrypt
        elif grep -qE '^\s*HOOKS=.*\bencrypt\b' /etc/mkinitcpio.conf; then
            LUKS_HOOK=encrypt
        else
            warn "Root is LUKS but neither 'encrypt' nor 'sd-encrypt' hook is in mkinitcpio.conf."
        fi
    fi
fi
info "LUKS:         $([[ $LUKS -eq 1 ]] && echo "yes (hook: ${LUKS_HOOK:-unknown})" || echo no)"

# RAM
RAM_BYTES=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) * 1024 ))
RAM_GB=$(( (RAM_BYTES + 1073741823) / 1073741824 ))
info "RAM:          ${RAM_GB} GiB"

# ACPI sleep
SUPPORTS_S4=0
if grep -qw disk /sys/power/state 2>/dev/null; then SUPPORTS_S4=1; fi
DISK_MODES="$(cat /sys/power/disk 2>/dev/null || echo '')"
info "ACPI S4:      $([[ $SUPPORTS_S4 -eq 1 ]] && echo "supported ($DISK_MODES)" || echo UNSUPPORTED)"
[[ $SUPPORTS_S4 -eq 1 ]] || die "Firmware does not expose S4. Hibernation will not work. Check BIOS for a 'hibernate' or 'modern standby' option."

# existing swap suitable for hibernation
EXISTING_HIBER_SWAP=""
while read -r name type size used prio; do
    [[ "$type" == "partition" || "$type" == "file" ]] || continue
    [[ "$name" == /dev/zram* ]] && continue
    EXISTING_HIBER_SWAP="$name ($size)"
    break
done < <(swapon --noheadings --show 2>/dev/null)

# existing resume= cmdline
case "$BOOTLOADER" in
    systemd-boot) CMDLINE_FILE="$(ls /boot/loader/entries/*.conf 2>/dev/null | head -1)" ;;
    grub)         CMDLINE_FILE=/etc/default/grub ;;
    limine)       CMDLINE_FILE="$( [[ -f /boot/limine/limine.conf ]] && echo /boot/limine/limine.conf || echo /boot/limine.conf )" ;;
esac
EXISTING_RESUME=""
grep -q 'resume=' "$CMDLINE_FILE" 2>/dev/null && EXISTING_RESUME=yes
info "Swap (hiber): ${EXISTING_HIBER_SWAP:-none (zram only)}"
info "resume=:      ${EXISTING_RESUME:-missing}"

# GPU
GPU_INTEL=0; GPU_AMD=0; GPU_NVIDIA=0
while read -r line; do
    v="$(printf '%s' "$line" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | head -1 | cut -d: -f1 | tr -d '[')"
    case "$v" in
        8086) GPU_INTEL=1 ;;
        1002|1022) GPU_AMD=1 ;;
        10de) GPU_NVIDIA=1 ;;
    esac
done < <(lspci -nn 2>/dev/null | grep -E 'VGA|3D|Display')
GPU_SUMMARY=""
[[ $GPU_INTEL -eq 1 ]] && GPU_SUMMARY+="Intel "
[[ $GPU_AMD -eq 1 ]] && GPU_SUMMARY+="AMD "
[[ $GPU_NVIDIA -eq 1 ]] && GPU_SUMMARY+="NVIDIA "
info "GPU:          ${GPU_SUMMARY:-unknown}"

# mkinitcpio resume hook present?
HAS_RESUME_HOOK=0
grep -qE '^\s*HOOKS=.*\bresume\b' /etc/mkinitcpio.conf && HAS_RESUME_HOOK=1
info "resume hook:  $([[ $HAS_RESUME_HOOK -eq 1 ]] && echo present || echo missing)"

# ─── plan ────────────────────────────────────────────────────────────────────
hdr "Plan"

NEED_SWAPFILE=0
if [[ -z "$EXISTING_HIBER_SWAP" ]]; then
    NEED_SWAPFILE=1
    if [[ -z "$SWAP_SIZE" ]]; then
        SWAP_SIZE="${RAM_GB}G"
    fi
    echo "  • Create ${SWAP_SIZE} swapfile at /swap/swapfile (FS: $ROOT_FS)"
else
    echo "  • Use existing swap: $EXISTING_HIBER_SWAP"
fi

[[ $HAS_RESUME_HOOK -eq 0 ]] && echo "  • Add 'resume' hook to /etc/mkinitcpio.conf"
[[ -z "$EXISTING_RESUME" ]] && echo "  • Add resume=... resume_offset=... to $BOOTLOADER cmdline"

if [[ $CONFIGURE_GPU -eq 1 ]]; then
    if [[ $GPU_NVIDIA -eq 1 ]]; then
        echo "  • NVIDIA: enable nvidia-suspend/hibernate/resume services"
        echo "  • NVIDIA: write /etc/modprobe.d/hibernate-fix-nvidia.conf (PreserveVideoMemoryAllocations=1)"
        [[ $ENABLE_NVIDIA_MODESET -eq 1 ]] && echo "  • NVIDIA: add nvidia-drm.modeset=1 to cmdline"
    fi
    [[ $GPU_AMD -eq 1 && $GPU_NVIDIA -eq 0 ]] && echo "  • AMD: no extra config required"
    [[ $GPU_INTEL -eq 1 && $GPU_AMD -eq 0 && $GPU_NVIDIA -eq 0 ]] && echo "  • Intel: no extra config required"
fi

echo "  • Regenerate initramfs (mkinitcpio -P)"
[[ "$BOOTLOADER" == "grub" ]] && echo "  • Regenerate GRUB config (grub-mkconfig)"

# Nothing to do?
if [[ $NEED_SWAPFILE -eq 0 && $HAS_RESUME_HOOK -eq 1 && -n "$EXISTING_RESUME" ]]; then
    ok "Hibernation appears to be fully configured already. Nothing to do."
    exit 0
fi

if [[ "$MODE" == "dry-run" ]]; then
    echo
    info "Dry run — no changes made. Re-run with --apply to execute."
    exit 0
fi

# ─── confirm ─────────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -ne 1 ]]; then
    echo
    read -rp "Proceed with --apply? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

# ─── apply ───────────────────────────────────────────────────────────────────
hdr "Applying"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TS"
mkdir -p "$BACKUP_DIR"
MANIFEST="$BACKUP_DIR/manifest"
: > "$MANIFEST"

backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local rel="${src#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$src" "$BACKUP_DIR/$rel"
    printf '%s|%s\n' "$src" "$rel" >> "$MANIFEST"
}

# swapfile
if [[ $NEED_SWAPFILE -eq 1 ]]; then
    info "Creating swapfile..."
    mkdir -p /swap
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        if ! btrfs subvolume show /swap >/dev/null 2>&1; then
            rmdir /swap 2>/dev/null || true
            btrfs subvolume create /swap
        fi
        btrfs filesystem mkswapfile --size "$SWAP_SIZE" /swap/swapfile
    else
        # ext4
        fallocate -l "$SWAP_SIZE" /swap/swapfile
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile >/dev/null
    fi
    swapon /swap/swapfile
    ok "Swapfile active: /swap/swapfile"

    # fstab
    backup_file /etc/fstab
    if ! grep -qE '^[^#]*\s/swap/swapfile\s' /etc/fstab; then
        printf '\n/swap/swapfile\tnone\tswap\tdefaults\t0 0\n' >> /etc/fstab
        ok "Added swapfile to /etc/fstab"
    fi
fi

# compute resume args
SWAP_PATH="/swap/swapfile"
[[ -n "$EXISTING_HIBER_SWAP" && $NEED_SWAPFILE -eq 0 ]] && SWAP_PATH="${EXISTING_HIBER_SWAP%% *}"

ROOT_UUID="$(findmnt -no UUID /)"

if [[ -f "$SWAP_PATH" ]]; then
    # swapfile
    case "$ROOT_FS" in
        btrfs)
            RESUME_OFFSET="$(btrfs inspect-internal map-swapfile -r "$SWAP_PATH")"
            ;;
        ext4)
            RESUME_OFFSET="$(filefrag -v "$SWAP_PATH" | awk 'NR>3 {print $4; exit}' | tr -d '.')"
            ;;
    esac
    RESUME_SPEC="resume=UUID=$ROOT_UUID resume_offset=$RESUME_OFFSET"
else
    # swap partition
    SWAP_UUID="$(blkid -s UUID -o value "$SWAP_PATH")"
    RESUME_SPEC="resume=UUID=$SWAP_UUID"
fi
info "Resume spec:  $RESUME_SPEC"

# mkinitcpio resume hook
if [[ $HAS_RESUME_HOOK -eq 0 ]]; then
    backup_file /etc/mkinitcpio.conf
    if [[ $LUKS -eq 1 && -n "$LUKS_HOOK" ]]; then
        # insert resume after the encrypt hook
        sed -i -E "s/^(HOOKS=\([^)]*\b$LUKS_HOOK\b)/\1 resume/" /etc/mkinitcpio.conf
    else
        # insert resume before filesystems
        sed -i -E "s/^(HOOKS=\([^)]*)\bfilesystems\b/\1resume filesystems/" /etc/mkinitcpio.conf
    fi
    grep -q 'resume' /etc/mkinitcpio.conf || die "Failed to insert resume hook."
    ok "Added resume hook to /etc/mkinitcpio.conf"
fi

# bootloader cmdline
NVIDIA_MODESET_ADD=""
if [[ $CONFIGURE_GPU -eq 1 && $GPU_NVIDIA -eq 1 && $ENABLE_NVIDIA_MODESET -eq 1 ]]; then
    NVIDIA_MODESET_ADD=" nvidia-drm.modeset=1"
fi

append_cmdline() {
    local add="$1"
    case "$BOOTLOADER" in
        systemd-boot)
            for entry in /boot/loader/entries/*.conf; do
                [[ -f "$entry" ]] || continue
                grep -q 'resume=' "$entry" && continue
                backup_file "$entry"
                sed -i -E "s|^(options .*)$|\1 ${add}|" "$entry"
                ok "Updated $entry"
            done
            ;;
        grub)
            backup_file /etc/default/grub
            if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
                sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)(\")|\1\2 ${add}\3|" /etc/default/grub
            else
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${add}\"" >> /etc/default/grub
            fi
            ok "Updated /etc/default/grub"
            ;;
        limine)
            local cfg
            cfg="$( [[ -f /boot/limine/limine.conf ]] && echo /boot/limine/limine.conf || echo /boot/limine.conf )"
            backup_file "$cfg"
            # append to every 'cmdline:' line that doesn't already have resume=
            sed -i -E "/^[[:space:]]*cmdline:/ { /resume=/!s|$| ${add}| }" "$cfg"
            ok "Updated $cfg"
            ;;
    esac
}

if [[ -z "$EXISTING_RESUME" || -n "$NVIDIA_MODESET_ADD" ]]; then
    ADD="$RESUME_SPEC$NVIDIA_MODESET_ADD"
    [[ -n "$EXISTING_RESUME" ]] && ADD="$NVIDIA_MODESET_ADD"
    append_cmdline "$ADD"
fi

# GPU (NVIDIA)
if [[ $CONFIGURE_GPU -eq 1 && $GPU_NVIDIA -eq 1 ]]; then
    NVCONF=/etc/modprobe.d/hibernate-fix-nvidia.conf
    if [[ ! -f "$NVCONF" ]]; then
        cat > "$NVCONF" <<'EOF'
# written by hibernate-fix
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
EOF
        ok "Wrote $NVCONF"
    fi
    for svc in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
            systemctl enable "$svc" >/dev/null 2>&1 && ok "Enabled $svc" || warn "Could not enable $svc"
        fi
    done
fi

# regenerate initramfs
info "Regenerating initramfs..."
mkinitcpio -P

# regenerate GRUB config if applicable
if [[ "$BOOTLOADER" == "grub" ]]; then
    info "Regenerating GRUB config..."
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# ─── summary ─────────────────────────────────────────────────────────────────
hdr "Done"
ok "Backups saved to: $BACKUP_DIR"
echo
info "Reboot, then test with:  sudo systemctl hibernate"
info "If something is wrong, revert with:  sudo $0 --revert"
