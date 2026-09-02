// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// Taito B System - game top.
//
// Structure follows the upstream Taito F2 core's game top, which is the right template
// because the two systems share their CPU, sound, sound-comms, palette and I/O silicon
// almost exactly. The video chain is the difference: F2 uses TC0100SCN + TC0200OBJ +
// TC0360PRI, Taito B uses a single TC0180VCU.
//
// Contents: 68000 + bus decode, Z80 sound subsystem (YM2610/YM2610B, or YM2203 + M6295),
// TC0140SYT / PC060HA mailbox, the per-game I/O chip, 93C46 EEPROM, MB87078 and the
// TC0180VCU video chip. Address maps follow src/mame/taito/taito_b.cpp; per-game variation
// is confined to taitob_board_config.sv.

import system_consts::*;

module TaitoB(
    input             clk,
    input             reset,
    input             pause,

    input      game_t game,
    input      [23:0] gfx_region_size,

    // Video
    output            ce_pixel,
    output            hsync,
    output            hblank,
    output            vsync,
    output            vblank,
    output      [7:0] red,
    output      [7:0] green,
    output      [7:0] blue,
    input             sync_fix,

    // Controls
    input       [9:0] joystick_p1,
    input       [9:0] joystick_p2,
    input       [9:0] joystick_p3,
    input       [9:0] joystick_p4,
    input       [3:0] start,
    input       [3:0] coin,

    // Service Mode. On the real cabinet this is a toggle switch on the coin door, and it
    // is how you reach the board's own I/O test - the only screen in these games that
    // shows live input state and does not advance on a timer. An OSD option rather than a
    // mapped button because it is a switch, not a momentary press.
    input             service,
    input       [7:0] dswa,
    input       [7:0] dswb,

    // Audio
    output     [15:0] audio_out,

    // SDRAM: CPU program ROM (64-bit, shared with the ROM loader in the wrapper)
    output     [26:0] sdr_cpu_addr,
    input      [63:0] sdr_cpu_q,
    output            sdr_cpu_req,
    input             sdr_cpu_ack,

    // SDRAM: TC0180VCU tile/sprite graphics (32-bit - one read yields all 4 bitplanes
    // for 8 pixels, which is why the MRA interleaves the two gfx ROM halves)
    output reg [26:0] sdr_vcu_addr,
    input      [31:0] sdr_vcu_q,
    output reg        sdr_vcu_req,
    input             sdr_vcu_ack,

    // Sprite gfx, on its own 64-bit channel. A 16x16 tile is 128 interleaved bytes, so
    // 64-bit reads halve the fetch count against the tilemap's 32-bit channel - which is
    // what makes the sprite raster budget close.
    output reg [26:0] sdr_spr_addr,
    input      [63:0] sdr_spr_q,
    output reg        sdr_spr_req,
    input             sdr_spr_ack,

    // SDRAM: YM2610 ADPCM + Z80 banked ROM, owned by the TC0140SYT
    output     [26:0] sdr_audio_addr,
    input      [15:0] sdr_audio_q,
    output            sdr_audio_req,
    input             sdr_audio_ack,

    // DDR3 - reserved for the TC0180VCU sprite framebuffer in M3
    ddr_if.to_host    ddr,

    // Z80 program ROM load path
    input      [23:0] bram_addr,
    input       [7:0] bram_data,
    input             bram_wr,

    // NVRAM (93C46 contents) - MiSTer save/restore
    input       [6:0] nvram_addr,
    input       [7:0] nvram_din,
    input             nvram_wr,
    output      [7:0] nvram_q,
    output            nvram_changed
);


// ------------------------------------------------------------------------------------
// Board configuration
// ------------------------------------------------------------------------------------
wire [2:0] cfg_irq_inth, cfg_irq_intl;
// Tile and sprite codes wrap by the number of elements in the graphics region, so the mask
// is the region size minus one. The size comes from the ROM image's own region header, not
// from a per-board table: several sets are aliased onto another set's board_t, and a table
// keyed by board hands an aliased set the size of the board it was aliased onto. ryujin
// declares 2 MiB and runs as the silentd board, which declares 4 - so every code from 0x4000
// up read past the end of ryujin's graphics instead of wrapping, and nothing in its attract
// sequence used one.
wire [21:0] gfx_mask = gfx_region_size[21:0] - 22'd1;
wire [1:0] cfg_io_chip;
wire       cfg_eeprom, cfg_mb87078, cfg_syt;
wire       cfg_ym2610b, cfg_ym2203, cfg_m6295;
wire       cfg_bpp15;
wire [7:0] cfg_cb_fb, cfg_cb_bg, cfg_cb_fg, cfg_cb_tx;
wire       cfg_cpu_16mhz, cfg_z80_6mhz;
wire [7:0] cfg_a_vcu, cfg_a_io, cfg_a_syt, cfg_a_pal, cfg_a_wram, cfg_a_mb;
wire       cfg_io_lowbyte, cfg_rom_1mb;
wire [2:0] cfg_io_layout;
wire       cfg_io_wordswap;
wire       cfg_io_indexed;
wire       cfg_p34_word;
wire [3:0] cfg_a_syt_sub;
wire [7:0] cfg_a_acrtc;
wire       cfg_coin_hi;

taitob_board_config board_config(
    .clk,
    .game,
    .cfg_irq_inth, .cfg_irq_intl,
    .cfg_io_chip, .cfg_eeprom, .cfg_mb87078, .cfg_syt,
    .cfg_ym2610b, .cfg_ym2203, .cfg_m6295,
    .cfg_bpp15, .cfg_cb_fb, .cfg_cb_bg, .cfg_cb_fg, .cfg_cb_tx,
    .cfg_cpu_16mhz, .cfg_z80_6mhz,
    .cfg_a_vcu, .cfg_a_io, .cfg_a_syt, .cfg_a_pal, .cfg_a_wram, .cfg_a_mb,
    .cfg_io_lowbyte, .cfg_rom_1mb, .cfg_io_layout, .cfg_coin_hi,
    .cfg_io_wordswap, .cfg_io_indexed, .cfg_p34_word, .cfg_a_syt_sub, .cfg_a_acrtc
);

// DDR3 carries the sprite framebuffer; tc0180vcu_fb owns the interface.

// ------------------------------------------------------------------------------------
// Clock enables
//
// clk_sys is 53.372 MHz - F2's clock, adopted because 53.372/106.744 is a clean 2:1 that
// meets timing while the ideal 54.328 MHz has no integer common VCO with a usable sys clock
// (101.865 MHz, the 15/8 compromise, built but failed timing at -4.589 ns).
//
// So clk_sys is NOT 8 x the 6.791 MHz dot clock, and EVERY rate below has to be a fractional
// enable computed for 53.372 - including the dot clock. A plain divide by 8 would run the
// whole core 1.76% slow (58.9 Hz, a 68000 at 11.79 MHz, music a third of a semitone flat).
// All ratios are within 10 ppm of the real chip rates:
//   68000     12 MHz (16 MHz on qzshowby)
//   YM2610     8 MHz
//   Z80        4 MHz  (6 MHz on masterw / hitice / viofight / realpunc - see below)
//   TC0180VCU  6.791 MHz dot clock
// ------------------------------------------------------------------------------------

// 12 MHz: 53.372 * 172/765 = 11.999979.  16 MHz: 53.372 * 277/924 = 16.000048.
wire [9:0] cpu_cen_n = cfg_cpu_16mhz ? 10'd277 : 10'd172;
wire [9:0] cpu_cen_m = cfg_cpu_16mhz ? 10'd924 : 10'd765;

wire ce_12m, ce_cpu_half;
jtframe_frac_cen #(2) cen_cpu(
    .clk(clk),
    .cen_in(~pause),
    .n(cpu_cen_n),
    .m(cpu_cen_m),
    .cen({ce_cpu_half, ce_12m}),
    .cenb()
);

// fx68k wants two non-overlapping phase enables per CPU clock. ce_cpu_count runs at twice
// the CPU rate and chases ce_steady_count, and is held while a CPU ROM fetch is in flight
// so the core stalls cleanly instead of relying on DTACK alone. Taken from the upstream F2 core.
reg [9:0]  ce_steady_count;
reg [10:0] ce_cpu_count;
reg        ce_cpu, ce_cpu_180;

always_ff @(posedge clk) begin
    if (ce_12m) ce_steady_count <= ce_steady_count + 10'd1;

    ce_cpu     <= 1'b0;
    ce_cpu_180 <= 1'b0;

    if (sdr_cpu_req == sdr_cpu_ack && ~pause) begin
        if (ce_cpu_count[10:1] != ce_steady_count) begin
            ce_cpu       <= ~ce_cpu_count[0];
            ce_cpu_180   <=  ce_cpu_count[0];
            ce_cpu_count <= ce_cpu_count + 11'd1;
        end
    end
end

// YM2610 8 MHz, Z80 4 MHz: 53.372 * 137/914 = 7.999961, halved by frac_cen for the Z80.
wire ce_8m, ce_4m;
jtframe_frac_cen #(2) cen_audio(
    .clk(clk),
    .cen_in(~pause),
    .n(10'd137),
    .m(10'd914),
    .cen({ce_4m, ce_8m}),
    .cenb()
);

// masterw, hitice, viofight and realpunc clock the Z80 at 6 MHz (12 MHz XTAL / 2) while
// still running the YM at 8, so it needs its own divider rather than a tap off the audio
// one. 53.372 * 86/765 = 5.999990 MHz.
// The halved output is not spare: 24 MHz / 8 = 3 MHz is exactly the YM2203 clock on the
// four PC060HA boards, and they are the same four boards that run the Z80 at 6 MHz, so one
// divider serves both and the two stay in exact ratio.
wire ce_6m, ce_3m;
jtframe_frac_cen #(2) cen_z80_6m(
    .clk(clk),
    .cen_in(~pause),
    .n(10'd86),
    .m(10'd765),
    .cen({ce_3m, ce_6m}),
    .cenb()
);

wire ce_z80 = cfg_z80_6mhz ? ce_6m : ce_4m;

// ------------------------------------------------------------------------------------
// Video timing
//
// 320x224 visible, H total 448, V total 253. ce_13m is 2x the 6.791 MHz dot clock:
// 53.372 * 71/279 = 13.582122 MHz, halved by taitob_video_timing's ce_div, giving
// 6.791061 MHz and 6.791061e6 / (448 * 253) = 59.925 Hz. See
// rtl/taitob_video_timing.sv for why those totals were chosen - MAME does not
// raw-configure this screen, so they are a documented judgement call, not a fact.
// ------------------------------------------------------------------------------------
wire       ce_13m;
wire       global_hsync, global_hblank, global_vsync, global_vblank;
wire [8:0] global_hcnt, global_vcnt;

jtframe_frac_cen #(2) cen_video(
    .clk(clk),
    .cen_in(1'b1),
    .n(10'd71),
    .m(10'd279),
    .cen({ce_video_unused, ce_13m}),
    .cenb()
);
wire ce_video_unused;   // frac_cen always emits a halved rate; the raster needs only ce_13m

taitob_video_timing video_timing(
    .clk(clk),
    .ce_13m(ce_13m),
    .ce_pixel(ce_pixel),
    .hcnt(global_hcnt),
    .vcnt(global_vcnt),
    .hsync(global_hsync),
    .vsync(global_vsync),
    .hblank(global_hblank),
    .vblank(global_vblank)
);

// ------------------------------------------------------------------------------------
// 68000
// ------------------------------------------------------------------------------------
wire        cpu_rw /* verilator public_flat */;
wire        cpu_as_n /* verilator public_flat */;
wire  [1:0] cpu_ds_n /* verilator public_flat */;
wire  [2:0] cpu_fc /* verilator public_flat */;
logic [15:0] cpu_data_in /* verilator public_flat */;   // driven by the read mux below
wire  [15:0] cpu_data_out /* verilator public_flat */;
wire [22:0] cpu_addr;
wire [23:0] A /* verilator public_flat */ = {cpu_addr, 1'b0};   // byte address, as the memory map documents it

wire IACKn = ~&cpu_fc;
wire [2:0] IPLn;
wire       DTACKn;

fx68k m68000(
    .clk(clk),
    .HALTn(1'b1),
    .extReset(reset),
    .pwrUp(reset),
    .enPhi1(ce_cpu),
    .enPhi2(ce_cpu_180),

    .eRWn(cpu_rw), .ASn(cpu_as_n), .LDSn(cpu_ds_n[0]), .UDSn(cpu_ds_n[1]),
    .E(), .VMAn(),

    .FC0(cpu_fc[0]), .FC1(cpu_fc[1]), .FC2(cpu_fc[2]),
    .BGn(),
    .oRESETn(), .oHALTEDn(),
    .DTACKn(DTACKn), .VPAn(IACKn),   // VPAn tied to IACKn => autovectored interrupts
    .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(IPLn[0]), .IPL1n(IPLn[1]), .IPL2n(IPLn[2]),
    .iEdb(cpu_data_in), .oEdb(cpu_data_out),
    .eab(cpu_addr)
);

// ------------------------------------------------------------------------------------
// Address decode
//
// Every base comes from taitob_board_config, because the Taito B games agree on almost
// nothing here: the VCU alone is at 0x200000 on selfeena, 0x400000 on most, 0x500000 on
// silentd and 0x900000 on sbm, and the I/O chip moves between 0x200000, 0x300000,
// 0x400000, 0x500000, 0x800000 and 0xA00000. Hardcoding pbobble's map is what made this
// core a one-game core.
//
// A base of 0x00 means the block is absent (only the EEPROM boards have an MB87078) - and
// since no block legitimately sits at 0x000000, which is always program ROM, 0x00 is a
// safe sentinel.
// ------------------------------------------------------------------------------------
wire cs_rom    = ~cpu_as_n & (cfg_rom_1mb ? (A[23:20] == 4'b0000)
                                          : (A[23:19] == 5'b00000));
wire cs_vcu    = ~cpu_as_n & (A[23:19] == {cfg_a_vcu[7:3]});    // 512 KiB window
wire cs_io_blk = ~cpu_as_n & (A[23:16] == cfg_a_io);
wire cs_mb     = ~cpu_as_n & (A[23:16] == cfg_a_mb)  & (cfg_a_mb  != 8'h00);
// The mailbox is four bytes, but every board except realpunc has it alone on its page, so a
// page match is enough there. realpunc shares the page with its I/O chip, its video control
// register and an output latch - see cfg_a_syt_sub.
wire cs_snd    = ~cpu_as_n & (A[23:16] == cfg_a_syt) & (A[15:12] == cfg_a_syt_sub)
                           & (cfg_a_syt != 8'h00);
wire cs_pal    = ~cpu_as_n & (A[23:16] == cfg_a_pal) & ~A[15];  // 8 KiB, mirrored to 32
wire cs_wram   = ~cpu_as_n & (A[23:16] == cfg_a_wram);

// $5000xx sub-decode. The driver header notes these are probably all one TC0640FIO die;
// MAME handles the strays ad hoc and so do we.
wire cs_fio    = cs_io_blk & (A[15:4] == 12'h000);              // 500000-50000F
wire cs_p34a   = cs_io_blk & (A[15:1] == 15'h0012);             // 500024
wire cs_eep    = cs_io_blk & (A[15:1] == 15'h0013);             // 500026
wire cs_coin34 = cs_io_blk & (A[15:1] == 15'h0014);             // 500028
wire cs_p34b   = cs_io_blk & (A[15:1] == 15'h0017);             // 50002E
// hitice only: players 3 and 4 as one 16-bit port a page above the I/O chip, at 610000.
wire cs_p34w   = ~cpu_as_n & cfg_p34_word
                 & (A[23:16] == (cfg_a_io + 8'd1)) & (A[15:1] == 15'd0);

// realpunc's HD63484 ACRTC status register, at 300000.
//
// The chip itself is not implemented and does not need to be: `screen_update_realpunc`, which
// would composite its framebuffer, is dead code - no machine_config installs it, and realpunc
// renders through the ordinary compositor. But the game PROGRAMS the chip and then polls its
// status, and an undecoded read returns 0xFFFF, which in HD63484 terms is
//
//     CER(80) ARD(40) CED(20) LPD(10) RFF(08) RFR(04) WFR(02) WFE(01)
//
// - a command error, forever. Measured with a read tap in MAME, the real chip answers 0xFF23
// when idle and 0xFF03 while a command runs; the upper byte is open bus, which MAME's own
// comment notes another game depends on. So the stub answers the idle value: no error,
// command always complete, write FIFO always ready and empty, read FIFO empty.
wire cs_acrtc  = ~cpu_as_n & cfg_a_acrtc != 8'h00 & (A[23:16] == cfg_a_acrtc)
                           & (A[15:2] == 14'd0);

wire cpu_wr = ~cpu_rw & ~cpu_as_n;

// ------------------------------------------------------------------------------------
// Work RAM - 64 KiB
// ------------------------------------------------------------------------------------
wire [15:0] wram_q;

m68k_ram #(.WIDTHAD(15)) work_ram(
    .clock(clk),
    .address(cpu_addr[14:0]),
    .we_lds_n(~(cs_wram & cpu_wr & ~cpu_ds_n[0])),
    .we_uds_n(~(cs_wram & cpu_wr & ~cpu_ds_n[1])),
    .data(cpu_data_out),
    .q(wram_q)
);

// ------------------------------------------------------------------------------------
// TC0180VCU
// ------------------------------------------------------------------------------------
wire [15:0] vcu_dout;
wire        vcu_dtack_n;
wire        vcu_inth /* verilator public_flat */;
wire        vcu_intl /* verilator public_flat */;
wire [13:0] vcu_pixel;
wire        vcu_screen_flip, vcu_video_enable;
wire [21:0] vcu_gfx_addr;
wire        vcu_gfx_req;
wire [21:0] vcu_spr_addr;
wire        vcu_spr_req;
wire [15:0] vcu_sprite_overrun, vcu_sprite_early, vcu_chain_heads, vcu_chain_subs;
wire [23:0] vcu_sprite_cycles;

wire        fb_wr_valid, fb_wr_busy, fb_wr_page, fb_disp_page, fb_erase_en;
wire        fb_cpu_req, fb_cpu_we, fb_cpu_page, fb_cpu_ack;
wire  [8:0] fb_cpu_x;
wire  [7:0] fb_cpu_y;
wire [15:0] fb_cpu_din, fb_cpu_dout;
wire  [1:0] fb_cpu_be;
wire  [8:0] fb_wr_x;
wire  [7:0] fb_wr_y, fb_wr_mask;
wire [79:0] fb_wr_pix;
wire  [9:0] fb_pixel;
wire [15:0] vcu_fetch_miss;
wire [63:0] vcu_dbg_ctrl;

TC0180VCU tc0180vcu(
    .clk(clk),
    .reset(reset),

    .cpu_addr(cpu_addr[17:0]),
    .cpu_din(cpu_data_out),
    .cpu_dout(vcu_dout),
    .cpu_cs(cs_vcu),
    .cpu_rw(cpu_rw),
    .cpu_uds_n(cpu_ds_n[1]),
    .cpu_lds_n(cpu_ds_n[0]),
    .cpu_dtack_n(vcu_dtack_n),

    .ce_pixel(ce_pixel),
    .hcnt(global_hcnt),
    .vcnt(global_vcnt),
    .hblank(global_hblank),
    .vblank(global_vblank),

    .inth(vcu_inth),
    .intl(vcu_intl),
    .inth_ack(vcu_inth_ack),
    .intl_ack(vcu_intl_ack),

    .cb_fb(cfg_cb_fb),
    .cb_bg(cfg_cb_bg),
    .cb_fg(cfg_cb_fg),
    .cb_tx(cfg_cb_tx),

    .gfx_addr(vcu_gfx_addr),
    .gfx_req(vcu_gfx_req),
    .gfx_ack(sdr_vcu_ack),
    .gfx_q(sdr_vcu_q),

    .spr_addr(vcu_spr_addr),
    .spr_req(vcu_spr_req),
    .spr_ack(sdr_spr_ack),
    .spr_q(sdr_spr_q),

    .fb_wr_valid(fb_wr_valid), .fb_wr_busy(fb_wr_busy), .fb_wr_page(fb_wr_page),
    .fb_wr_x(fb_wr_x), .fb_wr_y(fb_wr_y), .fb_wr_pix(fb_wr_pix), .fb_wr_mask(fb_wr_mask),
    .fb_pixel(fb_pixel), .fb_page_o(fb_disp_page), .fb_erase_en(fb_erase_en),
    .fb_cpu_req(fb_cpu_req), .fb_cpu_we(fb_cpu_we), .fb_cpu_page(fb_cpu_page),
    .fb_cpu_x(fb_cpu_x), .fb_cpu_y(fb_cpu_y), .fb_cpu_din(fb_cpu_din),
    .fb_cpu_be(fb_cpu_be), .fb_cpu_dout(fb_cpu_dout), .fb_cpu_ack(fb_cpu_ack),
    .sprite_overrun(vcu_sprite_overrun),
    .sprite_early(vcu_sprite_early),
    .chain_heads(vcu_chain_heads), .chain_subs(vcu_chain_subs),
    .sprite_cycles(vcu_sprite_cycles),

    .pixel(vcu_pixel),
    .screen_flip(vcu_screen_flip),
    .video_enable(vcu_video_enable),
    .fetch_miss(vcu_fetch_miss),
    // Testbench taps; unconnected here, and optimised away in synthesis.
    .dbg_ctrl(vcu_dbg_ctrl), .dbg_scroll(), .dbg_fetch(), .dbg_pair()
);

// The sprite framebuffer: two 512x256 pages in DDR3, scanned out a line at a time and
// erased behind the beam.
tc0180vcu_fb tc0180vcu_fb(
    .clk(clk),
    .reset(reset),

    .ce_pixel(ce_pixel),
    .hcnt(global_hcnt),
    .vcnt(global_vcnt),
    .visible_line(~global_vblank),

    .disp_page(fb_disp_page),
    .erase_en(fb_erase_en),
    .flip(vcu_screen_flip),

    .wr_valid(fb_wr_valid), .wr_busy(fb_wr_busy), .wr_page(fb_wr_page),
    .wr_x(fb_wr_x), .wr_y(fb_wr_y), .wr_pix(fb_wr_pix), .wr_mask(fb_wr_mask),

    .cpu_req(fb_cpu_req), .cpu_we(fb_cpu_we), .cpu_page(fb_cpu_page),
    .cpu_x(fb_cpu_x), .cpu_y(fb_cpu_y), .cpu_din(fb_cpu_din),
    .cpu_be(fb_cpu_be), .cpu_dout(fb_cpu_dout), .cpu_ack(fb_cpu_ack),

    .fb_pixel(fb_pixel),
    .dbg_scan_state(),
    .ddr(ddr)
);

// The VCU emits a byte address relative to its gfx region; add the SDRAM base here so the
// chip model stays independent of where the ROM happens to live.
always_comb begin
    sdr_vcu_addr = VCU_ROM_SDR_BASE[26:0] + {5'd0, vcu_gfx_addr & gfx_mask};
    sdr_vcu_req  = vcu_gfx_req;
    // Same wrap as the tile fetch: MAME reduces a sprite's code modulo the gfx element
    // count too, so an out-of-range sprite code wraps rather than fetching past the ROM.
    sdr_spr_addr = VCU_ROM_SDR_BASE[26:0] + {5'd0, vcu_spr_addr & gfx_mask};
    sdr_spr_req  = vcu_spr_req;
end

// ------------------------------------------------------------------------------------
// Interrupts
//
// INTH and INTL are encoded to 68000 IRQ levels by an external PAL, per game. Take the
// higher of the two if both are somehow pending.
// ------------------------------------------------------------------------------------
logic [2:0] irq_level /* verilator public_flat */;

always_comb begin
    irq_level = 3'd0;
    if (vcu_intl && cfg_irq_intl > irq_level) irq_level = cfg_irq_intl;
    if (vcu_inth && cfg_irq_inth > irq_level) irq_level = cfg_irq_inth;
end

assign IPLn = ~irq_level;

// Interrupt acknowledge. The 68000 drives FC=7 and puts the level being acknowledged on
// A3-A1 (cpu_addr[2:0], since A = {cpu_addr, 1'b0}). VPAn is tied to IACKn above, so these
// are autovectored and there is no vector fetch to decode - this cycle is the only signal
// that the CPU has taken the interrupt. Without clearing the source here the level stays
// up for the rest of its window and the handler is re-entered continuously; see the note
// in tc0180vcu.sv for the measurement that showed this.
reg prev_as_iack;
always_ff @(posedge clk) prev_as_iack <= cpu_as_n;
wire iack_cycle = ~IACKn & ~cpu_as_n & prev_as_iack;
wire vcu_inth_ack = iack_cycle & (cpu_addr[2:0] == cfg_irq_inth);
wire vcu_intl_ack = iack_cycle & (cpu_addr[2:0] == cfg_irq_intl);

// ------------------------------------------------------------------------------------
// I/O chip
// ------------------------------------------------------------------------------------
// Puzzle Bobble input wiring, from INPUT_PORTS_START(pbobble). Active low, except the
// EEPROM data-out bit in register 1, which is active high.
wire eeprom_do /* verilator public_flat */;

// Widths here are load-bearing: every one of these must come to exactly 8 bits. An
// oversized literal silently truncates from the TOP, which drops the highest input and
// shifts a 0 into a lower bit position - i.e. it fabricates a permanently-held button.
// A 4'b111 in place of 3'b111 below did exactly that to COIN1 and produced "COIN ERROR".
//
// The direction nibble is the BIT-REVERSE of MiSTer's, everywhere it appears. MiSTer's
// joystick is {up, down, left, right} in bits 3,2,1,0 - the order the input .map uses -
// while every Taito port is bit0 UP, bit1 DOWN, bit2 LEFT, bit3 RIGHT. Passing them
// through unreversed maps MiSTer RIGHT onto game UP, which still looks like a working
// game until you try to steer it. Confirmed on hardware and against the upstream F2 core.
wire [7:0] p1_dir = { 4'hf, ~joystick_p1[0], ~joystick_p1[1], ~joystick_p1[2], ~joystick_p1[3] };
wire [7:0] p2_dir = { 4'hf, ~joystick_p2[0], ~joystick_p2[1], ~joystick_p2[2], ~joystick_p2[3] };
wire [7:0] p3_dir = { 4'hf, ~joystick_p3[0], ~joystick_p3[1], ~joystick_p3[2], ~joystick_p3[3] };
wire [7:0] p4_dir = { 4'hf, ~joystick_p4[0], ~joystick_p4[1], ~joystick_p4[2], ~joystick_p4[3] };

// hitice's P3_P4 port, straight from INPUT_PORTS_START(hitice): low byte is player 3 -
// joystick in b0-b3, buttons 1-3 in b4-b6, START3 in b7 - and the high byte is player 4 the
// same way with START4. All active low.
wire [15:0] p34_word = { ~start[3], ~joystick_p4[6], ~joystick_p4[5], ~joystick_p4[4], p4_dir[3:0],
                         ~start[2], ~joystick_p3[6], ~joystick_p3[5], ~joystick_p3[4], p3_dir[3:0] };

logic [7:0] io_in0, io_in1, io_in2, io_in3, io_in7;
always_comb begin
    unique case (cfg_io_layout)
    // TC0640FIO. From INPUT_PORTS_START(pbobble): SERVICE / COIN / START / P1_P2_A /
    // P1_P2_B. Active low except the EEPROM data-out bit, which is active HIGH.
    IOL_FIO: begin
        io_in0 = { ~service, 7'h7f };                                // b7 SERVICE
        io_in1 = { ~coin[3], ~coin[2], ~coin[1], ~coin[0],           // b7-b4 COIN4-1
                   3'b111,                                           // b3-b1 unused
                   eeprom_do };                                      // b0 EEPROM DO
        io_in2 = { ~start[3], ~start[2], ~start[1], ~start[0],       // b7-b4 START4-1
                   3'b111, 1'b1 };                                   // b3-b1 SERVICE, b0 TILT
        io_in3 = { 1'b1, ~joystick_p2[6], ~joystick_p2[5], ~joystick_p2[4],
                   1'b1, ~joystick_p1[6], ~joystick_p1[5], ~joystick_p1[4] };
        io_in7 = { p2_dir[3:0], p1_dir[3:0] };
    end

    // TC0220IOC layout A: DSWA / DSWB / P1 joy+buttons / P2 joy+buttons / system.
    // TAITO_JOY_UDLR_2_BUTTONS puts the joystick in b0-b3 and buttons in b4-b5;
    // TAITO_B_SYSTEM_INPUT is b0 TILT, b1 SERVICE1, b2 COIN1, b3 COIN2, b6/b7 START1/2.
    IOL_IOC_A: begin
        io_in0 = dswa & (service ? 8'hfb : 8'hff);
        io_in1 = dswb;
        io_in2 = { 1'b1, ~joystick_p1[6], ~joystick_p1[5], ~joystick_p1[4], p1_dir[3:0] };
        io_in3 = { 1'b1, ~joystick_p2[6], ~joystick_p2[5], ~joystick_p2[4], p2_dir[3:0] };
        io_in7 = { ~start[1], ~start[0], 2'b11, ~coin[1], ~coin[0], 1'b1, 1'b1 };
    end

    // TC0510NIO on sbm. From its machine config: read_0 DSWA, read_1 DSWB, read_2 JOY,
    // read_3 START, read_7 PHOTOSENSOR - and the photosensor port is why this cannot reuse
    // another layout. Sonic Blast Man is a punching machine, and MAME declares pad sensors
    // 2 and 3 IP_ACTIVE_HIGH while sensors 1 and 4, the coins, service and tilt are all
    // active low. So the idle value of register 7 is 0x9F. Driving it to 0xFF - which is
    // what an unassigned layout does - tells the game two sensors are already made, i.e.
    // that the pad is raised, and it stops with SERVICE SWITCH ERROR. That message names
    // the service switch and the fault is in two photosensor bits.
    IOL_SBM: begin
        io_in0 = dswa;
        io_in1 = dswb;
        io_in2 = { p2_dir[3:0], p1_dir[3:0] };                       // b0-3 P1, b4-7 P2
        io_in3 = { 6'b111111, ~start[1], ~start[0] };                // b0 Select, b1 Start
        io_in7 = { 1'b1,                    // b7 pad sensor 4, active low
                   joystick_p1[6],          // b6 pad sensor 3, ACTIVE HIGH
                   joystick_p1[5],          // b5 pad sensor 2, ACTIVE HIGH
                   ~joystick_p1[4],         // b4 pad sensor 1, active low
                   ~coin[1], ~coin[0],      // b3 COIN2, b2 COIN1
                   ~service,                // b1 SERVICE1
                   1'b1 };                  // b0 TILT
    end

    // realpunc. From its machine config: read_0 DSWA, read_1 DSWB, read_2 IN0, read_3 IN1,
    // read_7 IN2 - and IN0/IN1/IN2 are nothing like any other board's. IN0 is start and
    // system together, IN1 is eight unknowns, and IN2 is a safety switch plus three pad
    // photosensors. It is a punching machine like sbm, but unlike sbm every one of its bits
    // is active low, so it cannot borrow IOL_SBM.
    IOL_RPUNC: begin
        io_in0 = dswa;
        io_in1 = dswb;
        io_in2 = { ~coin[1], ~coin[0],   // b7 COIN2, b6 COIN1
                   ~service,             // b5 SERVICE1
                   1'b1,                 // b4 TILT
                   1'b1,                 // b3 SERVICE (a switch, not a button)
                   1'b1,                 // b2 unused
                   ~start[1], ~start[0] };
        io_in3 = 8'hff;                  // eight unknowns, idle high
        io_in7 = { 1'b1,
                   ~joystick_p1[7],      // b6 pad photosensor 3 (D)
                   ~joystick_p1[6],      // b5 pad photosensor 2 (U)
                   ~joystick_p1[5],      // b4 pad photosensor 1 (N)
                   3'b111,
                   ~joystick_p1[4] };    // b0 safety switch
    end

    // TC0220IOC layout B, the East Technology boards (selfeena, silentd, ryujin):
    // DSWA / DSWB / buttons for both players / system / joysticks for both players.
    IOL_IOC_B: begin
        io_in0 = dswa & (service ? 8'hfb : 8'hff);
        io_in1 = dswb;
        io_in2 = { 2'b11, ~joystick_p2[6], ~joystick_p2[5], ~joystick_p2[4],
                          ~joystick_p1[6], ~joystick_p1[5], ~joystick_p1[4] };
        io_in3 = { 2'b11, coin[1] ^ ~cfg_coin_hi, coin[0] ^ ~cfg_coin_hi,
                   ~start[1], ~start[0], 1'b1, 1'b1 };
        io_in7 = { p2_dir[3:0], p1_dir[3:0] };
    end

    default: begin
        io_in0 = 8'hff; io_in1 = 8'hff; io_in2 = 8'hff; io_in3 = 8'hff; io_in7 = 8'hff;
    end
    endcase
end

wire [7:0] fio_dout;
wire       fio_watchdog;

// ---- TC0040IOC index latch (masterw, tetrista) ---------------------------------------
// On those boards the sixteen registers are reached through a two-address window: a write
// to the odd word offset latches the register index, and the even offset then reads or
// writes whatever register the latch names. The odd offset also READS, as the watchdog
// kick, and MAME returns 0 for it - not the index. Everything past the address is the same
// register file, so the TC0640FIO below serves both and only its A input moves.
reg [7:0] io_port_idx;
always_ff @(posedge clk) begin
    if (reset)                                   io_port_idx <= 8'd0;
    else if (cs_fio & cpu_wr & cfg_io_indexed & A[1])
        io_port_idx <= cfg_io_lowbyte ? cpu_data_out[7:0] : cpu_data_out[15:8];
end

// An index above 0x0F names no register at all; MAME's portreg_r falls through to 0xFF.
// The register file only sees four bits, so that case is caught here instead.
wire io_idx_valid = ~cfg_io_indexed | (io_port_idx[7:4] == 4'd0);
wire cs_fio_reg   = cs_fio & (~cfg_io_indexed | ~A[1]);

TC0640FIO tc0640fio(
    .clk(clk),
    .RES_INn(~reset),

    // sbm and realpunc use halfword_wordswap_r/w: the register INDEX is offset ^ 1.
    .A(cfg_io_indexed ? io_port_idx[3:0] : (A[4:1] ^ {3'd0, cfg_io_wordswap})),
    .WEn(cpu_rw),
    .CSn(~cs_fio_reg),
    .OEn(~cpu_rw),

    // Which byte lane the I/O chip sits on is per-game: everyone uses umask16(0xff00),
    // i.e. D15-D8, except silentd which uses umask16(0x00ff).
    .Din(cfg_io_lowbyte ? cpu_data_out[7:0] : cpu_data_out[15:8]),
    .Dout(fio_dout),

    .COIN_LOCK_A(), .COIN_LOCK_B(), .COINMETER_A(), .COINMETER_B(),
    .watchdog_kick(fio_watchdog),

    .INB(io_in7),
    .IN({io_in3, io_in2, io_in1, io_in0})
);

// ------------------------------------------------------------------------------------
// 93C46 EEPROM
//
// Control byte at $500026 (D15-D8): bit2 = DI, bit3 = CLK, bit4 = CS.
// $500026 reads back the last written latch, NOT the EEPROM output - DO comes back
// through TC0640FIO register 1 bit 0.
// ------------------------------------------------------------------------------------
reg [15:0] eep_latch /* verilator public_flat */;

always_ff @(posedge clk) begin
    if (reset) eep_latch <= 16'd0;
    else if (cs_eep & cpu_wr) begin
        if (~cpu_ds_n[1]) eep_latch[15:8] <= cpu_data_out[15:8];
        if (~cpu_ds_n[0]) eep_latch[7:0]  <= cpu_data_out[7:0];
    end
end

eeprom_93c46 eeprom(
    .clk(clk),
    .reset(reset),

    .cs(eep_latch[12]),      // bit 4 of the high byte
    .sck(eep_latch[11]),     // bit 3
    .di(eep_latch[10]),      // bit 2
    .dout(eeprom_do),

    .nv_addr(nvram_addr),
    .nv_din(nvram_din),
    .nv_wr(nvram_wr),
    .nv_q(nvram_q),
    .nv_changed(nvram_changed)
);

// ------------------------------------------------------------------------------------
// MB87078 electronic volume
// ------------------------------------------------------------------------------------
wire [8:0] mb_gain_q8;
wire [7:0] mb_gain_pct;

mb87078 mb87078(
    .clk(clk),
    .reset(reset),
    .cs(cs_mb & cpu_wr & ~cpu_ds_n[1]),
    .a(A[2:1]),
    .din(cpu_data_out[15:8]),
    .gain_q8(mb_gain_q8),
    .gain_pct(mb_gain_pct),
    .regs_0(), .regs_1()
);

// ------------------------------------------------------------------------------------
// Palette + TC0260DAR
// ------------------------------------------------------------------------------------
wire [15:0] dar_data_out;
wire        dar_dtack_n;
wire [13:0] dar_ram_addr;
wire [15:0] dar_ram_dout, color_ram_q;
wire        dar_ram_we_l_n, dar_ram_we_h_n;
wire        dar_hblank_n, dar_vblank_n;

m68k_ram #(.WIDTHAD(14)) color_ram(
    .clock(clk),
    .address(dar_ram_addr),
    .we_lds_n(dar_ram_we_l_n),
    .we_uds_n(dar_ram_we_h_n),
    .data(dar_ram_dout),
    .q(color_ram_q)
);

TC0260DAR tc0260dar(
    .clk(clk),
    .ce_pixel(ce_pixel),
    .ce_double(ce_13m),

    // Taito B's 15-bit palette entry is RRRRGGGGBBBBRGBx - four high bits per channel in
    // the top 12 bits, with each channel's LSB gathered in bits 3/2/1. In TC0260DAR terms
    // that is the bpp15+bppmix mode:
    //     VIDEOR <= { RDin[15:12], RDin[3], ... }
    // bpp15 alone selects a plain xRRRRRGGGGGBBBBB layout, which decodes the same RAM into
    // visibly wrong hues (white text comes out blue-violet). The 12-bit games use neither.
    .bpp15(cfg_bpp15),
    .bppmix(cfg_bpp15),

    .MDin(cpu_data_out),
    .MDout(dar_data_out),

    .MA(cpu_addr[13:0]),
    .RWn(cpu_rw),
    .UDSn(cpu_ds_n[1]),
    .LDSn(cpu_ds_n[0]),

    .CS(cs_pal),
    .DTACKn(dar_dtack_n),

    .ACCMODE(1'b1),

    .HBLANKn(~global_hblank),
    .VBLANKn(~global_vblank),
    .OHBLANKn(dar_hblank_n),
    .OVBLANKn(dar_vblank_n),

    .IM(vcu_pixel),

    .VIDEOR(dar_red),
    .VIDEOG(dar_grn),
    .VIDEOB(dar_blu),

    .RA(dar_ram_addr),
    .RDin(color_ram_q),
    .RDout(dar_ram_dout),
    .RWELn(dar_ram_we_l_n),
    .RWEHn(dar_ram_we_h_n)
);

wire [7:0] dar_red, dar_grn, dar_blu;

assign red   = dar_red;
assign green = dar_grn;
assign blue  = dar_blu;

assign hsync  = global_hsync;
assign vsync  = global_vsync;
assign hblank = ~dar_hblank_n;
assign vblank = ~dar_vblank_n;

// ------------------------------------------------------------------------------------
// CPU ROM out of SDRAM
//
// pbobble's 68000 ROM is 512 KiB - about 410 M10K blocks if held in BRAM, which the
// DE10-Nano cannot spare. rom_cache fetches through the shared 64-bit SDRAM channel and
// gates DTACK while a fetch is in flight.
// ------------------------------------------------------------------------------------
reg  prev_as_n;
wire pre_sdr_dtack_n = cs_rom & prev_as_n;
wire sdr_dtack_n;
wire [15:0] rom_q;

always_ff @(posedge clk) prev_as_n <= cpu_as_n;

rom_cache rom_cache(
    .clk(clk),
    .reset(reset),
    .sdr_addr(sdr_cpu_addr),
    .sdr_data(sdr_cpu_q),
    .sdr_req(sdr_cpu_req),
    .sdr_ack(sdr_cpu_ack),

    .extra_rom_n(1'b1),

    .as_n(~cs_rom | cpu_as_n),
    .dtack_n(sdr_dtack_n),
    .cpu_addr(cpu_addr),
    .data(rom_q)
);

// ------------------------------------------------------------------------------------
// DTACK and the CPU read mux
// ------------------------------------------------------------------------------------
assign DTACKn = sdr_dtack_n | pre_sdr_dtack_n | vcu_dtack_n | dar_dtack_n;

// Registered selects, because the BRAMs present their data a cycle after the address.
reg sel_rom_r, sel_vcu_r, sel_wram_r, sel_pal_r, sel_fio_r, sel_eep_r, sel_snd_r;
reg sel_p34a_r, sel_p34b_r;
reg sel_fio_wd_r;   // TC0040IOC odd offset: the watchdog kick, which reads back as 0
reg sel_p34w_r;
reg sel_acrtc_r;

always_ff @(posedge clk) begin
    sel_rom_r  <= cs_rom;
    sel_vcu_r  <= cs_vcu;
    sel_wram_r <= cs_wram;
    sel_pal_r  <= cs_pal;
    sel_fio_r  <= cs_fio;
    sel_fio_wd_r <= cs_fio & cfg_io_indexed & A[1];
    sel_eep_r  <= cs_eep;
    sel_snd_r  <= cs_snd;
    sel_p34a_r <= cs_p34a;
    sel_p34b_r <= cs_p34b;
    sel_p34w_r <= cs_p34w;
    sel_acrtc_r <= cs_acrtc;
end

wire [7:0] io_byte = sel_fio_wd_r ? 8'h00        :  // tc0040ioc_device::watchdog_r
                     io_idx_valid  ? fio_dout     :
                                     8'hff;         // index names no register

wire [3:0] syt_cpu_dout;

// P3/P4 ports exist on the board and are shown in service mode, but Puzzle Bobble never
// reads them. Reported as "no buttons pressed".
wire [7:0] p34_a = 8'hff;
wire [7:0] p34_b = 8'hff;

always_comb begin
    if      (sel_rom_r)  cpu_data_in = rom_q;
    else if (sel_vcu_r)  cpu_data_in = vcu_dout;
    else if (sel_wram_r) cpu_data_in = wram_q;
    else if (sel_pal_r)  cpu_data_in = dar_data_out;
    else if (sel_fio_r)  cpu_data_in = cfg_io_lowbyte ? {8'hff, io_byte} : {io_byte, 8'h00};
    else if (sel_eep_r)  cpu_data_in = eep_latch;
    else if (sel_snd_r)  cpu_data_in = {4'h0, syt_cpu_dout, 8'h00};
    else if (sel_p34a_r) cpu_data_in = {p34_a, 8'h00};
    else if (sel_p34b_r) cpu_data_in = {p34_b, 8'h00};
    else if (sel_p34w_r) cpu_data_in = p34_word;
    else if (sel_acrtc_r) cpu_data_in = 16'hFF23;   // HD63484 status: idle, no error
    else                 cpu_data_in = 16'hffff;
end

// ------------------------------------------------------------------------------------
// Sound subsystem - see rtl/taitob_sound.sv
// ------------------------------------------------------------------------------------
wire [15:0] audio_left, audio_right;
wire  [9:0] psg_snd;
wire        audio_sample;

taitob_sound sound(
    .clk(clk),
    .reset(reset),

    .ce_8m(ce_8m),
    .ce_4m(ce_4m),
    .ce_z80(ce_z80),
    .ce_12m(ce_12m),
    .ce_3m(ce_3m),

    .cfg_ym2610b(cfg_ym2610b),
    .cfg_ym2203(cfg_ym2203),
    .cfg_m6295(cfg_m6295),

    .cs_snd(cs_snd),
    .cpu_rw(cpu_rw),
    .cpu_data_out(cpu_data_out),
    .cpu_addr0(cpu_addr[0]),
    .syt_cpu_dout(syt_cpu_dout),

    .bram_addr(bram_addr),
    .bram_data(bram_data),
    .bram_wr(bram_wr),

    .sdr_audio_addr(sdr_audio_addr),
    .sdr_audio_q(sdr_audio_q),
    .sdr_audio_req(sdr_audio_req),
    .sdr_audio_ack(sdr_audio_ack),

    .audio_left(audio_left),
    .audio_right(audio_right),
    .psg_snd(psg_snd),
    .audio_sample(audio_sample)
);

// MB87078 attenuation. MAME applies the device's channel-1 gain to the YM2610's three
// output channels, so it belongs here, on the FM output, ahead of the mixer. Q8: a gain of
// 256 is unity and the arithmetic below is then exactly the identity. Registered because
// the multiply is on the audio path, which is where timing is tightest.
//
// THE PRODUCT NEEDS ITS OWN FULL WIDTH. Written as 16'(a * b >>> 8) the SIZE CAST makes the
// whole expression sixteen bits, so the multiply is evaluated in sixteen bits too and
// overflows: at unity gain every sample whose magnitude exceeds 127 wraps, which folds the
// signal modulo 256 rather than passing it through. The signature is an output level that
// stops depending on the input level.
reg signed [15:0] fm_left_att, fm_right_att;
wire signed [25:0] mb_prod_l = $signed({1'b0, mb_gain_q8}) * $signed(audio_left);
wire signed [25:0] mb_prod_r = $signed({1'b0, mb_gain_q8}) * $signed(audio_right);
always_ff @(posedge clk) begin
    fm_left_att  <= 16'(mb_prod_l >>> 8);
    fm_right_att <= 16'(mb_prod_r >>> 8);
end

audio_mix audio_mix(
    .clk(clk),
    .reset(reset),

    .fm_sample(audio_sample),
    .fm_left(fm_left_att),
    .fm_right(fm_right_att),
    .psg(psg_snd),

    .mono_output(audio_out)
);

endmodule
