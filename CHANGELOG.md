# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-11-20

### Added
- **Debian 12 (Bookworm) `armel` + OpenMediaVault 7 (Sandworm)** loop-mounted rootfs (`debian_omv.img`, auto-grows to 32 GB on first boot) preserving existing QNAP RAID 1 data volume (`/dev/md0` -> `/media/internal_1`).
- **Native U-Boot SPI NOR Flash Layout Resize** (`3 MB Kernel @ 0x100000`, `12 MB RootFS1 @ 0x400000`, `256 KB NAS_Config @ 0xc0000`) keeping `mtd0` (U-Boot) completely untouched, with automatic full SPI NOR backup + MD5 verification before flashing.
- **Custom Initramfs Boot Package (`qnap-ts219p-boot`)**:
  - Universal `/dev/md*` RAID 1 data volume discovery (> 5 GiB ext4) immune to `udev` MD numbering (`md0`, `md126`, `md127`).
  - POSIX-safe QNAP PIC16F 5-minute boot watchdog disarm (`0x67` octal `\147` over `/dev/ttyS1` @ 19200 8N1) plus `qnap-boot-healthcheck.service`.
  - Automated kernel/initrd flasher (`qnap-flash-boot`) with `uImage` + `kirkwood-ts219-6282.dtb` append, `xz --check=crc32` compression, and `flashcp` verification.
  - First-boot provisioning (`qnap-ts219p-firstboot`): SSH host key generation, password setup, online `resize2fs` to 32 GB, and RAID 1 swap activation.
- **Native OpenMediaVault 7 Hardware Plugin (`openmediavault-qnap-ts219p`)**:
  - **Interactive Hardware Overview Dashboard Widget** (EN/TR) with QNAP TS-219P II front & rear renders and live tooltips for Drive Bays 1 & 2, 70mm Fan, Gigabit LAN (`eth0`), Front USB 2.0 (`orion-ehci`), Rear 2× USB 3.0 (Etron `xhci_hcd`), Rear 2× eSATA II (JMicron `ahci`), and System/LED telemetry.
  - **6-Stage Fan & Thermal Control** (`qcontrol` PIC16F: Stop / Silence / Low / Medium / High / Full) with configurable automatic thermal curve using Kirkwood SoC thermal sensor.
  - **LED & Night Mode Control** (`STATUS`, `USB`, `POWER` LEDs + hourly auto-off schedule).
  - **Chassis Buttons & One-Touch USB Copy** (Front Power, Front USB Copy, Rear Reset — short & long press actions + automated USB backup).
- **Low-Memory & Single-Core ARMv5TE Optimizations**: PHP-FPM `ondemand`, volatile journald, `noatime`, Samba Gigabit tuning (`server signing = disabled`, `aio`, `sendfile`, `TCP_NODELAY`), and masked heavy background daemons (~125 MB idle RAM).
- **UART Recovery Guide (`docs/UART.md`)** with QNAP TS-219P II `CN1` pinout photo and U-Boot TFTP boot/restore instructions.
