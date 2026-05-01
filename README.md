# BZ5 Companion

**An Android app for monitoring the Toyota BZ5** through an OBD-II Bluetooth adapter.

Shows what the dashboard hides: precise battery health, cell balance, real pack voltage, temperature, and more — all in one place, in real time.

> ⚠️ **Unofficial project.** Not affiliated with Toyota or FAW-Toyota. Built by a BZ5 owner after popular apps like CarScanner Pro refused to work with this car.

---

## Why this exists

The Toyota BZ5 is a relatively new EV built on the BYD platform with a 65.28 kWh blade LiFePO4 battery. The car talks to diagnostic equipment on non-standard addresses, and most generic OBD scanners simply don't see it.

This app speaks the car's native language and surfaces data that's otherwise impossible to get.

## What the app shows

### Main screen

**State of Charge (SOC)** — large, with color indication. Range estimate in kilometers is calculated against the real-world consumption of 14.4 kWh/100km.

**State of Health (SOH)** — as a percentage. New cars sit at 98-100%; this number drops over time. Shows what the dashboard keeps to itself.

**Battery temperature** — in °C. Useful in winter and summer to know when the battery is uncomfortable.

**Pack voltage** — actual voltage across all cells combined. Drops under acceleration, rises during regen — you can watch the car "breathe."

**Odometer** — accurate to 100 meters. Don't confuse with the dashboard odometer, which rounds.

**Charge cycles** — how many full-equivalent charge cycles the battery has gone through in its lifetime. Battery "mileage" beyond kilometers driven.

**Gear and parking pawl** — which gear is engaged (P/R/N/D) and whether the mechanical parking pawl is locked (more reliable than the parking brake).

### Charging

When you plug in the cable, a dedicated card appears showing:
- Current charging power in kW
- Estimated time to 100%
- How much energy has been added in this session

### Cell balance

A separate screen with the voltage of every one of the 20 battery cells. On a healthy battery, the difference between the lowest and highest cell should be:
- 20-50 mV in the mid-SOC range
- 50-100 mV at 100% (a normal LFP chemistry quirk)
- if it goes above 150 mV — diagnostics needed

The app understands the context and grades the balance as Excellent / Good / Fair / Poor.

### Trip history

Every drive is saved locally with timestamp, distance, energy used, start and end SOC. Charging sessions are **not** logged as trips.

### All ECUs

For the curious — a separate screen showing all 30 electronic control units of the car and what they expose.

---

## What you need

### Hardware

**Bluetooth ELM327 adapter.** Tested with Vgate iCar Pro BLE. Any ELM327 v2.1+ with BLE should work (BLE / Bluetooth 4.0+, **not** classic Bluetooth).

**Android phone** running Android 12 or newer. There's no iOS version (Apple Developer account required for distribution, and the author doesn't have one).

### Setup

You can grab the APK from [Releases](../../releases) or build it yourself from source.

On first launch:
1. Grant Bluetooth and Location permissions (needed for BLE scanning)
2. Sit in the car, press Start with the brake pedal → car in Ready
3. Open Settings in the app → "Find adapter"
4. Pick your ELM327 from the list
5. Done — the app will start receiving data automatically

If data isn't coming after pairing, double-check that the adapter actually plugged into the OBD port (located under the steering wheel on the left, you'll need to crouch a little).

---

## What the app does **not** do

- **It doesn't control the car.** Read-only. No "start the AC", "open the windows", or similar commands.
- **It doesn't clear error codes.** That requires a different access level and could potentially break things.
- **The UI isn't meant to be used while driving.** For safety, only check the screen while parked or charging. Background data logging while driving is fine.
- **It doesn't show speed or RPM in real time.** These signals on the BZ5 are architecturally protected — the diagnostic port is isolated from the main vehicle bus. This isn't an app bug; it's a manufacturer security measure.
- **No remote access.** Only works while you're near the car with Bluetooth on.

---

## Security and privacy

- The app **does not send any data** to any servers. Everything stays local on your phone.
- No registration, account, or login required.
- Connects only to the BLE OBD adapter. No other network connections.
- Source is open — verify it yourself.

---

## Frequently Asked Questions

**Is this safe for the car?**
Yes. The app uses only standard diagnostic queries — the same kind an official dealer service uses during diagnostics. The car retains no record of the connection after the adapter is unplugged. No traces, no changes.

**Will it work on other cars?**
Only on the Toyota BZ5 (FAW-Toyota). Parameters were reverse-engineered specifically for this model. May partially work on related BYD vehicles on the same platform, but with no guarantees.

**Why does the adapter have to be BLE and not classic Bluetooth?**
Modern Android handles BLE better for long background connections. Classic-Bluetooth ELM327 adapters also need pairing through system settings, which complicates UX.

**Does the app drain the car's battery?**
The adapter pulls roughly 50 mA from the 12V battery. Overnight that's nothing. If you leave the adapter plugged in for a week with the car off, you might drain the 12V battery. Best to unplug when not in use, or get an adapter with auto-sleep.

**How fast does data update?**
A full poll cycle is 1-2 seconds. Numbers and charts update in real time.

**What if I have questions or find a bug?**
Open an Issue in this repository.

---

## Acknowledgments

This project was built by one person over a long evening with help from an AI assistant (Claude Opus 4.7), which handled protocol analysis and code generation. Without AI it would have taken weeks. Without a real car and a "but why doesn't CarScanner work?" itch — it wouldn't exist at all.

Thanks to the EV enthusiast communities in China and Russia, whose scattered forum posts and chat snippets pointed at what to look for.

---

## License

MIT. Use, fork, modify — at your own risk.

---

<details>
<summary><strong>📡 Technical details (for developers)</strong></summary>

### Architecture

- **Flutter 3.27.4** + Dart 3, Material 3
- **flutter_blue_plus** for BLE transport
- **Drift (SQLite)** for local trip / sample / snapshot storage
- **fl_chart, provider, intl** for UI and state management

### Protocol

- **ISO 15765-4 (CAN 11-bit, 500 kbps)** — protocol 6 in ELM327
- **UDS** for diagnostic queries (`22 XX YY` for read DID)
- 30 ECUs discovered on non-standard addresses outside the 7E0-7E7 range
- Addressing rule: RX = TX + 8

### Key ECUs

| TX→RX | Name | Purpose |
|---|---|---|
| 790→798 | BMS master | SOC, SOH, temperature, cells, pack voltage, counters |
| 791→799 | VCU | Odometer, gear, power, parking pawl, VIN |
| 782→78A | OBC charger | Cable status, charger parameters |
| 757→75F | GPS (Asensing) | Coordinates (placeholder when stationary) |
| 740→748 | Pack monitor | Cached voltage snapshots |

### Key DIDs (BMS, ECU 790)

| DID | Meaning | Scale |
|---|---|---|
| 0x0005 | SOC | % |
| 0x0015 | Pack voltage | × 0.02 V |
| 0x0029 | SOH | % |
| 0x002B / 0x002D | Cell V min/max | mV |
| 0x002F | Battery temp | offset −40 °C |
| 0x016D-0x01B7 | 20 cell voltages | mV |
| 0x0B00 | Lifetime charge counter | × 460 Wh (calibrated) |
| 0x0B02 | Cycle count | unit |

### What doesn't work

- **Broadcast traffic (ATMA)** is unavailable — the diagnostic gateway is isolated from the main vehicle bus
- **Signed current** isn't exposed via UDS, has to be inferred indirectly via Power-A (VCU) / Pack Voltage
- **Real-time RPM and speed** — not accessible via diagnostics
- **DID 0x0009 on BMS** has unclear semantics, not used

### Contributing

1. Fork the repo
2. Install Flutter 3.27.4 and dependencies from `pubspec.yaml`
3. Plug in your ELM327 BLE adapter
4. `flutter run` on a real Android device (emulators won't work — real BLE required)

APK builds run via GitHub Actions — see `.github/workflows/`.

### Calibration

All physical constants live in `lib/services/connection.dart` inside the `Bz5Model` class. Calibrated against a full charge session (48% → 100%) and dashboard readings. Accuracy ±5%.

</details>
