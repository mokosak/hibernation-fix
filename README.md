# hibernate-fix

Set up hibernation (S4) on Arch Linux without pulling your hair out.

## Why this exists

I have a laptop with hybrid Intel + NVIDIA graphics. Suspend gave me a black screen on wake. Hibernate didn't work either — turns out the firmware only exposes `s2idle` and `S4`, which is more common on recent laptops than you'd think. S3 deep sleep is just… gone.

The fix is "just" a swapfile, a `resume` hook, a kernel cmdline change, and an initramfs rebuild. Simple on paper. In practice you're juggling btrfs subvolumes, LUKS ordering quirks, three different bootloaders that all want their cmdline written differently, and — if you have NVIDIA — a couple of systemd services nobody tells you about.

So: a script. Run it once, pick preview/apply/revert in the terminal UI, and it tells you exactly what it is going to do before it writes anything. Every file it edits is backed up. If anything goes sideways, `--revert` puts it all back.

## What it does

1. Detects your bootloader (systemd-boot / GRUB / Limine), root filesystem (btrfs / ext4), whether root is on LUKS, your GPU vendor, and whether firmware actually supports S4.
2. Creates a swapfile the right way for your filesystem (btrfs needs a dedicated subvolume + `mkswapfile`; ext4 just needs `fallocate`).
3. Adds the `resume` hook to `/etc/mkinitcpio.conf` in the right position (after `encrypt`/`sd-encrypt` if you use LUKS, otherwise before `filesystems`).
4. Computes `resume_offset` using the correct tool for your filesystem and appends `resume=UUID=... resume_offset=...` to your bootloader's cmdline.
5. For NVIDIA: writes a modprobe config with `NVreg_PreserveVideoMemoryAllocations=1` and enables `nvidia-{suspend,hibernate,resume}.service`, which is what actually stops you waking up to a black screen.
6. Rebuilds the initramfs (and regenerates GRUB config if you're on GRUB).

For AMD or Intel-only systems: nothing GPU-specific is needed — the kernel drivers handle it — so the script just confirms and moves on.

## Supported setups

|                | Supported                                  |
|----------------|--------------------------------------------|
| Distros        | Arch family (anything using mkinitcpio)    |
| Bootloaders    | systemd-boot, GRUB, Limine                 |
| Filesystems    | btrfs, ext4                                |
| Encryption     | LUKS (via `encrypt` or `sd-encrypt`), none |
| GPUs           | Intel, AMD, NVIDIA, any hybrid combo       |

If your setup is outside this matrix, the script aborts with a clear error rather than making half-correct edits.

## Usage

```bash
# Open the terminal UI:
sudo ./hibernate-fix.sh

# Or run a plain preview with no TUI:
./hibernate-fix.sh --dry-run

# Apply the changes:
sudo ./hibernate-fix.sh --apply

# For NVIDIA/hybrid laptops, you may also want:
sudo ./hibernate-fix.sh --apply --nvidia-drm-modeset

# Roll back the most recent run:
sudo ./hibernate-fix.sh --revert
```

Then reboot and:

```bash
sudo systemctl hibernate
```

### Options

- `--dry-run` — show the plan, make no changes (default)
- `--apply` — actually do it
- `--revert` — restore the most recent backup
- `--swap-size SIZE` — e.g. `16G`. Defaults to your total RAM, which is the realistic minimum for hibernation
- `--no-gpu` — skip the GPU-specific steps
- `--nvidia-drm-modeset` — add `nvidia-drm.modeset=1` to cmdline (NVIDIA only)
- `--yes` / `-y` — skip the "proceed?" prompt
- `--tui` — force the terminal UI

## Safety

- `--dry-run` is the default. You have to ask for changes.
- In an interactive terminal, running with no arguments opens the TUI. The first action is still preview, not apply.
- Every file touched is copied to `/var/backups/hibernate-fix/<timestamp>/` before being edited, along with a manifest so `--revert` knows what to restore.
- Re-runs are idempotent: if hibernation is already configured, it says so and exits.
- Unsupported hardware / missing S4 / unknown bootloader → hard error, no edits.

## Caveats

- **BIOS has to support S4.** The script checks and aborts if not. Some laptops hide this as "Hibernate" or "Modern Standby off" in firmware settings — worth a look in UEFI before giving up.
- **Swap size ≥ RAM** is the rule of thumb. Less than that and the kernel may refuse to snapshot.
- **Secure Boot users**: after `mkinitcpio -P`, you'll need to re-sign the new initramfs if your setup requires it. The script does not handle signing.
- **UKI (Unified Kernel Image)** setups aren't supported yet — the cmdline lives inside the UKI, not in a bootloader entry file.
- **Non-Arch distros**: only Arch-family (mkinitcpio) for now. Dracut/booster support is a different script.

## What "it worked" looks like

1. `sudo systemctl hibernate` — the machine powers off (not just screen-off).
2. Press power — boot sequence starts, bootloader appears.
3. LUKS prompt (if encrypted), then instead of booting fresh, the initramfs `resume` hook restores the snapshot.
4. You're back where you were, apps and all.

If step 4 turns into a fresh boot instead, check `journalctl -b -1 | grep -iE 'hibern|resume'` — usually either the offset is wrong or the `resume` hook fired too early/late relative to `encrypt`.

## License

MIT. See [LICENSE](LICENSE).
