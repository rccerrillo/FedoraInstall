#!/usr/bin/env bash
# =============================================================================
# 02-fedora-postinstall.sh
# Post-install for the Fedora 45 encrypted-btrfs notebook built by
# 01-fedora-install.sh. Port of 02-debian-stable-postinstall.sh.
#
# Run as your NORMAL USER from the TTY after first boot, once you're online
# (nmcli / nmtui). It asks yes/no before each step and takes a Snapper snapshot
# before every step that changes the system, so any step can be rolled back
# from the GRUB snapshot menu.
#
#    1. System update
#    2. Snapper (+ dnf5 pre/post snapshots) + grub-btrfs + Btrfs Assistant GUI
#    3. Minimal KDE Plasma + Plasma Login Manager (+ optional extras)
#    4. Core utilities + printing
#    5. Network tools
#    6. Sync & VPN: Syncthing, Tailscale, Mullvad
#    7. Virtualization: QEMU/KVM/libvirt, OVMF, swtpm, SMB, hugepages
#    8. GPU passthrough: NVIDIA card -> vfio-pci (auto-detected)
#    9. Flatpak + Flathub + apps
#   10. Brave Origin + RealVNC Viewer
#   11. Backup tools
#   12. firewalld (public zone, no inbound except KDE Connect, Syncthing,
#       mDNS; tailscale0 trusted; libvirt handles its own zone)
#   13. RPM Fusion + full ffmpeg (optional, default no)
#
# Debian -> Fedora: apt -> dnf5, UFW -> firewalld, SDDM -> Plasma Login
# Manager, update-initramfs -> dracut, update-grub -> grub2-mkconfig,
# power-profiles-daemon -> tuned-ppd, libvirtd -> modular virt*d daemons.
#
# Logs: ~/fedora-postinstall.log
# =============================================================================
set -euo pipefail

LOG="$HOME/fedora-postinstall.log"
SNAPPER_CFG=root

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }
have() { command -v "$1" &>/dev/null; }
rpmq() { rpm -q "$1" &>/dev/null; }

yesno() {
  local prompt=$1 default=${2:-n} reply hint
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$prompt $hint " reply || true
  reply=${reply:-$default}
  [[ ${reply,,} == y* ]]
}

# dnf5 without prompts; packages that don't exist are skipped (and listed),
# so one renamed package doesn't abort the whole transaction.
DNF=(sudo dnf -y)

# Wait for the network (DNS) before downloads; let the user fix it if needed
wait_net() {
  for _ in {1..30}; do
    getent hosts mirrors.fedoraproject.org >/dev/null && return 0
    sleep 2
  done
  warn "No network. Fix it in another terminal (nmtui, or:"
  warn "  nmcli networking off && nmcli networking on), then press Enter."
  read -r _ || true
  getent hosts mirrors.fedoraproject.org >/dev/null
}

# retry CMD...  (3 tries, waiting for the network between them)
retry() {
  local n=1
  until "$@"; do
    ((n >= 3)) && return 1
    warn "Command failed (try $n/3): $*"
    wait_net || true
    n=$((n+1))
  done
}

dnf_install()       { wait_net; retry "${DNF[@]}" install --skip-unavailable "$@"; }
dnf_install_norec() { wait_net; retry "${DNF[@]}" --setopt=install_weak_deps=False install --skip-unavailable "$@"; }

# Snapshot before a step (no-op until Snapper is set up in step 2)
snap() {
  if have snapper && sudo snapper -c "$SNAPPER_CFG" get-config &>/dev/null; then
    sudo snapper -c "$SNAPPER_CFG" create -c number --userdata important=yes -d "$1" && ok "Snapshot: $1"
  fi
}

# Any change to the initramfs must keep the LUKS keyfile in it, or the next
# boot asks for the passphrase twice.
rebuild_initramfs() {
  sudo dracut --regenerate-all --force
  local img bad=0
  for img in /boot/initramfs-*.img; do
    [[ $img == *rescue* ]] && continue
    if sudo lsinitrd "$img" | grep -qE 'cryptsetup-keys\.d/.+\.key'; then
      ok "Keyfile present in $(basename "$img")"
    else
      warn "Keyfile MISSING from $(basename "$img")"; bad=1
    fi
  done
  ((bad == 0)) || warn "Check /etc/crypttab and /etc/dracut.conf.d/10-luks-keyfile.conf before rebooting!"
}

# Regenerate grub.cfg. With BLS this also rewrites the 'options' line of every
# boot entry and /etc/kernel/cmdline from GRUB_CMDLINE_LINUX.
regen_grub() {
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  sudo /usr/local/bin/encboot-fixup || true
}

# Add kernel arguments for current AND future kernels
add_kargs() {
  local cur a
  cur=$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/\1/p' /etc/default/grub)
  for a in "$@"; do [[ " $cur " == *" $a "* ]] || cur="$cur $a"; done
  cur=${cur# }
  sudo sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$cur\"|" /etc/default/grub
  regen_grub
  for a in "$@"; do
    grep -qw -- "$a" /etc/kernel/cmdline || warn "$a missing from /etc/kernel/cmdline"
  done
}

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root. It uses sudo when needed." >&2
  exit 1
fi

exec > >(tee -a "$LOG") 2>&1
info "Fedora post-install (log: $LOG)"
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

wait_net

# =============================================================================
# 1. System update
# =============================================================================
info "Step 1: Updating the system"
retry sudo dnf -y upgrade --refresh
dnf_install curl ca-certificates gnupg2 git make gawk inotify-tools \
            pciutils usbutils dnf-plugins-core
ok "System up to date"

if have mokutil; then
  if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    ok "Secure Boot is enabled"
  else
    warn "Secure Boot is OFF. Turn it on in firmware (standard mode, factory keys) when convenient."
  fi
fi

# =============================================================================
# 2. Snapper + dnf5 snapshots + grub-btrfs
# =============================================================================
if yesno "Step 2: set up Snapper and grub-btrfs (snapshots in the GRUB menu)?" y; then
  info "Installing Snapper and Btrfs Assistant"
  dnf_install snapper btrfs-progs btrfs-assistant libdnf5-plugin-actions

  if ! sudo snapper -c "$SNAPPER_CFG" get-config &>/dev/null; then
    # snapper create-config insists on creating its own nested .snapshots
    # subvolume; swap our @snapshots subvolume back in afterwards.
    sudo umount /.snapshots 2>/dev/null || true
    sudo rmdir /.snapshots 2>/dev/null || true
    sudo snapper -c "$SNAPPER_CFG" create-config /
    sudo btrfs subvolume delete /.snapshots
    sudo mkdir /.snapshots
    sudo systemctl daemon-reload
    sudo mount -a
    sudo chmod 750 /.snapshots
    sudo restorecon -RF /.snapshots      # SELinux label snapperd expects
    findmnt -no SOURCE /.snapshots | grep -q '@snapshots' \
      && ok "/.snapshots is the @snapshots subvolume" \
      || warn "/.snapshots is not mounted from @snapshots; check /etc/fstab"
  else
    ok "Snapper config '$SNAPPER_CFG' already exists"
  fi

  sudo snapper -c "$SNAPPER_CFG" set-config ALLOW_GROUPS=wheel SYNC_ACL=yes \
    TIMELINE_CREATE=yes TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=2 TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 \
    NUMBER_LIMIT=20 NUMBER_LIMIT_IMPORTANT=10
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

  # dnf5 has no snapper plugin; the actions plugin does the same job.
  # (Adapted from the libdnf5-actions man page's snapper example.)
  sudo tee /etc/dnf/libdnf5-plugins/actions.d/snapper.actions >/dev/null <<'EOF'
# Pre/post Snapper snapshots around every dnf transaction
pre_transaction::::/usr/bin/sh -c echo\ "tmp.snapper_descr=$(ps\ -o\ command\ --no-headers\ -p\ '${pid}')"
pre_transaction::::/usr/bin/sh -c echo\ "tmp.snapper_pre_number=$(snapper\ -c\ root\ create\ -c\ number\ -t\ pre\ -p\ -d\ '${tmp.snapper_descr}')"
post_transaction::::/usr/bin/sh -c [\ -n\ "${tmp.snapper_pre_number}"\ ]\ &&\ snapper\ -c\ root\ create\ -c\ number\ -t\ post\ --pre-number\ "${tmp.snapper_pre_number}"\ -d\ "${tmp.snapper_descr}"\ ;\ echo\ tmp.snapper_pre_number\ ;\ echo\ tmp.snapper_descr
EOF
  if grep -qsE '^\s*enabled\s*=\s*(0|false)' /etc/dnf/libdnf5-plugins/actions.conf; then
    sudo sed -i -E 's/^\s*enabled\s*=.*/enabled = 1/' /etc/dnf/libdnf5-plugins/actions.conf
  fi
  ok "dnf5 actions: pre/post snapshots on every dnf run"

  info "Installing grub-btrfs (upstream; not packaged in Fedora)"
  if [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
    ok "grub-btrfs already installed"
    [[ -d /opt/grub-btrfs ]] && sudo git -C /opt/grub-btrfs pull --ff-only || true
  else
    retry sudo git clone --depth 1 https://github.com/Antynea/grub-btrfs.git /opt/grub-btrfs
  fi
  [[ -d /opt/grub-btrfs ]] && sudo make -C /opt/grub-btrfs GRUB_UPDATE_EXCLUDE=true install
  CFG=/etc/default/grub-btrfs/config
  MKCONFIG=$(command -v grub2-mkconfig)
  sudo sed -i -E \
    -e 's|^#?GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"|' \
    -e "s|^#?GRUB_BTRFS_MKCONFIG=.*|GRUB_BTRFS_MKCONFIG=$MKCONFIG|" \
    -e 's|^#?GRUB_BTRFS_SCRIPT_CHECK=.*|GRUB_BTRFS_SCRIPT_CHECK=grub2-script-check|' "$CFG"
  if [[ ! -f /usr/share/grub/grub-mkconfig_lib && -f /usr/share/grub2/grub-mkconfig_lib ]]; then
    sudo sed -i -E 's|^#?GRUB_BTRFS_MKCONFIG_LIB=.*|GRUB_BTRFS_MKCONFIG_LIB=/usr/share/grub2/grub-mkconfig_lib|' "$CFG"
  fi
  sudo restorecon -RF /etc/grub.d /etc/default/grub-btrfs /usr/bin/grub-btrfsd \
    /usr/lib/systemd/system/grub-btrfsd.service 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable --now grub-btrfsd.service \
    && ok "grub-btrfsd watching /.snapshots" \
    || warn "Couldn't start grub-btrfsd; check: systemctl status grub-btrfsd"

  sudo snapper -c "$SNAPPER_CFG" create -c number --userdata important=yes -d "baseline (post-install start)"
  regen_grub
  grep -q 'snapshots-btrfs' /boot/grub2/grub.cfg \
    && ok "grub.cfg includes the snapshots submenu" \
    || warn "grub.cfg has no snapshots submenu yet; check: sudo /etc/grub.d/41_snapshots-btrfs"
  ok "Snapper + grub-btrfs ready"
fi

# =============================================================================
# 3. Minimal KDE Plasma (+ optional extras)
# =============================================================================
if yesno "Step 3: install minimal KDE Plasma?" y; then
  snap "pre-KDE"
  info "Installing minimal KDE Plasma (no weak deps)"
  KDE_PKGS=(
    plasma-desktop plasma-workspace kwin              # shell, panel, compositor (Wayland)
    plasma-login-manager kcm-plasmalogin              # login screen (Fedora's SDDM replacement)
    plasma-nm NetworkManager-wifi                     # network applet
    plasma-pa pipewire pipewire-pulseaudio pipewire-alsa wireplumber   # sound
    konsole dolphin                                   # terminal, file manager
    systemsettings kscreen powerdevil                 # settings, displays, power
    tuned-ppd                                         # Power Save / Balanced / Performance modes
    kscreenlocker                                     # screen locking
    xdg-desktop-portal-kde polkit-kde                 # file pickers, admin prompts
    plasma-breeze breeze-gtk kde-settings-plasma      # theme + Fedora's Plasma defaults
    google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-color-emoji-fonts
    mesa-dri-drivers mesa-vulkan-drivers              # Mesa OpenGL/Vulkan (userspace only)
    kwalletmanager5 pam-kwallet                       # wallet unlocks at login (no Brave prompts)
    ksshaskpass openssh-clients                       # SSH key passphrase from KDE Wallet
  )
  dnf_install_norec "${KDE_PKGS[@]}"
  if rpmq plasma-login-manager; then
    DM=plasmalogin
  else
    warn "plasma-login-manager not available; falling back to SDDM"
    dnf_install_norec sddm sddm-breeze sddm-kcm
    DM=sddm
  fi
  sudo systemctl enable --force "$DM.service"
  sudo systemctl set-default graphical.target
  ok "Plasma installed; $DM starts on next boot"

  # KDE Wallet auto-unlock: pam_kwallet5 opens 'kdewallet' with your login
  # password at the login screen, so Brave and other apps don't prompt for it.
  PAMF=/etc/pam.d/$DM
  if grep -q 'pam_kwallet5' "$PAMF" 2>/dev/null; then
    ok "pam_kwallet5 is in $DM's PAM stack (wallet unlocks at login)"
  elif [[ -f $PAMF ]]; then
    warn "Adding pam_kwallet5 to $PAMF"
    LAST_AUTH=$(grep -n '^-\?auth' "$PAMF" | tail -n1 | cut -d: -f1)
    if [[ -n $LAST_AUTH ]]; then
      sudo sed -i "${LAST_AUTH}a -auth       optional      pam_kwallet5.so" "$PAMF"
    fi
    echo '-session    optional      pam_kwallet5.so auto_start' | sudo tee -a "$PAMF" >/dev/null
    grep -q 'pam_kwallet5' "$PAMF" && ok "pam_kwallet5 added to $DM" \
      || warn "Couldn't add pam_kwallet5; check $PAMF"
  fi

  # SSH agent + KDE Wallet. Use a system-provided user agent unit if there is
  # one; only create our own when nothing else provides an agent, so we never
  # shadow a packaged unit (that's what made every ssh/git call hang on Debian).
  info "Setting up SSH key unlock via KDE Wallet"
  mkdir -p "$HOME/.config/environment.d" "$HOME/.config/autostart" "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  AGENT_UNIT=""
  for u in ssh-agent.socket ssh-agent.service plasma-ssh-agent.service gcr-ssh-agent.socket; do
    if [[ -e /usr/lib/systemd/user/$u ]]; then AGENT_UNIT=$u; break; fi
  done
  if [[ -n $AGENT_UNIT ]]; then
    rm -f "$HOME/.config/systemd/user/ssh-agent.service"
    printf 'SSH_ASKPASS=/usr/bin/ksshaskpass\nSSH_ASKPASS_REQUIRE=prefer\n' \
      > "$HOME/.config/environment.d/ssh.conf"
    systemctl --user enable "$AGENT_UNIT" 2>/dev/null || true
    ok "Using the packaged $AGENT_UNIT"
  else
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ssh-agent.service" <<'EOF'
[Unit]
Description=SSH key agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target
EOF
    cat > "$HOME/.config/environment.d/ssh.conf" <<'EOF'
SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket
SSH_ASKPASS=/usr/bin/ksshaskpass
SSH_ASKPASS_REQUIRE=prefer
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable ssh-agent.service 2>/dev/null || true
    ok "No packaged agent unit found; created ~/.config/systemd/user/ssh-agent.service"
  fi
  cat > "$HOME/.config/autostart/ssh-add.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SSH key (from KDE Wallet)
Exec=sh -c 'ssh-add -q < /dev/null'
X-KDE-autostart-phase=2
EOF
  if ! grep -qs AddKeysToAgent "$HOME/.ssh/config"; then
    printf 'Host *\n    AddKeysToAgent yes\n' >> "$HOME/.ssh/config"
  fi
  chmod 600 "$HOME/.ssh/config"

  if yesno "  Also install the KDE extras (Dolphin plugins, Gwenview, Spectacle, KDE Connect, Discover)?" y; then
    KDE_EXTRAS=(
      dolphin-plugins          # Git/SVN status, mount ISO, etc. in Dolphin
      gwenview                 # image viewer
      spectacle                # screenshots
      kde-connect              # phone integration (ports opened in step 12)
      plasma-discover plasma-discover-flatpak plasma-discover-packagekit   # software center
      bluedevil                # Bluetooth
      ark kate                 # archives, text editor
      plasma-systemmonitor
      plasma-firewall plasma-firewall-firewalld   # Firewall page in System Settings
      print-manager            # Printers page in System Settings
    )
    dnf_install_norec "${KDE_EXTRAS[@]}"
    ok "KDE extras installed"
  fi
fi

# =============================================================================
# 4. Core utilities + printing
# =============================================================================
if yesno "Step 4: install core utilities and printing?" y; then
  snap "pre-core-utils"
  info "Installing core utilities and printing"
  CORE_PKGS=(
    plocate                  # fast 'locate'
    man-db man-pages
    wget git rclone rsync
    unzip zip 7zip
    htop btop tree jq fastfetch
    terminus-fonts terminus-fonts-console   # Terminus for Konsole too

    # Printing
    cups cups-filters cups-browsed
    cups-pdf                 # print-to-PDF
    gutenprint-cups
    ghostscript
    print-manager

    # Network printer discovery
    avahi nss-mdns
  )
  dnf_install "${CORE_PKGS[@]}"
  sudo systemctl enable --now cups.service avahi-daemon.service 2>/dev/null || true
  sudo systemctl enable --now plocate-updatedb.timer 2>/dev/null || true
  # Don't index every file once per snapshot
  if [[ -f /etc/updatedb.conf ]] && ! grep -q '/\.snapshots' /etc/updatedb.conf; then
    sudo sed -i -E 's|^(PRUNEPATHS[[:space:]]*=[[:space:]]*")|\1/.snapshots |' /etc/updatedb.conf
  fi
  # Printer admin: CUPS on Fedora already trusts the wheel group (no lpadmin group)
  ok "Core utilities and printing installed"
fi

# =============================================================================
# 5. Network tools
# =============================================================================
if yesno "Step 5: install network tools?" y; then
  snap "pre-network-tools"
  info "Installing network tools"
  NET_PKGS=(
    bind-utils               # dig, nslookup, host
    iputils                  # ping, tracepath, arping
    telnet
    net-tools                # ifconfig, netstat (legacy)
    traceroute mtr
    nmap tcpdump iperf3 ethtool whois
    nmap-ncat                # nc
  )
  dnf_install "${NET_PKGS[@]}"
  ok "Network tools installed"
fi

# =============================================================================
# 6. Sync & VPN: Syncthing, Tailscale, Mullvad
# =============================================================================
if yesno "Step 6: install Syncthing, Tailscale and Mullvad VPN?" y; then
  snap "pre-sync-vpn"

  info "Installing Syncthing"
  dnf_install syncthing
  systemctl --user enable syncthing.service 2>/dev/null \
    && ok "Syncthing enabled as a user service (http://127.0.0.1:8384 after login)" \
    || warn "Enable it after logging in to Plasma: systemctl --user enable --now syncthing"

  info "Installing Tailscale"
  if have tailscale; then
    ok "Tailscale already installed"
  elif wait_net && curl -fsSL https://tailscale.com/install.sh | sh; then
    ok "Tailscale installed"
  else
    warn "Tailscale's installer failed; trying its Fedora repo directly"
    sudo dnf config-manager addrepo --overwrite \
      --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo || true
    dnf_install tailscale
  fi
  have tailscale && sudo systemctl enable tailscaled.service

  info "Installing Mullvad VPN"
  if ! rpmq mullvad-vpn; then
    retry sudo dnf config-manager addrepo --overwrite \
      --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
  fi
  dnf_install mullvad-vpn
  if rpmq mullvad-vpn; then
    sudo systemctl enable mullvad-daemon.service
    ok "Mullvad VPN installed (daemon starts on next boot)"
  fi
fi

# =============================================================================
# 7. Virtualization: QEMU / KVM / libvirt + TPM + SMB + hugepages
# =============================================================================
if yesno "Step 7: install the virtualization stack?" y; then
  snap "pre-virtualization"
  info "Installing virtualization stack"
  VIRT_PKGS=(
    qemu-kvm qemu-img
    libvirt-daemon-kvm libvirt-daemon-config-network libvirt-client
    virt-manager virt-viewer virt-install
    edk2-ovmf                # UEFI + Secure Boot firmware for Win11
    swtpm swtpm-tools        # TPM 2.0 for Win11
    dnsmasq
    virtiofsd

    # SMB / CIFS
    samba samba-client cifs-utils kio-extras
  )
  dnf_install "${VIRT_PKGS[@]}"

  info "Configuring virtualization"
  [[ -e /dev/kvm ]] && ok "KVM is available" \
    || warn "/dev/kvm missing: enable Intel VT-x and VT-d in firmware"
  # Fedora uses libvirt's modular daemons (virtqemud etc.), socket-activated
  for drv in qemu network nodedev nwfilter secret storage interface; do
    sudo systemctl enable "virt${drv}d.service" 2>/dev/null || true
    sudo systemctl enable --now "virt${drv}d.socket" "virt${drv}d-ro.socket" "virt${drv}d-admin.socket" 2>/dev/null || true
  done
  sudo usermod -aG libvirt,kvm "$USER"

  mkdir -p "$HOME/.config/libvirt"
  grep -qs '^uri_default' "$HOME/.config/libvirt/libvirt.conf" \
    || echo 'uri_default = "qemu:///system"' >> "$HOME/.config/libvirt/libvirt.conf"

  # Move libvirt's NAT network off 192.168.122.x if the LAN already uses it
  if sudo virsh net-info default &>/dev/null; then
    if ip -4 route | grep -v virbr | grep -q '192\.168\.122\.'; then
      warn "Your LAN uses 192.168.122.0/24; moving libvirt's network to 192.168.123.0/24"
      sudo virsh net-destroy default 2>/dev/null || true
      sudo virsh net-dumpxml default | sed 's/192\.168\.122\./192.168.123./g' > /tmp/default-net.xml
      sudo virsh net-define /tmp/default-net.xml && rm -f /tmp/default-net.xml
    fi
    sudo virsh net-autostart default >/dev/null
    sudo virsh net-start default 2>/dev/null || true
    ok "libvirt 'default' network active and set to autostart"
  fi

  # Samba server off until you configure shares
  sudo systemctl disable --now smb.service nmb.service 2>/dev/null || true

  # VM disk images must live on the No_COW subvolume, with the right SELinux label
  sudo restorecon -RF /var/lib/libvirt/images 2>/dev/null || true
  if lsattr -d /var/lib/libvirt/images 2>/dev/null | awk '{print $1}' | grep -q C; then
    ok "/var/lib/libvirt/images is No_COW (+C)"
  else
    warn "/var/lib/libvirt/images is NOT No_COW. If it's empty: sudo chattr +C /var/lib/libvirt/images"
  fi

  # Hugepages for the Win11 VM (default off on a notebook: the RAM is gone for the host)
  MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  if yesno "  Reserve hugepages for the Win11 VM? (this RAM is set aside permanently)" n; then
    read -r -p "  VM memory in GiB [8] (host has ~${MEM_GB} GiB): " HP_GB || true
    HP_GB=${HP_GB:-8}
    if [[ $HP_GB =~ ^[0-9]+$ ]] && ((HP_GB > 0 && HP_GB < MEM_GB - 8)); then
      echo "vm.nr_hugepages = $((HP_GB * 512))" | sudo tee /etc/sysctl.d/40-hugepages.conf >/dev/null
      sudo sysctl --system >/dev/null
      ok "Hugepages: $((HP_GB * 512)) x 2 MiB = ${HP_GB} GiB ($(awk '/HugePages_Total/ {print $2}' /proc/meminfo) allocated now; all after reboot)"
    else
      warn "Skipped: enter a whole number leaving at least 8 GiB for the host."
    fi
  fi
  ok "Virtualization configured (Samba server left disabled)"
fi

# =============================================================================
# 8. GPU passthrough: NVIDIA -> vfio-pci
# =============================================================================
if yesno "Step 8: bind the NVIDIA card to vfio-pci for passthrough?" y; then
  info "Detecting NVIDIA devices"
  mapfile -t NV_LINES < <(lspci -Dnn -d 10de: || true)
  if ((${#NV_LINES[@]} == 0)); then
    warn "No NVIDIA devices found; skipping."
  else
    printf '    %s\n' "${NV_LINES[@]}"
    NV_IDS=$(printf '%s\n' "${NV_LINES[@]}" | grep -o '\[10de:[0-9a-f]\{4\}\]' | tr -d '[]' | sort -u | paste -sd, -)

    # The laptop panel must stay on the Intel iGPU
    for line in "${NV_LINES[@]}"; do
      addr=${line%% *}
      if [[ $(cat "/sys/bus/pci/devices/$addr/boot_vga" 2>/dev/null) == 1 ]]; then
        warn "$addr is the BOOT display. Set the display mode to the Intel iGPU (Hybrid/Optimus)"
        warn "in firmware, or you'll get no host display."
      fi
    done

    if [[ -z $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; then
      warn "IOMMU is not active. Check VT-d in firmware and intel_iommu=on in /proc/cmdline."
    else
      NV_ADDRS=" $(printf '%s\n' "${NV_LINES[@]}" | awk '{print $1}' | paste -sd' ' -) "
      for line in "${NV_LINES[@]}"; do
        addr=${line%% *}
        grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$addr/iommu_group")" 2>/dev/null || echo '?')
        ok "$addr is in IOMMU group $grp"
        # Anything else in the group (except PCI bridges) has to go to the VM too
        others=""
        for d in /sys/kernel/iommu_groups/"$grp"/devices/*; do
          [[ -e $d ]] || continue
          d=${d##*/}
          [[ $NV_ADDRS == *" $d "* ]] && continue
          [[ $(cat "/sys/bus/pci/devices/$d/class" 2>/dev/null) == 0x0604* ]] && continue
          others+=" $d"
        done
        [[ -n $others ]] && warn "  Group $grp also holds:$others (they'd have to go to the VM too)"
      done
    fi

    if yesno "  Bind these IDs to vfio-pci: $NV_IDS ?" y; then
      snap "pre-vfio"
      sudo tee /etc/modprobe.d/vfio.conf >/dev/null <<EOF
# NVIDIA dGPU (and any audio function) reserved for the Win11 VM
options vfio-pci ids=$NV_IDS
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
      sudo tee /etc/dracut.conf.d/20-vfio.conf >/dev/null <<'EOF'
# Load vfio-pci from the initramfs, before nouveau can grab the card
force_drivers+=" vfio vfio_iommu_type1 vfio_pci "
install_items+=" /etc/modprobe.d/vfio.conf "
EOF
      rebuild_initramfs
      add_kargs rd.driver.pre=vfio_pci
      ok "vfio-pci binding set; after reboot check: lspci -nnk -d 10de:"
    fi
  fi
fi

# =============================================================================
# 9. Flatpak apps
# =============================================================================
if yesno "Step 9: install Flatpak and apps?" y; then
  snap "pre-flatpak"
  info "Installing Flatpak"
  dnf_install flatpak
  rpmq plasma-discover && dnf_install_norec plasma-discover-flatpak
  retry sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

  FLATPAKS=(
    com.github.tchx84.Flatseal              # Flatpak permissions editor
    io.github.flattool.Warehouse            # Flatpak manager
    io.github.giantpinkrobots.flatsweep     # leftover cleaner
    com.microsoft.Edge
    com.ticktick.TickTick
    net.cozic.joplin_desktop
    org.fkoehler.KTailctl                   # Tailscale GUI for KDE
    org.gnome.Calculator
    org.kde.kamoso                          # webcam
    org.libreoffice.LibreOffice
    org.mozilla.Thunderbird
    us.zoom.Zoom
    org.gtk.Gtk3theme.Breeze                # Breeze for GTK Flatpaks
  )
  info "Installing Flatpak apps (into the @flatpak subvolume, outside snapshots)"
  findmnt -no SOURCE /var/lib/flatpak | grep -q '@flatpak' \
    || warn "/var/lib/flatpak isn't the @flatpak subvolume; apps will land in snapshots"
  wait_net
  retry sudo flatpak install -y --noninteractive --system flathub "${FLATPAKS[@]}"
  ok "Flatpak apps installed"
fi

# =============================================================================
# 10. Vendor apps: Brave Origin, RealVNC Viewer
# =============================================================================
if yesno "Step 10: install Brave Origin and RealVNC Viewer?" y; then
  snap "pre-vendor-apps"
  info "Installing Brave Origin (official Brave installer)"
  if rpmq brave-origin || have brave-origin; then
    ok "Brave Origin already installed"
  elif wait_net && curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh; then
    ok "Brave Origin installed"
  else
    warn "Brave Origin install failed. Retry: curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh"
  fi

  info "Installing RealVNC Viewer"
  if rpmq realvnc-vnc-viewer; then
    ok "RealVNC Viewer already installed"
  else
    shopt -s nullglob
    VNC_RPMS=("$HOME"/Downloads/VNC-Viewer-*-Linux-x64.rpm "$HOME"/VNC-Viewer-*-Linux-x64.rpm)
    shopt -u nullglob
    if ((${#VNC_RPMS[@]})); then
      VNC_RPM=$(printf '%s\n' "${VNC_RPMS[@]}" | sort -V | tail -n1)
      retry sudo dnf -y install "$VNC_RPM"
      ok "RealVNC Viewer installed from $(basename "$VNC_RPM")"
    else
      warn "No VNC-Viewer-*-Linux-x64.rpm in ~/Downloads. Get the RPM x64 from"
      warn "  https://www.realvnc.com/en/connect/download/viewer/linux/"
      warn "then: sudo dnf install ~/Downloads/VNC-Viewer-*-Linux-x64.rpm"
    fi
  fi
fi

# =============================================================================
# 11. Backup tools
# =============================================================================
if yesno "Step 11: install backup tools?" y; then
  snap "pre-backup-tools"
  info "Installing backup tools"
  # No Timeshift: Snapper already handles system snapshots on btrfs, and
  # running both against the same subvolumes causes conflicts.
  BACKUP_PKGS=(
    restic                  # encrypted, deduplicated backups
    borgbackup borgmatic    # Borg + config-driven runs
    vorta                   # Qt GUI for Borg
    rsync rclone
    btrfs-progs             # btrfs send/receive for snapshot backups
    partclone               # imaging (Clonezilla isn't packaged; use its live ISO)
  )
  dnf_install "${BACKUP_PKGS[@]}"
  ok "Backup tools installed"
fi

# =============================================================================
# 12. firewalld
# =============================================================================
if yesno "Step 12: set up the firewall (firewalld)?" y; then
  snap "pre-firewall"
  info "Configuring firewalld"
  dnf_install firewalld
  sudo systemctl enable --now firewalld.service
  FW=(sudo firewall-cmd --permanent)

  # 'public' with nothing open, like UFW's deny incoming / allow outgoing.
  # (Fedora's KDE/Workstation zones open ports 1025-65535; we don't use them.)
  sudo firewall-cmd --set-default-zone=public
  for svc in ssh cockpit; do
    "${FW[@]}" --zone=public --remove-service="$svc" 2>/dev/null || true
  done
  "${FW[@]}" --zone=public --add-service=dhcpv6-client
  "${FW[@]}" --zone=public --add-service=mdns              # printer discovery (avahi)

  "${FW[@]}" --zone=public --add-service=kdeconnect \
    || { "${FW[@]}" --zone=public --add-port=1714-1764/tcp; "${FW[@]}" --zone=public --add-port=1714-1764/udp; }
  ok "KDE Connect ports 1714-1764 open"

  if have syncthing; then
    "${FW[@]}" --zone=public --add-service=syncthing \
      || { "${FW[@]}" --zone=public --add-port=22000/tcp; "${FW[@]}" --zone=public --add-port=22000/udp
           "${FW[@]}" --zone=public --add-port=21027/udp; }
    ok "Syncthing ports open"
  fi

  if have tailscale; then
    "${FW[@]}" --zone=trusted --add-interface=tailscale0
    ok "tailscale0 in the trusted zone (Tailscale ACLs still apply)"
  fi

  have virsh && ok "libvirt manages its own 'libvirt' zone for virbr0 (DHCP/DNS/NAT)"

  sudo firewall-cmd --reload
  sudo firewall-cmd --list-all
  ok "firewalld enabled"
fi

# =============================================================================
# 13. RPM Fusion + full ffmpeg (optional)
# =============================================================================
if yesno "Step 13: add RPM Fusion and swap in the full ffmpeg (codecs)?" n; then
  snap "pre-rpmfusion"
  info "Adding RPM Fusion free + nonfree"
  FED=$(rpm -E %fedora)
  wait_net
  retry sudo dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$FED.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$FED.noarch.rpm"
  retry sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing
  # Intel VA-API (intel-media-driver) intentionally left out, same as on Debian.
  ok "RPM Fusion added; full ffmpeg installed"
fi

# =============================================================================
# Checks
# =============================================================================
info "Final checks"
FAILS=0
chk() { local d=$1; shift; if "$@" &>/dev/null; then ok "$d"; else warn "FAIL: $d"; FAILS=$((FAILS+1)); fi; }
chk "Root is the @ subvolume"            bash -c "findmnt -no SOURCE / | grep -q '\[/@\]'"
chk "Keyfile in current initramfs"       bash -c "sudo lsinitrd /boot/initramfs-\$(uname -r).img | grep -qE 'cryptsetup-keys\\.d/.+\\.key'"
chk "ESP grub.cfg still has cryptomount" grep -q cryptomount /boot/efi/EFI/fedora/grub.cfg
rpmq intel-gpu-firmware && chk "Intel GPU firmware installed" rpmq intel-gpu-firmware
chk "Intel GPU not wedged"               bash -c "! sudo dmesg | grep -qi 'declaring it wedged'"
have snapper  && chk "Snapper config '$SNAPPER_CFG'"       sudo snapper -c "$SNAPPER_CFG" get-config
have snapper  && chk "dnf5 snapper actions present"        test -s /etc/dnf/libdnf5-plugins/actions.d/snapper.actions
have snapper  && chk "grub-btrfsd running"                 systemctl is-active grub-btrfsd
rpmq plasma-login-manager && chk "Plasma Login Manager enabled" systemctl is-enabled plasmalogin
rpmq plasma-login-manager && chk "KDE Wallet unlocks at login (pam_kwallet5)" grep -q pam_kwallet5 /etc/pam.d/plasmalogin
have virsh    && chk "virtqemud socket active"             systemctl is-active virtqemud.socket
[[ -f /etc/modprobe.d/vfio.conf ]] && chk "vfio.conf present"            test -s /etc/modprobe.d/vfio.conf
[[ -f /etc/modprobe.d/vfio.conf ]] && chk "rd.driver.pre=vfio_pci in cmdline" grep -q 'rd.driver.pre=vfio_pci' /etc/kernel/cmdline
have firewall-cmd && chk "firewalld active"                systemctl is-active firewalld
((FAILS)) && warn "$FAILS check(s) failed; see above and $LOG" || ok "All checks passed"

# Lean Hyper-V block that fixed the Win11 boot loop on the other PC
cat > "$HOME/win11-hyperv-block.xml" <<'EOF'
<!-- Paste into the Win11 VM's <features> (virsh edit). Leave out
     reenlightenment and stimer/direct: they caused the repair-loop boot.
     Keep VMX exposed (no vmx 'disable' line) so VBS/Credential Guard work. -->
<hyperv mode="custom">
  <relaxed state="on"/>
  <vapic state="on"/>
  <spinlocks state="on" retries="8191"/>
  <vpindex state="on"/>
  <runtime state="on"/>
  <synic state="on"/>
  <stimer state="on"/>
  <frequencies state="on"/>
  <tlbflush state="on"/>
  <ipi state="on"/>
  <avic state="on"/>
</hyperv>
<!-- Also add:  <memoryBacking><hugepages/></memoryBacking>  if you reserved hugepages -->
EOF
ok "Saved ~/win11-hyperv-block.xml for the VM"

echo
ok "Post-install complete."
cat <<'EOF'

Next steps:
  * Graphics: in Plasma, check the renderer says "Mesa Intel" (not llvmpipe):
      qdbus6 org.kde.KWin /KWin supportInformation | grep -i renderer
    (qdbus-qt6 if qdbus6 isn't there) and the firmware loaded:
      sudo dmesg | grep -iE 'dmc|guc'
  * KDE Wallet: let the first app create the wallet named 'kdewallet', type
    Blowfish (not GPG), password = your LOGIN password. It then opens
    automatically at every login. (Doesn't work with autologin; if you
    change your login password, change the wallet's in KWallet Manager too.)
  * SSH keys: if you have one (~/.ssh/id_ed25519), the first Plasma login
    asks for its passphrase. Tick "Remember password"; after that the key
    loads silently every login. Check with: ssh-add -l
  * Reboot: the login screen starts, group changes (libvirt, kvm) take
    effect, hugepages and the vfio-pci binding apply.
  * After reboot:
      lspci -nnk -d 10de:        -> "Kernel driver in use: vfio-pci"
      snapper list               -> snapshots; also in GRUB's snapshot menu
      sudo dnf install tree      -> creates a pre/post snapshot pair
  * Tailscale:   sudo tailscale up
                 sudo tailscale set --operator=$USER   (KTailctl without root)
  * Mullvad:     mullvad account login <account-number>
  * Syncthing:   http://127.0.0.1:8384  (systemctl --user enable --now syncthing if not running)
  * Win11 VM:    virt-manager -> UEFI with Secure Boot, TPM 2.0 (CRB), VirtIO disk
                 in /var/lib/libvirt/images, add the NVIDIA PCI function(s),
                 then apply ~/win11-hyperv-block.xml.
                 This is a laptop (Optimus) dGPU: it may have no display outputs,
                 so plan on Looking Glass/Parsec/RDP for the VM's screen; Windows'
                 driver may want the card's vBIOS (<rom file=.../>) and a virtual
                 battery (ACPI SSDT) to avoid Code 43; and a dGPU held by vfio-pci
                 doesn't power down, which costs battery.
  * Samba:       server disabled; edit /etc/samba/smb.conf, then
                 sudo systemctl enable --now smb
  * Backups:     restic or Borg for data; Snapper covers system rollback.
  * Updates:     sudo dnf upgrade --refresh   (Snapper snapshots each run;
                 encboot-fixup keeps the ESP stub + BLS paths right after it)
  * Fedora 46 later: sudo dnf system-upgrade download --releasever=46, then
                 sudo dnf offline reboot. Afterwards check the ESP stub:
                 grep cryptomount /boot/efi/EFI/fedora/grub.cfg
  * Rollback:    boot a snapshot from GRUB to test it, then make it permanent
                 with Btrfs Assistant (Snapper tab -> Restore).

Note: Mullvad and Tailscale can conflict over routing/DNS when both are
connected. Mullvad's "Local network sharing" may be needed for VM <-> LAN.
EOF
if yesno "Reboot now?" y; then
  sudo systemctl reboot
fi
