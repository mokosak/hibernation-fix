#!/usr/bin/env bash
# hibernate-fix - diagnose and configure S4 hibernation on Arch Linux.
set -Eeuo pipefail

VERSION="0.2.0"
BACKUP_ROOT="/var/backups/hibernate-fix"

MODE="dry-run"
SWAP_SIZE=""
CONFIGURE_GPU=1
ENABLE_NVIDIA_MODESET=0
ASSUME_YES=0
TUI_MODE=0
TUI_RAN=0
ARG_COUNT=0

BOOTLOADER=
ROOT_FS=
ROOT_SRC=
ROOT_SRC_DEV=
ROOT_UUID=
LUKS=0
LUKS_HOOK=
RAM_BYTES=0
RAM_GB=0
SUPPORTS_S4=0
DISK_MODES=
EXISTING_HIBER_SWAP=
EXISTING_HIBER_SWAP_SIZE=0
EXISTING_SWAP_TOO_SMALL=
NEED_SWAPFILE=0
HAS_RESUME_HOOK=0
GPU_INTEL=0
GPU_AMD=0
GPU_NVIDIA=0
GPU_SUMMARY=
BACKUP_DIR=
MANIFEST=
CMDLINE_FILES=()

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RST=$'\033[0m'
    C_BLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[38;5;160m'
    C_GRN=$'\033[38;5;108m'
    C_YLW=$'\033[38;5;179m'
    C_BLU=$'\033[38;5;75m'
    C_CYN=$'\033[38;5;109m'
else
    C_RST= C_BLD= C_DIM= C_RED= C_GRN= C_YLW= C_BLU= C_CYN=
fi

info() { printf '%b::%b %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%b[ok]%b %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%b!!%b %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()  { printf '%bxx%b %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%b== %s ==%b\n' "$C_BLD" "$*" "$C_RST"; }

usage() {
    cat <<EOF
hibernate-fix $VERSION - configure S4 hibernation on Arch Linux

Usage:
  sudo ./hibernate-fix.sh [options]

Options:
  --dry-run              Show the plan and change nothing (default)
  --apply                Apply the changes
  --revert               Restore the most recent backup
  --swap-size SIZE       Swapfile size, for example 16G. Default: total RAM
  --no-gpu               Skip GPU-specific configuration
  --nvidia-drm-modeset   Add nvidia-drm.modeset=1 to cmdline for NVIDIA
  --yes, -y              Skip the final apply prompt
  --tui                  Force the terminal UI
  -h, --help             Show help

No arguments in an interactive terminal opens the TUI.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run) MODE="dry-run" ;;
            --apply) MODE="apply" ;;
            --revert) MODE="revert" ;;
            --swap-size)
                shift
                [[ ${1:-} ]] || die "--swap-size needs a value"
                SWAP_SIZE=$1
                ;;
            --no-gpu) CONFIGURE_GPU=0 ;;
            --nvidia-drm-modeset) ENABLE_NVIDIA_MODESET=1 ;;
            --yes|-y) ASSUME_YES=1 ;;
            --tui) TUI_MODE=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done
}

require_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "must run as root"
    if (( TUI_RAN )); then
        local args=()
        case "$MODE" in
            apply) args+=(--apply) ;;
            revert) args+=(--revert) ;;
            *) args+=(--dry-run) ;;
        esac
        [[ -n $SWAP_SIZE ]] && args+=(--swap-size "$SWAP_SIZE")
        (( CONFIGURE_GPU == 0 )) && args+=(--no-gpu)
        (( ENABLE_NVIDIA_MODESET )) && args+=(--nvidia-drm-modeset)
        (( ASSUME_YES )) && args+=(--yes)
        exec sudo -E "$0" "${args[@]}"
    fi
    exec sudo -E "$0" "$@"
}

run() {
    if [[ $MODE == "dry-run" ]]; then
        printf '%b[dry]%b %s\n' "$C_YLW" "$C_RST" "$*"
        return 0
    fi
    "$@"
}

confirm_apply() {
    (( ASSUME_YES )) && return 0
    local reply
    printf '\nProceed with apply? [y/N] '
    IFS= read -r reply || return 1
    [[ $reply =~ ^[Yy]$ ]]
}

backup_file() {
    local src=$1 rel
    [[ -f $src ]] || return 0
    rel=${src#/}
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$src" "$BACKUP_DIR/$rel"
    printf '%s|%s\n' "$src" "$rel" >> "$MANIFEST"
}

write_root_file() {
    local dest=$1 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        ok "unchanged: $dest"
        return 0
    fi
    backup_file "$dest"
    install -D -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    ok "wrote $dest"
}

term_cols() { tput cols 2>/dev/null || printf '80'; }
repeat_char() { local c=$1 n=$2 out=; while (( n-- > 0 )); do out+=$c; done; printf '%s' "$out"; }

visible_len() {
    local text=$1 i=0 len=0 ch
    while (( i < ${#text} )); do
        ch=${text:i:1}
        if [[ $ch == $'\033' ]]; then
            i=$((i + 1))
            while (( i < ${#text} )); do
                ch=${text:i:1}
                i=$((i + 1))
                [[ $ch == [A-Za-z] ]] && break
            done
        else
            len=$((len + 1))
            i=$((i + 1))
        fi
    done
    printf '%d' "$len"
}

pad_right() {
    local text=$1 width=$2 len
    len=$(visible_len "$text")
    printf '%s' "$text"
    (( len < width )) && printf '%*s' "$((width - len))" ''
}

box_top() {
    local width=$1 title=${2:-} inner=$((width - 2))
    printf '  %b+' "$C_CYN"; repeat_char "-" "$inner"; printf '+%b\n' "$C_RST"
    if [[ -n $title ]]; then
        printf '  %b|%b ' "$C_CYN" "$C_RST"
        pad_right "${C_BLD}${title}${C_RST}" "$((inner - 1))"
        printf '%b|%b\n' "$C_CYN" "$C_RST"
        printf '  %b+' "$C_CYN"; repeat_char "-" "$inner"; printf '+%b\n' "$C_RST"
    fi
}

box_line() {
    local width=$1 text=${2:-} inner=$((width - 2))
    printf '  %b|%b ' "$C_CYN" "$C_RST"
    pad_right "$text" "$((inner - 1))"
    printf '%b|%b\n' "$C_CYN" "$C_RST"
}

box_bottom() {
    local width=$1 inner=$((width - 2))
    printf '  %b+' "$C_CYN"; repeat_char "-" "$inner"; printf '+%b\n' "$C_RST"
}

read_key() {
    local key seq rest
    IFS= read -rsn1 key || return 1
    case "$key" in
        "") printf enter; return ;;
        " ") printf space; return ;;
        $'\033')
            seq=$key
            while IFS= read -rsn1 -t 0.01 rest; do
                seq+=$rest
                [[ $rest == [A-Za-z~] ]] && break
                ((${#seq} >= 12)) && break
            done
            case "$seq" in
                $'\033[A'|$'\033OA'|$'\033['*A) printf up ;;
                $'\033[B'|$'\033OB'|$'\033['*B) printf down ;;
                $'\033[C'|$'\033OC'|$'\033['*C) printf right ;;
                $'\033[D'|$'\033OD'|$'\033['*D) printf left ;;
                *) printf escape ;;
            esac
            ;;
        *) printf '%s' "$key" ;;
    esac
}

tui_action_label() {
    case "$MODE" in
        dry-run) printf '%bpreview only%b' "$C_YLW" "$C_RST" ;;
        apply) printf '%bapply changes%b' "$C_RED" "$C_RST" ;;
        revert) printf '%brevert latest backup%b' "$C_GRN" "$C_RST" ;;
    esac
}

tui_cycle_mode() {
    case "$MODE" in
        dry-run) MODE=apply ;;
        apply) MODE=revert ;;
        *) MODE=dry-run ;;
    esac
}

tui_render() {
    local width cols
    cols=$(term_cols)
    (( cols < 86 )) && width=$((cols - 4)) || width=86
    (( width < 66 )) && width=66
    printf '\033[H'
    box_top "$width"
    box_line "$width" "${C_BLD}hibernate-fix${C_RST}  ${C_DIM}Arch S4 setup: swap, resume, bootloader${C_RST}"
    box_line "$width" "${C_DIM}action:${C_RST} $(tui_action_label)  ${C_DIM}swap:${C_RST} ${SWAP_SIZE:-RAM size}  ${C_DIM}gpu:${C_RST} $([[ $CONFIGURE_GPU -eq 1 ]] && printf on || printf off)"
    box_bottom "$width"
    printf '\n'
    box_top "$width" "controls"
    box_line "$width" "m  cycle action"
    box_line "$width" "g  toggle GPU configuration"
    box_line "$width" "n  toggle NVIDIA drm modeset"
    box_line "$width" "enter  run selected action"
    box_line "$width" "q  quit"
    box_line "$width" ""
    box_line "$width" "${C_DIM}NVIDIA drm modeset:${C_RST} $([[ $ENABLE_NVIDIA_MODESET -eq 1 ]] && printf enabled || printf disabled)"
    box_line "$width" "${C_DIM}Use --swap-size 16G if you want a fixed size from CLI.${C_RST}"
    box_bottom "$width"
    printf '\033[J'
}

run_tui() {
    local key
    TUI_RAN=1
    printf '\033[?1049h\033[?25l\033[2J'
    trap 'printf "\033[?25h\033[?1049l%b" "$C_RST"' EXIT
    while :; do
        tui_render
        key=$(read_key)
        case "$key" in
            m|M|right|space) tui_cycle_mode ;;
            g|G) CONFIGURE_GPU=$((CONFIGURE_GPU ? 0 : 1)) ;;
            n|N) ENABLE_NVIDIA_MODESET=$((ENABLE_NVIDIA_MODESET ? 0 : 1)) ;;
            enter) break ;;
            q|Q|escape) printf '\033[?25h\033[?1049l%b' "$C_RST"; trap - EXIT; exit 1 ;;
        esac
    done
    printf '\033[?25h\033[?1049l%b' "$C_RST"
    trap - EXIT
}

detect_bootloader() {
    if command -v bootctl >/dev/null 2>&1; then
        local bl
        bl=$(bootctl status 2>/dev/null | awk -F': *' '/Product:/ {print tolower($2); exit}')
        case "$bl" in
            systemd-boot*) echo systemd-boot; return ;;
            grub*) echo grub; return ;;
            limine*) echo limine; return ;;
        esac
    fi
    [[ -f /boot/loader/loader.conf ]] && { echo systemd-boot; return; }
    [[ -f /boot/grub/grub.cfg || -f /etc/default/grub ]] && { echo grub; return; }
    [[ -f /boot/limine/limine.conf || -f /boot/limine.conf ]] && { echo limine; return; }
    echo unknown
}

detect_cmdline_files() {
    CMDLINE_FILES=()
    case "$BOOTLOADER" in
        systemd-boot)
            local entry
            for entry in /boot/loader/entries/*.conf; do
                [[ -f $entry ]] && CMDLINE_FILES+=("$entry")
            done
            ;;
        grub) [[ -f /etc/default/grub ]] && CMDLINE_FILES+=(/etc/default/grub) ;;
        limine)
            if [[ -f /boot/limine/limine.conf ]]; then
                CMDLINE_FILES+=(/boot/limine/limine.conf)
            elif [[ -f /boot/limine.conf ]]; then
                CMDLINE_FILES+=(/boot/limine.conf)
            fi
            ;;
    esac
    ((${#CMDLINE_FILES[@]})) || die "could not find cmdline file for $BOOTLOADER"
}

cmdline_has_token_prefix() {
    local prefix=$1 file
    for file in "${CMDLINE_FILES[@]}"; do
        grep -qE "(^|[[:space:]\"])"$prefix "$file" 2>/dev/null && return 0
    done
    return 1
}

cmdline_all_have_token_prefix() {
    local prefix=$1 file
    for file in "${CMDLINE_FILES[@]}"; do
        grep -qE "(^|[[:space:]\"])"$prefix "$file" 2>/dev/null || return 1
    done
    return 0
}

detect_luks() {
    LUKS=0
    LUKS_HOOK=
    ROOT_SRC_DEV="${ROOT_SRC%%\[*}"
    if [[ $ROOT_SRC_DEV == /dev/mapper/* ]] && command -v cryptsetup >/dev/null 2>&1; then
        if cryptsetup status "$(basename "$ROOT_SRC_DEV")" 2>/dev/null | grep -q 'type:.*LUKS'; then
            LUKS=1
            if grep -qE '^[[:space:]]*HOOKS=.*\bsd-encrypt\b' /etc/mkinitcpio.conf; then
                LUKS_HOOK=sd-encrypt
            elif grep -qE '^[[:space:]]*HOOKS=.*\bencrypt\b' /etc/mkinitcpio.conf; then
                LUKS_HOOK=encrypt
            fi
        fi
    fi
}

detect_swap() {
    EXISTING_HIBER_SWAP=
    EXISTING_HIBER_SWAP_SIZE=0
    EXISTING_SWAP_TOO_SMALL=
    local name type size
    while read -r name type size; do
        [[ -n ${name:-} ]] || continue
        [[ $name == /dev/zram* ]] && continue
        [[ $type == partition || $type == file ]] || continue
        if (( size >= RAM_BYTES )); then
            EXISTING_HIBER_SWAP=$name
            EXISTING_HIBER_SWAP_SIZE=$size
            return 0
        fi
        EXISTING_SWAP_TOO_SMALL="$name ($((size / 1024 / 1024 / 1024)) GiB)"
    done < <(swapon --bytes --noheadings --show=NAME,TYPE,SIZE 2>/dev/null || true)
}

detect_gpu() {
    local line vendor
    GPU_INTEL=0; GPU_AMD=0; GPU_NVIDIA=0; GPU_SUMMARY=
    while read -r line; do
        vendor=$(printf '%s' "$line" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | head -1 | cut -d: -f1 | tr -d '[')
        case "$vendor" in
            8086) GPU_INTEL=1 ;;
            1002|1022) GPU_AMD=1 ;;
            10de) GPU_NVIDIA=1 ;;
        esac
    done < <(lspci -nn 2>/dev/null | grep -E 'VGA|3D|Display' || true)
    (( GPU_INTEL )) && GPU_SUMMARY+="Intel "
    (( GPU_AMD )) && GPU_SUMMARY+="AMD "
    (( GPU_NVIDIA )) && GPU_SUMMARY+="NVIDIA "
    GPU_SUMMARY=${GPU_SUMMARY:-unknown}
}

detect_system() {
    hdr "Detecting system"
    [[ -f /etc/arch-release ]] || warn "not Arch Linux; mkinitcpio assumptions may not hold"
    command -v mkinitcpio >/dev/null 2>&1 || die "mkinitcpio not found; only mkinitcpio systems are supported"

    BOOTLOADER=$(detect_bootloader)
    [[ $BOOTLOADER != unknown ]] || die "could not detect bootloader: supported systemd-boot, GRUB, Limine"
    detect_cmdline_files

    ROOT_FS=$(findmnt -no FSTYPE /)
    ROOT_SRC=$(findmnt -no SOURCE /)
    case "$ROOT_FS" in
        btrfs|ext4) ;;
        *) die "unsupported root filesystem: $ROOT_FS (supported: btrfs, ext4)" ;;
    esac

    detect_luks

    RAM_BYTES=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) * 1024 ))
    RAM_GB=$(( (RAM_BYTES + 1073741823) / 1073741824 ))
    [[ -n $SWAP_SIZE ]] || SWAP_SIZE="${RAM_GB}G"

    if grep -qw disk /sys/power/state 2>/dev/null; then
        SUPPORTS_S4=1
    fi
    DISK_MODES=$(cat /sys/power/disk 2>/dev/null || true)
    (( SUPPORTS_S4 )) || die "firmware does not expose S4/disk in /sys/power/state"

    detect_swap
    grep -qE '^[[:space:]]*HOOKS=.*\bresume\b' /etc/mkinitcpio.conf && HAS_RESUME_HOOK=1 || HAS_RESUME_HOOK=0
    detect_gpu

    info "bootloader:   $BOOTLOADER (${CMDLINE_FILES[*]})"
    info "root fs:      $ROOT_FS ($ROOT_SRC)"
    info "luks:         $([[ $LUKS -eq 1 ]] && printf 'yes (%s)' "${LUKS_HOOK:-hook missing}" || printf no)"
    info "ram:          ${RAM_GB} GiB"
    info "acpi s4:      supported (${DISK_MODES:-unknown disk modes})"
    if [[ -n $EXISTING_HIBER_SWAP ]]; then
        info "swap:         $EXISTING_HIBER_SWAP ($((EXISTING_HIBER_SWAP_SIZE / 1024 / 1024 / 1024)) GiB)"
    else
        info "swap:         none suitable"
        [[ -n $EXISTING_SWAP_TOO_SMALL ]] && warn "existing swap is smaller than RAM: $EXISTING_SWAP_TOO_SMALL"
    fi
    info "resume hook:  $([[ $HAS_RESUME_HOOK -eq 1 ]] && printf present || printf missing)"
    info "resume arg:   $(cmdline_all_have_token_prefix 'resume=' && printf present || printf missing)"
    info "gpu:          $GPU_SUMMARY"
}

plan() {
    hdr "Plan"
    NEED_SWAPFILE=0
    if [[ -z $EXISTING_HIBER_SWAP ]]; then
        NEED_SWAPFILE=1
        printf '  - create %s swapfile at /swap/swapfile (%s)\n' "$SWAP_SIZE" "$ROOT_FS"
    else
        printf '  - use existing swap: %s\n' "$EXISTING_HIBER_SWAP"
    fi
    (( HAS_RESUME_HOOK == 0 )) && printf "  - add resume hook to /etc/mkinitcpio.conf\n"
    cmdline_all_have_token_prefix 'resume=' || printf '  - add resume=... to %s cmdline\n' "$BOOTLOADER"
    if (( CONFIGURE_GPU && GPU_NVIDIA )); then
        printf '  - enable NVIDIA hibernate services and preserve video memory\n'
        (( ENABLE_NVIDIA_MODESET )) && printf '  - add nvidia-drm.modeset=1\n'
    elif (( CONFIGURE_GPU )); then
        printf '  - no GPU-specific config required for %s\n' "$GPU_SUMMARY"
    fi
    printf '  - rebuild initramfs with mkinitcpio -P\n'
    [[ $BOOTLOADER == grub ]] && printf '  - regenerate GRUB config\n'
}

create_swapfile() {
    [[ -e /swap/swapfile ]] && die "/swap/swapfile already exists but is not active; inspect it before re-running"
    info "creating swapfile: /swap/swapfile"
    if [[ $ROOT_FS == btrfs ]]; then
        command -v btrfs >/dev/null 2>&1 || die "btrfs command missing"
        if [[ -d /swap ]] && ! btrfs subvolume show /swap >/dev/null 2>&1; then
            rmdir /swap 2>/dev/null || die "/swap exists and is not an empty btrfs subvolume"
        fi
        [[ -d /swap ]] || btrfs subvolume create /swap
        btrfs filesystem mkswapfile --size "$SWAP_SIZE" /swap/swapfile
    else
        mkdir -p /swap
        fallocate -l "$SWAP_SIZE" /swap/swapfile
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile >/dev/null
    fi
    swapon /swap/swapfile
    backup_file /etc/fstab
    if ! grep -qE '^[^#]*[[:space:]]/swap/swapfile[[:space:]]' /etc/fstab; then
        printf '\n/swap/swapfile\tnone\tswap\tdefaults\t0 0\n' >> /etc/fstab
        ok "added swapfile to /etc/fstab"
    fi
}

resume_spec() {
    local swap_path=$1 uuid offset
    if [[ -f $swap_path ]]; then
        uuid=$(findmnt -no UUID -T "$swap_path" 2>/dev/null | head -1)
        [[ -n $uuid ]] || uuid=$(findmnt -no UUID / 2>/dev/null | head -1)
        [[ -n $uuid ]] || die "could not resolve filesystem UUID for $swap_path"
        case "$ROOT_FS" in
            btrfs) offset=$(btrfs inspect-internal map-swapfile -r "$swap_path") ;;
            ext4) offset=$(filefrag -v "$swap_path" | awk '/^[[:space:]]*[0-9]+:/ {gsub(/\./, "", $4); print $4; exit}') ;;
        esac
        [[ -n ${offset:-} ]] || die "could not compute resume_offset for $swap_path"
        printf 'resume=UUID=%s resume_offset=%s' "$uuid" "$offset"
    else
        uuid=$(blkid -s UUID -o value "$swap_path")
        [[ -n $uuid ]] || die "could not resolve swap UUID for $swap_path"
        printf 'resume=UUID=%s' "$uuid"
    fi
}

add_resume_hook() {
    (( HAS_RESUME_HOOK )) && return 0
    backup_file /etc/mkinitcpio.conf
    if (( LUKS )) && [[ -n $LUKS_HOOK ]]; then
        sed -i -E "s/(^HOOKS=\([^)]*\b${LUKS_HOOK}\b)/\1 resume/" /etc/mkinitcpio.conf
    else
        sed -i -E 's/(^HOOKS=\([^)]*)\bfilesystems\b/\1resume filesystems/' /etc/mkinitcpio.conf
    fi
    grep -qE '^[[:space:]]*HOOKS=.*\bresume\b' /etc/mkinitcpio.conf || die "failed to insert resume hook"
    ok "added resume hook"
}

missing_tokens_for_file() {
    local file=$1 add=$2 token out=
    for token in $add; do
        if [[ $token == resume=* ]]; then
            grep -qE '(^|[[:space:]\"])resume=' "$file" 2>/dev/null && continue
        elif grep -qF "$token" "$file" 2>/dev/null; then
            continue
        fi
        out+=" $token"
    done
    printf '%s' "${out# }"
}

append_cmdline_file() {
    local file=$1 add=$2 missing
    missing=$(missing_tokens_for_file "$file" "$add")
    [[ -n $missing ]] || return 0
    backup_file "$file"
    case "$BOOTLOADER" in
        systemd-boot)
            sed -i -E "0,/^[[:space:]]*options[[:space:]]/s|^([[:space:]]*options[[:space:]].*)$|\1 ${missing}|" "$file"
            ;;
        grub)
            if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$file"; then
                sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)(\")|\1\2 ${missing}\3|" "$file"
            elif grep -q '^GRUB_CMDLINE_LINUX=' "$file"; then
                sed -i -E "s|^(GRUB_CMDLINE_LINUX=\")([^\"]*)(\")|\1\2 ${missing}\3|" "$file"
            else
                printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$missing" >> "$file"
            fi
            ;;
        limine)
            sed -i -E "/^[[:space:]]*cmdline:/s|$| ${missing}|" "$file"
            ;;
    esac
    ok "updated $file"
}

append_cmdline() {
    local add=$1 file
    for file in "${CMDLINE_FILES[@]}"; do
        append_cmdline_file "$file" "$add"
    done
}

configure_nvidia() {
    (( CONFIGURE_GPU && GPU_NVIDIA )) || return 0
    write_root_file /etc/modprobe.d/hibernate-fix-nvidia.conf <<'EOF'
# written by hibernate-fix
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
EOF
    local svc
    for svc in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
            systemctl enable "$svc" >/dev/null 2>&1 && ok "enabled $svc" || warn "could not enable $svc"
        fi
    done
}

apply_changes() {
    confirm_apply || { info "aborted"; exit 0; }

    hdr "Applying"
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    MANIFEST="$BACKUP_DIR/manifest"
    mkdir -p "$BACKUP_DIR"
    : > "$MANIFEST"

    local swap_path add
    if (( NEED_SWAPFILE )); then
        create_swapfile
        swap_path=/swap/swapfile
    else
        swap_path=$EXISTING_HIBER_SWAP
    fi

    add=$(resume_spec "$swap_path")
    if (( CONFIGURE_GPU && GPU_NVIDIA && ENABLE_NVIDIA_MODESET )); then
        add+=" nvidia-drm.modeset=1"
    fi

    add_resume_hook
    append_cmdline "$add"
    configure_nvidia

    info "regenerating initramfs"
    mkinitcpio -P
    if [[ $BOOTLOADER == grub ]]; then
        info "regenerating GRUB config"
        grub-mkconfig -o /boot/grub/grub.cfg
    fi

    hdr "Done"
    ok "backups saved to: $BACKUP_DIR"
    info "reboot, then test with: sudo systemctl hibernate"
    info "revert with: sudo $0 --revert"
}

revert_latest() {
    hdr "Revert"
    local latest manifest orig rel
    latest=$(ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | head -1 || true)
    [[ -n $latest ]] || die "no backups found under $BACKUP_ROOT"
    manifest="$latest/manifest"
    [[ -f $manifest ]] || die "backup manifest missing: $manifest"
    info "restoring from: $latest"
    while IFS='|' read -r orig rel; do
        [[ -n ${orig:-} ]] || continue
        if [[ -f "$latest/$rel" ]]; then
            install -D -m 0644 "$latest/$rel" "$orig"
            ok "restored $orig"
        fi
    done < "$manifest"
    info "regenerating initramfs"
    mkinitcpio -P
    ok "revert complete; reboot to take effect"
}

main() {
    ARG_COUNT=$#
    parse_args "$@"

    if [[ $TUI_MODE -eq 1 || ( $ARG_COUNT -eq 0 && -t 0 && -t 1 ) ]]; then
        run_tui
    fi

    if [[ $MODE == revert ]]; then
        require_root "$@"
        revert_latest
        exit 0
    fi

    [[ $MODE == apply ]] && require_root "$@"
    detect_system
    plan

    if [[ $MODE == dry-run ]]; then
        printf '\n'
        info "dry run complete; no changes made"
        info "run with --apply, or use the TUI action toggle, to write changes"
        exit 0
    fi

    apply_changes
}

main "$@"
