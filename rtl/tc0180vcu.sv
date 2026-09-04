// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// TC0180VCU - Taito "Sprite, Background Tilemap and Frame Buffer Processor".
//
// No hardware documentation for this chip is publicly available. Everything here is
// transcribed from MAME's src/mame/taito/tc0180vcu.cpp and taito_b_v.cpp. Where MAME's own
// comments contradict its code (the control-register block is wrong about BG vs FG), the
// code is treated as authoritative and is what is implemented here.
//
// This module holds the CPU-side memory map, VRAM/sprite/scroll RAM, control registers,
// INTH/INTL generation, the tilemap fetch, the sprite framebuffer engine and the
// compositor, behind the `pixel` output.
//
// Device offsets within the 512 KiB window ($400000 on Taito B):
//   00000-0FFFF  VRAM        0x8000 words, BG/FG/TX code + attribute pages, banked
//   10000-1197F  Sprite RAM  408 sprites x 16 bytes
//   11980-137FF  scratch RAM
//   13800-13FFF  Scroll RAM  plane 0 (FG) at 13800, plane 1 (BG) at 13C00
//   18000-1801F  Control     16 words, regs 0-7 used, upper byte only
//   40000-7FFFF  Framebuffer two 512x256 pages

import system_consts::*;

module TC0180VCU(
    input             clk,
    input             reset,

    // ---- CPU interface -------------------------------------------------------------
    input      [17:0] cpu_addr,     // word address within the 512 KiB window
    input      [15:0] cpu_din,
    output reg [15:0] cpu_dout,
    input             cpu_cs,
    input             cpu_rw,       // 1 = read
    input             cpu_uds_n,
    input             cpu_lds_n,
    output            cpu_dtack_n,

    // ---- Video timing --------------------------------------------------------------
    input             ce_pixel,
    input       [8:0] hcnt,
    input       [8:0] vcnt,
    input             hblank,
    input             vblank,

    // ---- Interrupts ----------------------------------------------------------------
    // Two outputs, encoded to 68000 IRQ levels by an external PAL. The mapping is
    // per-game and lives in taitob_board_config.sv - never assume it here.
    output reg        inth,
    output reg        intl,
    input             inth_ack,   // 68000 acknowledged the level INTH is wired to
    input             intl_ack,

    // ---- Colour bases (from the board config) --------------------------------------
    input       [7:0] cb_fb,
    input       [7:0] cb_bg,
    input       [7:0] cb_fg,
    input       [7:0] cb_tx,

    // ---- Graphics ROM ----------------------------------------------------------------
    // Byte address relative to the gfx region; TaitoB.sv adds VCU_ROM_SDR_BASE. The bus is
    // 32 bits because the MRA interleaves the two ROM halves at 16-bit granularity, so one
    // read returns all four bitplanes for eight pixels:
    //   q[7:0]=plane0  q[15:8]=plane1  q[23:16]=plane2  q[31:24]=plane3
    output reg [21:0] gfx_addr,
    output reg        gfx_req,
    input             gfx_ack,
    input      [31:0] gfx_q,

    // ---- Video output --------------------------------------------------------------
    output     [13:0] pixel,        // palette index into TC0260DAR

    // ---- Status for other blocks ---------------------------------------------------
    output            screen_flip,
    output            video_enable,

    // Diagnostics: tile fetches that missed their display deadline. Should stay at zero.
    output reg [15:0] fetch_miss,
    // ---- Sprite gfx ROM (own 64-bit SDRAM channel) -----------------------------------
    output reg [21:0] spr_addr,
    output reg        spr_req,
    input             spr_ack,
    input      [63:0] spr_q,

    // ---- Sprite framebuffer -----------------------------------------------------------
    output reg        fb_wr_valid,
    input             fb_wr_busy,
    output reg        fb_wr_page,
    output reg  [8:0] fb_wr_x,
    output reg  [7:0] fb_wr_y,
    output reg [79:0] fb_wr_pix,
    output reg  [7:0] fb_wr_mask,
    input       [9:0] fb_pixel,
    output            fb_page_o,
    output            fb_erase_en,

    // ---- CPU framebuffer port ---------------------------------------------------------
    // Decoded here because this module owns the CPU bus; the access itself is performed by
    // tc0180vcu_fb, which owns the DDR interface.
    output            fb_cpu_req,
    output            fb_cpu_we,
    output            fb_cpu_page,
    output      [8:0] fb_cpu_x,
    output      [7:0] fb_cpu_y,
    output     [15:0] fb_cpu_din,
    output      [1:0] fb_cpu_be,
    input      [15:0] fb_cpu_dout,
    input             fb_cpu_ack,
    output reg [15:0] sprite_overrun,
    output reg [15:0] sprite_early,
    // Chain accounting for the frame just ended: how many entries started a big sprite and
    // how many were consumed as its continuations. A chain whose head is seen but whose
    // continuations are not says `big_sprite` is not being held, which is invisible in the
    // picture because a continuation read as a standalone sprite lands at its own x/y - and
    // for a chain body those are 0,0, which the clip rejects exactly.
    output reg [15:0] chain_heads,
    output reg [15:0] chain_subs,
    // How long the last completed sprite walk took, in clk cycles. This decides whether the
    // one-frame sprite latency is removable: MAME draws every sprite at the start of vblank
    // into the page displayed that same frame, which is only possible here if the whole walk
    // fits inside vblank. If it does not, the latency is a property of the design and not a
    // bug to be chased.
    output reg [23:0] sprite_cycles,   // walks that went idle before reaching entry 0

    output     [63:0] dbg_ctrl,       // ctrl[7:0] packed, for the testbench
    output     [63:0] dbg_scroll,     // {sy_bg, sx_bg, sy_fg, sx_fg}, for the testbench
    output     [31:0] dbg_fetch,      // last group's {fg_lx, fg_index, fetch_h}
    output     [63:0] dbg_pair        // {nxt_fg, cur_fg}
);

// ------------------------------------------------------------------------------------
// Address decode
// ------------------------------------------------------------------------------------
// cpu_addr is a WORD address inside the 512 KiB window, so each device byte offset below
// is halved before decoding. Getting this wrong is silent: writes disappear and reads
// return the default 0xFFFF, which passes an FFFF memory-test pattern and fails AAAA.
//   byte 00000-0FFFF -> word 00000-07FFF
//   byte 10000-13FFF -> word 08000-09FFF
//   byte 18000-1801F -> word 0C000-0C00F
//   byte 40000-7FFFF -> word 20000-3FFFF
wire sel_vram   = cpu_cs & (cpu_addr[17:15] == 3'b000);    // VRAM
wire sel_upper  = cpu_cs & (cpu_addr[17:13] == 5'd4);      // sprite + scratch + scroll
wire sel_ctrl   = cpu_cs & (cpu_addr[17:4]  == 14'h0C00);  // control registers
wire sel_fb     = cpu_cs & cpu_addr[17];                   // sprite framebuffer

wire wr = cpu_cs & ~cpu_rw;
wire [1:0] be = {~cpu_uds_n, ~cpu_lds_n};

// Every access completes in one cycle except the framebuffer, which is in DDR and has to
// wait for it. MAME's framebuffer_word_r/w give the layout: within the framebuffer window
// the word offset is cpu_addr[16:0], sy = offset >> 8 with bit 8 of sy selecting the page,
// and sx = 2 * (offset & 0xff) - so a word is two horizontally adjacent pixels and x is
// always even.
//
// A WRITE must wait for the data strobes. cs_vcu is qualified by AS alone (TaitoB.sv), and
// on a 68000 write AS asserts in S2 while UDS/LDS assert in S4 - a clock later. Every other
// VCU write is LEVEL-held (vram_we & be[1], upper_we & be[0], sel_ctrl & wr & be[1]), so a
// late strobe still lands. This path is the only one that LATCHES once and fires a one-shot
// DDR transaction, so it samples `be` at an instant instead of over the cycle - and sampled
// a cycle early it reads 00, producing a beat that enables no bytes and stores nothing.
// Do NOT qualify cs_vcu globally instead - that would change every VCU access, including
// the level-held paths that are already correct.
assign fb_cpu_req  = sel_fb & (cpu_rw | (|be));
assign fb_cpu_we   = sel_fb & ~cpu_rw;
assign fb_cpu_page = cpu_addr[16];
assign fb_cpu_y    = cpu_addr[15:8];
assign fb_cpu_x    = {cpu_addr[7:0], 1'b0};
assign fb_cpu_din  = cpu_din;
assign fb_cpu_be   = be;

assign cpu_dtack_n = sel_fb & ~fb_cpu_ack;

// ------------------------------------------------------------------------------------
// Control registers
//
// Only the upper byte of each register is acted on (ACCESSING_BITS_8_15), so these are
// effectively byte registers at even addresses.
// ------------------------------------------------------------------------------------
reg [7:0] ctrl[8];

wire [7:0] video_control = ctrl[7];

// Page bases, in words. MAME masks these fields to 4 bits, but VRAM only holds 8 pages of
// 0x1000 words, and the source's own doc comment says 3 bits - so 3 bits it is for BG/FG.
// TX pages are 0x800 words, so 4 bits there.
wire [14:0] fg_code_page = {ctrl[0][2:0], 12'd0};
wire [14:0] fg_attr_page = {ctrl[0][6:4], 12'd0};
wire [14:0] bg_code_page = {ctrl[1][2:0], 12'd0};
wire [14:0] bg_attr_page = {ctrl[1][6:4], 12'd0};
wire [14:0] tx_page      = {ctrl[6][3:0], 11'd0};

// lines_per_block = 256 - reg, so reg 0x00 is one scroll value for the whole screen and
// 0xFF is full per-scanline scroll.
wire [7:0] fg_scroll_reg = ctrl[2];
wire [7:0] bg_scroll_reg = ctrl[3];

wire [7:0] tx_bank0 = ctrl[4];
wire [7:0] tx_bank1 = ctrl[5];

assign dbg_ctrl = {ctrl[7], ctrl[6], ctrl[5], ctrl[4], ctrl[3], ctrl[2], ctrl[1], ctrl[0]};

// Screen flip. Only rambo3 sets this bit, so nothing else in the family exercises it.
// MAME's own comment block for this register is unreliable - it swaps BG and FG for
// registers 0 and 1 - so the bit assignment was confirmed against MAME's rendered output
// rather than its comments.
wire flip = video_control[4];
assign screen_flip  = flip;
assign fb_page_o    = fb_page;
assign fb_erase_en  = ~video_control[0];
assign video_enable = video_control[5];

// Framebuffer page.
//
// MAME writes m_framebuffer_page from two places - the vblank flip and the control-register
// write that forces a page - so it has to be ONE register here, with one always_ff. Splitting
// it across the control block and the vblank block is two constant drivers on the same net:
// Quartus refuses to elaborate it, and Verilator only lets it pass because MULTIDRIVEN is
// suppressed for the vendored SDRAM code. Note the inversion: MAME reads
//     m_framebuffer_page = BIT(~m_video_control, 6)
// so a forced page is the complement of bit 6.
reg fb_page;

// Declared here rather than with the interrupt logic below, because the page register is
// the first thing that needs the vblank edge.
reg  prev_vblank;
reg  prev_vcnt0;
wire vblank_start = vblank & ~prev_vblank;
wire vblank_end   = ~vblank & prev_vblank;
wire line_tick    = vcnt[0] ^ prev_vcnt0;

always_ff @(posedge clk) begin
    if (reset)
        fb_page <= 1'b0;
    else if (sel_ctrl & wr & be[1] & ~cpu_addr[3] & (cpu_addr[2:0] == 3'd7) & cpu_din[15])
        fb_page <= ~cpu_din[14];
    else if (vblank_start & ~video_control[7])
        fb_page <= ~fb_page;
end

always_ff @(posedge clk) begin
    if (reset) begin
        for (int i = 0; i < 8; i++) ctrl[i] <= 8'd0;
    end else if (sel_ctrl & wr & be[1] & (cpu_addr[3] == 1'b0)) begin
        ctrl[cpu_addr[2:0]] <= cpu_din[15:8];
    end
end

// ------------------------------------------------------------------------------------
// VRAM - 0x8000 words
//
// Split into byte lanes so port A gets 68000 UDS/LDS byte enables while port B stays a
// free 16-bit read port for the render pipeline. On real hardware the VCU arbitrates
// CPU and render access to a single RAM; a dual-port BRAM is the FPGA equivalent and
// removes the arbitration entirely.
// ------------------------------------------------------------------------------------
wire [14:0] vram_cpu_addr = cpu_addr[14:0];
wire        vram_we       = sel_vram & wr;
wire [15:0] vram_q;

// Driven by the tilemap fetch below.
logic [14:0] vram_rd_addr;
wire  [15:0] vram_rd_q;

vcu_ram16 #(.WIDTHAD(15)) vram(
    .clk(clk),
    .addr_a(vram_cpu_addr),
    .data_a(cpu_din),
    .be_a({vram_we & be[1], vram_we & be[0]}),
    .q_a(vram_q),

    .addr_b(vram_rd_addr),
    .q_b(vram_rd_q)
);

// ------------------------------------------------------------------------------------
// Upper RAM - 0x2000 words covering sprite RAM, scratch RAM and scroll RAM
//
// Kept as one contiguous block because that is exactly how the 68000 sees it; Rastan
// Saga 2 RAM-tests straight through the sprite/scratch boundary.
// ------------------------------------------------------------------------------------
wire [12:0] upper_cpu_addr = cpu_addr[12:0];
wire        upper_we       = sel_upper & wr;
wire [15:0] upper_q;

// The scroll fetch and the sprite rasteriser must not share this RAM's single read port.
// The read path is two cycles deep - `upper_sp_addr` is a register and the RAM registers
// its output again - so a capture state consumes the data for the address set TWO states
// earlier. Any stall of the sprite engine (holding `upper_sp_addr` still while another
// fetcher borrows the port) breaks that pipeline: on resume `upper_rd_q` carries data for
// the current address, not the one two states back, and the next capture latches a wrong
// word into a sprite field. Stalling cannot repair this, because stalling is what breaks it.
//
// So the contention is removed. Scroll RAM (word 0x1C00-0x1FFF of this window) gets its
// own small RAM, written through from the CPU port in parallel with the main array, so each
// fetcher has a private read port and neither ever stalls. The CPU still reads the main
// array, so the shadow can never be seen and cannot go stale. Two extra M10K blocks.
logic [12:0] upper_sp_addr;
logic [12:0] scroll_rd_addr;

wire  [12:0] upper_rd_addr = upper_sp_addr;
wire  [15:0] upper_rd_q;

vcu_ram16 #(.WIDTHAD(13)) upper_ram(
    .clk(clk),
    .addr_a(upper_cpu_addr),
    .data_a(cpu_din),
    .be_a({upper_we & be[1], upper_we & be[0]}),
    .q_a(upper_q),

    .addr_b(upper_rd_addr),
    .q_b(upper_rd_q)
);

// Write-through shadow of the scroll block (words 0x1C00-0x1FFF), so the per-line scroll
// fetch has a read port of its own. Written only; never read by the CPU.
wire [15:0] scroll_rd_q;
vcu_ram16 #(.WIDTHAD(10)) scroll_ram(
    .clk(clk),
    .addr_a(upper_cpu_addr[9:0]),
    .data_a(cpu_din),
    .be_a({2{upper_cpu_addr[12:10] == 3'b111}} & {upper_we & be[1], upper_we & be[0]}),
    .q_a(),

    .addr_b(scroll_rd_addr[9:0]),
    .q_b(scroll_rd_q)
);

// ------------------------------------------------------------------------------------
// CPU read mux
// ------------------------------------------------------------------------------------
reg sel_vram_r, sel_upper_r, sel_ctrl_r;
reg [2:0] ctrl_idx_r;

always_ff @(posedge clk) begin
    sel_vram_r  <= sel_vram;
    sel_upper_r <= sel_upper;
    sel_ctrl_r  <= sel_ctrl;
    ctrl_idx_r  <= cpu_addr[2:0];
end

always_comb begin
    if (sel_fb)           cpu_dout = fb_cpu_dout;   // held until fb_cpu_ack releases DTACK
    else if (sel_vram_r)  cpu_dout = vram_q;
    else if (sel_upper_r) cpu_dout = upper_q;
    else if (sel_ctrl_r)  cpu_dout = {ctrl[ctrl_idx_r], 8'h00};
    else                  cpu_dout = 16'hffff;
end

// ------------------------------------------------------------------------------------
// Interrupt generation
//
// MAME's model, which it flags as a guess (the real outputs are encoded and acknowledged
// through an external PAL and flip-flops that MAME does not emulate):
//
//   start of vblank : framebuffer clear/flip/sprite raster, then INTH asserts
//   +8 scanlines    : INTH clears, INTL asserts
//   end of vblank   : INTL clears
//
// MAME hooks both as HOLD_LINE, so the line also drops when the CPU acknowledges. That
// matters: a pure level stays asserted for its whole window, so the moment the handler
// executes RTE the 68000 takes the same interrupt again, over and over until the window
// ends. On a board whose INTL sits above INTH in priority (crimec: INTH = IRQ5, INTL =
// IRQ3) the re-entered low handler runs with the mask at its own level and hides the high
// one entirely. MAME takes each level about once per frame, which is the signature of an
// acknowledge clearing the source.
//
// So the sources are cleared on acknowledge as well as on their scheduled deassert. The
// 68000 signals that with FC=7 and the level on A3-A1; TaitoB.sv decodes it against the
// per-game INTH/INTL levels and pulses inth_ack/intl_ack here.
// ------------------------------------------------------------------------------------
reg [3:0] vbl_line;      // scanlines since the start of vblank
reg       inth_win;      // inside the INTH window; separate from the inth output,
                         // which an acknowledge can clear early

always_ff @(posedge clk) begin
    prev_vblank <= vblank;
    prev_vcnt0  <= vcnt[0];

    if (reset) begin
        inth        <= 1'b0;
        intl        <= 1'b0;
        vbl_line    <= 4'd0;
        inth_win    <= 1'b0;
    end else begin
        if (vblank_start) begin
            inth     <= 1'b1;
            intl     <= 1'b0;
            vbl_line <= 4'd0;
            inth_win <= 1'b1;
        end else if (inth_win & line_tick) begin
            // Keyed on inth_win, NOT on the inth output. Using the output as the phase
            // state works only while nothing else can clear it - and the acknowledge
            // below now does. With `inth & line_tick` the counter stopped the moment the
            // CPU took IRQ INTH, so the handover never happened and INTL was never
            // asserted at all: crimec went from 2016 L3 / 30 L5 to 0 L3 / 1366 L5.
            if (vbl_line == 4'd7) begin
                inth     <= 1'b0;
                intl     <= 1'b1;
                inth_win <= 1'b0;
            end else begin
                vbl_line <= vbl_line + 4'd1;
            end
        end

        if (vblank_end) begin
            intl <= 1'b0;
        end

        // Acknowledge clears the source, so one assertion delivers exactly one interrupt.
        // Placed after the scheduled transitions so that an acknowledge arriving in the
        // same cycle INTL is raised still leaves it raised.
        if (inth_ack) inth <= 1'b0;
        if (intl_ack) intl <= 1'b0;
    end
end

// ------------------------------------------------------------------------------------
// Render pipeline (M3.2 text layer, M3.3 BG/FG)
//
// Three tilemap layers share one fetch sequencer that runs once per 8 displayed pixels:
//
//   BG  64x64 map of 16x16 tiles, opaque,            scrolled from scroll plane 1
//   FG  64x64 map of 16x16 tiles, pen 0 transparent, scrolled from scroll plane 0
//   TX  64x32 map of  8x8  tiles, pen 0 transparent, not scrolled at all
//
// One group costs 5 VRAM reads (TX word, BG code+attr, FG code+attr) and 3 gfx ROM reads.
// At 8 clk per pixel that is a 64 clk budget against roughly 7 + 3 x latency, so the
// sequencer stays strictly serial - no bursting, no caching, no speculation. `fetch_miss`
// counts any group that did not finish in time, which is the only cheap way to tell a
// bandwidth problem apart from a decode problem.
//
// TWO GROUPS AHEAD, NOT ONE. Horizontal scroll is not a multiple of 8, so a displayed
// 8-pixel group straddles two 8-pixel groups in layer space. Each layer therefore keeps
// `cur` (layer group k + scroll/8) and `nxt` (the one after it) and selects across the
// pair using the sub-group offset scroll[2:0]. Having both valid at the start of a line
// needs the prefetch to run two groups ahead, which also makes the end-of-line redirect
// cover the last two groups instead of the last one.
// ------------------------------------------------------------------------------------
localparam [8:0] H_TOTAL = 9'd448;
localparam [8:0] V_TOTAL = 9'd253;
localparam [8:0] V_START = 9'd16;    // first visible bitmap line; see taitob_video_timing.sv

// Scroll RAM lives in upper RAM: device byte 13800 -> word 09C00 -> upper index 1C00.
// Plane 0 (FG) occupies 1C00-1DFF, plane 1 (BG) 1E00-1FFF, as {x,y} word pairs per line.
localparam [12:0] SCROLL_FG = 13'h1C00;
localparam [12:0] SCROLL_BG = 13'h1E00;

// Fetch coordinates: two groups ahead of the beam, wrapping onto the next line.
wire [8:0] fetch_h_raw = hcnt + 9'd16;
wire       line_wrap   = fetch_h_raw >= H_TOTAL;
wire [8:0] fetch_h     = line_wrap ? (fetch_h_raw - H_TOTAL) : fetch_h_raw;
wire [8:0] next_v      = (vcnt == V_TOTAL - 9'd1) ? 9'd0 : (vcnt + 9'd1);
wire [8:0] fetch_v_raw = line_wrap ? next_v : vcnt;

// Flip mirrors both axes. The vertical half is done here, at the source: the line composited
// during raster line R is displayed on line R+1 (the horizontal mirror below costs one line),
// so line R must be sourced from 255 - (R+1) = 254 - R. Visible rows 16..239 map onto source
// rows 239..16, which is the same set, so nothing moves off screen.
wire [8:0] fetch_v     = flip ? (9'd254 - fetch_v_raw) : fetch_v_raw;

// ------------------------------------------------------------------------------------
// Per-line scroll fetch
//
// Scroll is block-granular: lines_per_block = 256 - ctrl[2 + plane], and every line in a
// block uses the pair stored at the block's FIRST line. Rather than divide by a runtime
// lines_per_block, walk it: a counter says how many lines of the current block have been
// used and the block base only moves when it fills. Resetting on bitmap line 0 anchors
// the block grid where MAME's loop anchors it.
//
// The fetch runs once per line at hcnt 400 - inside hblank, after the last fetch that
// still belongs to this line (hcnt 424) and before the first that belongs to the next
// one (hcnt 432).
// ------------------------------------------------------------------------------------
wire [8:0] fg_lpb = 9'd256 - {1'b0, fg_scroll_reg};
wire [8:0] bg_lpb = 9'd256 - {1'b0, bg_scroll_reg};

reg  [7:0] fg_blk_base, bg_blk_base;
reg  [8:0] fg_blk_cnt,  bg_blk_cnt;

wire       fg_new_blk = (next_v == 9'd0) | (fg_blk_cnt == fg_lpb);
wire       bg_new_blk = (next_v == 9'd0) | (bg_blk_cnt == bg_lpb);
wire [7:0] fg_base_n  = (next_v == 9'd0) ? 8'd0 : (fg_new_blk ? next_v[7:0] : fg_blk_base);
wire [7:0] bg_base_n  = (next_v == 9'd0) ? 8'd0 : (bg_new_blk ? next_v[7:0] : bg_blk_base);
wire [8:0] fg_cnt_n   = fg_new_blk ? 9'd1 : (fg_blk_cnt + 9'd1);
wire [8:0] bg_cnt_n   = bg_new_blk ? 9'd1 : (bg_blk_cnt + 9'd1);

reg [15:0] sx_fg, sy_fg, sx_bg, sy_bg;

// SAMPLE PER BLOCK, NOT PER LINE.
//
// The walk below visits every line, but a plane's scroll pair is only COMMITTED when that
// plane's block begins, plus once at the first visible line. Re-committing every line made
// the chip honour a CPU write that lands mid-frame, which MAME cannot do - it reads
// scrollram once per block at screen_update (tc0180vcu.cpp: set_scrollx/set_scrolly then
// draw, per block, clipped by min_y).
//
// WHAT IS MEASURED HERE, AND WHAT IS NOT. A scanline-binned tap over 5000 frames of ashura
// in MAME: FGx/BGx are written from the vblank ISR, pinned at line 10 with 0.6 lines of
// jitter, while FGy/BGy are written from the main loop - 1041 updates out of 1041 inside
// active display, wandering 14.3 lines between them. That much is measurement. A video
// capture of the real PCB then showed no tear where this core showed one - but ashura's Y
// moves only 1-2 px, about once every five frames, and a seam that small at a wandering
// line can sit below what a capture resolves. "No tear seen" is weaker than "no tear".
//
// The test that would settle it, unrun: ashura's attract loop resets scroll mid-frame by
// 437 px at visible line 41, on a frame with zero VRAM writes, about 36 s after boot and
// every 41 s after. A per-line chip must render that one frame as a single picture split
// into two halves offset by 437 px, which no capture could miss.
//
// Sampling at next_v == V_START rather than at bitmap line 0 is deliberate: every other
// game in the set writes scroll during vblank, and line 0 is early enough in vblank to miss
// some of those writes. Committing at the first visible line takes the post-write value, so
// those games are bit-identical to the per-line behaviour they had before.
//
// The flags are PER PLANE. FG and BG can carry different lines_per_block, and a shared
// trigger would let a BG block boundary commit a mid-frame write to the FG pair.
//
// Only the commits are gated - the address walk and the RAM accesses are unchanged, so this
// costs no cycles and moves no other timing.
reg fg_smp, bg_smp;

reg [2:0] sstate;
localparam [2:0] S_IDLE = 3'd7;

always_ff @(posedge clk) begin
    if (reset) begin
        sstate        <= S_IDLE;
        scroll_rd_addr <= 13'd0;
        sx_fg <= 16'd0; sy_fg <= 16'd0;
        sx_bg <= 16'd0; sy_bg <= 16'd0;
        fg_blk_base <= 8'd0; fg_blk_cnt <= 9'd1;
        bg_blk_base <= 8'd0; bg_blk_cnt <= 9'd1;
        fg_smp <= 1'b0; bg_smp <= 1'b0;
    end else begin
        case (sstate)
            S_IDLE: if (ce_pixel && hcnt == 9'd400) begin
                fg_blk_base   <= fg_base_n; fg_blk_cnt <= fg_cnt_n;
                bg_blk_base   <= bg_base_n; bg_blk_cnt <= bg_cnt_n;
                fg_smp        <= fg_new_blk | (next_v == V_START);
                bg_smp        <= bg_new_blk | (next_v == V_START);
                scroll_rd_addr <= SCROLL_FG + {4'd0, fg_base_n, 1'b0};
                sstate        <= 3'd0;
            end
            // upper_rd_addr is a register and the RAM registers it again, so the data for
            // the address set in state N can be read in state N+1.
            3'd0: begin scroll_rd_addr <= SCROLL_FG + {4'd0, fg_blk_base, 1'b0} + 13'd1; sstate <= 3'd1; end
            3'd1: begin scroll_rd_addr <= SCROLL_BG + {4'd0, bg_blk_base, 1'b0};         sstate <= 3'd2; if (fg_smp) sx_fg <= scroll_rd_q; end
            3'd2: begin scroll_rd_addr <= SCROLL_BG + {4'd0, bg_blk_base, 1'b0} + 13'd1; sstate <= 3'd3; if (fg_smp) sy_fg <= scroll_rd_q; end
            3'd3: begin sstate <= 3'd4;   if (bg_smp) sx_bg <= scroll_rd_q; end
            3'd4: begin sstate <= S_IDLE; if (bg_smp) sy_bg <= scroll_rd_q; end
            default: sstate <= S_IDLE;
        endcase
    end
end

// ------------------------------------------------------------------------------------
// Layer coordinates for the group being fetched
//
// SCROLL IS SUBTRACTED, NOT ADDED. MAME writes set_scrollx(0, -scrollram_x), and the net
// effect of a MAME tilemap scroll is that the pixel shown at screen x comes from tilemap
// x + value - so with value = -scrollram_x the layer coordinate is screen_x - scrollram_x.
//
// The 64x64 map of 16x16 tiles wraps at 1024 on both axes, so the subtraction underflowing
// is not a special case - it is the wrap.
// ------------------------------------------------------------------------------------
wire [9:0] bg_lx = {1'b0, fetch_h} - sx_bg[9:0];
wire [9:0] bg_ly = {1'b0, fetch_v} - sy_bg[9:0];
wire [9:0] fg_lx = {1'b0, fetch_h} - sx_fg[9:0];
wire [9:0] fg_ly = {1'b0, fetch_v} - sy_fg[9:0];

assign dbg_scroll = {sy_bg, sx_bg, sy_fg, sx_fg};

wire [11:0] bg_index = {bg_ly[9:4], bg_lx[9:4]};   // TILEMAP_SCAN_ROWS, 64 wide
wire [11:0] fg_index = {fg_ly[9:4], fg_lx[9:4]};
wire [10:0] tx_index = {fetch_v[7:3], fetch_h[8:3]};

// ------------------------------------------------------------------------------------
// Fetch sequencer
//
// TIMING BUDGET - this is the tight part of the whole design. A group is 8 pixels, and at
// ce_pixel 13.582 MHz that is 31 clk cycles. Every group needs three SDRAM reads (TX, BG,
// FG) and sdram.sv allows one outstanding request per channel, so they are strictly
// serial; a round trip is ~6 clk cycles (the controller is back in STATE_IDLE 8 clk_sdr
// after issuing, and clk_sdr is 2x clk).
//
// Laid out naively - six VRAM reads, then issue/wait three times with a separate issue
// state each - the cost is 9 + 3*RT: 27 cycles at RT=6 and 33 at RT=8. The budget is 31,
// so it fits only while nothing perturbs it, and a single transaction from another channel
// in flight at the wrong moment pushes it over. A group that misses its deadline redisplays
// the previous group's pixels (see `fetch_miss`), which on screen is one wrong 8-pixel
// column for one frame - sporadic, and only visible with realistic SDRAM latency.
//
// So the sequencer overlaps instead: the TX read is launched as soon as its address is
// known (T_V3) and runs underneath the remaining VRAM reads, and each wait state issues
// the next request in the cycle it accepts the previous result. That gives 3 + 3*RT - 21
// cycles at RT=6, 27 at RT=8 - which leaves real slack rather than none.
// ------------------------------------------------------------------------------------
localparam [3:0] T_IDLE = 4'd0,  T_V1  = 4'd1,  T_V2  = 4'd2,  T_V3 = 4'd3,
                 T_V4   = 4'd4,  T_V5  = 4'd5,  T_V6  = 4'd6,
                 T_TXD  = 4'd8,  T_BGD = 4'd10, T_FGD = 4'd12,
                 T_DONE = 4'd13;

reg [3:0] fstate;
reg [31:0] dbg_fetch_r;
assign dbg_fetch = dbg_fetch_r;

// Coordinates are latched at the start of the group so the sequencer is immune to hcnt
// and vcnt moving underneath it.
//
// THE MAP INDEX MUST BE LATCHED TOO, not just the intra-tile part. hcnt increments on the
// very ce_pixel edge that starts the group, so anything the sequencer evaluates in a later
// state sees hcnt + 1. Leaving the index combinational splits it from the line and half
// latched here: the two disagree exactly when fetch_h + scroll lands on a 16-pixel tile
// boundary, i.e. when scroll[3:0] is 7 or 15, and the layer then samples one tile column
// to the right on every other group. It renders perfectly at every other scroll value,
// which is what makes it worth a comment.
reg  [2:0] f_tx_ln;
reg  [3:0] f_bg_ly, f_fg_ly;
reg        f_bg_hx, f_fg_hx;
reg [11:0] f_bg_index, f_fg_index;

reg [15:0] tx_word_r, bg_code_r, bg_attr_r, fg_code_r, fg_attr_r;

// TX map entry: bits 10-0 tile index, bit 11 selects ctrl[4]/ctrl[5] as the high bank,
// bits 15-12 colour code.
wire  [7:0] tx_bank = tx_word_r[11] ? tx_bank1 : tx_bank0;
wire [18:0] tx_tile = {tx_bank, tx_word_r[10:0]};

// BG/FG attribute word: bits 5-0 colour, bit 6 flip X, bit 7 flip Y.
wire       bg_fx = bg_attr_r[6];
wire       bg_fy = bg_attr_r[7];
wire       fg_fx = fg_attr_r[6];
wire       fg_fy = fg_attr_r[7];
wire [3:0] bg_ly_e = bg_fy ? ~f_bg_ly : f_bg_ly;
wire [3:0] fg_ly_e = fg_fy ? ~f_fg_ly : f_fg_ly;
wire       bg_hx_e = bg_fx ? ~f_bg_hx : f_bg_hx;
wire       fg_hx_e = fg_fx ? ~f_fg_hx : f_fg_hx;

// 8x8 char = 32 interleaved bytes, 4 per row.
wire [21:0] tx_gfx_a = {tx_tile[16:0], 5'd0} + {17'd0, f_tx_ln, 2'd0};
// 16x16 tile = 128 interleaved bytes as four 8x8 sub-blocks in the order
// (rows 0-7, cols 0-7), (rows 0-7, cols 8-15), (rows 8-15, cols 0-7), (rows 8-15, cols 8-15),
// so the sub-block index is {line[3], half} and the whole address is one concatenation.
// FIFTEEN bits of tile code, not fourteen. 14 bits reaches 16384 tiles = 2 MiB, which is
// every set in this family except silentd, whose graphics region is 4 MiB. With the code
// truncated, silentd's upper-half tiles came out as unrelated artwork in the right
// layout - a mosaic, not a blank or a shifted image. the graphics-region mask still wraps the result
// to each board's own region size, so a 2 MiB board is unaffected by the extra bit.
wire [21:0] bg_gfx_a = {bg_code_r[14:0], bg_ly_e[3], bg_hx_e, bg_ly_e[2:0], 2'b00};
wire [21:0] fg_gfx_a = {fg_code_r[14:0], fg_ly_e[3], fg_hx_e, fg_ly_e[2:0], 2'b00};

// Pending group: filled by the sequencer, handed to `nxt` at the group boundary.
reg [31:0] pend_tx, pend_bg, pend_fg;
reg  [7:0] pend_tx_c, pend_bg_c, pend_fg_c;
reg        pend_bg_fx, pend_fg_fx;

// The displayed pair.
reg [31:0] cur_tx, nxt_tx, cur_bg, nxt_bg, cur_fg, nxt_fg;
reg  [7:0] cur_tx_c, nxt_tx_c, cur_bg_c, nxt_bg_c, cur_fg_c, nxt_fg_c;
reg        cur_bg_fx, nxt_bg_fx, cur_fg_fx, nxt_fg_fx;

reg  primed;
wire group_end = ce_pixel && (hcnt[2:0] == 3'd7);

always_ff @(posedge clk) begin
    if (reset) begin
        fstate       <= T_IDLE;
        gfx_req      <= 1'b0;
        vram_rd_addr <= 15'd0;
        fetch_miss   <= 16'd0;
        primed       <= 1'b0;
        cur_tx <= 32'd0; nxt_tx <= 32'd0; pend_tx <= 32'd0;
        cur_bg <= 32'd0; nxt_bg <= 32'd0; pend_bg <= 32'd0;
        cur_fg <= 32'd0; nxt_fg <= 32'd0; pend_fg <= 32'd0;
    end else begin
        case (fstate)
            T_IDLE: if (ce_pixel && hcnt[2:0] == 3'd0) begin
                f_tx_ln <= fetch_v[2:0];
                f_bg_ly <= bg_ly[3:0];  f_bg_hx <= bg_lx[3];  f_bg_index <= bg_index;
                f_fg_ly <= fg_ly[3:0];  f_fg_hx <= fg_lx[3];  f_fg_index <= fg_index;
                vram_rd_addr <= tx_page + {4'd0, tx_index};
                dbg_fetch_r  <= {1'b0, fg_lx, fg_index, fetch_h};
                fstate       <= T_V1;
            end

            // Five VRAM reads, pipelined one address per cycle with the data trailing by
            // one state. The render port is a dedicated BRAM port, so none of this ever
            // contends with the 68000 - a deliberate deviation, not a claim about the chip.
            // VRAM is external on the real board, so it is one bus and the VCU must grant
            // the CPU slots. Measured cost of not modelling that: the renderer takes 44,800
            // of the 71,680 active-display slots and the 68000 asks for about 44 of the rest,
            // so slot arbitration would cost 0.06% of its cycles in a typical frame. Left
            // out because it cannot account for any known residual; it only reaches a few
            // percent during a stage load.
            T_V1: begin vram_rd_addr <= bg_code_page + {3'd0, f_bg_index}; fstate <= T_V2; end
            T_V2: begin vram_rd_addr <= bg_attr_page + {3'd0, f_bg_index}; fstate <= T_V3; tx_word_r <= vram_rd_q; end
            // The TX graphics address only needs tx_word_r, which lands here - so the TX
            // SDRAM read is launched now and runs in the shadow of the four VRAM reads
            // still to come, instead of after them. See the budget note above.
            T_V3: begin
                vram_rd_addr <= fg_code_page + {3'd0, f_fg_index}; fstate <= T_V4;
                bg_code_r    <= vram_rd_q;
                gfx_addr     <= tx_gfx_a;
                gfx_req      <= ~gfx_req;
                pend_tx_c    <= cb_tx + {4'd0, tx_word_r[15:12]};
            end
            T_V4: begin vram_rd_addr <= fg_attr_page + {3'd0, f_fg_index}; fstate <= T_V5; bg_attr_r <= vram_rd_q; end
            T_V5: begin fstate <= T_V6;  fg_code_r <= vram_rd_q; end
            T_V6: begin fstate <= T_TXD; fg_attr_r <= vram_rd_q; end

            // Each wait state issues the next request in the same cycle it takes delivery
            // of the previous one, so the three round-trips are back to back with no idle
            // cycle between them. bg_gfx_a is settled since T_V5 and fg_gfx_a since T_V6,
            // and gfx_addr is registered at issue, so both are stable when used.
            T_TXD: if (gfx_req == gfx_ack) begin
                pend_tx    <= gfx_q;
                gfx_addr   <= bg_gfx_a;
                gfx_req    <= ~gfx_req;
                pend_bg_c  <= cb_bg + {2'd0, bg_attr_r[5:0]};
                pend_bg_fx <= bg_fx;
                fstate     <= T_BGD;
            end

            T_BGD: if (gfx_req == gfx_ack) begin
                pend_bg    <= gfx_q;
                gfx_addr   <= fg_gfx_a;
                gfx_req    <= ~gfx_req;
                pend_fg_c  <= cb_fg + {2'd0, fg_attr_r[5:0]};
                pend_fg_fx <= fg_fx;
                fstate     <= T_FGD;
            end

            T_FGD: if (gfx_req == gfx_ack) begin pend_fg <= gfx_q; fstate <= T_DONE; end

            T_DONE: ;   // wait for the group boundary
            default: fstate <= T_IDLE;
        endcase

        if (group_end) begin
            cur_tx <= nxt_tx; nxt_tx <= pend_tx;
            cur_bg <= nxt_bg; nxt_bg <= pend_bg;
            cur_fg <= nxt_fg; nxt_fg <= pend_fg;

            cur_tx_c <= nxt_tx_c; nxt_tx_c <= pend_tx_c;
            cur_bg_c <= nxt_bg_c; nxt_bg_c <= pend_bg_c;
            cur_fg_c <= nxt_fg_c; nxt_fg_c <= pend_fg_c;

            cur_bg_fx <= nxt_bg_fx; nxt_bg_fx <= pend_bg_fx;
            cur_fg_fx <= nxt_fg_fx; nxt_fg_fx <= pend_fg_fx;

            fstate <= T_IDLE;

            // Missed-deadline meter. A group that has not finished by its boundary shows
            // the previous group's pixels again - a stale 8-pixel column that only turns
            // up under bus contention and is otherwise very hard to attribute. `primed`
            // suppresses the unavoidable misses right after reset, before the pipeline
            // has been filled; without it the meter never reads zero and stops being a
            // signal at all.
            if (fstate == T_DONE) primed <= 1'b1;
            else if (primed && ~hblank && ~vblank) fetch_miss <= fetch_miss + 16'd1;
        end
    end
end

// ------------------------------------------------------------------------------------
// Pixel extraction
// ------------------------------------------------------------------------------------
assign dbg_pair = {nxt_fg, cur_fg};

wire [2:0] px = hcnt[2:0];

wire [3:0] bg_pix, fg_pix, tx_pix;
wire [7:0] bg_col, fg_col, tx_col;

vcu_tile_pix bg_pix_sel(
    .cur(cur_bg), .nxt(nxt_bg), .cur_fx(cur_bg_fx), .nxt_fx(nxt_bg_fx),
    .cur_col(cur_bg_c), .nxt_col(nxt_bg_c),
    .sh(3'd0 - sx_bg[2:0]), .o(px), .pix(bg_pix), .col(bg_col)
);

vcu_tile_pix fg_pix_sel(
    .cur(cur_fg), .nxt(nxt_fg), .cur_fx(cur_fg_fx), .nxt_fx(nxt_fg_fx),
    .cur_col(cur_fg_c), .nxt_col(nxt_fg_c),
    .sh(3'd0 - sx_fg[2:0]), .o(px), .pix(fg_pix), .col(fg_col)
);

// The text layer has no scroll register anywhere in MAME, so its sub-group offset is
// fixed at zero and `nxt_tx` is never selected.
vcu_tile_pix tx_pix_sel(
    .cur(cur_tx), .nxt(nxt_tx), .cur_fx(1'b0), .nxt_fx(1'b0),
    .cur_col(cur_tx_c), .nxt_col(nxt_tx_c),
    .sh(3'd0), .o(px), .pix(tx_pix), .col(tx_col)
);

// ------------------------------------------------------------------------------------
// Sprite rasteriser
//
// 408 entries of 16 bytes at device offset 0x10000, walked BACKWARDS so entry 0 ends up on
// top.
//
// RASTERISED ACROSS THE FRAME INTO THE BACK PAGE, not in one shot during vblank. MAME does
// the latter, but a full 408-sprite list does not fit in vblank: vblank is 103 936 clocks
// and a 1:1 sprite costs about 300, so the list needs roughly 122 000. Drawing across the
// whole frame gives 906 752, nine times the headroom, at the cost of one frame of sprite
// latency against the tilemaps.
//
// That is almost certainly what the real chip does: a one-shot-at-vblank design would need
// only one framebuffer page, and this chip has two, with register bits to pin and to stop
// flipping them. MAME's own TODO admits its sprites "are not in perfect sync with the
// background".
//
// The sprite engine owns the upper-RAM read port outright and never stalls: the scroll
// fetch reads a write-through shadow RAM instead. See the note by `upper_sp_addr` for why
// sharing the port cannot be made correct by stalling.
//
// The gfx fetch uses its own 64-bit SDRAM channel. A 16x16 tile is 128 interleaved bytes as
// four 8x8 sub-blocks, so one 64-bit read covers two consecutive source rows of one half;
// a 1:1 sprite therefore costs 16 reads rather than the 32 a 32-bit channel would need.
// That halving is the whole reason the vblank budget closes at all.
//
// ZOOM. MAME's own comment calls its zoom wrong ("chopped up into 16x16 sections instead of
// one sprite"), so there is no trustworthy reference for zoomed output. What is implemented
// here is the geometry MAME computes (zx/zy per sub-sprite, and the chained big-sprite
// walk) with nearest-neighbour source sampling. At 1:1 - which is what pbobble uses and
// what the reference model checks exactly - the sampling degenerates to a straight copy.
// ------------------------------------------------------------------------------------

// Destination clip. MAME draws sprites with the screen's visible area as the cliprect, so
// nothing outside it ever reaches the framebuffer.
localparam int CLIP_X0 = 0,  CLIP_X1 = 319;
localparam int CLIP_Y0 = 16, CLIP_Y1 = 239;

// Source step per destination pixel, 16.16, for a destination extent of 1..16 pixels.
// (16 << 16) / n. Only 16 values are possible, so this is a table rather than a divider.
// MAME's drawgfxzoom starts the source accumulator at (dstwidth-1)*dx when the sprite is
// flipped and then steps DOWNWARD, so the source index for destination pixel i is
// ((n-1-i)*dx)>>16 - not 15 minus ((i*dx)>>16). The two agree only at n == 16, which is why
// no unzoomed sprite ever shows the difference and every zoomed flipped one does.
// zbase(n) = (n-1)*zstep(n), a pure function of n, so this costs a table and no multiplier.
function automatic [20:0] zbase(input [4:0] n);
    case (n)
        5'd1:  zbase = 21'd0;
        5'd2:  zbase = 21'd524288;
        5'd3:  zbase = 21'd699050;
        5'd4:  zbase = 21'd786432;
        5'd5:  zbase = 21'd838860;
        5'd6:  zbase = 21'd873810;
        5'd7:  zbase = 21'd898776;
        5'd8:  zbase = 21'd917504;
        5'd9:  zbase = 21'd932064;
        5'd10: zbase = 21'd943713;
        5'd11: zbase = 21'd953250;
        5'd12: zbase = 21'd961191;
        5'd13: zbase = 21'd967908;
        5'd14: zbase = 21'd973674;
        5'd15: zbase = 21'd978670;
        default: zbase = 21'd983040;   // 15 * 65536, i.e. 1:1
    endcase
endfunction

function automatic [20:0] zstep(input [4:0] n);
    case (n)
        5'd1:  zstep = 21'd1048576;
        5'd2:  zstep = 21'd524288;
        5'd3:  zstep = 21'd349525;
        5'd4:  zstep = 21'd262144;
        5'd5:  zstep = 21'd209715;
        5'd6:  zstep = 21'd174762;
        5'd7:  zstep = 21'd149796;
        5'd8:  zstep = 21'd131072;
        5'd9:  zstep = 21'd116508;
        5'd10: zstep = 21'd104857;
        5'd11: zstep = 21'd95325;
        5'd12: zstep = 21'd87381;
        5'd13: zstep = 21'd80659;
        5'd14: zstep = 21'd74898;
        5'd15: zstep = 21'd69905;
        default: zstep = 21'd65536;      // 16, i.e. 1:1
    endcase
endfunction

typedef enum bit [4:0] {
    SP_IDLE,
    SP_A0, SP_A1, SP_A2, SP_A3, SP_A4, SP_A5, SP_A6, SP_A7,
    SP_DECODE, SP_CLIP,
    SP_ROW, SP_FETCH_L, SP_WAIT_L, SP_FETCH_R, SP_WAIT_R,
    SP_GROUP, SP_GROUP2, SP_PIXEL, SP_WRITE,
    SP_NEXT
} spr_state_t;

spr_state_t spstate;

reg  [8:0] spr_i;                     // sprite index, counted down from 407
reg [15:0] s_code, s_color, s_xraw, s_yraw, s_zoom, s_cnts;

// Big-sprite chain state, carried across entries.
reg        big_sprite;
reg  [7:0] x_num, y_num, x_no, y_no;
reg signed [11:0] xlatch, ylatch;   // sign-adjusted, as MAME latches them
reg  [7:0] zoomxlatch, zoomylatch;

// Decoded placement for the sub-sprite being drawn.
reg signed [11:0] s_x, s_y;
reg         [4:0] s_zx, s_zy;
reg        [20:0] xbase, ybase;
reg        [15:0] heads_acc, subs_acc;
reg        [23:0] cyc_acc;
reg         [5:0] s_col;
reg               s_fx, s_fy;
reg        [14:0] s_tile;   // 15 bits: see bg_gfx_a
reg        [20:0] xstep, ystep;

reg  [4:0] dy;                        // destination row within this sub-sprite
reg [20:0] yacc, xacc;
reg  [3:0] srow;
reg  [2:0] grp;                       // destination column group (8 pixels each)
reg  [2:0] pixj;

// Two 64-bit gfx words: the left and right halves of a source row pair.
reg [63:0] g_lo, g_hi;
reg [18:0] g_tag;   // must match want_tag; a narrow tag aliases two different tiles
reg        g_valid;

wire [18:0] want_tag = {s_tile, srow[3], srow[2:1]};

wire [31:0] wordL = srow[0] ? g_lo[63:32] : g_lo[31:0];
wire [31:0] wordR = srow[0] ? g_hi[63:32] : g_hi[31:0];

// Unpack a row into 16 source pens. Plane 0 is the MSB of the pen and bit 7 of a plane
// byte is the leftmost pixel, exactly as in the tilemap path.
function automatic [3:0] pen_of(input [31:0] w, input [2:0] i);
    pen_of = {w[7 - i], w[15 - i], w[23 - i], w[31 - i]};
endfunction

wire [63:0] src_pen = {
    pen_of(wordR, 3'd7), pen_of(wordR, 3'd6), pen_of(wordR, 3'd5), pen_of(wordR, 3'd4),
    pen_of(wordR, 3'd3), pen_of(wordR, 3'd2), pen_of(wordR, 3'd1), pen_of(wordR, 3'd0),
    pen_of(wordL, 3'd7), pen_of(wordL, 3'd6), pen_of(wordL, 3'd5), pen_of(wordL, 3'd4),
    pen_of(wordL, 3'd3), pen_of(wordL, 3'd2), pen_of(wordL, 3'd1), pen_of(wordL, 3'd0)
};

function automatic [3:0] pen_at(input [63:0] pens, input [3:0] col);
    pen_at = pens[col * 4 +: 4];
endfunction

// ---- decode helpers ------------------------------------------------------------------
wire  [7:0] zoomx_raw = s_zoom[15:8];
wire  [7:0] zoomy_raw = s_zoom[7:0];
wire        start_big = ~big_sprite & (s_cnts != 16'd0);

wire  [7:0] zx_zoom = start_big ? zoomx_raw : zoomxlatch;
wire  [7:0] zy_zoom = start_big ? zoomy_raw : zoomylatch;
// 10-bit signed wrap, as MAME does it: x &= 0x3ff; if (x >= 0x200) x -= 0x400.
function automatic signed [11:0] sign10(input [11:0] v);
    sign10 = (v[9:0] >= 10'h200) ? ({2'b11, v[9:0]}) : ({2'b00, v[9:0]});
endfunction

// MAME latches x AFTER the 10-bit sign adjustment and then adds the sub-sprite offset
// with no further wrap. Latching the raw value and re-wrapping the sum turns a
// sub-sprite that MAME places just off the right edge into one placed far off the left.
wire signed [11:0] x_self = sign10({2'd0, s_xraw[9:0]});
wire signed [11:0] y_self = sign10({2'd0, s_yraw[9:0]});
wire signed [11:0] xl     = start_big ? x_self : xlatch;
wire signed [11:0] yl     = start_big ? y_self : ylatch;

// On the entry that STARTS a chain the sub-sprite index is 0, but x_no/y_no are only
// cleared by the register write in the same cycle - so the combinational offsets below
// have to use the forced value, not the stale register. Reading the register instead
// places the head of every chain using whatever the previous chain left behind.
wire  [7:0] xno_eff = start_big ? 8'd0 : x_no;
wire  [7:0] yno_eff = start_big ? 8'd0 : y_no;

wire [15:0] xm0 = xno_eff * (8'hff - zx_zoom);
wire [15:0] xm1 = (xno_eff + 8'd1) * (8'hff - zx_zoom);
wire [15:0] ym0 = yno_eff * (8'hff - zy_zoom);
wire [15:0] ym1 = (yno_eff + 8'd1) * (8'hff - zy_zoom);

wire [11:0] xo0 = (xm0 + 16'd15) >> 4;
wire [11:0] xo1 = (xm1 + 16'd15) >> 4;
wire [11:0] yo0 = (ym0 + 16'd15) >> 4;
wire [11:0] yo1 = (ym1 + 16'd15) >> 4;

// Chained sub-sprite placement, versus a standalone sprite's own fields.
wire signed [11:0] big_x = xl + $signed({4'd0, xo0[7:0]});
wire signed [11:0] big_y = yl + $signed({4'd0, yo0[7:0]});
wire  [4:0] big_zx = (xo1 - xo0) > 12'd16 ? 5'd16 : (xo1 - xo0);
wire  [4:0] big_zy = (yo1 - yo0) > 12'd16 ? 5'd16 : (yo1 - yo0);

wire  [4:0] one_zx = (9'h100 - {1'b0, zoomx_raw}) >> 4;
wire  [4:0] one_zy = (9'h100 - {1'b0, zoomy_raw}) >> 4;

wire signed [11:0] use_x = (start_big | big_sprite) ? big_x : x_self;
wire signed [11:0] use_y = (start_big | big_sprite) ? big_y : y_self;
wire  [4:0] use_zx = (start_big | big_sprite) ? big_zx : one_zx;
wire  [4:0] use_zy = (start_big | big_sprite) ? big_zy : one_zy;


// ---- destination geometry ------------------------------------------------------------
wire signed [11:0] dst_y  = s_y + {7'd0, dy};
wire        [11:0] dst_x0 = $unsigned(s_x) + {6'd0, grp, 3'd0};

// A sprite whose rectangle misses the visible area entirely costs only its sprite-RAM
// read. That is what makes a mostly-empty 408-entry list cheap, and a real game's list is
// mostly empty.
wire clip_out = (s_zx == 5'd0) || (s_zy == 5'd0)
             || (s_x > CLIP_X1) || ((s_x + {7'd0, s_zx}) <= CLIP_X0)
             || (s_y > CLIP_Y1) || ((s_y + {7'd0, s_zy}) <= CLIP_Y0);

wire row_visible = (dst_y >= CLIP_Y0) && (dst_y <= CLIP_Y1);

wire [20:0] y_src = s_fy ? (ybase - yacc) : yacc;

// ---- 1:1 fast path -------------------------------------------------------------------
// At zx == 16 the eight destination pixels of a group are eight consecutive source
// columns, so the whole group is a wire selection instead of eight accumulator steps.
// This is the case every unzoomed sprite takes, which is all of them in pbobble.
wire unity_x = (s_zx == 5'd16);

logic [79:0] grp_pix;
logic  [7:0] grp_mask;

always_comb begin
    grp_pix  = 80'd0;
    grp_mask = 8'd0;
    for (int j = 0; j < 8; j++) begin
        automatic logic [4:0]  ddx = {1'b0, grp[0], 3'd0} + {2'd0, j[2:0]};
        automatic logic [11:0] dxa = $unsigned(s_x) + {7'd0, ddx};
        automatic logic [3:0]  sc  = s_fx ? (4'd15 - ddx[3:0]) : ddx[3:0];
        automatic logic [3:0]  pn  = pen_at(src_pen, sc);
        if ((ddx < s_zx) && (pn != 4'd0)
            && ($signed(dxa) >= CLIP_X0) && ($signed(dxa) <= CLIP_X1)) begin
            grp_pix[j*10 +: 10] = {s_col, pn};
            grp_mask[j]         = 1'b1;
        end
    end
end

// ---- zoomed path, one destination pixel per cycle --------------------------------------
reg [79:0] acc_pix;
reg  [7:0] acc_mask;

wire [20:0] z_xsrc     = s_fx ? (xbase - xacc) : xacc;
wire  [3:0] z_scol     = z_xsrc[19:16];
wire  [3:0] z_pen      = pen_at(src_pen, z_scol);
wire [11:0] z_dstx     = $unsigned(s_x) + {6'd0, grp, pixj};
wire        z_keep     = (z_pen != 4'd0) && ({grp, pixj} < s_zx)
                      && ($signed(z_dstx) >= CLIP_X0) && ($signed(z_dstx) <= CLIP_X1);

// ---- the engine ------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (reset) begin
        spstate        <= SP_IDLE;
        spr_req        <= 1'b0;
        fb_wr_valid    <= 1'b0;
        big_sprite     <= 1'b0;
        g_valid        <= 1'b0;
        sprite_overrun <= 16'd0;
        sprite_early   <= 16'd0;
        chain_heads    <= 16'd0;
        chain_subs     <= 16'd0;
        sprite_cycles  <= 24'd0;
        cyc_acc        <= 24'd0;
        heads_acc      <= 16'd0;
        subs_acc       <= 16'd0;
    end else begin
        fb_wr_valid <= 1'b0;

        // A raster still running when the next one is due has overrun its whole frame.
        // This counter is what settled the one-shot-versus-continuous question above, and
        // it stays because the answer depends on how full a game's sprite list gets.
        if (vblank_start && spstate != SP_IDLE)
            sprite_overrun <= sprite_overrun + 16'd1;

        // A walk that STOPS EARLY is invisible to the overrun counter: the counter asks
        // whether the engine was still busy at vblank, and an engine that gave up is idle,
        // which is what a completed walk looks like. Count the other failure separately.
        // The only intended exit is at entry 0, so idle with spr_i != 0 means the state
        // machine left through `default` or was otherwise diverted, and every entry below
        // that point - the ones drawn ON TOP - was silently dropped.
        if (vblank_start && spstate == SP_IDLE && spr_i != 9'd0)
            sprite_early <= sprite_early + 16'd1;

        // Count while the walk is running; freeze the total when it goes idle.
        if (spstate != SP_IDLE) cyc_acc <= cyc_acc + 24'd1;

        if (vblank_start) begin
            chain_heads <= heads_acc;
            chain_subs  <= subs_acc;
            heads_acc   <= 16'd0;
            subs_acc    <= 16'd0;
            sprite_cycles <= cyc_acc;
            cyc_acc       <= 24'd0;
            spr_i      <= 9'd407;
            big_sprite <= 1'b0;
            x_no       <= 8'd0;
            y_no       <= 8'd0;
            g_valid    <= 1'b0;
            spstate    <= SP_A0;
        end else begin
            case (spstate)
                SP_IDLE: ;

                // Six words per entry out of the shared upper RAM, one address per cycle
                // with the data trailing two states behind.
                SP_A0: begin upper_sp_addr <= {spr_i, 3'd0} + 13'd0; spstate <= SP_A1; end
                SP_A1: begin upper_sp_addr <= {spr_i, 3'd0} + 13'd1; spstate <= SP_A2; end
                SP_A2: begin upper_sp_addr <= {spr_i, 3'd0} + 13'd2; spstate <= SP_A3; s_code  <= upper_rd_q; end
                SP_A3: begin upper_sp_addr <= {spr_i, 3'd0} + 13'd3; spstate <= SP_A4; s_color <= upper_rd_q; end
                SP_A4: begin upper_sp_addr <= {spr_i, 3'd0} + 13'd4; spstate <= SP_A5; s_xraw  <= upper_rd_q; end
                SP_A5: begin upper_sp_addr <= {spr_i, 3'd0} + 13'd5; spstate <= SP_A6; s_yraw  <= upper_rd_q; end
                SP_A6: begin spstate <= SP_A7;     s_zoom <= upper_rd_q; end
                SP_A7: begin spstate <= SP_DECODE; s_cnts <= upper_rd_q; end

                SP_DECODE: begin
                    if (start_big)      heads_acc <= heads_acc + 16'd1;
                    else if (big_sprite) subs_acc <= subs_acc + 16'd1;
                    if (start_big) begin
                        x_num      <= s_cnts[15:8];
                        y_num      <= s_cnts[7:0];
                        x_no       <= 8'd0;
                        y_no       <= 8'd0;
                        xlatch     <= x_self;
                        ylatch     <= y_self;
                        zoomxlatch <= zoomx_raw;
                        zoomylatch <= zoomy_raw;
                        big_sprite <= 1'b1;
                    end

                    s_tile <= s_code[14:0];
                    s_col  <= s_color[5:0];
                    s_fx   <= s_color[14];
                    s_fy   <= s_color[15];
                    s_x    <= use_x;   // already sign-adjusted, as in MAME
                    s_y    <= use_y;
                    s_zx   <= use_zx;
                    s_zy   <= use_zy;
                    xstep  <= zstep(use_zx);
                    ystep  <= zstep(use_zy);
                    xbase  <= zbase(use_zx);
                    ybase  <= zbase(use_zy);
                    spstate <= SP_CLIP;
                end

                SP_CLIP: begin
                    dy   <= 5'd0;
                    yacc <= 21'd0;
                    if (clip_out) spstate <= SP_NEXT;
                    else          spstate <= SP_ROW;
                end

                SP_ROW: begin
                    if (dy >= s_zy) begin
                        spstate <= SP_NEXT;
                    end else if (~row_visible) begin
                        dy   <= dy + 5'd1;
                        yacc <= yacc + ystep;
                    end else begin
                        srow    <= y_src[19:16];
                        spstate <= SP_FETCH_L;
                    end
                end

                SP_FETCH_L: begin
                    if (g_valid && g_tag == want_tag) begin
                        grp     <= 3'd0;
                        pixj    <= 3'd0;
                        xacc    <= 21'd0;
                        acc_mask <= 8'd0;
                        spstate <= unity_x ? SP_GROUP : SP_PIXEL;
                    end else begin
                        spr_addr <= {s_tile, srow[3], 1'b0, srow[2:1], 3'b000};
                        spr_req  <= ~spr_req;
                        spstate  <= SP_WAIT_L;
                    end
                end
                SP_WAIT_L: if (spr_req == spr_ack) begin g_lo <= spr_q; spstate <= SP_FETCH_R; end

                SP_FETCH_R: begin
                    spr_addr <= {s_tile, srow[3], 1'b1, srow[2:1], 3'b000};
                    spr_req  <= ~spr_req;
                    spstate  <= SP_WAIT_R;
                end
                SP_WAIT_R: if (spr_req == spr_ack) begin
                    g_hi     <= spr_q;
                    g_tag    <= want_tag;
                    g_valid  <= 1'b1;
                    grp      <= 3'd0;
                    pixj     <= 3'd0;
                    xacc     <= 21'd0;
                    acc_mask <= 8'd0;
                    spstate  <= unity_x ? SP_GROUP : SP_PIXEL;
                end

                // 1:1 - the whole eight-pixel group is ready combinationally.
                SP_GROUP: if (~fb_wr_busy) begin
                    fb_wr_valid <= |grp_mask;
                    fb_wr_page  <= ~fb_page;
                    fb_wr_x     <= dst_x0[8:0];
                    fb_wr_y     <= dst_y[7:0];
                    fb_wr_pix   <= grp_pix;
                    fb_wr_mask  <= grp_mask;
                    spstate     <= SP_WRITE;
                end

                // Zoomed - one destination pixel per cycle into an eight-pixel group.
                SP_PIXEL: begin
                    if (z_keep) begin
                        acc_pix[pixj*10 +: 10] <= {s_col, z_pen};
                        acc_mask[pixj]         <= 1'b1;
                    end
                    xacc <= xacc + xstep;
                    if (pixj == 3'd7 || ({grp, pixj} + 6'd1) >= {1'b0, s_zx}) begin
                        spstate <= SP_GROUP2;
                    end else begin
                        pixj <= pixj + 3'd1;
                    end
                end

                SP_GROUP2: if (~fb_wr_busy) begin
                    fb_wr_valid <= |acc_mask;
                    fb_wr_page  <= ~fb_page;
                    fb_wr_x     <= dst_x0[8:0];
                    fb_wr_y     <= dst_y[7:0];
                    fb_wr_pix   <= acc_pix;
                    fb_wr_mask  <= acc_mask;
                    acc_pix     <= 80'd0;
                    acc_mask    <= 8'd0;
                    pixj        <= 3'd0;
                    spstate     <= SP_WRITE;
                end

                SP_WRITE: begin
                    if (({grp, 3'd0} + 6'd8) >= {1'b0, s_zx}) begin
                        dy      <= dy + 5'd1;
                        yacc    <= yacc + ystep;
                        spstate <= SP_ROW;
                    end else begin
                        grp     <= grp + 3'd1;
                        spstate <= unity_x ? SP_GROUP : SP_PIXEL;
                    end
                end

                SP_NEXT: begin
                    if (big_sprite) begin
                        if (y_no >= y_num) begin
                            y_no <= 8'd0;
                            if (x_no >= x_num) big_sprite <= 1'b0;
                            else               x_no <= x_no + 8'd1;
                        end else begin
                            y_no <= y_no + 8'd1;
                        end
                    end
                    if (spr_i == 9'd0) spstate <= SP_IDLE;
                    else begin
                        spr_i   <= spr_i - 9'd1;
                        spstate <= SP_A0;
                    end
                end

                default: spstate <= SP_IDLE;
            endcase
        end
    end
end

// ------------------------------------------------------------------------------------
// Compositor (M3.5)
//
// MAME's screen_update, in draw order - later passes paint over earlier ones:
//
//     BG  ->  obj1  ->  FG  ->  obj0  ->  TX
//
// The two sprite passes are one framebuffer read split by priority. `draw_framebuffer`
// shifts its priority argument left by 4 and compares it against bit 4 of the stored
// value, which is bit 0 of the sprite's colour code - so sprites with an odd colour code
// go behind the FG layer and even ones in front of it. Video control bit 3 collapses that:
// with it set the whole framebuffer is drawn in the obj0 pass and the order becomes
// BG, FG, all sprites, TX.
//
// The framebuffer contributes its stored value ADDED to the colour base, not OR-ed. For
// pbobble the base is 0x800 and the value at most 0x3ff so it makes no difference, but
// games with a low base (silentd and friends use 0x10 -> 0x100) genuinely carry.
//
// Video control bit 5 clear blanks the picture to pen 0.
// ------------------------------------------------------------------------------------
wire        fb_nz   = (fb_pixel != 10'd0);
wire        fb_odd  = fb_pixel[4];              // bit 0 of the sprite colour code
wire        pri_all = video_control[3];

wire        obj0_hit = fb_nz & (pri_all ? 1'b1 : ~fb_odd);
wire        obj1_hit = fb_nz & (pri_all ? 1'b0 :  fb_odd);
wire [13:0] fb_index = {2'b00, cb_fb, 4'd0} + {4'd0, fb_pixel};

wire [13:0] composite = ~video_enable    ? 14'd0
                      : (tx_pix != 4'd0) ? {2'b00, tx_col, tx_pix}
                      : obj0_hit         ? fb_index
                      : (fg_pix != 4'd0) ? {2'b00, fg_col, fg_pix}
                      : obj1_hit         ? fb_index
                                         : {2'b00, bg_col, bg_pix};

// Blanking is left entirely to the TC0260DAR, but the two paths through this chain are
// not the same length. Blanking: taitob_video_timing registers hblank/vblank (1 pixel),
// then the DAR runs them through hb1..hb3 (3 more), so the visible window opens 4 pixels
// after hcnt says it does. Data: the DAR's own path from IM to VIDEO is a palette read
// plus an output register, 1 pixel. Presenting the index in the same slot as the raster
// therefore loses the first three columns of every line to the DAR's own blanking.
//
// Delay the composite by three pixels so index and blanking arrive together. The F2 core
// gets this alignment for free from the TC0100SCN's deeper pipeline, which is why nothing
// upstream has to say so.
reg [13:0] pixel_d1, pixel_d2, pixel_d3;
always_ff @(posedge clk) if (ce_pixel) begin
    pixel_d1 <= composite;
    pixel_d2 <= pixel_d1;
    pixel_d3 <= pixel_d2;
end

// ------------------------------------------------------------------------------------
// Horizontal mirror for screen flip
//
// The vertical half of the flip is done at the source, by mirroring the fetch line. The
// horizontal half cannot be: the tile fetch sequencer walks left to right, two groups ahead,
// with a deadline of one group, and making it walk backwards would touch every index in the
// tightest part of the design.
//
// So mirror the finished picture instead. Composite each line exactly as before into a line
// buffer, then read it back reversed on the next line. That mirrors the tile layers and the
// sprite framebuffer together, because both are already inside `composite`, and it cannot
// affect a game with the bit clear because the whole path is bypassed.
//
// The cost is one line of delay, which is why the vertical mirror above uses 254 and not 255.
// ------------------------------------------------------------------------------------
localparam [8:0] VIS_W = 9'd320;

reg  [8:0] flip_waddr;
reg [13:0] flip_wdata;
reg        flip_we;
reg        flip_bank;

always_ff @(posedge clk) begin
    if (reset) flip_bank <= 1'b0;
    else if (ce_pixel && hcnt == H_TOTAL - 9'd1) flip_bank <= ~flip_bank;
end

always_ff @(posedge clk) begin
    flip_we <= 1'b0;
    if (ce_pixel) begin
        flip_waddr <= hcnt;
        flip_wdata <= pixel_d3;
        flip_we    <= (hcnt < FLIP_RD_OFF + 9'd2);   // cover the columns the read reaches
    end
end

// The read offset carries several one-slot corrections, so it is a constant fixed by
// measurement against MAME's output rather than by argument. A wrong value shows up as a
// whole-picture horizontal shift. The composite lags the raster by six slots here (three
// for the DAR blanking alignment, one for the registered write address, one for the RAM
// output register, one for the pixel pipeline), so the last visible source column arrives
// at hcnt 325 - which is why the write window has to reach into hblank rather than stop
// at 320.
localparam [8:0] FLIP_RD_OFF = 9'd325;
wire [8:0] flip_rd_x = FLIP_RD_OFF - hcnt;

wire [13:0] flip_q;
dualport_ram_unreg #(.WIDTH(14), .WIDTHAD(10)) flip_lbuf(
    .clock_a(clk), .wren_a(flip_we),  .address_a({flip_bank,  flip_waddr}),
    .data_a(flip_wdata), .q_a(),
    .clock_b(clk), .wren_b(1'b0),     .address_b({~flip_bank, flip_rd_x}),
    .data_b(14'd0),      .q_b(flip_q)
);

assign pixel = flip ? flip_q : pixel_d3;

endmodule

// ------------------------------------------------------------------------------------
// One layer's pixel tap.
//
// Selects across the `cur`/`nxt` pair with the layer's sub-group scroll offset, applies
// the per-tile X flip and unpacks the four bitplanes. MAME builds a 4bpp pen with plane 0
// as the most significant bit, and within a plane byte bit 7 is the leftmost pixel.
// ------------------------------------------------------------------------------------
module vcu_tile_pix(
    input  [31:0] cur,
    input  [31:0] nxt,
    input         cur_fx,
    input         nxt_fx,
    input   [7:0] cur_col,
    input   [7:0] nxt_col,
    input   [2:0] sh,        // horizontal scroll modulo 8
    input   [2:0] o,         // pixel within the displayed group
    output  [3:0] pix,
    output  [7:0] col
);

wire [3:0]  sel = {1'b0, sh} + {1'b0, o};
wire [31:0] d   = sel[3] ? nxt : cur;
wire        fx  = sel[3] ? nxt_fx : cur_fx;
assign      col = sel[3] ? nxt_col : cur_col;

wire [2:0] bi = fx ? sel[2:0] : (3'd7 - sel[2:0]);

wire [7:0] p0 = d[7:0];
wire [7:0] p1 = d[15:8];
wire [7:0] p2 = d[23:16];
wire [7:0] p3 = d[31:24];

assign pix = {p0[bi], p1[bi], p2[bi], p3[bi]};

endmodule

