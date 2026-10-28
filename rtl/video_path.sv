// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). See README for credits.
//
// Video hand-off to the MiSTer framework, built the way the MiSTer Ryu Jin core
// (MiSTer_Ryu_Jin, RyuJin.sv) does it, for 15 kHz CRTs on any analog output (verified on a
// consumer CRT over component and RGB) as well as HDMI:
//
//   * the raster goes straight into the framework's own arcade_video (sys/arcade_video.v,
//     24-bit), which registers it on the pixel enable, re-times VSync onto the HSync edge
//     and VBlank onto the line start, and runs video_mixer (gamma, scandoubler, HQ2x,
//     scanline Fx). No video_freak and no sync regeneration in between;
//   * RGB is forced to black outside the active area, as the Ryu Jin core's renderer does;
//   * screen_rotate (Vertical CW/CCW on HDMI) sits after it, as in that core.
//
// The OSD's Analog Video H-Pos/V-Pos still work through jtframe_resync, but only while one
// of them is non-zero (chosen at the start of a frame): at 0/0, the default, the sync goes
// to arcade_video exactly as the raster produced it.
module video_path(
    input             CLK_VIDEO,

    // Configuration inputs
    input       [4:0] hoffset,
    input       [4:0] voffset,
    input             forced_scandoubler,
    input       [2:0] scandoubler_fx,
    input       [1:0] ar,
    input             no_rotate,     // rtl/taitob_orientation.sv: 0 = Vertical CW/CCW on HDMI
    input             rotate_ccw,
    output            video_rotated,

    // Core video signal
    input             core_ce_pix,
    input             core_hs,
    input             core_vs,
    input             core_hb,
    input             core_vb,
    input       [7:0] core_r,
    input       [7:0] core_g,
    input       [7:0] core_b,

    // Scaler info out
    output     [12:0] VIDEO_ARX,
    output     [12:0] VIDEO_ARY,

    // Gamma
    inout      [21:0] gamma_bus,

    // Framebuffer signals for rotation
    output            FB_EN,
    output      [4:0] FB_FORMAT,
    output reg [11:0] FB_WIDTH,
    output reg [11:0] FB_HEIGHT,
    output     [31:0] FB_BASE,
    output     [13:0] FB_STRIDE,
    input             FB_VBL,
    input             FB_LL,

    // DDR for rotation
    ddr_if.to_host    ddr,

    // Final output
    output            CE_PIXEL,
    output      [7:0] VGA_R,
    output      [7:0] VGA_G,
    output      [7:0] VGA_B,
    output            VGA_HS,
    output            VGA_VS,
    output            VGA_DE,
    output      [1:0] VGA_SL
);

// ---- optional H/V position (OSD), off by default ----
wire jt_hs, jt_vs;
jtframe_resync #(5) jtframe_resync
(
    .clk(CLK_VIDEO),
    .pxl_cen(core_ce_pix),
    .hs_in(core_hs),
    .vs_in(core_vs),
    .LVBL(~core_vb),
    .LHBL(~core_hb),
    .hoffset(-hoffset), // flip the sign
    .voffset(-voffset),
    .hs_out(jt_hs),
    .vs_out(jt_vs)
);

// jtframe_resync rebuilds the pulses from the previous frame of each field parity, so it is
// only trusted once it has run eight frames, and only used while an offset is set. The
// choice is made at the start of vertical blank. Its output is one pixel later than the
// raw pulses; at 0/0 the raw pulses are used.
reg [3:0] resync_frames = 4'd0;
reg       use_resync = 1'b0, old_vb = 1'b0;
always @(posedge CLK_VIDEO) if (core_ce_pix) begin
    old_vb <= core_vb;
    if (core_vb & ~old_vb) begin
        if (~resync_frames[3]) resync_frames <= resync_frames + 4'd1;
        use_resync <= resync_frames[3] && (hoffset != 5'd0 || voffset != 5'd0);
    end
end
wire av_hs_in = use_resync ? jt_hs : core_hs;
wire av_vs_in = use_resync ? jt_vs : core_vs;

// ---- arcade_video, as the Ryu Jin core ----
wire [23:0] av_rgb = (core_hb | core_vb) ? 24'd0 : {core_r, core_g, core_b};

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
    .clk_video(CLK_VIDEO),
    .ce_pix(core_ce_pix),
    .RGB_in(av_rgb),
    .HBlank(core_hb),
    .VBlank(core_vb),
    .HSync(av_hs_in),
    .VSync(av_vs_in),
    .CLK_VIDEO(),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R),
    .VGA_G(VGA_G),
    .VGA_B(VGA_B),
    .VGA_HS(VGA_HS),
    .VGA_VS(VGA_VS),
    .VGA_DE(VGA_DE),
    .VGA_SL(VGA_SL),
    .fx(scandoubler_fx),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus)
);

// the aspect of the picture the scaler actually shows: 3:4 only while it is turned
assign VIDEO_ARX = (!ar) ? (video_rotated ? 13'd3 : 13'd4) : {11'd0, ar - 2'd1};
assign VIDEO_ARY = (!ar) ? (video_rotated ? 13'd4 : 13'd3) : 13'd0;

wire [28:0] rotate_addr;
wire [63:0] rotate_data;
wire rotate_wr;
wire [7:0] rotate_be;

screen_rotate screen_rotate(
    .CLK_VIDEO,
    .CE_PIXEL,

    .VGA_R, .VGA_G, .VGA_B,
    .VGA_HS, .VGA_VS, .VGA_DE,

    .rotate_ccw,
    .no_rotate,
    .flip(1'b0),        // Flipped is native (TC0180VCU), never a scaler-only 180
    .video_rotated,

    .FB_EN,
    .FB_FORMAT, .FB_WIDTH, .FB_HEIGHT,
    .FB_BASE, .FB_STRIDE,
    .FB_VBL, .FB_LL,

    .DDRAM_CLK(), // it's clk_sys and clk_video
    .DDRAM_BUSY(0),
    .DDRAM_BURSTCNT(),
    .DDRAM_ADDR(rotate_addr),
    .DDRAM_DIN(rotate_data),
    .DDRAM_BE(rotate_be),
    .DDRAM_WE(rotate_wr),
    .DDRAM_RD()
);

reg [9:0] fifo_wr_addr, fifo_rd_addr;
wire [63:0] fifo_out;

assign ddr.read = 0;
assign ddr.burstcnt = 1;
assign ddr.addr = { fifo_out[63:35], 3'b0 };
assign ddr.wdata = { fifo_out[31:0], fifo_out[31:0] };
assign ddr.byteenable = {{4{fifo_out[33]}}, {4{fifo_out[32]}}};

dualport_ram_unreg #(.WIDTH(64), .WIDTHAD(10)) rotate_fifo
(
    // Port A
    .clock_a(CLK_VIDEO),
    .wren_a(rotate_wr),
    .address_a(fifo_wr_addr),
    .data_a({rotate_addr, 1'b0, rotate_be[4], rotate_be[0], rotate_data[31:0]}),
    .q_a(),

    // Port B
    .clock_b(CLK_VIDEO),
    .wren_b(0),
    .address_b(fifo_rd_addr),
    .data_b(0),
    .q_b(fifo_out)
);

always_ff @(posedge CLK_VIDEO) begin
    if (rotate_wr) begin
        fifo_wr_addr <= fifo_wr_addr + 1;
    end

    if (fifo_wr_addr != fifo_rd_addr) begin
        ddr.acquire <= 1;
    end

    if (~ddr.busy & ddr.acquire) begin
        if (ddr.write) begin
            if (fifo_rd_addr != fifo_wr_addr) begin
                fifo_rd_addr <= fifo_rd_addr + 1;
            end else begin
                ddr.write <= 0;
                ddr.acquire <= 0;
            end
        end else begin
            if (fifo_rd_addr != fifo_wr_addr) begin
                ddr.write <= 1;
                fifo_rd_addr <= fifo_rd_addr + 1;
            end
        end
    end
end

endmodule
