# 3-Key Bluetooth Macro Pad — Build Guide

## Core design decisions

**Controller: nice!nano v2** — Pro Micro footprint board with an nRF52840 chip, native Bluetooth LE, and built-in LiPo charging over USB-C. Runs ZMK firmware.

**Switches: Kailh Choc v1 (low-profile)** — Standard for slim builds. Only 8mm total travel height vs ~18mm for MX switches. Options: Choc White (clicky), Choc Brown (tactile), Choc Pink (linear, 20gf), or Choc Red Pro (linear, 35gf). The linears give the best "thock" on a macro pad.

**Keycaps: MBK or Choc-compatible blanks** — MBK profile is the sleekest low-profile option. Blanks can be customized later via UV printing, laser engraving, or vinyl/rub-on transfers for prototyping.

**Battery: 301230 or 401230 LiPo cell** — Small, flat, fits under the PCB or beside the controller. ~100–150mAh is plenty for a 3-key pad.

---

## Bill of materials

| Component | Part | Approx Cost |
|---|---|---|
| Controller | nice!nano v2 | $25 |
| Switches (x3) | Kailh Choc v1 (your choice of color) | $2–3 |
| Keycaps (x3) | MBK Choc blanks | $3–5 |
| Battery | 3.7V LiPo 110mAh (301230) | $3–5 |
| Hotswap sockets (x3) | Kailh Choc hotswap sockets | $1–2 |
| Power switch | MSK-12C02 SPDT slide switch | $0.50 |
| Reset switch | TC-1212T 3×6mm tactile momentary | $0.50 |
| Wire | 28–30 AWG silicone wire | $3 |
| Case | 3D printed | ~$1 filament |
| **Total** | | **~$40–45** |

---

## Wiring scheme

Since it's only 3 keys, you can skip a matrix and wire directly — each switch gets one pin to a nice!nano GPIO and the other to ground.

```
Switch 1 ───── Pin D4
Switch 2 ───── Pin D5
Switch 3 ───── Pin D6
     (all sharing common GND)

Battery + ──── Slide switch ──── B+ pad on nice!nano
Battery − ──── B− pad on nice!nano
```

The slide switch sits between battery positive and the B+ pad, allowing you to fully cut power when not in use.

---

## Case design

**Target dimensions:** ~65 × 43 × 10mm (compact two-piece snap-together design held by 4× M2 screws).

**Bottom shell** includes dedicated pockets for the nice!nano (centered) and LiPo battery (to its left), a USB-C port cutout on the back wall aligned with the nice!nano's port, and a slide switch pocket on the left side wall.

**Top plate** is a 1.6mm plate with three Choc v1 switch cutouts (13.8 × 13.8mm each) at standard 19mm spacing, plus small side notches for switch clip retention tabs.

### 3D printing tips

- Print the top plate **face-down** so switch cutout edges come out crisp.
- Bottom shell prints right-side-up, no supports needed.
- Use **0.12–0.16mm layer height** for a smooth finish.
- PLA works fine for prototyping; white resin + sanding for a polished look.
- Use 4× M2×8mm screws to hold the halves together.

### Expect to tweak after a test print

- USB-C port alignment (measure your specific nice!nano)
- Battery pocket depth if your LiPo is slightly different
- Slide switch pocket dimensions once you have the actual MSK-12C02
- Add a few tenths of mm tolerance to switch cutouts if your printer runs tight

---

## Firmware (ZMK)

ZMK is the firmware for the nice!nano. Setup involves creating a `macropad.keymap` file that maps each of the 3 keys to whatever you want — keyboard shortcuts, media controls, macros, or multi-key combos.

### Setup steps

1. Follow the ZMK docs to create a new "shield" (their term for a keyboard definition).
2. Define your keymap — for example, mapping keys to `Cmd+1`, `Cmd+2`, `Cmd+3`.
3. Build the firmware through GitHub Actions.
4. Flash the resulting `.uf2` file by double-tapping the nice!nano's reset button.

The nice!nano will appear as a USB drive when in bootloader mode — just drag the `.uf2` file onto it.