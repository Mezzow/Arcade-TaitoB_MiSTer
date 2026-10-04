// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// Taito B raster timing.
//
// Separate from the upstream F2 video_timing.sv because the two systems have genuinely
// different dot clocks and totals:
//
//   Taito F2   26.686 MHz / 4 = 6.6715 MHz,  H 424 x V 262  -> 15.735 kHz / 60.06 Hz
//   Taito B    27.164 MHz / 4 = 6.791  MHz,  H 440 (+17 clk) x V 256 -> 15.360 kHz / 60.000 Hz
//
// Reusing F2's numbers would run the game about 2% slow, so clk_sys is 54.328 MHz - exactly
// 8 x the Taito B dot clock. ce_13m is clk_sys / 4 and this module halves it again, so
// ce_pixel is an exact divide-by-8 of CLK_VIDEO.
//
// THAT INTEGER RATIO IS LOAD-BEARING, not a tidiness preference. sys/video_mixer.sv requires
// "CLK_VIDEO should be multiple by (ce_pix*4)": sys/scandoubler.v regenerates its own pixel
// enable from the measured pixel period, and Direct Video hands the raster to the HDMI
// transmitter at CLK_VIDEO granularity. A fractional dot clock jitters by one clk_sys cycle,
// which slipped the scandoubler about 6 pixels per line and made the H total sent over HDMI
// alternate between 3520 and 3521 - the RetroTINK 4K DV1 black lines of issue #1.
// See TaitoB.sv's clock-enable block.
//
// THE RASTER MATCHES THE MISTER RYU JIN CORE (MiSTer_Ryu_Jin, rj_video_timing.sv). That core
// runs MAME's Taito B screen as 256 lines at exactly 60 Hz: 446 dots of 14 clocks plus 6 idle
// clocks = 6250 clocks of 96 MHz per line (15.36 kHz), HSync dots 344-375, VSync lines
// 244-246. This module produces the same raster from this core's 54.328 MHz clk_sys - a
// standard 15 kHz raster for any CRT, verified on a consumer CRT over component and RGB:
//
//   line   = 440 dots x 8 clocks + 17 idle clocks = 3537 clocks = 65.104 us = 15.360 kHz
//   frame  = 256 lines = 905,472 clocks = 60.000 Hz (MAME's rate; PCB measured 60.00 Hz)
//   HSync  = dots 344..375 (24 dots after the last active one, 32 wide = 4.71 us)
//   VSync  = lines 244..246
//
// Every pixel is still exactly 8 clocks of CLK_VIDEO, the rule this core's Direct Video and
// scandoubler fixes depend on; the 17 idle clocks sit at the end of horizontal blanking,
// where neither the scandoubler (it measures the pixel period during active video) nor
// Direct Video's per-line pixel-repeat reading sees them - the same arrangement as the Ryu
// Jin core's 6 idle clocks. ce_13m (the TC0260DAR's double-rate enable) is generated here
// with the same phase and gap. 440 = 55 tiles keeps the total a multiple of 8.
//
// Guru's PCB measurement (HSync 15.1782 kHz, VSync 60.000 Hz) implies 253 lines; this
// raster keeps the frame rate and changes the line count, as the Ryu Jin core does.
//
// sync_fix (OSD "Consumer CRT Sync", default On) picks the HSync width: On = 32 dots, the
// Ryu Jin core's pulse; Off = 64 dots. It is applied at the frame boundary.
//
// VERTICAL ORIGIN: vcnt is the TC0180VCU's own bitmap line, not the 0-based visible line.
// MAME renders Taito B into a 512x256 bitmap and shows visarea y 16..239, so the visible
// window starts at line 16 and every layer coordinate - text rows, BG/FG scroll blocks and
// the sprite framebuffer - is indexed off the bitmap origin. Making vcnt 0-based instead
// puts the whole picture 16 lines out and silently shifts every scroll block boundary.
// Keep vcnt == bitmap y and the video chip needs no offsets.

module taitob_video_timing(
    input             clk,
    input             sync_fix,    // 1: 32-dot HSync (see above)

    output            ce_13m,      // 2x the dot rate, for the TC0260DAR; none in the idle clocks
    output            ce_pixel,    // 6.791 MHz, every 8th clock outside the idle clocks

    output reg  [8:0] hcnt,
    output reg  [8:0] vcnt,

    output reg        hsync,
    output reg        vsync,
    output reg        hblank,
    output reg        vblank
);

localparam [11:0] LINE_CLKS = 12'd3537;   // 440 dots x 8 + 17 idle
localparam [11:0] DOT_CLKS  = 12'd3520;

localparam [8:0] H_TOTAL   = 9'd440;
localparam [8:0] H_VISIBLE = 9'd320;
localparam [8:0] HS_START  = 9'd344;   // 24 dots after blanking starts (Ryu Jin core)
localparam [8:0] HS_END    = 9'd407;   // 64 dots wide (sync_fix = 0)
localparam [8:0] HS_END_FIX = 9'd375;  // 32 dots wide (sync_fix = 1), as the Ryu Jin core

localparam [8:0] V_TOTAL   = 9'd256;
localparam [8:0] V_START   = 9'd16;    // first visible line - see the note above
localparam [8:0] V_END     = 9'd239;   // last visible line
localparam [8:0] VS_START  = 9'd244;   // as the Ryu Jin core
localparam [8:0] VS_END    = 9'd246;   // 3 lines wide

reg [11:0] lclk = 12'd0;
reg fix = 1'b1;   // sync_fix, taken once per frame (On until the first frame boundary)

wire in_dots = (lclk < DOT_CLKS);
assign ce_13m   = in_dots && (lclk[1:0] == 2'd3);
assign ce_pixel = in_dots && (lclk[2:0] == 3'd7);

always_ff @(posedge clk) begin
    lclk <= (lclk == LINE_CLKS - 12'd1) ? 12'd0 : lclk + 12'd1;

    if (ce_pixel) begin
        hcnt <= hcnt + 9'd1;

        if (hcnt == H_TOTAL - 9'd1) begin
            hcnt <= 9'd0;
            vcnt <= vcnt + 9'd1;

            if (vcnt == V_TOTAL - 9'd1) begin
                vcnt <= 9'd0;
                fix  <= sync_fix;
            end
        end

        hsync  <= (hcnt >= HS_START) && (hcnt <= (fix ? HS_END_FIX : HS_END));
        hblank <= (hcnt >= H_VISIBLE);
        vsync  <= (vcnt >= VS_START) && (vcnt <= VS_END);
        vblank <= (vcnt < V_START) || (vcnt > V_END);
    end
end

endmodule
