# desk firmware settings

Gigabyte B650I AORUS ULTRA, firmware F43c. A firmware update resets everything here, so this is
what to put back. The binary profiles saved from setup sit in
[`bios/`](bios/); the plan and the reasoning are in
[docs/desktop-migration.md](../../docs/desktop-migration.md) (Fan control,
BIOS tuning).

## Fans (Smart Fan 6), set 2026-09-25

Saved with F3 as [`bios/fan-profile-2026-09-25`](bios/fan-profile-2026-09-25),
load it back with F2 in Smart Fan 6. The values below are decoded from that
file, not transcribed from the screen.

| Header (it87 channel) | Curve (°C → duty) | Notes |
|---|---|---|
| CPU cooler — `fan1` | 30 → 52 %, 40 → 60 %, 50 → 64 %, 60 → 69 %, 65 → 80 %, 70 → 100 % | The firmware default, kept: already louder than the plan's curve, and the CPU is heat-limited |
| Case fan — `fan3` | ≤55 → 40 %, 63 → 48 %, 78 → 100 % | Adjusted. Its input is not the CPU (it stays at the floor while Tctl sits at 95 °C) |
| Two more headers | no curve points stored | `fan2` and `fan5` read 0 RPM: nothing plugged in |

Not recovered from the file: the Temperature Interval, the PWM/Voltage mode,
and which sensor feeds the case fan. Those need a look in setup.

### The file format ("SPF 3", 627 bytes)

Reverse-engineered from this one file, so treat anything marked "?" as a guess.

- 0–4 `SPF 3`, then an 11-byte board/firmware tag, then at 16 a u32 LE
  holding the length of the rest (619).
- From 20: one 45-byte record per header. The records at 20 and 155 hold
  curves; the ones at 65 and 110 hold none.
  - +0..+4: ? (`14 46 42 36 00` and `28 4e 4d 0d 00`). Byte +1 equals the
    curve's full-speed temperature in both records.
  - +5: `01` in every record (? mode). +6: `02` or `00` (? temperature input).
  - +7: nine points of 4 bytes: temperature °C, duty 0–255, the slope to
    the next point in duty/°C ×8 (`ff` when the step is vertical), and `00`.
    Unused points repeat the last one.

## Fan load test, 2026-09-25 after the curves

`stress-ng --cpu 12 --cpu-method matrixprod`, 60 s each, sampled every 5 s.
The fans were read with the out-of-tree `it87` loaded read-only for the test
and unloaded after it (docs/desktop-migration.md explains why it isn't in the
config). Its `pwmN` values stay fixed at 66/63/77 while the RPM moves, so
they don't show the firmware's live duty in automatic mode. RPM is the
reading to trust.

| | Idle (Eco on) | Stock, end of load | Eco on, end of load |
|---|---|---|---|
| Tctl | 54.6 °C | 95.4 °C (hit within 5 s) | 91.1 °C, still rising slowly |
| PPT | 28 W | 95–101 W | 88.0 W (the limit) |
| CPU fan (`fan1`) | 1318 RPM | 1829 RPM (full speed by 10 s) | 1829 RPM |
| Case fan (`fan3`) | 3534 RPM | ~3600 RPM | ~3650 RPM |
| DIMMs | 46.5 / 47.8 °C | 46.8 / 47.8 °C | 47.8 / 48.5 °C |

- **The loud fan was fan3.** It ran at ~7400 RPM on 2026-09-24 and now idles
  at ~3500 on its 40 % floor.
- **The CPU fan steps, it doesn't hunt.** It reaches full speed about 10 s
  into load and holds it for about 10 s after, then falls back to its idle
  speed over about 30 s. It doesn't oscillate.
- **Load temperatures barely moved.** Before the fan changes: 95.4 °C at
  94.4 W stock, 90 °C at 88 W Eco. The CPU fan's default curve was already at
  full speed under load, so no curve can do better. Stock now sustains a few
  watts more at the same 95 °C ceiling. What's left to improve is the cooler
  itself (or Curve Optimizer), not the curves.
- **DIMMs:** under 49 °C throughout, well inside 55 °C. A CPU-only load
  doesn't stress them; the GPU's exhaust is what matters, so the hot run in
  BIOS tuning still has to check them.
