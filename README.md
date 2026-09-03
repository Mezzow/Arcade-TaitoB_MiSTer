# Taito B System core for MiSTer (Arcade-TaitoB)

An FPGA implementation of Taito's **B System** arcade hardware for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: 68000 and Z80 CPUs, the
YM2610/YM2610B or YM2203 + M6295 sound sections, Taito's I/O chips, the 93C46 EEPROM, the MB87078
volume control, and the **TC0180VCU** video chip with its three tilemaps, 408-sprite framebuffer
engine and compositor.

> ## Please read first: this is a "slopcore"
>
> **Every line of Taito B specific logic in this repository was written by an AI coding assistant**
> (Anthropic's Claude), working from MAME's source under human direction. None of it was
> hand-written by a hardware engineer.
>
> The core has been checked against MAME reference frames in simulation and runs the games listed
> below on real MiSTer hardware, but **it makes no claim of cycle accuracy** and no claim to
> reproduce the TC0180VCU silicon. Where the real chip is undocumented the core does what MAME
> does, and where MAME's own comments say "guess", so does this.
>
> **All credit belongs to the original creators listed below.** This project only exists because
> of the upstream Taito F2 core it was adapted from, the CPU and sound cores it reuses, the MiSTer
> framework, and the MAME team whose driver is the only public documentation of this hardware.
> Use at your own risk and expect bugs.

## Credits

This core is a fork of **[Arcade-TaitoF2_MiSTer](https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer)**
by **Martin Donlon (wickerwaka)** and contributors, taken at commit `9438df9`. The 68000, Z80,
YM2610, TC0140SYT, TC0260DAR and TC0220IOC infrastructure, the top level, the SDRAM and DDR
plumbing and the ROM loader are that project's work. The Taito B additions replace the F2 video
chain (TC0100SCN + TC0200OBJ + TC0360PRI) with the TC0180VCU and add the remaining Taito B board
variants.

| Component | Author | Licence | Path |
|---|---|---|---|
| Arcade-TaitoF2_MiSTer (upstream core) | Martin Donlon (wickerwaka) and contributors | GPL-2.0 | top level, `rtl/`, `sys/` |
| **fx68k** cycle-exact 68000 | Jorge Cwik (ijor) | GPL-3.0 | `rtl/fx68k/` |
| **tv80** Z80 | Guy Hutchison (hutch31) | MIT | `rtl/tv80/` |
| **jt12 / jt10** YM2610 (OPNB) with ADPCM-A/B, also configured as the YM2203 | Jose Tejada (jotego) | GPL-3.0 | `rtl/jt12/` |
| **jt6295** OKI MSM6295 ADPCM | Jose Tejada (jotego) | GPL-3.0 | `rtl/jt6295/` |
| **jtframe** fragments (`jtframe_frac_cen`, `jtframe_resync`) | Jose Tejada (jotego) | GPL-3.0 | `rtl/` |
| `pause.sv` | Jim Gregory | GPL-3.0 | `rtl/` |
| `sdram.sv` | Sorgelig | GPL-3.0 | `rtl/` |
| MiSTer framework | Sorgelig and the MiSTer-devel project | GPL-2.0 / GPL-3.0 / LGPL | `sys/` |
| PLL and megafunction wrappers | Intel | Intel FPGA licence | `rtl/pll.v`, `sys/pll_*` |

Hardware knowledge came from:

- **MAME** (`src/mame/taito/taito_b.cpp`, `taito_b_v.cpp`, `tc0180vcu.cpp`, `taitoio.cpp`,
  `src/mame/shared/taitosnd.cpp`) by Jarek Burczynski, Nicola Salmoria and the MAME team. There
  is no public Taito B manual, schematic or die shot; MAME is the authority for everything here.
- **FinalBurn Neo** (`d_taitob.cpp`, `taito_ic.cpp`) as an independent cross-check.
- **system16.com** for the board-level specification, and the PCB measurements quoted by Guru in
  the MAME driver.
- The games themselves are the work of **Taito Corporation**. No ROM data is distributed with
  this project.

**Local change to jt12.** `rtl/jt12/hdl/jt10_acc.v`, `jt12_top.v` and `jt10.v` (and the generated
`rtl/jt10_auto_ss.sv` that the build compiles) carry one modification: a `ym2610b` input. The
YM2610 has four FM channels because two of its six accumulator slots carry the ADPCM streams; the
YM2610B has all six FM channels *and* both ADPCM streams, so in that mode the slots sum both.
Without it two of Puzzle Bobble's six FM channels are silent. The change is offered under jt12's
GPL-3.0.

## Supported games

| Game | Set | Board | State |
|---|---|---|---|
| Ashura Blaster | `ashura` | TC0220IOC, YM2610 | plays on hardware |
| Crime City | `crimec` | TC0220IOC, YM2610 | plays on hardware |
| Hit the Ice | `hitice` | TC0220IOC, PC060HA, YM2203 + M6295 | plays on hardware |
| Master of Weapon | `masterw` | TC0040IOC, PC060HA, YM2203 | plays on hardware; a few stray pixels against MAME |
| Nastar | `nastar` | TC0220IOC, YM2610 | plays on hardware |
| Puzzle Bobble | `pbobble` | TC0640FIO, 93C46, YM2610B | plays on hardware; screenshots pixel-identical to MAME |
| Rambo III | `rambo3` | TC0220IOC, YM2610B | plays on hardware; screen flip verified |
| Rastan Saga 2 | `rastsag2` | TC0220IOC, YM2610 | plays on hardware |
| Real Puncher | `realpunc` | TC0510NIO, YM2610B, HD63484 status | plays on hardware |
| Ryu Jin | `ryujin` | TC0220IOC, YM2610 | plays on hardware |
| Sel Feena | `selfeena` | TC0220IOC, YM2610 | plays on hardware |
| Silent Dragon | `silentd` | TC0220IOC, YM2610B | plays on hardware |
| Sonic Blast Man | `sbm` | TC0510NIO, YM2610, photosensor inputs | plays on hardware |
| Space Invaders DX | `spacedx` | TC0640FIO, 93C46, YM2610 | plays on hardware |
| Tetris (Nastar conversion kit) | `tetrist` | TC0220IOC, CPU-drawn framebuffer | plays on hardware; pixel-exact in simulation |
| Violence Fight | `viofight` | TC0220IOC, PC060HA, YM2203 + M6295 | plays on hardware |

The core's board table covers all 18 machine configurations in MAME's `taito_b.cpp` driver.
`releases/` carries **39 MRAs** - every set in the driver for which a romset exists, except
`hiticej`, which is the only one that switches on Hit the Ice's CPU-drawn pixel layer and is
therefore deliberately omitted. The 16 sets listed above are the ones checked frame-by-frame
against MAME; the other 23 are clones and regional variants, booted to attract mode on
hardware but not put through the golden-frame gate.

## Installation

1. Copy `releases/Arcade-TaitoB_<date>.rbf` to `_Arcade/cores/` on the MiSTer SD card.
2. Copy the `.mra` files from `releases/` to `_Arcade/`.
3. Put the ROMs in `games/mame/`: one zip per game, named after the `<setname>` in the MRA (for
   example `pbobble.zip`). The MRAs describe the MAME 0.277 ROM sets.

## Controls and options

- Buttons are mapped per game by the MRA and labelled in the MiSTer button-definition menu.
- DIP switches come from each MRA's `<switches>` block. Puzzle Bobble and Space Invaders DX have
  no DIP switches; they keep their settings in the 93C46 EEPROM, which the core saves through the
  MiSTer framework (`Save EEPROM` in the OSD).
- OSD: aspect ratio, scandoubler effects, scaling, orientation, analog H/V position, consumer-CRT
  sync; rotary input mode (joystick, paddle, spinner, D-pad) with sensitivity and invert; OSD
  pause with optional dimming; service mode; reset.

## Known limitations

- Save states are not implemented.
- No high-score saving beyond what the 93C46 boards store themselves.
- Sprites are drawn one frame behind the tilemaps. The chip's two framebuffer pages imply this is
  what the real hardware does, but MAME draws sprites in one shot at vblank, so single frames of
  busy sprite screens differ from MAME by one frame of sprite motion.
- Sprite zoom follows the geometry MAME computes, which MAME's own comments describe as
  inaccurate. Games that use it at 1:1 (most of them) are unaffected.
- Audio levels on the YM2610 boards were matched against MAME in simulation only to within
  roughly 10 dB. The YM2203 and M6295 boards were checked for correct register traffic but not
  level-matched.
- Hit the Ice's CPU-drawn pixel layer is not implemented.
- Small residual differences against MAME: a few isolated pixels on Master of Weapon, and a
  palette animation one step out of phase on one text row in Violence Fight and Hit the Ice.

## Building

Quartus Prime Lite 17.0.x, from the repository root:

```
quartus_sh --flow compile Arcade-TaitoB
```

`sys/build_id.tcl` runs as a pre-flow step and generates `build_id.v`. The bitstream is written
to `output_files/Arcade-TaitoB.rbf`.

## How it was verified

- A Verilator bench runs each game's ROMs through the whole core and compares its frames, at
  fixed frame numbers, against MAME captures of the same frames. All 16 sets passed this gate;
  several are pixel-exact.
- A second bench drives the TC0180VCU with synthetic graphics data and compares every visible
  pixel against a C++ model of the chip: tile addressing, plane order, flips, scroll, sprite
  chaining, layer priority and the palette DAC.
- The board table, memory maps and DIP switches were extracted mechanically from MAME's driver
  and cross-checked against it. Every MRA's ROM stream is verified byte-for-byte against the
  image the bench runs.
- All 16 games were booted, coined and played on a MiSTer. Puzzle Bobble screenshots taken from
  the device are pixel-identical to MAME frames. The 23 further sets were booted to attract mode
  on the device as well.

The verification harness is not part of this repository.

## Licence

This project's own code is licensed GPL-2.0-or-later, inherited from the upstream core; see
`LICENSE`. The bundled third-party components keep their own licences as listed under Credits.
Because several of them (fx68k, jt12, jt6295, `pause.sv`, `sdram.sv`) are GPL-3.0, the combined
work is effectively subject to GPL-3.0.
