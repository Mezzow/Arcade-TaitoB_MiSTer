# Simulation

A Verilator model of the whole core, built for checking what the core actually sends out:
sync pulses, pixel enables, blanking, pictures and the HDMI rotation framebuffer.

## What is real and what is a model

* **Real:** `emu` (`Arcade-TaitoB.sv`) and everything under it from `files.qip`, plus the
  framework's `video_mixer`, `scandoubler`, `hq2x`, `gamma_corr`, `video_freak` and
  `arcade_video` (`screen_rotate`). After `emu`, `tb_top.sv` rebuilds the analog path of
  `sys/sys_top.v` from the framework's own `sync_fix`, `scanlines` and `csync`, cut verbatim
  out of `sys_top.v` at build time - so `ana_hs/ana_vs/ana_cs/ana_de` are what reaches the
  VGA/analog connector before the pin inversion.
* **Models** (`models/`): the PLL (clk_sys = clk_sdr / 2), SDRAM at the controller's channel
  level (same request/acknowledge contract, burst-of-4 wrap and byte enables), DDR3 (memory in
  C++, 12-clock read latency, burst writes), and `hps_io` driven by the scenario through DPI -
  status word, joysticks, Direct Video, forced scandoubler, and ROM / DIP downloads the way
  Main_MiSTer makes them (an MRA with `address=` is copied into DDR3 first, then only its
  length is signalled). A core-initiated status update is applied as Main_MiSTer does.
* **Sim-only copies** of two framework files, made by `build.sh`, each changing only a
  construct Verilator rejects or mis-scopes: `hq2x.sv` (an output written procedurally) and
  `video_mixer.sv` (`R_in/G_in/B_in` declared inside a generate branch and used after it,
  which Verilator turns into 1-bit implicit nets - a black picture).

## Running

Needs msys2's UCRT64 environment (Verilator 5.x, g++, perl), Python 3 with Pillow, and the
MAME ROM zips.

```bash
C:/msys64/usr/bin/env MSYSTEM=UCRT64 /usr/bin/bash -lc 'cd <repo> && bash sim/build.sh'
python sim/tools/mra_rom.py "releases/Ryu Jin (Japan, ET910000A PCB).mra" --rompath <mame roms> --out sim/work/ryujina
cd sim/work && ../obj/Vtb_top.exe --rom ryujina.rom --dip ryujina.dip --script ../scenarios/modes.txt --out ../out/modes
```

Run from `sim/work` (the 68000 microcode files are copied there). About 1.5 s of wall time
per emulated frame. `sim/run_unit.sh` runs the ROM-free orientation truth-table test.

## Scenarios and reports

A scenario (`scenarios/*.txt`) is a list of `<frame> <command>` lines; `tb_main.cpp` lists the
commands (status bits, joystick, Direct Video, scandoubler, downloads, OSD reset, captures,
bus traces). Each `segment` starts a new section of `<out>_timing.txt`: histograms, in
CLK_VIDEO cycles, of every period and pulse width of CE_PIXEL, VGA_HS/VS, analog HS/VS/DE and
composite sync, the porches at the analog output, and active pixels per line and lines per
frame. A single short, long or missing pulse shows up as an extra histogram entry.

`shot` saves the next analog frame as a PPM; `shotpair` also saves the `screen_rotate`
buffer written during that same frame, so `tools/compare_frames.py` can check rotation and
flips pixel for pixel.

| Scenario | Checks |
|---|---|
| `baseline.txt` | power-up, ROM load, boot, OSD reset, 31 kHz scandoubler and back |
| `after.txt` | the same plus Consumer CRT Sync on/off/on |
| `flipA.txt` / `flipB.txt` | identical runs, Horizontal vs Flipped: B must be A turned 180 |
| `gridA.txt` / `gridB.txt` | the same on the boot grid screen (frame 200) |
| `modes.txt` | default orientation, every mode with its timing and framebuffer, Direct Video, OSD reset and Consumer CRT Sync in Flipped |
| `controls.txt` | the joystick word reaching the game in every mode (no ROM needed) |
