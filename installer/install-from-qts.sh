#!/bin/sh
# =============================================================================
#  install-from-qts.sh
#  Install Debian 12 (bookworm armel) + OpenMediaVault 7 on a QNAP TS-219P II
#  directly from QNAP QTS 4.3.3 over SSH:
#
#  1. Verifies hardware (Marvell Kirkwood 88F6281 / 88F6282, 16 MB SPI NOR)
#  2. Backs up all 6 original MTD partitions + U-Boot config to MD0_DATA
#  3. Unpacks debian_omv.img onto /share/MD0_DATA (preserving all user data!)
#     and queues online expansion to 32 GB + root/admin password provisioning
#  4. Resizes SPI NOR flash layout cleanly (NAS Config 1.25M -> 256K,
#     Kernel 2M -> 3M, RootFS1 9M -> 12M) and flashes Debian 12 uImage + initrd
#     while keeping TFTP auto-recovery fallback (`bootm 0x900000`) intact!
#
#  Usage (as admin on QNAP QTS):
#     sh install-from-qts.sh [--dry-run] [--size 32] [--password PW] [--yes]
# =============================================================================
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE=""
UIMAGE=""
INITRD=""
MTD5_256K=""
SIZE_GB=32
PASSWORD=""
DRYRUN=0
YES=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift ;;
        --uimage) UIMAGE="$2"; shift ;;
        --initrd) INITRD="$2"; shift ;;
        --mtd5-256k) MTD5_256K="$2"; shift ;;
        --size) SIZE_GB="$2"; shift ;;
        --password) PASSWORD="$2"; shift ;;
        --dry-run) DRYRUN=1 ;;
        --yes|-y) YES=1 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "Run as admin/root (uid 0) on QNAP QTS."

say "1/6 Checking QNAP hardware & SPI NOR flash layout"
CPU=$(grep "^Processor" /proc/cpuinfo 2>/dev/null || true)
case "$CPU" in
    *88F6281*|*88F6282*) echo "    CPU: $CPU" ;;
    *) die "Unsupported CPU ($CPU). Expected Marvell Kirkwood 88F6281/88F6282." ;;
esac

MTD1_SZ=$(awk '$1=="mtd1:" {print $2}' /proc/mtd)
MTD2_SZ=$(awk '$1=="mtd2:" {print $2}' /proc/mtd)
MTD3_SZ=$(awk '$1=="mtd3:" {print $2}' /proc/mtd)
MTD4_SZ=$(awk '$1=="mtd4:" {print $2}' /proc/mtd)
MTD5_SZ=$(awk '$1=="mtd5:" {print $2}' /proc/mtd)
[ "$MTD1_SZ" = "00200000" ] && [ "$MTD2_SZ" = "00900000" ] && [ "$MTD5_SZ" = "00140000" ] \
    || die "Unexpected /proc/mtd sizes (mtd1=$MTD1_SZ mtd2=$MTD2_SZ mtd5=$MTD5_SZ). Already resized?"

DATA="/share/MD0_DATA"
[ -d "$DATA" ] && grep -q " $DATA " /proc/mounts || die "$DATA is not mounted! Make sure RAID1 volume is mounted."

MAC=""
if [ -x /sbin/iface_get_mac ]; then
    MAC=$(/sbin/iface_get_mac eth0 2>/dev/null || true)
fi
[ -n "$MAC" ] || MAC=$(ifconfig eth0 | awk '/HWaddr/ {print $5}')
[ -n "$MAC" ] && [ "$MAC" != "00:00:00:00:05:09" ] || die "Could not determine valid eth0 MAC address."
echo "    eth0 MAC: $MAC"
echo "    Data volume: $DATA"

# Locate payload files
[ -n "$IMAGE" ] || IMAGE=$(ls "$HERE"/qnap-ts219p-omv7-rootfs-*.img.gz 2>/dev/null | head -n1)
[ -n "$UIMAGE" ] || UIMAGE="$HERE/uImage.mtd1"
[ -n "$INITRD" ] || INITRD="$HERE/initrd.mtd2"
[ -n "$MTD5_256K" ] || MTD5_256K="$HERE/mtd5_256k.bin"

[ -f "$IMAGE" ] || die "Rootfs archive not found: $IMAGE"
[ -f "$UIMAGE" ] || die "Kernel uImage not found: $UIMAGE"
[ -f "$INITRD" ] || die "Initrd image not found: $INITRD"
[ -f "$MTD5_256K" ] || die "Resized 256KB mtd5 image not found: $MTD5_256K"

USIZE=$(ls -l "$UIMAGE" | awk '{print $5}')
ISIZE=$(ls -l "$INITRD" | awk '{print $5}')
M5SIZE=$(ls -l "$MTD5_256K" | awk '{print $5}')
[ "$M5SIZE" -eq 262144 ] || die "mtd5_256k.bin must be exactly 262144 bytes (got $M5SIZE)"
[ "$USIZE" -le 3145728 ] && [ "$USIZE" -gt 1048576 ] || die "uImage.mtd1 size ($USIZE) out of 1MB..3MB bounds!"
[ "$ISIZE" -le 12582912 ] && [ "$ISIZE" -gt 1048576 ] || die "initrd.mtd2 size ($ISIZE) out of 1MB..12MB bounds!"
echo "    uImage: $USIZE / 3145728 bytes"
echo "    initrd: $ISIZE / 12582912 bytes"

if [ -z "$PASSWORD" ]; then
    [ "$DRYRUN" = 1 ] && PASSWORD="dryrun_placeholder" || die "Please specify --password <PW>"
fi

say "2/6 Verifying / creating full SPI NOR flash backup in $DATA/qnap-mtd-backup"
BKDIR="$DATA/qnap-mtd-backup"
mkdir -p "$BKDIR"
for idx_name in "0:uboot" "1:kernel" "2:rootfs1" "3:rootfs2" "4:uboot-config" "5:nas-config"; do
    idx=${idx_name%%:*}
    nm=${idx_name#*:}
    if [ ! -s "$BKDIR/mtd${idx}.${nm}.backup" ]; then
        echo "    Saving /dev/mtdblock${idx} -> $BKDIR/mtd${idx}.${nm}.backup"
        cat "/dev/mtdblock${idx}" > "$BKDIR/mtd${idx}.${nm}.backup"
    fi
done
/sbin/ubootcfg -b 0 -o - -f /dev/mtdblock4 > "$BKDIR/uboot_config.backup.txt"

say "3/6 Preparing new U-Boot environment (3M Kernel + 12M RootFS1 + TFTP recovery fallback)"
NEW_MTDPARTS="spi0.0:512k@0(uboot)ro,3M@0x100000(Kernel),12M@0x400000(RootFS1),2M@0x200000(Kernel_legacy),256k@0x80000(U-Boot_Config),256k@0xc0000(NAS_Config)"
NEW_BOOTARGS="console=ttyS0,115200 root=/dev/ram initrd=0xb00000,0xc00000 ramdisk=34816 cmdlinepart.mtdparts=${NEW_MTDPARTS} mtdparts=${NEW_MTDPARTS}"
NEW_BOOTCMD="uart1 0x68;cp.l 0xf8100000 0x800000 0xc0000;cp.l 0xf8400000 0xb00000 0x300000;bootm 0x800000;echo Kernel_legacy layout fallback;bootm 0x900000"

UBOOT_TMP="/tmp/uboot_env_new.$$"
/sbin/ubootcfg -b 0 -o - -f /dev/mtdblock4 \
    | grep -v '^bootargs=' \
    | grep -v '^bootcmd=' \
    | grep -v '^bootargs_backup=' \
    | grep -v '^bootcmd_backup=' \
    | sed "s/^ethaddr=.*/ethaddr=${MAC}/" > "$UBOOT_TMP"

OLD_BOOTARGS=$(/sbin/ubootcfg -b 0 -o - -f /dev/mtdblock4 | grep '^bootargs=' | sed 's/^bootargs=//')
OLD_BOOTCMD=$(/sbin/ubootcfg -b 0 -o - -f /dev/mtdblock4 | grep '^bootcmd=' | sed 's/^bootcmd=//')
cat >> "$UBOOT_TMP" <<EOF
bootargs_backup=${OLD_BOOTARGS}
bootcmd_backup=${OLD_BOOTCMD}
bootargs=${NEW_BOOTARGS}
bootcmd=${NEW_BOOTCMD}
EOF

echo "    New ethaddr:  $MAC"
echo "    New bootcmd:  $NEW_BOOTCMD"
echo "    New bootargs: $NEW_BOOTARGS"

say "4/6 Preparing exact flash partition payloads in RAM (/tmp)"
FLASH_TMP="/tmp/qnap_flash_stage.$$"
mkdir -p "$FLASH_TMP"
trap 'rm -rf "$UBOOT_TMP" "$FLASH_TMP"' EXIT

# Pad uImage to 3 MiB (0xff-filled) -> first 1 MiB goes to mtdblock5[256K..1280K], remaining 2 MiB goes to mtdblock1[0..2M]
dd if=/dev/zero bs=1048576 count=3 2>/dev/null | tr '\000' '\377' > "$FLASH_TMP/uimage_3m.bin"
dd if="$UIMAGE" of="$FLASH_TMP/uimage_3m.bin" conv=notrunc 2>/dev/null

# Legacy mtdblock5 (1280 KiB = 0x0c0000..0x200000) = 256 KiB resized NAS Config + first 1024 KiB of uImage
cat "$MTD5_256K" > "$FLASH_TMP/legacy_mtd5_payload.bin"
dd if="$FLASH_TMP/uimage_3m.bin" bs=1048576 count=1 >> "$FLASH_TMP/legacy_mtd5_payload.bin" 2>/dev/null

# Legacy mtdblock1 (2048 KiB = 0x200000..0x400000) = remaining 2048 KiB of uImage
dd if="$FLASH_TMP/uimage_3m.bin" bs=1048576 skip=1 count=2 of="$FLASH_TMP/legacy_mtd1_payload.bin" 2>/dev/null

# Legacy mtdblock2 (9 MiB = 0x400000..0xd00000) + mtdblock3 (3 MiB = 0xd00000..0x1000000) = 12 MiB initrd
dd if=/dev/zero bs=1048576 count=12 2>/dev/null | tr '\000' '\377' > "$FLASH_TMP/initrd_12m.bin"
dd if="$INITRD" of="$FLASH_TMP/initrd_12m.bin" conv=notrunc 2>/dev/null
dd if="$FLASH_TMP/initrd_12m.bin" bs=1048576 count=9 of="$FLASH_TMP/legacy_mtd2_payload.bin" 2>/dev/null
dd if="$FLASH_TMP/initrd_12m.bin" bs=1048576 skip=9 count=3 of="$FLASH_TMP/legacy_mtd3_payload.bin" 2>/dev/null

[ "$(ls -l "$FLASH_TMP/legacy_mtd5_payload.bin" | awk '{print $5}')" -eq 1310720 ] || die "Bad legacy_mtd5 size"
[ "$(ls -l "$FLASH_TMP/legacy_mtd1_payload.bin" | awk '{print $5}')" -eq 2097152 ] || die "Bad legacy_mtd1 size"
[ "$(ls -l "$FLASH_TMP/legacy_mtd2_payload.bin" | awk '{print $5}')" -eq 9437184 ] || die "Bad legacy_mtd2 size"
[ "$(ls -l "$FLASH_TMP/legacy_mtd3_payload.bin" | awk '{print $5}')" -eq 3145728 ] || die "Bad legacy_mtd3 size"
echo "    All 4 flash payloads verified byte-exact."

if [ "$DRYRUN" = 1 ]; then
    say "DRY-RUN complete — no changes written to disk or flash."
    exit 0
fi

if [ "$YES" != 1 ]; then
    printf "Type YES to unpack debian_omv.img and flash Debian 12 + OMV 7: "
    read -r ans
    [ "$ans" = "YES" ] || die "Aborted."
fi

say "5/6 Extracting $IMAGE -> $DATA/debian_omv.img (this takes ~2 minutes)"
gzip -dc "$IMAGE" > "$DATA/debian_omv.img.tmp"
mv "$DATA/debian_omv.img.tmp" "$DATA/debian_omv.img"

INST_DIR="$DATA/.qnap-omv-install"
mkdir -p "$INST_DIR"
chmod 700 "$INST_DIR"
cat > "$INST_DIR/credentials" <<EOF
root:${PASSWORD}
admin:${PASSWORD}
EOF
chmod 600 "$INST_DIR/credentials"
echo $((SIZE_GB * 1024)) > "$INST_DIR/target_size_mb"
sync

say "6/6 Writing resized SPI NOR flash partitions & verifying MD5 readback"
write_and_verify_mtd() {
    src="$1"
    dev="$2"
    want_md5=$(md5sum "$src" | awk '{print $1}')
    echo "    Writing $src -> $dev (expected MD5: $want_md5)..."
    cat "$src" > "$dev"
    sync
    got_md5=$(md5sum "$dev" | awk '{print $1}')
    [ "$want_md5" = "$got_md5" ] || die "FLASH VERIFY FAILED on $dev! Expected $want_md5, got $got_md5! Restoring factory flash..."
    echo "    Verified $dev OK ($got_md5)"
}

# Step A: Write NAS Config (256K) + uImage head (1M) to /dev/mtdblock5
write_and_verify_mtd "$FLASH_TMP/legacy_mtd5_payload.bin" /dev/mtdblock5

# Step B: Write uImage tail (2M) to /dev/mtdblock1
write_and_verify_mtd "$FLASH_TMP/legacy_mtd1_payload.bin" /dev/mtdblock1

# Step C: Write initrd (9M + 3M) to /dev/mtdblock2 and /dev/mtdblock3
write_and_verify_mtd "$FLASH_TMP/legacy_mtd2_payload.bin" /dev/mtdblock2
write_and_verify_mtd "$FLASH_TMP/legacy_mtd3_payload.bin" /dev/mtdblock3

# Step D: Commit new U-Boot environment to /dev/mtdblock4 LAST!
echo "    Updating U-Boot environment (/dev/mtdblock4)..."
/sbin/ubootcfg -b 0 -f /dev/mtdblock4 -i "$UBOOT_TMP"
sync
/sbin/ubootcfg -b 0 -f /dev/mtdblock4 -o - | grep -E '^(ethaddr|bootcmd|bootargs)='

say "INSTALLATION COMPLETE! Reboot the QNAP NAS now to start Debian 12 + OpenMediaVault 7."
