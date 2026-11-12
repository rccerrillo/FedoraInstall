#!/usr/bin/env bash
# =============================================================================
# 01-fedora-install.sh
# Fedora 45 on one NVMe: LUKS2 (PBKDF2, GRUB-readable) + btrfs + Snapper-ready
# subvolumes, /boot inside the encrypted root, shim + signed GRUB (Secure Boot),
# one passphrase per boot (keyfile in the initramfs), zram, big Terminus font.
# The Fedora counterpart of 01-debian-stable-install.sh: dnf --installroot
# plays the part of debootstrap.
#
# Run from a Fedora 45 LIVE USB session (KDE live is fine), as root:
#   sudo -i
#   ./01-fedora-install.sh            # full install (default)
#   ./01-fedora-install.sh check      # unlock + mount the installed system, run checks
#   ./01-fedora-install.sh mount      # unlock + mount it at /mnt for a rescue chroot
#
# Firmware first (Dell Precision 3561): Storage = AHCI/NVMe (not "RAID On"),
# VT-x + VT-d on, Secure Boot OFF for the install (turn it on afterwards).
#
# Layout:
#   p1  1 GiB  FAT32 ESP            -> /boot/efi   (shim + GRUB + a small grub.cfg stub)
#   p2  rest   LUKS2 -> luks-<UUID> -> btrfs
#        @                     -> /                         (includes /boot; snapshotted)
#        @home                 -> /home
#        @snapshots            -> /.snapshots
#        @var_log              -> /var/log
#        @var_cache            -> /var/cache
#        @var_tmp              -> /var/tmp
#        @flatpak              -> /var/lib/flatpak          (apps stay out of snapshots)
#        @plasmalogin          -> /var/lib/plasmalogin      (login screen works when
#                                                            booting a read-only snapshot)
#        @libvirt_images       -> /var/lib/libvirt/images   (chattr +C, no CoW)
#
# How the "type it once" unlock works on Fedora:
#   GRUB unlocks LUKS (cryptomount in the ESP stub) and reads /boot from @.
#   The initramfs (dracut) carries /etc/cryptsetup-keys.d/luks-<UUID>.key, so
#   systemd-cryptsetup opens the disk again with no second prompt.
#   /usr/local/bin/encboot-fixup re-applies the ESP stub and BLS paths after
#   every dnf transaction and kernel install, because Fedora's grub2 updates
#   rewrite the ESP grub.cfg without the cryptomount line.
#
# After the reboot, log in on the TTY, connect with
#   nmcli device wifi connect "<SSID>" --ask
# then run 02-fedora-postinstall.sh as your normal user.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Settings (defaults; most are asked for interactively)
# -----------------------------------------------------------------------------
MNT=/mnt
RELEASEVER=45
ESP_SIZE=1G
PBKDF_ITER_MS=1500          # keeps GRUB's (slow) PBKDF2 unlock to a few seconds
BTRFS_OPTS=noatime,compress=zstd:1,space_cache=v2
CONSOLE_FONT=ter-v32n       # Terminus 16x32 (initramfs + plain getty)
KMSCON_FONT_SIZE=20         # tty1-6 run kmscon on Fedora 45
# No 'rhgb quiet' so you can see where boot stops. Add it later in /etc/default/grub.
KERNEL_CMDLINE="intel_iommu=on iommu=pt"
LOG=/root/01-fedora-install.log

# Subvolume -> mountpoint (order matters: @ first, parents before children)
SUBVOLS=(@ @home @snapshots @var_log @var_cache @var_tmp @flatpak @plasmalogin @libvirt_images)
declare -A SUBVOL_MNT=(
  [@]=/
  [@home]=/home
  [@snapshots]=/.snapshots
  [@var_log]=/var/log
  [@var_cache]=/var/cache
  [@var_tmp]=/var/tmp
  [@flatpak]=/var/lib/flatpak
  [@plasmalogin]=/var/lib/plasmalogin
  [@libvirt_images]=/var/lib/libvirt/images
)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" &>/dev/null; }

yesno() {
  local prompt=$1 default=${2:-n} reply hint
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$prompt $hint " reply || true
  reply=${reply:-$default}
  [[ ${reply,,} == y* ]]
}

ask() {   # ask VAR "Prompt" "default"
  local __var=$1 prompt=$2 default=${3:-} reply
  read -r -p "$prompt${default:+ [$default]}: " reply || true
  printf -v "$__var" '%s' "${reply:-$default}"
}

# Partition device name: nvme0n1 -> nvme0n1p1, sda -> sda1
part() { [[ $1 =~ [0-9]$ ]] && echo "${1}p$2" || echo "${1}$2"; }

FAILS=0
check() {  # check "description" command...
  local desc=$1; shift
  if "$@" &>/dev/null; then ok "$desc"; else warn "FAIL: $desc"; FAILS=$((FAILS+1)); fi
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root: 'sudo -i' first, then run this script."; }

live_tools() {
  local need=()
  have arch-chroot || need+=(arch-install-scripts)
  have sgdisk      || need+=(gdisk)
  have mkfs.btrfs  || need+=(btrfs-progs)
  have cryptsetup  || need+=(cryptsetup)
  have mkfs.fat    || need+=(dosfstools)
  have cpio        || need+=(cpio)
  have efibootmgr  || need+=(efibootmgr)
  have setfiles    || need+=(policycoreutils)
  if ((${#need[@]})); then
    dnf -y install "${need[@]}"
  fi
}

# -----------------------------------------------------------------------------
# Mount / unmount the target (used by install, check and mount)
# -----------------------------------------------------------------------------
mount_target() {
  local dev=/dev/mapper/$MAPPER sv mp opts
  mountpoint -q "$MNT" && return 0
  for sv in "${SUBVOLS[@]}"; do
    mp=$MNT${SUBVOL_MNT[$sv]}
    mkdir -p "$mp"
    opts="$BTRFS_OPTS,subvol=/$sv"
    [[ $sv == @libvirt_images ]] && opts="noatime,subvol=/$sv"   # no compression on VM images
    mount -o "$opts" "$dev" "$mp"
  done
  mkdir -p "$MNT/boot/efi"
  mount "$ESP" "$MNT/boot/efi"
}

umount_target() {
  sync
  umount -R "$MNT" 2>/dev/null || true
  cryptsetup close "$MAPPER" 2>/dev/null || true
}

find_disk_parts() {
  ESP=$(part "$DISK" 1)
  LUKSPART=$(part "$DISK" 2)
  [[ -b $ESP && -b $LUKSPART ]] || die "Expected $ESP and $LUKSPART to exist."
}

set_mapper() {   # Fedora's naming: luks-<UUID>, same as crypttab and rd.luks.uuid
  LUKS_UUID=$(blkid -s UUID -o value "$LUKSPART")
  [[ -n $LUKS_UUID ]] || die "$LUKSPART has no LUKS UUID."
  MAPPER=luks-$LUKS_UUID
}

open_luks() {
  set_mapper
  [[ -e /dev/mapper/$MAPPER ]] && return 0
  cryptsetup open --allow-discards "$LUKSPART" "$MAPPER"
}

pick_disk() {
  echo
  lsblk -d -e 7,11 -o NAME,SIZE,MODEL,TRAN
  echo
  local default
  default=$(lsblk -dn -e 7,11 -o NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print "/dev/"$1; exit}')
  ask DISK "Target disk" "${default:-/dev/nvme0n1}"
  [[ -b $DISK ]] || die "$DISK is not a block device."
}

# -----------------------------------------------------------------------------
# Post-install checks (also used by the 'check' subcommand)
# -----------------------------------------------------------------------------
run_checks() {
  FAILS=0
  local img key=/etc/cryptsetup-keys.d/$MAPPER.key
  info "Checking the installed system"
  check "ESP has shimx64.efi"                     test -f "$MNT/boot/efi/EFI/fedora/shimx64.efi"
  check "ESP has grubx64.efi"                     test -f "$MNT/boot/efi/EFI/fedora/grubx64.efi"
  check "ESP grub.cfg unlocks LUKS (cryptomount)" grep -q "cryptomount -u ${LUKS_UUID//-/}" "$MNT/boot/efi/EFI/fedora/grub.cfg"
  check "ESP grub.cfg points at /@/boot/grub2"    grep -q '/@/boot/grub2' "$MNT/boot/efi/EFI/fedora/grub.cfg"
  check "GRUB_ENABLE_CRYPTODISK=y set"            grep -q '^GRUB_ENABLE_CRYPTODISK=y' "$MNT/etc/default/grub"
  check "grub.cfg exists"                         test -s "$MNT/boot/grub2/grub.cfg"
  check "grubenv blsdir = /@/boot/loader/entries" grep -q '^blsdir=/@/boot/loader/entries' "$MNT/boot/grub2/grubenv"
  check "BLS boot entries exist"                  compgen -G "$MNT/boot/loader/entries/*.conf"
  check "BLS kernels load from /@/boot"           bash -c "grep -h '^linux' '$MNT'/boot/loader/entries/*.conf | grep -vq ' /@/boot/' && exit 1 || exit 0"
  check "Kernel cmdline: rootflags=subvol=@"      bash -c "grep -h '^options' '$MNT'/boot/loader/entries/*.conf | grep -q 'rootflags=subvol=@'"
  check "Kernel cmdline: rd.luks.uuid"            bash -c "grep -h '^options' '$MNT'/boot/loader/entries/*.conf | grep -q 'rd.luks.uuid=$MAPPER'"
  check "Kernel cmdline: intel_iommu=on"          bash -c "grep -h '^options' '$MNT'/boot/loader/entries/*.conf | grep -q 'intel_iommu=on'"
  check "/etc/crypttab uses the keyfile"          grep -q "$key" "$MNT/etc/crypttab"
  check "Keyfile exists and is 0400"              bash -c "[[ \$(stat -c %a '$MNT$key') == 400 ]]"
  check "dracut config installs the keyfile"      grep -q "$key" "$MNT/etc/dracut.conf.d/10-luks-keyfile.conf"
  for img in "$MNT"/boot/initramfs-*.img; do
    [[ -e $img && $img != *rescue* ]] || continue
    check "Keyfile inside $(basename "$img")"     bash -c "{ lsinitrd '$img' 2>/dev/null || chroot '$MNT' lsinitrd '/boot/$(basename "$img")'; } | grep -q 'cryptsetup-keys.d/$MAPPER.key'"
    check "$(basename "$img") is mode 600"        bash -c "[[ \$(stat -c %a '$img') == 600 ]]"
  done
  check "fstab mounts by subvol= name"            grep -q 'subvol=/@[[:space:],]' "$MNT/etc/fstab"
  check "fstab has no subvolid= (rollback-safe)"  bash -c "! grep -q subvolid= '$MNT/etc/fstab'"
  check "VM image dir is No_COW (+C)"             bash -c "lsattr -d '$MNT/var/lib/libvirt/images' | awk '{print \$1}' | grep -q C"
  check "Boot fixup hook for dnf installed"       test -s "$MNT/etc/dnf/libdnf5-plugins/actions.d/zz-encboot.actions"
  check "Boot fixup hook for kernel-install"      test -x "$MNT/etc/kernel/install.d/99-encboot-fixup.install"
  check "Persistent journal dir exists"           test -d "$MNT/var/log/journal"
  check "Console font is $CONSOLE_FONT"           grep -q "^FONT=$CONSOLE_FONT" "$MNT/etc/vconsole.conf"
  check "Wi-Fi firmware installed (iwlwifi)"      bash -c "chroot '$MNT' rpm -q iwlwifi-mvm-firmware"
  check "Intel graphics firmware installed"       bash -c "chroot '$MNT' rpm -q intel-gpu-firmware"
  check "zram swap configured"                    grep -q 'zstd' "$MNT/etc/systemd/zram-generator.conf"
  check "SELinux labels applied"                  bash -c "[[ -e '$MNT/.autorelabel' ]] || stat -c %C '$MNT/etc/shadow' | grep -q shadow_t"
  check "UEFI boot entry points at shim"          bash -c "efibootmgr -v | grep -qi 'fedora.*shimx64'"
  check "Fedora $RELEASEVER repos installed"      bash -c "[[ \$(chroot '$MNT' rpm -q --qf '%{VERSION}' fedora-repos) == $RELEASEVER ]]"
  echo
  if ((FAILS)); then
    warn "$FAILS check(s) failed. Fix them (or paste this output) before rebooting."
  else
    ok "All checks passed"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Subcommands: check / mount
# -----------------------------------------------------------------------------
cmd_check_or_mount() {
  need_root
  live_tools
  pick_disk
  find_disk_parts
  open_luks
  mount_target
  if [[ $1 == check ]]; then
    run_checks
    if yesno "Unmount and close the disk now?" y; then umount_target; fi
  else
    ok "Mounted at $MNT. Enter it with: arch-chroot $MNT"
    ok "When done: umount -R $MNT && cryptsetup close $MAPPER"
  fi
}

# =============================================================================
# Full install
# =============================================================================
cmd_install() {
  need_root
  exec > >(tee -a "$LOG") 2>&1
  info "Fedora $RELEASEVER encrypted btrfs install (log: $LOG)"

  [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. Turn off CSM/Legacy boot in firmware."
  getent hosts mirrors.fedoraproject.org >/dev/null || die "No network/DNS. Connect first (nmtui or the network applet)."
  [[ $(rpm -E %fedora) == "$RELEASEVER" ]] \
    || warn "This live session is Fedora $(rpm -E %fedora), installing Fedora $RELEASEVER (host repo config is reused)."

  # ---------------------------------------------------------------------------
  # 0. Questions up front, then it runs unattended (except the user password)
  # ---------------------------------------------------------------------------
  pick_disk
  local HOST USERNAME TZONE PASS PASS2 HEADER_DIR
  ask HOST     "Hostname" ""
  [[ $HOST =~ ^[a-zA-Z0-9-]+$ ]] || die "Hostname must be letters, digits and dashes."
  ask USERNAME "Username" "robert"
  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."
  ask TZONE    "Time zone" "America/Phoenix"
  [[ -e /usr/share/zoneinfo/$TZONE ]] || die "Unknown time zone: $TZONE"
  ask HEADER_DIR "Folder to save the LUKS header backup (ideally a 2nd USB stick)" "/root"
  mkdir -p "$HEADER_DIR"

  while true; do
    read -r -s -p "LUKS passphrase (you'll type it at every boot): " PASS; echo
    read -r -s -p "Repeat passphrase: " PASS2; echo
    [[ -n $PASS && $PASS == "$PASS2" ]] && break
    warn "Empty or not matching. Try again."
  done
  unset PASS2

  echo
  warn "This ERASES EVERYTHING on $DISK:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK"
  local confirm
  read -r -p "Type the disk name ($DISK) to confirm: " confirm
  [[ $confirm == "$DISK" ]] || die "Not confirmed. Nothing was changed."

  # ---------------------------------------------------------------------------
  # 1. Live-session tools
  # ---------------------------------------------------------------------------
  info "Step 1: Installing tools in the live session"
  live_tools
  ok "Live tools ready"

  # ---------------------------------------------------------------------------
  # 2. Can Fedora's signed GRUB read LUKS2? Decide the LUKS version.
  # ---------------------------------------------------------------------------
  info "Step 2: Checking LUKS support in Fedora's signed GRUB"
  local LUKS_TYPE tmpd efi
  tmpd=$(mktemp -d)
  (cd "$tmpd" && dnf -q download --releasever="$RELEASEVER" grub2-efi-x64 >/dev/null 2>&1 \
     && rpm2cpio grub2-efi-x64-*.rpm | cpio -idm --quiet) || true
  efi=$(find "$tmpd" -name grubx64.efi -print -quit)
  if [[ -n $efi ]] && grep -aq luks2 "$efi"; then
    LUKS_TYPE=luks2
    ok "Signed GRUB includes luks2 -> using LUKS2 (PBKDF2)"
  elif [[ -n $efi ]] && grep -aq cryptodisk "$efi"; then
    LUKS_TYPE=luks1
    warn "Signed GRUB has cryptodisk but not luks2 -> using LUKS1 (equally secure with PBKDF2)"
  else
    rm -rf "$tmpd"
    die "Couldn't confirm that Fedora's signed GRUB can unlock LUKS. Nothing was changed."
  fi
  rm -rf "$tmpd"

  # ---------------------------------------------------------------------------
  # 3. Partition, encrypt, btrfs + subvolumes
  # ---------------------------------------------------------------------------
  info "Step 3: Partitioning $DISK"
  umount -R "$MNT" 2>/dev/null || true
  swapoff -a || true
  # Close a LUKS container left open by an earlier, interrupted run
  local m
  for m in $(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="crypt" {print $1}'); do
    cryptsetup close "$m" || die "Couldn't close $m; run: umount -R $MNT && cryptsetup close $m"
  done
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:+"$ESP_SIZE" -t1:ef00 -c1:EFI \
         -n2:0:0           -t2:8309 -c2:cryptroot "$DISK"
  partprobe "$DISK" || true
  udevadm settle
  find_disk_parts
  mkfs.fat -F32 -n EFI "$ESP"
  ok "Partitions created"

  info "Encrypting $LUKSPART ($LUKS_TYPE, PBKDF2, ${PBKDF_ITER_MS} ms)"
  local fmt=(cryptsetup luksFormat --batch-mode --type "$LUKS_TYPE" --hash sha256 --iter-time "$PBKDF_ITER_MS")
  [[ $LUKS_TYPE == luks2 ]] && fmt+=(--pbkdf pbkdf2)
  printf '%s' "$PASS" | "${fmt[@]}" --key-file=- "$LUKSPART"
  set_mapper
  printf '%s' "$PASS" | cryptsetup open --allow-discards --key-file=- "$LUKSPART" "$MAPPER"
  ok "LUKS container open as /dev/mapper/$MAPPER"

  local HDR
  HDR="$HEADER_DIR/luks-header-$HOST-$(date +%Y%m%d).img"
  cryptsetup luksHeaderBackup "$LUKSPART" --header-backup-file "$HDR"
  ok "LUKS header backed up to $HDR"

  info "Creating btrfs and subvolumes"
  mkfs.btrfs -f -L fedora "/dev/mapper/$MAPPER"
  mount "/dev/mapper/$MAPPER" "$MNT"
  local sv
  for sv in "${SUBVOLS[@]}"; do btrfs subvolume create "$MNT/$sv"; done
  umount "$MNT"
  mount_target
  chattr +C "$MNT/var/lib/libvirt/images"     # must be set while the dir is empty
  chmod 1777 "$MNT/var/tmp"
  ok "Subvolumes mounted; VM image dir set to No_COW"

  local BTRFS_UUID
  BTRFS_UUID=$(blkid -s UUID -o value "/dev/mapper/$MAPPER")

  # ---------------------------------------------------------------------------
  # 4. Base system with dnf --installroot (no kernel yet) + fstab
  # ---------------------------------------------------------------------------
  info "Step 4: dnf --installroot: Fedora $RELEASEVER base"
  dnf -y --installroot="$MNT" --use-host-config --releasever="$RELEASEVER" \
    install @core fedora-repos glibc-langpack-en \
    btrfs-progs cryptsetup dracut policycoreutils selinux-policy-targeted \
    NetworkManager NetworkManager-wifi NetworkManager-tui iw wireless-regdb \
    sudo bash-completion curl nano less which \
    zram-generator terminus-fonts terminus-fonts-console \
    efibootmgr mokutil libdnf5-plugin-actions
  genfstab -U "$MNT" >> "$MNT/etc/fstab"
  sed -i 's/subvolid=[0-9]*,//; s/,subvolid=[0-9]*//' "$MNT/etc/fstab"
  ok "Base system installed, fstab written (subvol= names only)"

  # ---------------------------------------------------------------------------
  # 5. Keyfile so the passphrase is typed once (created from the live side,
  #    so the passphrase never enters the chroot)
  # ---------------------------------------------------------------------------
  info "Step 5: Adding the initramfs keyfile"
  local KEY=/etc/cryptsetup-keys.d/$MAPPER.key
  install -d -m 0700 "$MNT/etc/cryptsetup-keys.d"
  dd if=/dev/urandom of="$MNT$KEY" bs=64 count=1 status=none
  chmod 0400 "$MNT$KEY"
  local addkey=(cryptsetup luksAddKey --batch-mode --key-file=- "$LUKSPART" "$MNT$KEY")
  if [[ $LUKS_TYPE == luks2 ]]; then
    addkey+=(--pbkdf pbkdf2 --pbkdf-force-iterations 1000)
  else
    addkey+=(--iter-time 1)
  fi
  printf '%s' "$PASS" | "${addkey[@]}"
  unset PASS
  echo "$MAPPER UUID=$LUKS_UUID $KEY discard" > "$MNT/etc/crypttab"
  chmod 0600 "$MNT/etc/crypttab"
  ok "Keyfile in slot 1, crypttab written"

  # ---------------------------------------------------------------------------
  # 6. Boot fixup helper (ESP stub + BLS paths), baked with this disk's UUIDs
  # ---------------------------------------------------------------------------
  info "Step 6: Installing the encrypted-/boot fixup helper"
  install -d "$MNT/usr/local/bin" "$MNT/etc/kernel/install.d" "$MNT/etc/dnf/libdnf5-plugins/actions.d"
  cat > "$MNT/usr/local/bin/encboot-fixup" <<EOF
#!/usr/bin/bash
# encboot-fixup: keeps the encrypted-/boot boot chain intact on Fedora.
#  1. The ESP grub.cfg stub must unlock LUKS before it can read /@/boot/grub2.
#     Fedora's grub2 updates regenerate that stub without the cryptomount line.
#  2. BLS entries must load the kernel/initramfs from /@/boot (GRUB sees the
#     btrfs top level, not the @ subvolume).
# Runs after every dnf transaction and every kernel-install. Quiet on stdout
# (dnf's actions plugin parses stdout); messages go to stderr and the journal.
set -u
LUKS_UUID=$LUKS_UUID
BTRFS_UUID=$BTRFS_UUID
STUB=/boot/efi/EFI/fedora/grub.cfg
if [[ -d /boot/efi/EFI/fedora ]] && ! grep -qs "cryptomount -u \${LUKS_UUID//-/}" "\$STUB"; then
  cat > "\$STUB" <<STUB_EOF
cryptomount -u \${LUKS_UUID//-/}
search --no-floppy --fs-uuid --set=dev \$BTRFS_UUID
set prefix=(\\\$dev)/@/boot/grub2
export \\\$prefix
configfile \\\$prefix/grub.cfg
STUB_EOF
  logger -t encboot-fixup "rewrote \$STUB with cryptomount" 2>/dev/null || true
  echo "encboot-fixup: rewrote \$STUB" >&2
fi
for f in /boot/loader/entries/*.conf; do
  [[ -f \$f ]] || continue
  sed -i -E '/^(linux|initrd)[[:space:]]/ s#([[:space:]])(/@)?(/boot)?/(vmlinuz|initramfs|initrd)#\1/@/boot/\4#g' "\$f"
done
exit 0
EOF
  chmod 0755 "$MNT/usr/local/bin/encboot-fixup"
  cat > "$MNT/etc/kernel/install.d/99-encboot-fixup.install" <<'EOF'
#!/usr/bin/bash
# Re-apply the encrypted-/boot fixups after a kernel is added or removed.
case "$1" in add|remove) /usr/local/bin/encboot-fixup >/dev/null || : ;; esac
exit 0
EOF
  chmod 0755 "$MNT/etc/kernel/install.d/99-encboot-fixup.install"
  echo 'post_transaction::::/usr/local/bin/encboot-fixup' \
    > "$MNT/etc/dnf/libdnf5-plugins/actions.d/zz-encboot.actions"
  ok "encboot-fixup runs after every dnf transaction and kernel install"

  # ---------------------------------------------------------------------------
  # 7. Configure inside the chroot
  # ---------------------------------------------------------------------------
  info "Step 7: Configuring the system (chroot)"
  cat > "$MNT/root/chroot-setup.sh" <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }

# Hostname, locale, time zone, keyboard + console font
echo "$HOST" > /etc/hostname
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
printf 'KEYMAP=us\nFONT=%s\n' "$FONT" > /etc/vconsole.conf
if [[ -d /etc/kmscon ]] || rpm -q kmscon &>/dev/null; then
  mkdir -p /etc/kmscon
  printf 'font-name=Terminus\nfont-size=%s\n' "$KMSCON_SIZE" > /etc/kmscon/kmscon.conf
fi
ok "Locale en_US.UTF-8, time zone $TZONE, console font $FONT"

# Persistent journal, so a failed boot leaves logs behind
mkdir -p /var/log/journal

# zram swap: 1/4 of RAM, zstd
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 4
compression-algorithm = zstd
EOF

# dracut: keyfile + crypttab in the initramfs (it's mode 0600 on Fedora)
cat > /etc/dracut.conf.d/10-luks-keyfile.conf <<EOF
# Lets systemd-cryptsetup open $MAPPER without a 2nd passphrase prompt
install_items+=" $KEY /etc/crypttab "
add_dracutmodules+=" crypt btrfs "
EOF

# GRUB settings BEFORE the kernel goes in. grub2-mkconfig adds
# root=UUID=... and rootflags=subvol=@ itself and syncs /etc/kernel/cmdline.
cat > /etc/default/grub <<EOF
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="\$(sed 's, release .*\$,,g' /etc/system-release)"
GRUB_DEFAULT=0
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="rd.luks.uuid=$MAPPER $CMDLINE"
GRUB_DISABLE_RECOVERY=true
GRUB_ENABLE_BLSCFG=true
GRUB_ENABLE_CRYPTODISK=y
GRUB_DISABLE_OS_PROBER=true
EOF
mkdir -p /etc/kernel
echo "root=UUID=$BTRFS_UUID ro rootflags=subvol=@ rd.luks.uuid=$MAPPER $CMDLINE" > /etc/kernel/cmdline

# Kernel, firmware (incl. Intel graphics + Wi-Fi), microcode, GRUB + shim (Secure Boot)
dnf -y install --skip-unavailable kernel linux-firmware intel-gpu-firmware \
  iwlwifi-mvm-firmware iwlwifi-dvm-firmware realtek-firmware atheros-firmware \
  microcode_ctl grub2-efi-x64 grub2-tools grub2-tools-extra shim-x64 grubby
ok "Kernel, firmware, GRUB and shim installed"

dracut --regenerate-all --force
/usr/local/bin/encboot-fixup
grub2-mkconfig -o /boot/grub2/grub.cfg
grub2-editenv - set blsdir=/@/boot/loader/entries   # grub2-mkconfig normally sets this too
grub2-editenv - unset menu_auto_hide 2>/dev/null || true   # GRUB can't write grubenv on btrfs
/usr/local/bin/encboot-fixup
ok "initramfs, BLS entries, grub.cfg and ESP stub ready"

# Services and defaults
systemctl enable NetworkManager.service
systemctl set-default multi-user.target

# User
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/bash -G wheel "$USERNAME"
fi
echo
echo "Set the login password for $USERNAME:"
until passwd "$USERNAME"; do echo "Try again."; done
passwd -l root >/dev/null
ok "User $USERNAME created (wheel = sudo); root login locked"
CHROOT
  chmod 700 "$MNT/root/chroot-setup.sh"

  # DNS inside the chroot: Fedora's resolv.conf is a symlink into /run, which
  # is empty in a chroot. Use a plain copy of the live session's for now.
  local rc_link=""
  if [[ -L $MNT/etc/resolv.conf ]]; then rc_link=$(readlink "$MNT/etc/resolv.conf"); fi
  rm -f "$MNT/etc/resolv.conf"
  cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

  arch-chroot "$MNT" /usr/bin/env \
    HOST="$HOST" USERNAME="$USERNAME" TZONE="$TZONE" MAPPER="$MAPPER" KEY="$KEY" \
    BTRFS_UUID="$BTRFS_UUID" FONT="$CONSOLE_FONT" KMSCON_SIZE="$KMSCON_FONT_SIZE" \
    CMDLINE="$KERNEL_CMDLINE" \
    bash /root/chroot-setup.sh
  rm -f "$MNT/root/chroot-setup.sh"

  rm -f "$MNT/etc/resolv.conf"
  if [[ -n $rc_link ]]; then ln -s "$rc_link" "$MNT/etc/resolv.conf"; fi

  # ---------------------------------------------------------------------------
  # 8. UEFI boot entry -> shim
  # ---------------------------------------------------------------------------
  info "Step 8: UEFI boot entry"
  local n
  for n in $(efibootmgr | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*? Fedora([[:space:]].*)?$/\1/p'); do
    efibootmgr -q -b "$n" -B || true
  done
  efibootmgr -q -c -d "$DISK" -p 1 -L Fedora -l '\EFI\fedora\shimx64.efi'
  ok "Boot entry 'Fedora' -> \\EFI\\fedora\\shimx64.efi"

  # ---------------------------------------------------------------------------
  # 9. Hand over the post-install script, label files for SELinux
  # ---------------------------------------------------------------------------
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f $here/02-fedora-postinstall.sh ]]; then
    install -m 0755 "$here/02-fedora-postinstall.sh" "$MNT/home/$USERNAME/02-fedora-postinstall.sh"
    arch-chroot "$MNT" chown "$USERNAME:$USERNAME" "/home/$USERNAME/02-fedora-postinstall.sh"
    ok "Copied 02-fedora-postinstall.sh to /home/$USERNAME"
  else
    warn "02-fedora-postinstall.sh not found next to this script; download it after first boot."
  fi
  cp "$LOG" "$MNT/var/log/01-fedora-install.log" 2>/dev/null || true

  info "Step 9: Applying SELinux labels"
  if setfiles -F -r "$MNT" -e "$MNT/boot/efi" \
       "$MNT/etc/selinux/targeted/contexts/files/file_contexts" "$MNT"; then
    ok "SELinux labels applied (no relabel reboot needed)"
  else
    touch "$MNT/.autorelabel"
    warn "Labeling from the live session failed; the first boot relabels and reboots once."
  fi

  # ---------------------------------------------------------------------------
  # 10. Verify
  # ---------------------------------------------------------------------------
  run_checks

  echo
  warn "LUKS header backup: $HDR"
  warn "Copy it somewhere OFF this machine (vault / USB) before you reboot."
  [[ $HEADER_DIR == /root* ]] && warn "/root in a live session is RAM: it is gone after reboot."
  cat <<EOF

Next:
  1. Copy the LUKS header backup off this machine.
  2. Reboot, remove the USB. GRUB asks for the passphrase ONCE (a few seconds
     pause after you type it is normal), then Linux boots with no 2nd prompt.
  3. Log in as $USERNAME on the TTY. Connect to the network: nmtui
  4. Check:  journalctl -b | grep -i $MAPPER     (unlocked by keyfile)
  5. Firmware: turn Secure Boot ON (standard mode, factory keys), boot again:
             mokutil --sb-state                   -> SecureBoot enabled
  6. Run:    ~/02-fedora-postinstall.sh

If something won't boot: boot this USB again, 'sudo -i', then
  ./01-fedora-install.sh mount     and     arch-chroot $MNT
EOF
  if yesno "Unmount, close the disk and reboot now?" n; then
    umount_target
    systemctl reboot
  fi
}

# -----------------------------------------------------------------------------
case "${1:-install}" in
  install)      cmd_install ;;
  check|mount)  cmd_check_or_mount "$1" ;;
  *) echo "Usage: $0 [install|check|mount]" >&2; exit 2 ;;
esac
