// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// TC0180VCU sprite framebuffer - storage, scanout and erase.
//
// Two 512x256 pages living in DDR3 at two bytes per pixel - DDR3 rather than block RAM
// because the DE10-Nano has 141 M10K free and this wants ~256. The address layout is the
// one the upstream F2 core's tc0200obj.sv uses:
//
//     OBJ_FB_DDR_BASE + {page, y[7:0], x[8:0]} * 2      -> a 1024-byte line
//
// A pixel is 10 bits, (colour_code & 0x3f) << 4 | pen, stored in 16. Value 0 is transparent;
// the compositor never looks at the colour bases for a zero.
//
// SCANOUT. One 128-beat burst per line pulls the whole 1024-byte line into a double line
// buffer selected by the line's LSB, so line v+1 is fetched while line v is on screen. The
// display side then reads four pixels per 64-bit entry.
//
// ERASE AFTER THE BEAM. Video control bit 0 says "do NOT erase the framebuffer after the
// beam", which describes the hardware exactly: each line is zeroed once the beam has passed
// it. MAME models the same thing as a bulk clear of the displayed page at vblank; spreading
// it over the frame is the same semantics and keeps the vblank free for the rasteriser,
// which needs all of it. Each page therefore ends a frame clean and is drawn into on the
// next flip, exactly as in MAME.
//
// The 29 lines that are never displayed (240-252 and 0-15) would never be erased by a
// beam-following scheme, so they are erased as extra work during the first 29 visible
// lines. Without that, sprites drawn off screen would accumulate forever - invisible, but
// visible to a CPU that reads the framebuffer back, which hitice and realpunc do.

import system_consts::*;

module tc0180vcu_fb(
    input             clk,
    input             reset,

    input             ce_pixel,
    input       [8:0] hcnt,
    input       [8:0] vcnt,
    input             visible_line,   // this raster line is inside the visible window

    input             disp_page,      // page being displayed, and therefore erased
    input             erase_en,       // ~video_control[0]
    input             flip,           // video_control[4] - mirror both axes

    // ---- Rasteriser write port -------------------------------------------------------
    // Up to eight horizontally consecutive pixels, which is what one gfx ROM read yields.
    // The unaligned split into 64-bit DDR beats happens here so the rasteriser does not
    // have to know the storage layout.
    input             wr_valid,
    output            wr_busy,
    input             wr_page,
    input       [8:0] wr_x,
    input       [7:0] wr_y,
    input      [79:0] wr_pix,         // 8 x 10 bits, [9:0] is the leftmost pixel
    input       [7:0] wr_mask,        // 1 = opaque, 0 = leave the framebuffer alone

    // ---- CPU port --------------------------------------------------------------------
    // hitice, realpunc and spacedx read and write the framebuffer directly. One 16-bit
    // word is two pixels: the upper byte is pixel x and the lower byte pixel x+1, and only
    // 8 of each pixel's 10 stored bits are visible to the CPU - which is what MAME's
    // framebuffer_word_r/w do, so a CPU write clears the top two bits of the pixel.
    input             cpu_req,        // held high until cpu_ack
    input             cpu_we,
    input             cpu_page,
    input       [8:0] cpu_x,          // even pixel index
    input       [7:0] cpu_y,
    input      [15:0] cpu_din,
    input       [1:0] cpu_be,         // [1] = upper byte = pixel x
    output reg [15:0] cpu_dout,
    output reg        cpu_ack,

    // ---- Display ---------------------------------------------------------------------
    output      [9:0] fb_pixel,

    output      [2:0] dbg_scan_state,   // testbench tap - names the state an FSM hangs in

    ddr_if.to_host    ddr
);

// ------------------------------------------------------------------------------------
// Two DDR clients: scanout/erase and draw.
// ------------------------------------------------------------------------------------
// Three clients now. Priority is scanout, then draw, then the CPU: scanout has a hard
// per-line deadline and the CPU has none, so the CPU must never be able to stall a line
// fetch. Chained two-way muxes give exactly that order.
ddr_if ddr_scan(), ddr_draw(), ddr_cpu(), ddr_rest();

ddr_mux fb_ddr_mux(
    .clk(clk),
    .x(ddr),
    .a(ddr_scan),
    .b(ddr_rest)
);

ddr_mux fb_ddr_mux2(
    .clk(clk),
    .x(ddr_rest),
    .a(ddr_draw),
    .b(ddr_cpu)
);

localparam [31:0] FB_BASE = OBJ_FB_DDR_BASE;

// Byte address of the start of a line.
function automatic [31:0] line_addr(input bit page, input bit [7:0] y);
    line_addr = FB_BASE + {13'd0, page, y, 10'd0};
endfunction

localparam [8:0] H_TOTAL = 9'd448;
localparam [8:0] V_TOTAL = 9'd253;

// ------------------------------------------------------------------------------------
// Line buffer - two lines of 128 x 64 bits (four 16-bit pixels per entry)
// ------------------------------------------------------------------------------------
reg         lb_we;
reg   [7:0] lb_waddr;
reg  [63:0] lb_wdata;
wire  [7:0] lb_raddr;
wire [63:0] lb_rdata;

dualport_ram_unreg #(.WIDTH(64), .WIDTHAD(8)) line_buffer(
    .clock_a(clk), .wren_a(lb_we), .address_a(lb_waddr), .data_a(lb_wdata), .q_a(),
    .clock_b(clk), .wren_b(1'b0),  .address_b(lb_raddr), .data_b(64'd0),   .q_b(lb_rdata)
);

// Display reads the buffer holding this line; scanout fills the other one.
//
// The selector is an explicit toggle, NOT vcnt[0]. V_TOTAL is 253 - an odd number - so at
// the frame wrap line 252 is followed by line 0 and the two have the same parity. Keying
// the buffer on the line's LSB therefore has the fetch of line 0 overwrite line 252 while
// it is still being displayed. Line 252 is inside vblank, so that would be invisible today,
// but it would stop being invisible the moment the raster totals were retuned.
// The toggle happens at the END of the line, not at hcnt 0. The read address is
// combinational and the RAM registers it, so an address that changes on the same edge the
// pixel is sampled reads one change late, and column 0 of every line would carry the
// previous line's pixel. Flipping a slot early gives the selector the same settling time
// every other address change already gets.
reg lb_sel;
always_ff @(posedge clk) begin
    if (reset)                                    lb_sel <= 1'b0;
    else if (ce_pixel && hcnt == H_TOTAL - 9'd1)  lb_sel <= ~lb_sel;
end

assign lb_raddr = {lb_sel, hcnt[8:2]};

wire [15:0] fb_word = (hcnt[1:0] == 2'd0) ? lb_rdata[15:0]
                    : (hcnt[1:0] == 2'd1) ? lb_rdata[31:16]
                    : (hcnt[1:0] == 2'd2) ? lb_rdata[47:32]
                                          : lb_rdata[63:48];

assign fb_pixel = fb_word[9:0];

// ------------------------------------------------------------------------------------
// Scanout and erase
//
// Runs once per line, started at the beginning of hblank. Order matters: fetch line v+1
// first so the display side is never left waiting, then erase, which nothing is waiting on.
// ------------------------------------------------------------------------------------
localparam [8:0] SCAN_START_H = 9'd328;   // just inside hblank (visible ends at 320)

wire [8:0] next_v = (vcnt == V_TOTAL - 9'd1) ? 9'd0 : (vcnt + 9'd1);

// Screen flip mirrors the vertical axis here, in the line the display fetches and in the
// line the erase reclaims. Both have to move together: erase follows the beam, so erasing
// the unmirrored line would clear a line BEFORE it is displayed and sprites would vanish.
// The constant is 254 and not 255 because the horizontal mirror in tc0180vcu.sv delays the
// picture by one line; see the note there.
wire [7:0] disp_line  = flip ? (8'd254 - next_v[7:0]) : next_v[7:0];
wire [7:0] erase_line = flip ? (8'd254 - vcnt[7:0])   : vcnt[7:0];

// The off-screen lines, erased as extra work during the first 29 visible lines:
//   vcnt 16..28 pays for lines 240..252,  vcnt 29..44 pays for lines 0..15.
wire [7:0] extra_line = (vcnt < 9'd29) ? (8'd240 + (vcnt[7:0] - 8'd16))
                                       : (vcnt[7:0] - 8'd29);
wire       extra_due  = (vcnt >= 9'd16) && (vcnt < 9'd45) && erase_en;

typedef enum bit [2:0] {
    SC_IDLE, SC_RD_REQ, SC_RD_DATA, SC_ER_REQ, SC_ER_DATA, SC_EX_REQ, SC_EX_DATA
} scan_state_t;

scan_state_t sstate;
assign dbg_scan_state = sstate;
reg  [7:0]   burstidx;
reg          scan_line_done;

// Everything the burst depends on is latched when it starts. A burst that runs long - and
// it can, because the draw port shares the DDR interface - must not have vcnt, the page or
// the erase decision change underneath it halfway through.
reg  [7:0] sc_fetch_line, sc_erase_line, sc_extra_line;
reg        sc_page, sc_do_erase, sc_do_extra;
reg        sc_wr_sel;      // half of the line buffer this fetch is filling

always_ff @(posedge clk) begin
    lb_we <= 1'b0;

    if (reset) begin
        sstate            <= SC_IDLE;
        ddr_scan.acquire  <= 1'b0;
        ddr_scan.read     <= 1'b0;
        ddr_scan.write    <= 1'b0;
        scan_line_done    <= 1'b0;
    end else begin
        if (ce_pixel && hcnt == 9'd0) scan_line_done <= 1'b0;

        case (sstate)
            SC_IDLE: begin
                ddr_scan.acquire <= 1'b0;
                ddr_scan.read    <= 1'b0;
                ddr_scan.write   <= 1'b0;
                if (ce_pixel && hcnt == SCAN_START_H && ~scan_line_done) begin
                    scan_line_done <= 1'b1;
                    sc_fetch_line  <= disp_line;
                    sc_erase_line  <= erase_line;
                    sc_extra_line  <= extra_line;
                    sc_page        <= disp_page;
                    sc_do_erase    <= erase_en & visible_line;
                    sc_do_extra    <= extra_due;
                    sc_wr_sel      <= ~lb_sel;
                    sstate         <= SC_RD_REQ;
                end
            end

            // Fetch line v+1 of the displayed page into the buffer it will be read from.
            SC_RD_REQ: begin
                ddr_scan.acquire <= 1'b1;
                if (~ddr_scan.busy) begin
                    ddr_scan.read     <= 1'b1;
                    ddr_scan.burstcnt <= 8'd128;
                    ddr_scan.addr     <= line_addr(sc_page, sc_fetch_line);
                    lb_waddr          <= {~lb_sel, 7'd0};
                    burstidx          <= 8'd0;
                    sstate            <= SC_RD_DATA;
                end
            end

            SC_RD_DATA: begin
                // Hold `read` until a cycle where the controller is not busy - that cycle
                // IS the acceptance. Pulsing it for one cycle regardless silently drops the
                // request whenever busy happens to be high just then, and the FSM waits
                // forever for data that was never asked for.
                if (~ddr_scan.busy) ddr_scan.read <= 1'b0;
                if (ddr_scan.rdata_ready) begin
                    lb_we    <= 1'b1;
                    lb_wdata <= ddr_scan.rdata;
                    lb_waddr <= {sc_wr_sel, burstidx[6:0]};
                    burstidx <= burstidx + 8'd1;
                    if (burstidx == 8'd127)
                        sstate <= sc_do_erase ? SC_ER_REQ
                                : sc_do_extra ? SC_EX_REQ
                                              : SC_IDLE;
                end
            end

            // Erase the line the beam has just finished with.
            SC_ER_REQ: begin
                if (~ddr_scan.busy) begin
                    ddr_scan.write      <= 1'b1;
                    ddr_scan.burstcnt   <= 8'd128;
                    ddr_scan.addr       <= line_addr(sc_page, sc_erase_line);
                    ddr_scan.wdata      <= 64'd0;
                    ddr_scan.byteenable <= 8'hff;
                    burstidx            <= 8'd1;
                    sstate              <= SC_ER_DATA;
                end
            end

            SC_ER_DATA: begin
                if (~ddr_scan.busy) begin
                    burstidx <= burstidx + 8'd1;
                    if (burstidx == 8'd128) begin
                        ddr_scan.write <= 1'b0;
                        sstate         <= sc_do_extra ? SC_EX_REQ : SC_IDLE;
                    end
                end
            end

            // Erase one of the lines the beam never reaches.
            SC_EX_REQ: begin
                if (~ddr_scan.busy) begin
                    ddr_scan.write      <= 1'b1;
                    ddr_scan.burstcnt   <= 8'd128;
                    ddr_scan.addr       <= line_addr(sc_page, sc_extra_line);
                    ddr_scan.wdata      <= 64'd0;
                    ddr_scan.byteenable <= 8'hff;
                    burstidx            <= 8'd1;
                    sstate              <= SC_EX_DATA;
                end
            end

            SC_EX_DATA: begin
                if (~ddr_scan.busy) begin
                    burstidx <= burstidx + 8'd1;
                    if (burstidx == 8'd128) begin
                        ddr_scan.write <= 1'b0;
                        sstate         <= SC_IDLE;
                    end
                end
            end

            default: sstate <= SC_IDLE;
        endcase
    end
end

// ------------------------------------------------------------------------------------
// Draw port
//
// Eight pixels arrive at an arbitrary x, so they straddle two or three aligned 64-bit
// beats. Splitting them here keeps the rasteriser free of the storage layout, and the
// byte enables mean transparent pixels cost nothing - no read-modify-write anywhere.
// ------------------------------------------------------------------------------------
reg  [79:0] d_pix;
reg   [7:0] d_mask;
reg   [8:0] d_x;
reg   [7:0] d_y;
reg         d_page;
reg   [1:0] d_beat;      // which of the three aligned beats is being emitted

typedef enum bit [1:0] { DR_IDLE, DR_EMIT, DR_WAIT } draw_state_t;
draw_state_t dstate;

assign wr_busy = (dstate != DR_IDLE) | wr_valid;

// Pixel i of the incoming run lands at x + i, i.e. in beat (x + i)[8:2] and lane
// (x + i)[1:0]. Build each beat by asking, for all four lanes, which incoming pixel (if
// any) belongs there. `first` is the beat index of the leftmost pixel.
wire [6:0] d_first = d_x[8:2];
wire [1:0] d_lane0 = d_x[1:0];

logic [63:0] beat_data;
logic  [7:0] beat_be;

always_comb begin
    beat_data = 64'd0;
    beat_be   = 8'd0;
    for (int lane = 0; lane < 4; lane++) begin
        // index of the incoming pixel that falls in this lane of this beat
        automatic int idx = d_beat * 4 + lane - int'(d_lane0);
        if (idx >= 0 && idx < 8) begin
            if (d_mask[idx[2:0]]) begin
                beat_data[lane*16 +: 16] = {6'd0, d_pix[idx[2:0]*10 +: 10]};
                beat_be[lane*2 +: 2]     = 2'b11;
            end
        end
    end
end

// A run of eight starting at lane 0 fits in two beats; any other alignment needs three.
wire [1:0] d_beats = (d_lane0 == 2'd0) ? 2'd2 : 2'd3;

always_ff @(posedge clk) begin
    if (reset) begin
        dstate           <= DR_IDLE;
        ddr_draw.acquire <= 1'b0;
        ddr_draw.write   <= 1'b0;
    end else begin
        case (dstate)
            DR_IDLE: begin
                ddr_draw.write <= 1'b0;
                if (wr_valid && |wr_mask) begin
                    d_pix  <= wr_pix;  d_mask <= wr_mask;
                    d_x    <= wr_x;    d_y    <= wr_y;
                    d_page <= wr_page; d_beat <= 2'd0;
                    ddr_draw.acquire <= 1'b1;
                    dstate <= DR_EMIT;
                end else begin
                    ddr_draw.acquire <= 1'b0;
                end
            end

            DR_EMIT: begin
                if (~ddr_draw.busy) begin
                    if (|beat_be) begin
                        ddr_draw.write      <= 1'b1;
                        ddr_draw.burstcnt   <= 8'd1;
                        ddr_draw.addr       <= FB_BASE +
                                               {13'd0, d_page, d_y, d_first + {5'd0, d_beat}, 3'd0};
                        ddr_draw.wdata      <= beat_data;
                        ddr_draw.byteenable <= beat_be;
                        dstate              <= DR_WAIT;
                    end else begin
                        // Nothing opaque in this beat - skip it without touching DDR.
                        if (d_beat == d_beats - 2'd1) dstate <= DR_IDLE;
                        else                          d_beat <= d_beat + 2'd1;
                    end
                end
            end

            DR_WAIT: begin
                if (~ddr_draw.busy) begin
                    ddr_draw.write <= 1'b0;
                    if (d_beat == d_beats - 2'd1) dstate <= DR_IDLE;
                    else begin
                        d_beat <= d_beat + 2'd1;
                        dstate <= DR_EMIT;
                    end
                end
            end

            default: dstate <= DR_IDLE;
        endcase
    end
end



// ------------------------------------------------------------------------------------
// CPU port
//
// A CPU word is two pixels, and x is even, so the four bytes it touches always sit inside
// one 64-bit beat: byte offset x*2 is 0 or 4 modulo 8. One beat therefore serves any
// access, with byte enables so a write never disturbs the two pixels it does not name.
// ------------------------------------------------------------------------------------
wire [2:0] cpu_lane0 = {1'b0, cpu_x[1:0]};
wire [2:0] cpu_lane1 = cpu_lane0 + 3'd1;
wire [31:0] cpu_beat_addr = FB_BASE + {13'd0, cpu_page, cpu_y, cpu_x[8:2], 3'd0};

logic [63:0] cpu_wdata;
logic  [7:0] cpu_wbe;
always_comb begin
    cpu_wdata = 64'd0;
    cpu_wbe   = 8'd0;
    cpu_wdata[cpu_lane0*16 +: 16] = {8'd0, cpu_din[15:8]};
    cpu_wdata[cpu_lane1*16 +: 16] = {8'd0, cpu_din[7:0]};
    if (cpu_be[1]) cpu_wbe[cpu_lane0*2 +: 2] = 2'b11;
    if (cpu_be[0]) cpu_wbe[cpu_lane1*2 +: 2] = 2'b11;
end

typedef enum bit [1:0] { CP_IDLE, CP_REQ, CP_WAIT, CP_DONE } cpu_state_t;
cpu_state_t cstate;

always_ff @(posedge clk) begin
    if (reset) begin
        cstate           <= CP_IDLE;
        ddr_cpu.acquire  <= 1'b0;
        ddr_cpu.read     <= 1'b0;
        ddr_cpu.write    <= 1'b0;
        cpu_ack          <= 1'b0;
        cpu_dout         <= 16'd0;
    end else begin
        case (cstate)
            CP_IDLE: begin
                ddr_cpu.read  <= 1'b0;
                ddr_cpu.write <= 1'b0;
                cpu_ack       <= 1'b0;
                if (cpu_req) begin
                    ddr_cpu.acquire <= 1'b1;
                    cstate          <= CP_REQ;
                end else begin
                    ddr_cpu.acquire <= 1'b0;
                end
            end

            CP_REQ: if (~ddr_cpu.busy) begin
                ddr_cpu.addr     <= cpu_beat_addr;
                ddr_cpu.burstcnt <= 8'd1;
                if (cpu_we) begin
                    ddr_cpu.write      <= 1'b1;
                    ddr_cpu.wdata      <= cpu_wdata;
                    ddr_cpu.byteenable <= cpu_wbe;
                end else begin
                    ddr_cpu.read       <= 1'b1;
                    ddr_cpu.byteenable <= 8'hff;
                end
                cstate <= CP_WAIT;
            end

            CP_WAIT: begin
                if (cpu_we) begin
                    if (~ddr_cpu.busy) begin
                        ddr_cpu.write <= 1'b0;
                        cpu_ack       <= 1'b1;
                        cstate        <= CP_DONE;
                    end
                end else begin
                    if (~ddr_cpu.busy) ddr_cpu.read <= 1'b0;
                    if (ddr_cpu.rdata_ready) begin
                        // Only the low 8 bits of each stored pixel reach the CPU.
                        cpu_dout <= { ddr_cpu.rdata[cpu_lane0*16 +: 8],
                                      ddr_cpu.rdata[cpu_lane1*16 +: 8] };
                        cpu_ack  <= 1'b1;
                        cstate   <= CP_DONE;
                    end
                end
            end

            CP_DONE: begin
                ddr_cpu.acquire <= 1'b0;
                if (~cpu_req) begin
                    cpu_ack <= 1'b0;
                    cstate  <= CP_IDLE;
                end
            end
        endcase
    end
end

// ------------------------------------------------------------------------------------
// Simulation-only instrumentation for the CPU framebuffer port.
//
// Some sets (tetrist) draw their entire picture through this port and nothing through
// the tile layers, so a fault here is the whole screen. These counters split "write
// cycles the 68000 put on the bus" from "writes the DDR side actually accepted":
//
//   dbg_cpu_wr_bus  write cycles this port took from the CPU bus
//   dbg_cpu_wr_ddr  cycles where the DDR side actually ACCEPTED one of those writes
//   dbg_cpu_rd_ddr  read completions
//   dbg_cpu_stall   cycles spent in CP_REQ waiting on the DDR mux. The CPU port is the
//                   lowest-priority client (scanout, then draw, then this), so if the
//                   bus writes are being lost to arbitration it shows here first.
//   dbg_erase_burst erase bursts ARMED. A set that draws with fb_noerase set relies on
//                   the framebuffer PERSISTING for hundreds of frames, so this must stay
//                   0 there; any erase destroys the picture.
//
// wr_bus == wr_ddr  -> every write reached DDR; the loss is downstream (scanout
//                      addressing, the displayed page, or persistence).
// wr_bus >  wr_ddr  -> writes are being dropped at this port, and stall says whether
//                      arbitration is why.
//
// Guarded so it costs nothing in synthesis; nothing here is read by the data path.
`ifdef VERILATOR
logic [31:0] dbg_cpu_wr_bus;
logic [31:0] dbg_cpu_wr_ddr;
logic [31:0] dbg_cpu_rd_ddr;
logic [31:0] dbg_cpu_stall;
logic [31:0] dbg_erase_burst;

always_ff @(posedge clk) begin
    if (reset) begin
        dbg_cpu_wr_bus  <= 32'd0;
        dbg_cpu_wr_ddr  <= 32'd0;
        dbg_cpu_rd_ddr  <= 32'd0;
        dbg_cpu_stall   <= 32'd0;
        dbg_erase_burst <= 32'd0;
    end else begin
        // One count per bus cycle taken, at the CP_IDLE -> CP_REQ transition.
        if (cstate == CP_IDLE && cpu_req && cpu_we)
            dbg_cpu_wr_bus <= dbg_cpu_wr_bus + 32'd1;
        // Every cycle the port is held off the DDR mux before it can even issue.
        if (cstate == CP_REQ && ddr_cpu.busy)
            dbg_cpu_stall <= dbg_cpu_stall + 32'd1;
        // The acceptance itself: write is asserted and the controller is not busy.
        // CP_WAIT leaves for CP_DONE on this same condition, so it counts exactly once.
        if (cstate == CP_WAIT && cpu_we && ~ddr_cpu.busy)
            dbg_cpu_wr_ddr <= dbg_cpu_wr_ddr + 32'd1;
        if (cstate == CP_WAIT && ~cpu_we && ddr_cpu.rdata_ready)
            dbg_cpu_rd_ddr <= dbg_cpu_rd_ddr + 32'd1;
        // Armed where sc_do_erase is latched, using the same terms.
        if (ce_pixel && hcnt == SCAN_START_H && ~scan_line_done &&
            sstate == SC_IDLE && (erase_en & visible_line))
            dbg_erase_burst <= dbg_erase_burst + 32'd1;
    end
end
`endif

endmodule
