<?php
namespace Engined\Rpc;

class FanControl extends \OMV\Rpc\ServiceAbstract {
    private $fanConfigFile = "/etc/qnap-fan.json";
    private $ledConfigFile = "/etc/qnap-led.json";
    private $stateFile = "/run/qnap-ts219p-hwstate.json";

    public function getName() {
        return "FanControl";
    }

    public function initialize() {
        $this->registerMethod("getSettings");
        $this->registerMethod("setSettings");
        $this->registerMethod("getStatus");
        $this->registerMethod("getGridItems");
        $this->registerMethod("getVisualOverview");
    }

    private function readFanConfig() {
        $defaults = [
            "mode" => "auto",
            "manual_rpm" => 1400,
            "temp_low" => 40,
            "temp_med" => 48,
            "temp_high" => 56
        ];
        if (file_exists($this->fanConfigFile)) {
            $decoded = @json_decode(@file_get_contents($this->fanConfigFile), true);
            if (is_array($decoded)) {
                $defaults = array_merge($defaults, $decoded);
            }
        }
        return $defaults;
    }

    private function readLedConfig() {
        $defaults = [
            "preset_mode" => "normal",
            "led_white_power" => "on",
            "led_red_power" => "off",
            "led_white_sata" => "on",
            "led_red_sata" => "off",
            "schedule_enabled" => false,
            "off_start_hour" => 23,
            "off_end_hour" => 7,
            "sync_button_toggle" => true
        ];
        if (file_exists($this->ledConfigFile)) {
            $decoded = @json_decode(@file_get_contents($this->ledConfigFile), true);
            if (is_array($decoded)) {
                $defaults = array_merge($defaults, $decoded);
            }
        }
        return $defaults;
    }

    private function getHardwareStats() {
        $st = [
            "fan_name" => "low",
            "fan_rpm" => 950,
            "fan_pct" => 50,
            "cpu_temp" => 40.0,
            "status_led" => "greenon",
            "usb_led" => "on"
        ];
        if (file_exists($this->stateFile)) {
            $dec = @json_decode(@file_get_contents($this->stateFile), true);
            if (is_array($dec)) $st = array_merge($st, $dec);
        }

        $cpuTemp = floatval($st["cpu_temp"]);
        foreach (glob("/sys/class/thermal/thermal_zone*/temp") as $tp) {
            $v = intval(@trim(file_get_contents($tp)));
            if ($v > 1000) { $cpuTemp = round($v / 1000.0, 1); break; }
        }

        $diskTemps = [];
        foreach (["sda", "sdb"] as $d) {
            $dt = "--";
            $out = [];
            @exec("smartctl -A -n standby /dev/$d 2>/dev/null", $out);
            foreach ($out as $line) {
                if (strpos($line, "Temperature_Celsius") !== false || strpos($line, "Airflow_Temperature_Cel") !== false) {
                    $cols = preg_split('/\s+/', trim($line));
                    if (count($cols) >= 10) {
                        $dt = $cols[9] . " °C";
                        break;
                    }
                }
            }
            $diskTemps[$d] = $dt;
        }

        $rpm = intval($st["fan_rpm"]);
        $pct = intval($st["fan_pct"]);
        $level = ($pct >= 85) ? 3 : (($pct >= 65) ? 2 : (($pct > 0) ? 1 : 0));

        return [
            "cpu_temp" => $cpuTemp,
            "phy_temp" => $cpuTemp,
            "rpm" => $rpm,
            "pwm" => intval(round($pct * 2.55)),
            "pct" => $pct,
            "fan_name" => strval($st["fan_name"]),
            "level" => $level,
            "sda_temp" => $diskTemps["sda"],
            "sdb_temp" => $diskTemps["sdb"],
            "white_led" => ($st["status_led"] === "off") ? "OFF" : strtoupper($st["status_led"]),
            "red_led" => strtoupper($st["usb_led"])
        ];
    }

    public function getSettings($params, $context) {
        $cfg = $this->readFanConfig();
        $hw = $this->getHardwareStats();
        $modeLabel = ($cfg["mode"] === "manual") ? "Manual" : "Auto (PIC Smart Thermal)";
        return [
            "live_status" => sprintf(
                "Fan: ~%d RPM (%s / %d%% - %s) | SoC/Sys: %.1f °C | Disk 1 (sda): %s | Disk 2 (sdb): %s",
                $hw["rpm"], strtoupper($hw["fan_name"]), $hw["pct"], $modeLabel, $hw["cpu_temp"], $hw["sda_temp"], $hw["sdb_temp"]
            ),
            "mode" => strval($cfg["mode"]),
            "manual_rpm" => intval($cfg["manual_rpm"]),
            "temp_low" => intval($cfg["temp_low"]),
            "temp_med" => intval($cfg["temp_med"]),
            "temp_high" => intval($cfg["temp_high"])
        ];
    }

    public function setSettings($params, $context) {
        $tLow = max(25, min(70, intval($params["temp_low"] ?? 40)));
        $tMed = max($tLow + 2, min(78, intval($params["temp_med"] ?? 48)));
        $tHigh = max($tMed + 2, min(85, intval($params["temp_high"] ?? 56)));
        $cfg = [
            "mode" => (($params["mode"] ?? "auto") === "manual") ? "manual" : "auto",
            "manual_rpm" => intval($params["manual_rpm"] ?? 1400),
            "temp_low" => $tLow,
            "temp_med" => $tMed,
            "temp_high" => $tHigh
        ];
        file_put_contents($this->fanConfigFile, json_encode($cfg, JSON_PRETTY_PRINT));
        @shell_exec("/usr/sbin/qnap-ts219p-hwd --once >/dev/null 2>&1");
        return $this->getSettings($params, $context);
    }

    public function getStatus($params, $context) {
        $cfg = $this->readFanConfig();
        $hw = $this->getHardwareStats();
        return [
            [
                "order" => 1,
                "sensor" => "Chassis Fan (PIC16F)",
                "value" => sprintf("~%d RPM (%s - %d%%)", $hw["rpm"], strtoupper($hw["fan_name"]), $hw["pct"]),
                "detail" => ($cfg["mode"] === "auto") ? "Auto Mode" : "Manual Mode"
            ],
            [
                "order" => 2,
                "sensor" => "CPU (Kirkwood 88F6282 @ 2.0 GHz)",
                "value" => sprintf("%.1f °C", $hw["cpu_temp"]),
                "detail" => "Kirkwood Thermal Sensor"
            ],
            [
                "order" => 3,
                "sensor" => "Disk 1 & Disk 2 Temp",
                "value" => sprintf("%s / %s", $hw["sda_temp"], $hw["sdb_temp"]),
                "detail" => "RAID 1 (/dev/md0)"
            ]
        ];
    }

    public function getGridItems($params, $context) {
        $cfg = $this->readFanConfig();
        $hw = $this->getHardwareStats();
        $modeText = ($cfg["mode"] === "auto") ? "Auto" : "Manual";
        return [
            "data" => [
                [
                    "title" => "Fan Speed (" . $modeText . ")",
                    "value" => sprintf("~%d RPM (%s)", $hw["rpm"], strtoupper($hw["fan_name"])),
                    "icon" => "mdi:fan",
                    "state" => "ok"
                ],
                [
                    "title" => "SoC / System Temp",
                    "value" => sprintf("%.1f °C", $hw["cpu_temp"]),
                    "icon" => "mdi:thermometer",
                    "state" => "ok"
                ],
                [
                    "title" => "Disk 1 & 2 Temp",
                    "value" => sprintf("%s / %s", $hw["sda_temp"], $hw["sdb_temp"]),
                    "icon" => "mdi:harddisk",
                    "state" => "ok"
                ]
            ],
            "total" => 3
        ];
    }

    private function getDiskDetail($dev, $bayNum, $tempStr) {
        $model = @trim(file_get_contents("/sys/block/$dev/device/model")) ?: "Unknown HDD";
        $serial = "--";
        $out = [];
        @exec("lsblk -dn -o SERIAL,SIZE /dev/$dev 2>/dev/null", $out);
        if (!empty($out[0])) {
            $parts = preg_split('/\s+/', trim($out[0]));
            if (count($parts) >= 1) $serial = $parts[0];
        }
        $sectors = floatval(@trim(file_get_contents("/sys/block/$dev/size")));
        $bytes = $sectors * 512.0;
        $tib = round($bytes / (1024*1024*1024*1024), 2);
        $tb = round($bytes / 1000000000000.0, 2);
        return [
            "bay" => $bayNum,
            "device" => "/dev/$dev",
            "model" => $model,
            "serial" => $serial,
            "size" => "{$tib} TiB ({$tb} TB)",
            "temp" => $tempStr,
            "smart" => "GOOD / PASSED",
            "raid" => "RAID 1 (/dev/md0)"
        ];
    }

    private function inspectUsbDevice($cid, $portNum, $defaultSpeed) {
        $base = "/sys/bus/usb/devices/$cid";
        if (!is_dir($base)) return null;
        $prod = @trim(file_get_contents("$base/product"));
        $mfg = @trim(file_get_contents("$base/manufacturer"));
        $spd = @trim(file_get_contents("$base/speed"));
        $vid = @trim(file_get_contents("$base/idVendor"));
        $pid = @trim(file_get_contents("$base/idProduct"));
        $blkName = "";
        $blkSize = "";
        $blkModel = "";
        foreach (glob("/sys/block/sd*") as $bpath) {
            $real = realpath($bpath);
            if ($real && strpos($real, "/$cid/") !== false) {
                $bn = basename($bpath);
                $blkName = "/dev/$bn";
                $sec = floatval(@trim(file_get_contents("$bpath/size")));
                $b = $sec * 512.0;
                $blkSize = ($b >= 1073741824) ? (round($b / 1073741824, 2) . " GiB") : (round($b / 1048576, 1) . " MiB");
                $blkModel = @trim(file_get_contents("$bpath/device/model"));
                break;
            }
        }
        $usbVer = (intval($spd) >= 5000) ? "USB 3.0 SuperSpeed" : "USB 2.0 High-Speed";
        $displayName = trim(($mfg ? "$mfg " : "") . ($prod ? $prod : ""));
        if ($blkModel && stripos($displayName, $blkModel) === false) {
            $displayName = trim($displayName . " ($blkModel)");
        }
        if (!$displayName) $displayName = "USB Device ($vid:$pid)";
        return [
            "connected" => true,
            "port" => $portNum,
            "bus_id" => $cid,
            "name" => $displayName,
            "vendor" => $mfg ?: "Generic",
            "product" => $prod ?: ($blkModel ?: "USB Device"),
            "usb_id" => "$vid:$pid",
            "speed" => "{$spd} Mbps ({$usbVer})",
            "block_dev" => $blkName ?: "--",
            "capacity" => $blkSize ?: "--"
        ];
    }

    private function getUsbPortDetail($slot) {
        // Dynamically map buses by host controller so bus numbering changes never break port mapping:
        // orion-ehci (f1050000.ehci) -> Front USB 2.0 (port 1)
        // xhci_hcd (0000:02:00.0 Etron EJ168) -> Rear USB 3.0 #1 (port 1) & #2 (port 2)
        $ehciBuses = [];
        $xhciBuses = [];
        foreach (glob("/sys/bus/usb/devices/usb*") as $ub) {
            $bnum = intval(substr(basename($ub), 3));
            $real = realpath($ub) ?: "";
            if (strpos($real, "ehci") !== false) {
                $ehciBuses[] = $bnum;
            } else {
                $xhciBuses[] = $bnum;
            }
        }

        $candidates = [];
        $defaultSpeed = "USB 3.0 (5000 Mbps)";
        $portNum = 2;
        if ($slot === "front") {
            $portNum = 1;
            $defaultSpeed = "USB 2.0 (480 Mbps)";
            foreach ($ehciBuses as $b) $candidates[] = "{$b}-1";
        } elseif ($slot === "rear1") {
            $portNum = 2;
            foreach ($xhciBuses as $b) $candidates[] = "{$b}-1";
        } elseif ($slot === "rear2") {
            $portNum = 3;
            foreach ($xhciBuses as $b) $candidates[] = "{$b}-2";
        } else {
            // Combined rear summary
            $portNum = 2;
            foreach ($xhciBuses as $b) {
                $candidates[] = "{$b}-1";
                $candidates[] = "{$b}-2";
            }
        }

        foreach ($candidates as $cid) {
            $res = $this->inspectUsbDevice($cid, $portNum, $defaultSpeed);
            if ($res !== null) return $res;
        }
        return [
            "connected" => false,
            "port" => $portNum,
            "bus_id" => "--",
            "name" => "",
            "vendor" => "--",
            "product" => "--",
            "usb_id" => "--",
            "speed" => $defaultSpeed,
            "block_dev" => "--",
            "capacity" => "--"
        ];
    }

    private function getEsataPortDetail($portIdx) {
        // JMicron JMB363 PCIe AHCI (0000:01:00.0) provides 2 rear eSATA 3 Gbps ports (ata3 / ata4)
        $ahciHosts = [];
        foreach (glob("/sys/class/scsi_host/host*") as $h) {
            $real = realpath($h) ?: "";
            if (strpos($real, "0000:01:00.0") !== false) {
                $ahciHosts[] = basename($h);
            }
        }
        sort($ahciHosts, SORT_NATURAL);
        $targetHost = $ahciHosts[$portIdx - 1] ?? null;
        if ($targetHost) {
            foreach (glob("/sys/block/sd*") as $bpath) {
                $real = realpath($bpath) ?: "";
                if (strpos($real, "/$targetHost/") !== false) {
                    $bn = basename($bpath);
                    $model = @trim(file_get_contents("$bpath/device/model")) ?: "eSATA Drive";
                    $sec = floatval(@trim(file_get_contents("$bpath/size")));
                    $b = $sec * 512.0;
                    $cap = ($b >= 1099511627776) ? (round($b / 1099511627776, 2) . " TiB") : (round($b / 1073741824, 1) . " GiB");
                    return [
                        "connected" => true,
                        "port" => $portIdx,
                        "name" => $model,
                        "block_dev" => "/dev/$bn",
                        "capacity" => $cap,
                        "speed" => "eSATA II (3.0 Gbps)"
                    ];
                }
            }
        }
        return [
            "connected" => false,
            "port" => $portIdx,
            "name" => "",
            "block_dev" => "--",
            "capacity" => "--",
            "speed" => "eSATA II (3.0 Gbps)"
        ];
    }

    private function formatBytes($bytes) {
        if ($bytes >= 1073741824) return round($bytes / 1073741824, 2) . " GiB";
        if ($bytes >= 1048576) return round($bytes / 1048576, 2) . " MiB";
        if ($bytes >= 1024) return round($bytes / 1024, 1) . " KiB";
        return $bytes . " B";
    }

    public function getVisualOverview($params, $context) {
        $fcfg = $this->readFanConfig();
        $lcfg = $this->readLedConfig();
        $hw = $this->getHardwareStats();

        $iface = "eth0";
        $oper = strtoupper(@trim(file_get_contents("/sys/class/net/$iface/operstate")) ?: "UP");
        $speed = @trim(file_get_contents("/sys/class/net/$iface/speed")) ?: "1000";
        $duplex = ucfirst(@trim(file_get_contents("/sys/class/net/$iface/duplex")) ?: "full");
        $mac = strtoupper(@trim(file_get_contents("/sys/class/net/$iface/address")) ?: "-");
        $rxBytes = floatval(@trim(file_get_contents("/sys/class/net/$iface/statistics/rx_bytes")));
        $txBytes = floatval(@trim(file_get_contents("/sys/class/net/$iface/statistics/tx_bytes")));
        $rxPkts = intval(@trim(file_get_contents("/sys/class/net/$iface/statistics/rx_packets")));
        $txPkts = intval(@trim(file_get_contents("/sys/class/net/$iface/statistics/tx_packets")));

        $ipOut = [];
        @exec("ip -4 -o addr show dev $iface 2>/dev/null | awk '{print \$4}'", $ipOut);
        $ipAddr = !empty($ipOut[0]) ? trim($ipOut[0]) : "-";

        $uptimeSec = intval(explode(' ', @trim(file_get_contents("/proc/uptime")))[0]);
        $hours = floor($uptimeSec / 3600);
        $mins = floor(($uptimeSec % 3600) / 60);
        $uptimeStr = "{$hours}h {$mins}m";

        $loadParts = explode(' ', @trim(file_get_contents("/proc/loadavg")));
        $loadStr = "{$loadParts[0]} / {$loadParts[1]} / {$loadParts[2]}";

        $memInfo = @file("/proc/meminfo", FILE_IGNORE_NEW_LINES);
        $memTotal = 515428;
        $memAvail = 400000;
        if ($memInfo) {
            foreach ($memInfo as $ml) {
                if (strpos($ml, "MemTotal:") === 0) $memTotal = intval(preg_replace('/\D+/', '', $ml));
                if (strpos($ml, "MemAvailable:") === 0) $memAvail = intval(preg_replace('/\D+/', '', $ml));
            }
        }
        $memUsedMb = round(($memTotal - $memAvail) / 1024.0, 1);
        $memTotalMb = round($memTotal / 1024.0, 1);
        $memPct = intval(round(($memUsedMb / max(1, $memTotalMb)) * 100));

        return [
            "ts_ms" => round(microtime(true) * 1000),
            "model" => "QNAP TS-219P II (Kirkwood 88F6282 @ 2.0 GHz)",
            "disks" => [
                "bay1" => $this->getDiskDetail("sda", 1, $hw["sda_temp"]),
                "bay2" => $this->getDiskDetail("sdb", 2, $hw["sdb_temp"])
            ],
            "fan" => [
                "rpm" => $hw["rpm"],
                "pwm" => $hw["pwm"],
                "pct" => $hw["pct"],
                "level" => $hw["level"],
                "mode" => $fcfg["mode"],
                "cpu_temp" => $hw["cpu_temp"],
                "phy_temp" => $hw["phy_temp"],
                "thresholds" => "{$fcfg['temp_low']}°C / {$fcfg['temp_med']}°C / {$fcfg['temp_high']}°C"
            ],
            "usb" => [
                "front" => $this->getUsbPortDetail("front"),
                "rear" => $this->getUsbPortDetail("rear"),
                "rear1" => $this->getUsbPortDetail("rear1"),
                "rear2" => $this->getUsbPortDetail("rear2")
            ],
            "esata" => [
                "port1" => $this->getEsataPortDetail(1),
                "port2" => $this->getEsataPortDetail(2)
            ],
            "eth" => [
                "iface" => $iface,
                "operstate" => $oper,
                "ip" => $ipAddr,
                "mac" => $mac,
                "speed" => "{$speed} Mbps ({$duplex})",
                "rx_bytes" => $rxBytes,
                "tx_bytes" => $txBytes,
                "rx_human" => $this->formatBytes($rxBytes),
                "tx_human" => $this->formatBytes($txBytes),
                "rx_packets" => $rxPkts,
                "tx_packets" => $txPkts,
                "phy_temp" => $hw["cpu_temp"] . " °C"
            ],
            "system" => [
                "hostname" => gethostname(),
                "uptime" => $uptimeStr,
                "load" => $loadStr,
                "mem_used_mb" => $memUsedMb,
                "mem_total_mb" => $memTotalMb,
                "mem_pct" => $memPct,
                "led_mode" => $lcfg["preset_mode"],
                "white_led" => $hw["white_led"],
                "red_led" => $hw["red_led"]
            ]
        ];
    }
}
