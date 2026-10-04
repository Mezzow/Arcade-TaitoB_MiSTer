// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - whole-core simulation top.
//
// The real `emu` (Arcade-TaitoB.sv and everything under it) with the board replaced by
// models: sim/models/pll.v, sdram.sv (channel level), hps_io.sv (DPI-driven), ddr3.sv
// (memory in C++). After emu, the analog path of sys/sys_top.v is reproduced with the
// framework's own modules - sync_fix (polarity normalisation), scanlines (the VGA stage,
// scanlines off) and csync - extracted verbatim from sys/sys_top.v at build time
// (sim/build.sh), so `ana_*` and `ana_cs` are what reaches the analog connector before
// the pin inversion.
module tb_top (
    input         clk_sdr,          // 108.656 MHz; emu's PLL stand-in halves it for clk_sys
    input         fb_vbl,           // HDMI scaler vblank stand-in for screen_rotate
    input  [11:0] hdmi_w,
    input  [11:0] hdmi_h,

    output        clk_video,
    output        ce_pixel,
    output  [7:0] vga_r, vga_g, vga_b,
    output        vga_hs, vga_vs, vga_de,
    output [12:0] arx, ary,

    output        fb_en,
    output  [4:0] fb_format,
    output [11:0] fb_width, fb_height,
    output [31:0] fb_base,
    output [13:0] fb_stride,

    output        ana_hs, ana_vs, ana_de, ana_ce, ana_cs,
    output [23:0] ana_rgb,

    output [15:0] audio_l,

    // probes into the game core
    output  [9:0] game_joy1,
    output  [9:0] game_joy2,
    output        game_reset,
    output  [1:0] rot_ifb,          // screen_rotate buffer being written
    output        vcu_flip,         // TC0180VCU flip in effect (game bit ^ OSD Flipped)
    output [23:0] cpu_a,            // 68000 byte address
    output        cpu_as_n,
    output        vcu_video_en,
    output        cpu_rw,
    output [15:0] cpu_din, cpu_dout,
    output [13:0] vcu_pixel,
    output  [7:0] core_r
);

assign vcu_pixel = emu.TaitoB.vcu_pixel;
assign core_r    = emu.core_r;

assign cpu_rw   = emu.TaitoB.cpu_rw;
assign cpu_din  = emu.TaitoB.cpu_data_in;
assign cpu_dout = emu.TaitoB.cpu_data_out;

assign cpu_a        = emu.TaitoB.A;
assign cpu_as_n     = emu.TaitoB.cpu_as_n;
assign vcu_video_en = emu.TaitoB.vcu_video_enable;

assign rot_ifb  = emu.video_path.screen_rotate.i_fb;
assign vcu_flip = emu.TaitoB.vcu_screen_flip;

assign game_joy1  = emu.TaitoB.joystick_p1;
assign game_joy2  = emu.TaitoB.joystick_p2;
assign game_reset = emu.reset;

wire        ddr_busy, ddr_dout_ready, ddr_rd, ddr_we;
wire  [7:0] ddr_burstcnt, ddr_be;
wire [28:0] ddr_addr;
wire [63:0] ddr_dout, ddr_din;
wire [45:0] hps_bus;
wire [15:0] sdram_dq;
wire  [3:0] adc_bus;

emu emu (
    .CLK_50M(clk_sdr),
    .RESET(1'b0),
    .HPS_BUS(hps_bus),
    .CLK_VIDEO(clk_video),
    .CE_PIXEL(ce_pixel),
    .VIDEO_ARX(arx),
    .VIDEO_ARY(ary),
    .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b),
    .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
    .VGA_F1(), .VGA_SL(), .VGA_SCALER(), .VGA_DISABLE(),
    .HDMI_WIDTH(hdmi_w), .HDMI_HEIGHT(hdmi_h),
    .HDMI_FREEZE(), .HDMI_BLACKOUT(), .HDMI_BOB_DEINT(),
    .FB_EN(fb_en), .FB_FORMAT(fb_format), .FB_WIDTH(fb_width), .FB_HEIGHT(fb_height),
    .FB_BASE(fb_base), .FB_STRIDE(fb_stride), .FB_VBL(fb_vbl), .FB_LL(1'b0),
    .FB_FORCE_BLANK(),
    .LED_USER(), .LED_POWER(), .LED_DISK(), .BUTTONS(),
    .CLK_AUDIO(1'b0),
    .AUDIO_L(audio_l), .AUDIO_R(), .AUDIO_S(), .AUDIO_MIX(),
    .ADC_BUS(adc_bus),
    .SD_SCK(), .SD_MOSI(), .SD_MISO(1'b1), .SD_CS(), .SD_CD(1'b1),
    .DDRAM_CLK(),
    .DDRAM_BUSY(ddr_busy),
    .DDRAM_BURSTCNT(ddr_burstcnt),
    .DDRAM_ADDR(ddr_addr),
    .DDRAM_DOUT(ddr_dout),
    .DDRAM_DOUT_READY(ddr_dout_ready),
    .DDRAM_RD(ddr_rd),
    .DDRAM_DIN(ddr_din),
    .DDRAM_BE(ddr_be),
    .DDRAM_WE(ddr_we),
    .SDRAM_CLK(), .SDRAM_CKE(), .SDRAM_A(), .SDRAM_BA(), .SDRAM_DQ(sdram_dq),
    .SDRAM_DQML(), .SDRAM_DQMH(), .SDRAM_nCS(), .SDRAM_nCAS(), .SDRAM_nRAS(), .SDRAM_nWE(),
    .UART_CTS(1'b0), .UART_RTS(), .UART_RXD(1'b0), .UART_TXD(), .UART_DTR(), .UART_DSR(1'b0),
    .USER_IN(7'h7f), .USER_OUT(),
    .OSD_STATUS(1'b0)
);

ddr3 ddr3 (
    .clk(clk_video),
    .busy(ddr_busy),
    .burstcnt(ddr_burstcnt),
    .addr(ddr_addr),
    .dout(ddr_dout),
    .dout_ready(ddr_dout_ready),
    .rd(ddr_rd),
    .din(ddr_din),
    .be(ddr_be),
    .we(ddr_we)
);

// ---- sys_top.v analog path (scanlines off, OSD closed) ----
wire hs_fix, vs_fix;
sync_fix sync_v(clk_video, vga_vs, vs_fix);
sync_fix sync_h(clk_video, vga_hs, hs_fix);

scanlines #(0) VGA_scanlines (
    .clk(clk_video),
    .scanlines(2'd0),
    .din(vga_de ? {vga_r, vga_g, vga_b} : 24'd0),
    .hs_in(hs_fix),
    .vs_in(vs_fix),
    .de_in(vga_de),
    .ce_in(ce_pixel),
    .dout(ana_rgb),
    .hs_out(ana_hs),
    .vs_out(ana_vs),
    .de_out(ana_de),
    .ce_out(ana_ce)
);

csync csync_vga(clk_video, ana_hs, ana_vs, ana_cs);

endmodule
