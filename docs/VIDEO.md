# Video output, CRT sync and orientation

## Native raster

The core produces one raster, always, from the moment the FPGA is configured. It never
waits for the ROM, the game's reset or anything else, and nothing changes its timing.

| | Value | Source |
|---|---|---|
| Pixel clock | clk_sys / 8 = 54.328 / 8 = 6.791 MHz, every pixel exactly 8 clocks | 27.164 MHz XTAL / 4 (MAME) |
| Line | 440 pixels + 17 idle clocks = 3537 clocks = 65.10 us = **15.360 kHz** | the MiSTer Ryu Jin core |
| Frame | 256 lines = **60.000 Hz**, progressive | the MiSTer Ryu Jin core; MAME's rate |
| Active | 320 x 224, bitmap lines 16..239 | MAME visarea |
| HSync | 32 dots (4.71 us), dots 344..375 - 24 dots after the last active one | the MiSTer Ryu Jin core |
| VSync | 3 lines, lines 244..246, starting on an HSync leading edge | the MiSTer Ryu Jin core |

### Matching the MiSTer Ryu Jin core

The video output is built the way the separate MiSTer Ryu Jin core (MiSTer_Ryu_Jin), which
runs the same Taito B hardware, builds it, end to end: a standard 15 kHz raster and the
framework's standard hand-off, for any 15 kHz CRT on any analog output, and for HDMI.
Verified on a consumer CRT (JVC D-series) over component and RGB, and over HDMI:

* the same raster: 15.360 kHz lines, 256 lines, 60.000 Hz, HSync 24 dots after the picture
  and 32 wide, VSync lines 244..246. That core makes a 65.10 us line from 446 dots of 14
  clocks plus 6 idle clocks of 96 MHz; this one from 440 dots of 8 clocks plus 17 idle
  clocks of 54.328 MHz. Pixels stay exactly 8 clocks; the idle clocks sit at the end of
  horizontal blanking, as in that core;
* the same hand-off: the raster goes straight into the framework's `arcade_video` (24-bit),
  which puts VSync on an HSync edge, with RGB forced to black outside the active area and
  `screen_rotate` after it - no `video_freak` and, at the default H/V position, no
  `jtframe_resync` (see `rtl/video_path.sv`).

The core's earlier raster (448 x 253, 15.158 kHz / 59.915 Hz) was a judgement call, not a
measurement: MAME 0.289 only says 60.000 Hz (`set_refresh_hz(60)`), and Guru's PCB
measurement in the driver (HSync 15.1782 kHz, VSync 60.000 Hz) implies 252.97 lines and a
non-integer 447.4-pixel line at this dot clock. The current raster keeps MAME's and the PCB's
60 Hz exactly (game speed +0.14 % against the earlier raster) and, like the Ryu Jin core,
uses 256 lines.

## Consumer CRT Sync (OSD, Video Settings)

| | On (default) | Off (the original timing) |
|---|---|---|
| HSync | 32 px = **4.71 us** | 64 px = 9.42 us |
| H back porch (HSync end to active) | 553 clocks = 10.2 us | 297 clocks = 5.5 us |
| H front porch | 21 px = 3.1 us | 21 px = 3.1 us |
| VSync, line rate, frame rate, pixel clock | unchanged | unchanged |

The HSync leading edge does not move. The choice is applied at the frame boundary.

The core used to carry this menu item without wiring it to anything; it now selects the
HSync width. On is EIA-170's 4.7 us and the Ryu Jin core's pulse; Off is the core's original
64-pixel pulse, kept for comparison.

## Power-up and loading

Every MRA load reconfigures the FPGA (Main_MiSTer `xml_load` -> `fpga_load_rbf`), so the
first thing a CRT sees from this core is its power-up raster, under Main_MiSTer's loading
screen. The raster counters free-run from configuration and are not reset by the ROM load,
the game reset or the OSD reset, so the line and frame periods are exact throughout.

One defect was found at power-up: `jtframe_resync` starts with zeroed measurements, turns a
zero pulse length into a hold count of 1023, and emitted a 1023-pixel HSync and a VSync held
high for about three frames. `rtl/video_path.sv` now passes the raw pulses (one pixel late,
the resync path's own phase) for the first eight frames and then hands over without a seam.

## Orientation (OSD, top level)

| OSD | Analog / native / Direct Video | HDMI scaler | Aspect reported | Controls |
|---|---|---|---|---|
| Horizontal | H | H | 4:3 | game's own |
| Vertical CCW | H | H turned 90 deg counter-clockwise | 3:4 | game's own |
| Vertical CW | H | H turned 90 deg clockwise | 3:4 | game's own |
| Flipped | H turned 180 deg | H turned 180 deg | 4:3 | game's own |

* **H** is the raster as the board emits it.
* **CW / CCW** describe the picture as the viewer sees it: Vertical CW moves the top edge of
  H to the right-hand side, Vertical CCW moves it to the left.
* **Flipped** is made inside the TC0180VCU's own flip path (the one the game's flip bit and
  Flip Screen DIPs use, verified on Rambo III): the visible window is mirrored on both axes,
  every layer and the sprite framebuffer together, on the unchanged native raster. It is the
  game's flip bit inverted, so on a game that flips itself it gives back the upright picture.
  Per-block scroll is mirrored with the rows (as MAME mirrors its scroll blocks), so a game
  with several scroll bands is turned whole. Making Flipped exact also fixed a bug in that
  path: the sprite framebuffer erased a line only while the raster was visible, but flipped,
  line 239 is shown from raster 15 (in vblank), so it was never erased and old sprite pixels
  piled up on the first line of every flipped picture - Rambo III and Flip Screen DIPs too.
* **CW / CCW** exist only in the framework's `screen_rotate` framebuffer on HDMI. A 90-degree
  turn cannot be made on a 15 kHz raster without changing its timing, so the analog output
  keeps H, which is what a physically rotated CRT wants.
* **Direct Video** bypasses `screen_rotate`: HDMI then carries the native raster in every mode
  (H, or H turned 180 in Flipped), and the DV1 InfoFrame's "rotated" bit stays clear.
* Controls follow the game in every mode; nothing is re-mapped and coin, start, service and
  action buttons are never touched. Each mode exists to show the game upright to the viewer,
  and then the game's up is the viewer's up (the Namco cores reached the same rule).
* Mode changes take effect at the start of vertical blank: `screen_rotate` is switched there,
  and the VCU latches Flipped at line 240, so no frame is half one way.

### Default

The second byte of each MRA's board record is the set's MAME orientation (0 = ROT0,
3 = ROT270). After the ROM load the core proposes the mode that stands the set upright on a
horizontal HDMI screen - **Vertical CCW** for Ashura Blaster, Master of Weapon, Ryu Jin and
Yukiwo (MAME ROT270), **Horizontal** for everything else - unless the set's saved settings
already hold a choice. Main_MiSTer keeps a CFG per MRA `<setname>`; *Save settings* stores the
choice (with status bit 42) and the default is not applied over it again. None of the defaults
changes the analog raster.

The ROT270 MRAs also say `<rotation>vertical (ccw)</rotation>`, MiSTer's convention for
ROT270 (Galaga, Xevious and Dig Dug, all ROT90, say `vertical (cw)`). Main_MiSTer uses it to
rotate the OSD on a rotated CRT (`osd_rotate=3`) and in the DV1 InfoFrame. It used to say
plain `vertical`, which Main_MiSTer reads as CW.

## Verification

`sim/` holds a Verilator bench of the whole core (real `emu`, real `sys/` video modules, the
framework's `sync_fix`/`scanlines`/`csync` analog path cut from `sys/sys_top.v`), with models
for the PLL, SDRAM, DDR3 and HPS. Its monitor histograms every period and width of what
leaves the core and the analog stage - CE_PIXEL, VGA_HS/VS/DE, analog HS/VS/DE and composite
sync - per scenario segment, so a single short or missing pulse shows. See `sim/README.md`.

### Results (Ryu Jin, the only Taito B set available to the bench)

| Check | Result |
|---|---|
| Power-up, ROM download, game reset, OSD reset, every orientation, every mode change, Consumer CRT Sync toggles | every analog HS period 3537 clk, every VS period 905472 clk, CE every 8 clk plus one 25-clk gap per line in blanking; VSync on an HSync edge; no short, long or missing pulse |
| Ryu-Jin-matched raster against the earlier 448 x 253 | every captured frame pixel-identical (Horizontal, Flipped, CW, CCW) |
| Original core at power-up | VSync held high ~3 frames, 6880/8224-clock HSync pulses |
| Flipped vs Horizontal, identical runs, three attract frames | 180-degree rotation exact: 0 of 40,076-44,918 lit pixels differ; sync timing byte-identical |
| Vertical CCW / CW framebuffer vs the native frame | exact 90-degree rotations, 0 pixels differ; 224 x 320, aspect 3:4; CCW matches MAME's upright ROT270 picture |
| Direct Video in CW and Flipped | no framebuffer (FB_EN low), video_rotated 0, native raster |
| Default orientation | Ryu Jin (ROT270) comes up Vertical CCW with status bit 42 set |
| Controls | the game receives the MiSTer joystick word unchanged in every mode |
| Consumer CRT (JVC D-series), component and RGB | correct picture and black level; loading screen, title and gameplay (hardware) |
| HDMI | correct (hardware) |
| Scandoubler (31 kHz) | CE 4 clk; HS 1768/1769 clk alternating (the 3537-clock line is odd), 448 lines |

No Puzzle Bobble or other horizontal ROM set was available, so the horizontal class is
covered by Ryu Jin's raw (Horizontal) raster and the hardware test.
