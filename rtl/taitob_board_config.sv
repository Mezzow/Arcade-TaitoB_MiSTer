// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// Per-game board configuration for the Taito B system.
//
// One case arm per MAME machine config. Every value here was extracted directly from
// src/mame/taito/taito_b.cpp (machine-config functions and GAME() lines); the romset ->
// config mapping is carried by the MRA's board-config byte.
//
// Nothing about a specific game belongs anywhere else in the core. In particular the
// INTH/INTL -> 68000 IRQ level mapping is done by an external PAL on the real boards and
// varies from 6/1 to 2/3 across the driver, so it must never be hardcoded in the VCU or
// the CPU glue.

import system_consts::*;

module taitob_board_config(
    input clk,
    input game_t game,

    // Interrupts: which 68000 IRQ level each TC0180VCU output drives.
    output reg  [2:0] cfg_irq_inth,
    output reg  [2:0] cfg_irq_intl,

    // Chip population
    output reg  [1:0] cfg_io_chip,   // IO_NONE / IO_TC0220IOC / IO_TC0640FIO / IO_TC0510NIO
    output reg        cfg_eeprom,     // 93C46 present (implies no DIP switches)
    output reg        cfg_mb87078,    // electronic volume present
    output reg        cfg_syt,        // 1 = TC0140SYT, 0 = PC060HA
    output reg        cfg_ym2610b,    // 6-channel FM output instead of 4
    output reg        cfg_ym2203,     // YM2203 instead of the YM2610 family
    output reg        cfg_m6295,      // OKI M6295 present

    // Video
    output reg        cfg_bpp15,      // 1 = RRRRGGGGBBBBRGBx, 0 = RGBx_444
    output reg  [7:0] cfg_cb_fb,      // TC0180VCU colour bases
    output reg  [7:0] cfg_cb_bg,
    output reg  [7:0] cfg_cb_fg,
    output reg  [7:0] cfg_cb_tx,

    // Clocking
    output reg        cfg_cpu_16mhz,  // qzshowby runs its 68000 at 16 MHz, not 12
    output reg        cfg_z80_6mhz,   // masterw / hitice / viofight / realpunc

    // 68000 address map. Every Taito B game puts the same handful of blocks at DIFFERENT
    // addresses - the VCU alone lives at 0x200000 (selfeena), 0x400000 (most), 0x500000
    // (silentd) or 0x900000 (sbm) - so the decode cannot be hardcoded the way it was for
    // pbobble. Each of these is A[23:16] of the block's base; the VCU window is 512 KiB so
    // only A[23:19] of cfg_a_vcu is compared.
    output reg  [7:0] cfg_a_vcu,
    output reg  [7:0] cfg_a_io,      // 16 bytes
    output reg  [7:0] cfg_a_syt,     // 4 bytes, TC0140SYT master port
    output reg  [7:0] cfg_a_pal,     // 8 KiB
    output reg  [7:0] cfg_a_wram,    // up to 64 KiB
    output reg  [7:0] cfg_a_mb,      // MB87078, EEPROM boards only
    output reg        cfg_io_lowbyte,// silentd reads the I/O chip on D7-D0, not D15-D8
    // sbm and realpunc reach the I/O chip through halfword_wordswap_r/w, which MAME
    // implements as halfword_r(offset ^ 1) - the REGISTER INDEX is swapped, not the byte
    // lane. Without it a game reads register 6 where it means register 7, and register 6
    // is undriven, so the port comes back 0xFF: every active-low input looks idle and
    // every active-high one looks pressed.
    output reg        cfg_io_indexed,  // masterw, tetrista: TC0040IOC, index latch + data
    output reg        cfg_p34_word,    // hitice: players 3 and 4 as one word at io_base+0x10000
    // A[15:12] of the sound mailbox. Zero on every board but realpunc, which is the only one
    // that puts the mailbox on the SAME 64 KiB page as its I/O chip: TC0510NIO at 180000,
    // video control at 184000, mailbox at 188000, an output latch at 18C000. Decoding the
    // mailbox by page alone there selects it for every I/O access as well, so an input read
    // also writes the sound port.
    output reg  [3:0] cfg_a_syt_sub,
    // Page of the HD63484 ACRTC. realpunc only; 0 means the board has none.
    output reg  [7:0] cfg_a_acrtc,
    output reg        cfg_io_wordswap,
    output reg        cfg_rom_1mb,   // qzshowby / realpunc have a 1 MiB program ROM
    output reg  [2:0] cfg_io_layout, // IOL_FIO / IOL_IOC_A / IOL_IOC_B / IOL_SBM / IOL_RPUNC
    output reg        cfg_coin_hi    // coin inputs are ACTIVE HIGH on this board
);

// Packed config word, mirroring the upstream F2 core's idiom: one literal per game keeps
// the table readable as a table and lets the synthesiser build a single ROM.
// Field order matches the concatenation at the bottom of the block: 2 + 9 = 11 bits.
always_comb begin
    bit [10:0] c;

    case (game)
        //                     io    ee mb syt 2610b 2203 6295 bpp15 cpu16 z80_6
        GAME_RASTSAG2: c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
        GAME_MASTERW:  c = { IO_NONE,      1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1 };
        GAME_ASHURA:   c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
        GAME_CRIMEC:   c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
        GAME_HITICE:   c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1 };
        GAME_RAMBO3P:  c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
        GAME_RAMBO3:   c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
        GAME_PBOBBLE:  c = { IO_TC0640FIO, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0 };
        GAME_SPACEDX:  c = { IO_TC0640FIO, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0 };
        GAME_SPACEDXO: c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0 };
        GAME_QZSHOWBY: c = { IO_TC0640FIO, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0 };
        // PC060HA + YM2203 + M6295, the same combination as masterw and hitice.
        GAME_VIOFIGHT: c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1 };
        GAME_SELFEENA: c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0 };
        GAME_SILENTD:  c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0 };
        GAME_SBM:      c = { IO_TC0510NIO, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
        GAME_REALPUNC: c = { IO_TC0510NIO, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1 };
        GAME_TETRIST:  c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0 };
        GAME_TETRISTA: c = { IO_NONE,      1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1 };
        default:       c = { IO_TC0220IOC, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
    endcase

    { cfg_io_chip, cfg_eeprom, cfg_mb87078, cfg_syt,
      cfg_ym2610b, cfg_ym2203, cfg_m6295, cfg_bpp15,
      cfg_cpu_16mhz, cfg_z80_6mhz } = c;
end

// Interrupt levels. Set by an external PAL per board; from MAME's taito_b.cpp.
always_comb begin
    case (game)
        GAME_RASTSAG2, GAME_TETRIST:  begin cfg_irq_inth = 3'd4; cfg_irq_intl = 3'd2; end
        GAME_MASTERW,  GAME_TETRISTA: begin cfg_irq_inth = 3'd5; cfg_irq_intl = 3'd4; end
        GAME_ASHURA:                  begin cfg_irq_inth = 3'd4; cfg_irq_intl = 3'd2; end
        GAME_CRIMEC:                  begin cfg_irq_inth = 3'd5; cfg_irq_intl = 3'd3; end
        GAME_HITICE:                  begin cfg_irq_inth = 3'd4; cfg_irq_intl = 3'd6; end
        GAME_RAMBO3P, GAME_RAMBO3:    begin cfg_irq_inth = 3'd6; cfg_irq_intl = 3'd1; end
        GAME_PBOBBLE, GAME_SPACEDX,
        GAME_QZSHOWBY:                begin cfg_irq_inth = 3'd3; cfg_irq_intl = 3'd5; end
        GAME_SPACEDXO, GAME_SELFEENA,
        GAME_SILENTD:                 begin cfg_irq_inth = 3'd6; cfg_irq_intl = 3'd4; end
        GAME_VIOFIGHT:                begin cfg_irq_inth = 3'd4; cfg_irq_intl = 3'd1; end
        GAME_SBM:                     begin cfg_irq_inth = 3'd4; cfg_irq_intl = 3'd5; end
        GAME_REALPUNC:                begin cfg_irq_inth = 3'd2; cfg_irq_intl = 3'd3; end
        default:                      begin cfg_irq_inth = 3'd4; cfg_irq_intl = 3'd2; end
    endcase
end

// The graphics-region mask is NOT a table here any more.
//
// MAME hands a tile code to tileinfo.set(), which reduces it modulo the number of elements
// in the graphics region, so a code past the end of the ROM WRAPS. Taito relied on that:
// crimec's pavement is drawn with codes 0x2349-0x2350 out of a region holding only 8192
// tiles, and they wrap to 0x0349-0x0350, continuing the wall's own tile run. Without the
// wrap those fetches land past the end of the region and the whole bottom of the screen is
// missing - which is exactly what it did.
//
// The size is a per-SET fact, and this table is keyed by board_t, which several sets SHARE.
// ryujin declares a 2 MiB region and runs as the silentd board, which declares 4 MiB, so it
// inherited a mask twice its own size and codes from 0x4000 up read past the end of its
// graphics instead of wrapping. Nothing in its attract sequence used one, so every captured
// reference frame passed.
//
// The ROM image already carries each region's size in its own header, so rtl/rom_loader.sv
// latches region 1's and rtl/TaitoB.sv masks with size-1. That is per-set by construction
// and cannot be wrong for an aliased set.


// TC0180VCU colour bases. set_fb_colorbase() multiplies by 16 inside the MAME device, so
// cfg_cb_fb is the raw driver value and the VCU applies the shift.
always_comb begin
    case (game)
        GAME_PBOBBLE, GAME_SPACEDX, GAME_QZSHOWBY, GAME_CRIMEC:
            begin cfg_cb_fb = 8'h80; cfg_cb_bg = 8'h00; cfg_cb_fg = 8'h40; cfg_cb_tx = 8'hc0; end
        GAME_MASTERW, GAME_RAMBO3, GAME_VIOFIGHT, GAME_SPACEDXO,
        GAME_SELFEENA, GAME_SILENTD, GAME_TETRISTA:
            begin cfg_cb_fb = 8'h10; cfg_cb_bg = 8'h30; cfg_cb_fg = 8'h20; cfg_cb_tx = 8'h00; end
        default: // rastsag2, ashura, hitice, rambo3p, sbm, realpunc, tetrist
            begin cfg_cb_fb = 8'h40; cfg_cb_bg = 8'hc0; cfg_cb_fg = 8'h80; cfg_cb_tx = 8'h00; end
    endcase
end

// ------------------------------------------------------------------------------------
// 68000 address map, straight from each game's *_map() in taito_b.cpp.
//
// 00 means "this block does not exist on this board" - only the EEPROM boards have an
// MB87078. cfg_a_syt is filled in for the PC060HA boards too: that chip is the TC0140SYT
// mailbox at a different address, not a different chip (see rtl/taitob_sound.sv).
// ------------------------------------------------------------------------------------
always_comb begin
    cfg_io_lowbyte = 1'b0;
    cfg_rom_1mb    = 1'b0;
    case (game)
        //                   vcu    io     syt    pal    wram
        GAME_PBOBBLE:  begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h50, 8'h70, 8'h80, 8'h90, 8'h60}; end
        GAME_SPACEDX:  begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h50, 8'h70, 8'h80, 8'h90, 8'h60}; end
        GAME_QZSHOWBY: begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h20, 8'h60, 8'h80, 8'h90, 8'h70}; cfg_rom_1mb = 1'b1; end
        GAME_CRIMEC:   begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h20, 8'h60, 8'h80, 8'hA0, 8'h00}; end
        GAME_RASTSAG2,
        GAME_ASHURA:   begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'hA0, 8'h80, 8'h20, 8'h60, 8'h00}; end
        GAME_SILENTD:  begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h50, 8'h20, 8'h10, 8'h30, 8'h40, 8'h00};
                              cfg_io_lowbyte = 1'b1; end
        GAME_SELFEENA: begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h20, 8'h40, 8'h50, 8'h30, 8'h10, 8'h00}; end
        // spacedxo maps its TC0220IOC with umask16(0x00ff) - the low byte, like silentd.
        // Untestable here (no romset), but the driver is unambiguous.
        GAME_SPACEDXO: begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h50, 8'h20, 8'h10, 8'h30, 8'h40, 8'h00};
                              cfg_io_lowbyte = 1'b1; end
        // halfword_wordswap_r calls halfword_r, which returns the register in the LOW
        // byte - so sbm reads the I/O chip on D7-D0, like silentd, while every
        // halfword_byteswap_r board reads it on D15-D8.
        GAME_SBM:      begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h90, 8'h30, 8'h32, 8'h20, 8'h10, 8'h00};
                              cfg_io_lowbyte = 1'b1; end
        // Measured from MAME's bus traffic rather than read off the driver: 200000 is two
        // write-only addresses (the sound mailbox), 600000 is six addresses at stride 2
        // ending in 0E (the I/O chip), 800000 is read and written like memory (work RAM),
        // A00000 is written far more than read (the palette).
        // rambo3p is set the same and is NOT verified - no ROM for it here.
        GAME_RAMBO3,
        GAME_RAMBO3P:  begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h60, 8'h20, 8'hA0, 8'h80, 8'h00}; end
        // The PC060HA sits in cfg_a_syt: MAME derives pc060ha_device from tc0140syt_device
        // with no overridden behaviour, so it IS the same mailbox and rtl/tc0140syt.sv
        // serves it.
        // viofight: ciu 200000, vcu 400000, palette 600000, TC0220IOC 800000, RAM a00000.
        GAME_VIOFIGHT: begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h80, 8'h20, 8'h60, 8'hA0, 8'h00}; end
        // masterw: RAM 200000, vcu 400000, palette 600000, TC0040IOC 800000, ciu a00000.
        GAME_MASTERW:  begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h80, 8'hA0, 8'h60, 8'h20, 8'h00}; end
        // palette A0, work RAM 80, I/O 60, ciu 700000. hitice also has a P3_P4 port at
        // 610000 and a CPU-drawn bitmap at b00000, which are outside this table.
        GAME_HITICE:   begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h60, 8'h70, 8'hA0, 8'h80, 8'h00}; end
        // Work RAM is at 100000 - 300000 is the HD63484. The set's own reset vector agrees
        // (SSP = 0x0010FFFC). MAME declares 100000-13FFFF, but the game only touches page
        // 10, so the core's single 64 KiB work RAM is enough.
        GAME_REALPUNC: begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h20, 8'h18, 8'h18, 8'h28, 8'h10, 8'h00};
                              // halfword_wordswap_r, same as sbm: low byte and index ^ 1
                              cfg_io_lowbyte = 1'b1;
                              cfg_rom_1mb = 1'b1; end
        // tetrist is a Nastar conversion kit. MAME's tetrist() machine_config calls
        // rastsag2(config) and then OVERRIDES the map with set_addrmap(tetrist_map), so
        // it does NOT inherit rastsag2's addresses - the two share chips, not pages.
        // From tetrist_map(): sound mailbox 200000, vcu 400000, TC0220IOC 600000 with
        // umask16(0xff00) so the chip is read on D15-D8 as usual, work RAM 800000,
        // palette a00000.
        GAME_TETRIST:  begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h60, 8'h20, 8'hA0, 8'h80, 8'h00}; end
        // tetrista is a Master of Weapon conversion kit and moves almost everything:
        // palette 200000, vcu 400000, TC0040IOC 600000, RAM 800000, ciu a00000. No romset
        // here, so this is transcribed from tetrista_map and untested.
        GAME_TETRISTA: begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h60, 8'hA0, 8'h20, 8'h80, 8'h00}; end
        default:       begin {cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb}
                              = {8'h40, 8'h50, 8'h70, 8'h80, 8'h90, 8'h60}; end
    endcase
end

// Which port lands in which I/O register. See IOL_* in system_consts.sv.
always_comb begin
    case (game)
        GAME_SBM, GAME_REALPUNC: cfg_io_wordswap = 1'b1;  // halfword_wordswap_r/w
        default:                 cfg_io_wordswap = 1'b0;
    endcase
end

// The TC0040IOC is the indexed ancestor of the TC0220IOC: the same register file behind a
// two-address window instead of sixteen consecutive ones. MAME's tc0040ioc_device::read /
// ::write route the ODD word offset to the index latch (write) and the watchdog (read),
// and the EVEN offset to whichever register the latch currently names. Everything else -
// which register holds what, and what a write to register 4 does - is identical, so the
// core reuses the TC0640FIO register file and only redirects its address.
always_comb begin
    case (game)
        GAME_MASTERW, GAME_TETRISTA: cfg_io_indexed = 1'b1;
        default:                     cfg_io_indexed = 1'b0;
    endcase
end

// hitice is the four-player set and reads players 3 and 4 as a plain 16-bit port at
// 610000 - one page above its TC0220IOC, outside the chip entirely.
always_comb begin
    case (game)
        GAME_HITICE: cfg_p34_word = 1'b1;
        default:     cfg_p34_word = 1'b0;
    endcase
end

always_comb begin
    case (game)
        GAME_REALPUNC: cfg_a_syt_sub = 4'h8;   // 188000
        default:       cfg_a_syt_sub = 4'h0;
    endcase
end

always_comb begin
    case (game)
        GAME_REALPUNC: cfg_a_acrtc = 8'h30;    // 300000
        default:       cfg_a_acrtc = 8'h00;
    endcase
end

always_comb begin
    case (game)
        // Measured from MAME's input handling rather than transcribed. The discriminator is which
        // port carries Tilt: layout A has it in IN2 with the joystick in IN0, layout B has
        // it in IN1 with the buttons in IN0. A game on the wrong layout reads tilt from a
        // bit that is not tilt, and stops with TILT on the screen before it draws anything.
        GAME_PBOBBLE, GAME_SPACEDX, GAME_QZSHOWBY: cfg_io_layout = IOL_FIO;
        GAME_SELFEENA, GAME_SILENTD,
        GAME_RAMBO3,  GAME_HITICE:                 cfg_io_layout = IOL_IOC_B;
        GAME_SBM:                                  cfg_io_layout = IOL_SBM;
        GAME_REALPUNC:                             cfg_io_layout = IOL_RPUNC;
        default:                                   cfg_io_layout = IOL_IOC_A;
    endcase
end

// Coin input polarity, measured from the idle value of every input field in MAME: rambo3
// is the only set here whose coin inputs idle
// LOW, so it is the only one where they are active high. Everything else on this hardware
// idles high. Driven active low, rambo3 reads both coins as held down for ever and stops
// with COIN ERROR, which says nothing about polarity.
always_comb begin
    case (game)
        GAME_RAMBO3, GAME_RAMBO3P: cfg_coin_hi = 1'b1;   // rambo3p not verified - no ROM here
        default:                   cfg_coin_hi = 1'b0;
    endcase
end

endmodule
