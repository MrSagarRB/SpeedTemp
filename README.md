# SpeedTemp

A tiny macOS menu bar app that shows your live network speed and your Mac's temperature.

```
↓ 340 KB/s  ↑ 12.5 KB/s  🌡 44°C
```

## Features

- Live download and upload speed in KB/s, updated every second
- CPU temperature in the menu bar
- Click for details:
  - Download and upload speed, and the totals since the app started
  - CPU, GPU, SoC, SSD and battery temperatures
  - Thermal state (Normal / Warm / Hot / Critical)
- Open at Login option
- Native Swift, a single file, no dependencies, very low CPU use

## Install

1. Download **SpeedTemp.zip** from the [latest release](../../releases/latest).
2. Unzip it and drag **SpeedTemp.app** into your **Applications** folder.
3. Open it. macOS will warn that the app is from an unidentified developer, because it isn't notarized by Apple. To open it anyway:
   - Right-click the app → **Open** → **Open**, or
   - go to **System Settings → Privacy & Security** and click **Open Anyway**.

It needs no permissions. Requires macOS 13 (Ventura) or later.

## Notes

- **Which traffic it counts:** Wi-Fi, Ethernet and cellular/hotspot. VPN tunnels are skipped so traffic isn't counted twice.
- **Temperatures need an Apple Silicon Mac (M1 or later).** They come from Apple's built-in sensors, read through an undocumented system interface, so a future macOS update could break them. If sensors aren't available, the menu bar shows `--°C`.

## Build from source

```sh
git clone https://github.com/MrSagarRB/SpeedTemp.git
cd SpeedTemp
./build.sh
open SpeedTemp.app
```

You need the Xcode Command Line Tools (`xcode-select --install`).

## License

MIT
