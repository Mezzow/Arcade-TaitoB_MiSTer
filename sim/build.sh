#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the whole-core Verilator model: sim/obj/Vtb_top(.exe)
#
#   C:/msys64/usr/bin/env MSYSTEM=UCRT64 /usr/bin/bash -lc 'cd <repo> && bash sim/build.sh'
#   (msys2's UCRT64 environment: Verilator 5.x, g++, perl)
#
# Uses the production RTL list (files.qip) and sys/ video modules unchanged; the board
# (PLL, SDRAM, HPS, DDR3) comes from sim/models. The analog-path modules sync_fix and
# csync are cut verbatim out of sys/sys_top.v so the model cannot drift from them.
set -e
cd "$(dirname "$0")/.."
mkdir -p sim/obj sim/work sim/out

echo '`define BUILD_DATE "000000"' > sim/work/build_id.v
cp rtl/fx68k/hdl/microrom.mem rtl/fx68k/hdl/nanorom.mem sim/work/
# Verilator rejects one framework construct (a procedural assign to an output declared
# without `reg` in hq2x.sv's Blend module); compile a copy with only that changed.
sed 's/^\(\s*\)output \[23:0\] Result/\1output reg [23:0] Result/' sys/hq2x.sv > sim/work/hq2x.sv
python sim/tools/patch_video_mixer.py sys/video_mixer.sv sim/work/video_mixer.sv
sed -n '/^module sync_fix/,/^endmodule/p; /^module csync/,/^endmodule/p' sys/sys_top.v > sim/work/sys_sync.v

RTL="
rtl/system_consts.sv rtl/ddram.sv rtl/savestates.sv
Arcade-TaitoB.sv
rtl/fx68k/hdl/fx68k.sv rtl/fx68k/hdl/fx68kAlu.sv rtl/fx68k/hdl/uaddrPla.sv
rtl/pause.sv rtl/ddram.sv rtl/system_consts.sv rtl/ram.sv rtl/rom_loader.sv rtl/rom_cache.sv
rtl/mame_keys.sv rtl/coin_pulse.sv rtl/video_path.sv rtl/taitob_orientation.sv rtl/audio_mix.sv
rtl/savestates.sv rtl/memory_stream.sv rtl/jtframe_frac_cen.v rtl/jtframe_resync.v
rtl/TaitoB.sv rtl/taitob_board_config.sv rtl/taitob_sound.sv rtl/tc0180vcu.sv rtl/tc0180vcu_fb.sv
rtl/taitob_video_timing.sv rtl/tc0640fio.sv rtl/eeprom_93c46.sv rtl/mb87078.sv
rtl/tc0140syt.sv rtl/tc0260dar.sv rtl/tc0220ioc.sv
rtl/tv80_auto_ss.sv rtl/jt10_auto_ss.sv
rtl/jt6295/hdl/jt6295.v rtl/jt6295/hdl/jt6295_timing.v rtl/jt6295/hdl/jt6295_rom.v
rtl/jt6295/hdl/jt6295_ctrl.v rtl/jt6295/hdl/jt6295_adpcm.v rtl/jt6295/hdl/jt6295_serial.v
rtl/jt6295/hdl/jt6295_acc.v rtl/jt6295/hdl/jt6295_sh_rst.v
sys/math.sv sim/work/hq2x.sv sys/scandoubler.v sys/scanlines.v sys/gamma_corr.sv sim/work/video_mixer.sv
sys/arcade_video.v sys/iir_filter.v
sim/models/pll.v sim/models/sdram.sv sim/models/hps_io.sv sim/models/ddr3.sv
sim/work/sys_sync.v sim/tb_top.sv
"

verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast --no-assert \
    --top-module tb_top -Mdir sim/obj -o Vtb_top \
    -DMISTER_FB=1 -DUSE_AUTO_SS=1 -DSIMULATION \
    -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
    -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-PINMISSING -Wno-IMPLICIT \
    -Wno-SELRANGE -Wno-COMBDLY -Wno-LATCH -Wno-INITIALDLY -Wno-ASSIGNIN \
    +incdir+sim/work +incdir+sys +incdir+rtl +incdir+rtl/fx68k/hdl +incdir+rtl/jt12/hdl +incdir+rtl/tv80 \
    -CFLAGS "-O2 -std=c++17" \
    $RTL sim/tb_main.cpp
echo built sim/obj/Vtb_top
