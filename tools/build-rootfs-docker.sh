#!/bin/bash
# =============================================================================
#  build-rootfs-docker.sh
#  Builds the complete Debian 12 (bookworm armel) + OpenMediaVault 7 rootfs,
#  3M Kernel uImage, and 12M Loop-Root Initramfs inside an arm32v5 container.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export QNAP_SKIP_FLASH=1

MAC_ADDR="${MAC_ADDR:-00:08:9b:11:22:33}"
MD0_UUID="${MD0_UUID:-}"
HOSTNAME_NEW="${HOSTNAME_NEW:-qnap-nas}"

say() { printf '\n==> %s\n' "$*"; }

# Prevent services from starting inside Docker build container
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

say "1/8 Installing base system, systemd, SSH, eatmydata & keyring tools"
apt-get update -qq
apt-get install -y --no-install-recommends \
    eatmydata ca-certificates curl gnupg wget apt-transport-https \
    systemd systemd-sysv dbus udev kmod initramfs-tools \
    openssh-server sudo locales tzdata iproute2 netbase ethtool \
    mdadm e2fsprogs util-linux parted smartmontools hdparm \
    u-boot-tools device-tree-compiler mtd-utils qcontrol \
    python3 rsync procps nano less xz-utils cpio

# Configure locales (en_US.UTF-8 + tr_TR.UTF-8)
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^# *tr_TR.UTF-8 UTF-8/tr_TR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# Configure eatmydata wrapper for apt to avoid fsync stalls on 512MB single-core Kirkwood
cat > /etc/apt/apt.conf.d/99eatmydata <<'EOF'
Dir::Bin::dpkg "/usr/bin/eatmydata";
DPkg::Options:: "--force-confdef";
DPkg::Options:: "--force-confold";
EOF
# Wait: Dir::Bin::dpkg eatmydata needs dpkg argument; safer standard OMV dpkg wrapper:
rm -f /etc/apt/apt.conf.d/99eatmydata

say "2/8 Adding OpenMediaVault 7 (Sandworm) repository"
curl -fsSL https://packages.openmediavault.org/public/archive.key \
    | gpg --dearmor -o /usr/share/keyrings/openmediavault-archive-keyring.gpg

rm -f /etc/apt/sources.list.d/debian.sources
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

cat > /etc/apt/sources.list.d/openmediavault.list <<'EOF'
deb [arch=armel signed-by=/usr/share/keyrings/openmediavault-archive-keyring.gpg] https://packages.openmediavault.org/public sandworm main
EOF

eatmydata apt-get update -qq

# Pre-install MODULES=list & COMPRESS=xz BEFORE linux-image-marvell so every update-initramfs run is fast (~15s instead of 4m) and ~4.5 MB!
mkdir -p /etc/initramfs-tools/conf.d
cat > /etc/initramfs-tools/conf.d/qnap-xz <<'EOF'
COMPRESS=xz
MODULES=list
EOF

say "3/8 Installing Debian 12 Kirkwood kernel (linux-image-marvell) & OpenMediaVault 7"
eatmydata apt-get install -y --no-install-recommends \
    openmediavault-keyring \
    linux-image-marvell \
    openmediavault \
    wsdd

say "4/8 Installing QNAP TS-219P II boot & hardware OMV 7 packages"
eatmydata apt-get install -y \
    /repo/dist/qnap-ts219p-boot_1.0.0_armel.deb \
    /repo/dist/openmediavault-qnap-ts219p_1.0.0_all.deb

say "5/8 Applying 512 MB RAM & Kirkwood 88F6282 performance tuning"
# 1. PHP-FPM ondemand tuning (saves ~60 MB idle RAM)
for pool in /etc/php/*/fpm/pool.d/*.conf; do
    [ -f "$pool" ] || continue
    if grep -q '^pm = ' "$pool"; then
        sed -i 's/^pm = .*/pm = ondemand/' "$pool"
        grep -q '^pm.process_idle_timeout' "$pool" \
            && sed -i 's/^pm.process_idle_timeout.*/pm.process_idle_timeout = 10s/' "$pool" \
            || echo "pm.process_idle_timeout = 10s" >> "$pool"
        grep -q '^pm.max_children' "$pool" \
            && sed -i 's/^pm.max_children.*/pm.max_children = 4/' "$pool" \
            || echo "pm.max_children = 4" >> "$pool"
    fi
done

# 2. Mask heavy/unneeded background daemons on 512 MB RAM
systemctl mask postfix.service monit.service qcontrold.service qcontrold.socket qcontrol.service >/dev/null 2>&1 || true
systemctl disable collectd.service rrdcached.service >/dev/null 2>&1 || true

# 3. Journald volatile/rate-limited configuration to allow HDD spindown & save RAM
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/qnap-lowmem.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
RateLimitIntervalSec=30s
RateLimitBurst=200
EOF

# 4. Kernel sysctl tuning for 512 MB NAS
cat > /etc/sysctl.d/99-qnap-nas.conf <<'EOF'
vm.swappiness = 20
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 16384
EOF

# 5. Network configuration: systemd-networkd DHCP on eth0 (preserves factory QNAP MAC)
systemctl enable systemd-networkd.service systemd-resolved.service ssh.service openmediavault-engined.service nginx.service >/dev/null 2>&1 || true
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
ClientIdentifier=mac
EOF

# Permit root SSH login with password
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/allow-root.conf

# Add root & admin to _ssh group if OMV enforces AllowGroups _ssh
if getent group _ssh >/dev/null 2>&1; then
    usermod -a -G _ssh root || true
    id admin >/dev/null 2>&1 && usermod -a -G _ssh admin || true
fi

# Set hostname & fstab (register /media/internal_1 for OMV!)
echo "$HOSTNAME_NEW" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_NEW
EOF

mkdir -p /media/internal_1
cat > /etc/fstab <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
/dev/root / ext4 defaults,noatime,errors=remount-ro 0 0
EOF

# Configure fw_env.config so fw_printenv / fw_setenv work out of the box in Debian
cat > /etc/fw_env.config <<'EOF'
# MTD device name   Device offset   Env. size   Flash sector size   Number of sectors
/dev/mtd4           0x0000          0x1000      0x40000             1
EOF

# Pre-register /media/internal_1 (/dev/md0) in OMV config.xml if UUID provided so Storage -> File Systems shows it immediately!
if [ -n "$MD0_UUID" ] && [ -f /etc/openmediavault/config.xml ]; then
    python3 - /etc/openmediavault/config.xml "$HOSTNAME_NEW" "$MD0_UUID" <<'PYEOF'
import sys, uuid, xml.etree.ElementTree as ET
cfg_path, host, md0_uuid = sys.argv[1], sys.argv[2], sys.argv[3]
tree = ET.parse(cfg_path)
r = tree.getroot()

h = r.find("./system/network/dns/hostname")
if h is not None:
    h.text = host

# Add eth0 interface entry if none exists
ifaces = r.find("./system/network/interfaces")
if ifaces is not None and len(list(ifaces)) == 0:
    ifc = ET.SubElement(ifaces, "interface")
    ET.SubElement(ifc, "uuid").text = str(uuid.uuid4())
    ET.SubElement(ifc, "type").text = "ethernet"
    ET.SubElement(ifc, "devicename").text = "eth0"
    ET.SubElement(ifc, "method").text = "dhcp"
    ET.SubElement(ifc, "address")
    ET.SubElement(ifc, "netmask")
    ET.SubElement(ifc, "gateway")
    ET.SubElement(ifc, "method6").text = "auto"
    ET.SubElement(ifc, "address6")
    ET.SubElement(ifc, "netmask6").text = "64"
    ET.SubElement(ifc, "gateway6")
    ET.SubElement(ifc, "dnsnameservers")
    ET.SubElement(ifc, "dnssearch")
    ET.SubElement(ifc, "mtu").text = "0"
    ET.SubElement(ifc, "wol").text = "0"
    ET.SubElement(ifc, "comment").text = "Gigabit Ethernet"

# Add /media/internal_1 mntent if not present
fstab = r.find("./system/fstab")
if fstab is not None:
    exists = any((m.findtext("dir") == "/media/internal_1") for m in fstab.findall("mntent"))
    if not exists:
        m = ET.SubElement(fstab, "mntent")
        ET.SubElement(m, "uuid").text = str(uuid.uuid4())
        ET.SubElement(m, "fsname").text = f"/dev/disk/by-uuid/{md0_uuid}"
        ET.SubElement(m, "dir").text = "/media/internal_1"
        ET.SubElement(m, "type").text = "ext4"
        ET.SubElement(m, "opts").text = "defaults,nofail,user_xattr,noatime"
        ET.SubElement(m, "freq").text = "0"
        ET.SubElement(m, "passno").text = "0"
        ET.SubElement(m, "hidden").text = "1"
        ET.SubElement(m, "usagewarnthreshold").text = "90"
        ET.SubElement(m, "comment").text = "QNAP RAID1 Data Volume (/dev/md0)"

# Samba ARM tuning options
smb_extra = r.find("./services/smb/extraoptions")
if smb_extra is not None:
    smb_extra.text = "socket options = TCP_NODELAY IPTOS_LOWDELAY\naio read size = 16384\naio write size = 16384\nuse sendfile = yes"

for el in r.iter():
    if len(el) == 0 and el.text is not None and el.text.strip() == "":
        el.text = None

tree.write(cfg_path, encoding="utf-8", xml_declaration=True)
PYEOF
fi

# Ensure OMV workbench UI and our dashboard widget injection are built
omv-mkworkbench all >/dev/null 2>&1 || true
/usr/share/openmediavault-qnap-ts219p/webui-inject || true

say "6/8 Building xz-compressed Loop-Root Initramfs & 3MB uImage"
KVER=$(ls /lib/modules | sort -V | tail -n1)
echo "Detected kernel version: $KVER"
update-initramfs -c -k "$KVER" || update-initramfs -u -k "$KVER"
/usr/sbin/qnap-flash-boot --no-flash --mac "$MAC_ADDR" "$KVER"

mkdir -p /repo/dist/boot
cp "/boot/uImage.mtd1" /repo/dist/boot/uImage.mtd1
cp "/boot/initrd.mtd2" /repo/dist/boot/initrd.mtd2
ls -lh /repo/dist/boot/

say "7/8 Sanitizing rootfs & marking first-boot flag"
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
mkdir -p /etc/qnap-ts219p
touch /etc/qnap-ts219p/firstboot

say "8/8 Packing clean ext4 rootfs image -> /repo/dist/qnap-ts219p-omv7-rootfs.img.gz"
STAGE=/tmp/rootfs_stage
mkdir -p "$STAGE"
rsync -aHAX --numeric-ids --one-file-system \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
    --exclude='/tmp/*' --exclude='/repo' --exclude='/repo/*' \
    --exclude='/etc/resolv.conf' --exclude='/etc/hostname' --exclude='/etc/hosts' \
    / "$STAGE/"

echo "$HOSTNAME_NEW" > "$STAGE/etc/hostname"
cat > "$STAGE/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_NEW
EOF
ln -sf /run/systemd/resolve/stub-resolv.conf "$STAGE/etc/resolv.conf"
mkdir -p "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/run" "$STAGE/tmp" "$STAGE/media/internal_1"
chmod 1777 "$STAGE/tmp"

USED_MB=$(du -sm "$STAGE" | awk '{print $1}')
SIZE_MB=$(( (USED_MB * 14 / 10 + 512 + 255) / 256 * 256 ))
echo "Rootfs stage uses ${USED_MB} MB -> creating ${SIZE_MB} MB ext4 image (grown to 32 GB on first boot)"
rm -f /tmp/rootfs.img
mke2fs -q -t ext4 -L DEBIAN_OMV -m 1 -d "$STAGE" /tmp/rootfs.img "${SIZE_MB}M"
e2fsck -fn /tmp/rootfs.img || true
gzip -1 -c /tmp/rootfs.img > /repo/dist/qnap-ts219p-omv7-rootfs-1.0.0.img.gz
rm -rf /tmp/rootfs.img "$STAGE"
ls -lh /repo/dist/qnap-ts219p-omv7-rootfs-1.0.0.img.gz /repo/dist/boot/*
say "BUILD COMPLETE!"
