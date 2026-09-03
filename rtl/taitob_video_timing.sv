// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// Taito B raster timing.
//
// Separate from the upstream F2 video_timing.sv because the two systems have genuinely
// different dot clocks and totals:
//
//   Taito F2   26.686 MHz / 4 = 6.6715 MHz,  H 424 x V 262  -> 15.735 kHz / 60.06 Hz
//   Taito B    27.164 MHz / 4 = 6.791  MHz,  H 448 x V 253  -> 15.158 kHz / 59.92 Hz
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
// THE TOTALS ARE A JUDGEMENT CALL. MAME does not raw-configure
// this screen, so H and V total are undocumented. What is known:
//
//   * visible area is 320 x 224 (MAME visarea 0-319 x 16-239)
//   * Guru measured HSync 15.1782 kHz and VSync 60.00000 Hz on a real PCB
//
// Those two measurements are mutually inconsistent with a 6.791 MHz dot clock: they imply
// H x V = 113183, i.e. H = 447.4 at V = 253, which is not an integer. One of the measured
// figures carries more error than a crystal ever would, so the totals have to be chosen.
//
//   H=447, V=253 -> 15.192 kHz / 60.049 Hz   (closest to both measurements)
//   H=448, V=253 -> 15.158 kHz / 59.915 Hz   <- chosen
//
// H=448 is chosen because a total that is a multiple of 8 is the norm for tile-based video
// hardware - it keeps the tile fetch pipeline aligned with the raster. 448 = 56 tiles. The 0.14% refresh difference is well inside
// normal arcade variance and the MiSTer scaler handles it.
//
// Revisit if the game's own timing (music tempo, attract-mode length) measurably disagrees
// with MAME.
//
// Sync position inside the blanking interval is not documented anywhere, so it is centred:
// 128 pixels of hblank with a 32-pixel front porch, 64-pixel sync, 32-pixel back porch.
//
// VERTICAL ORIGIN: vcnt is the TC0180VCU's own bitmap line, not the 0-based visible line.
// MAME renders Taito B into a 512x256 bitmap and shows visarea y 16..239, so the visible
// window starts at line 16 and every layer coordinate - text rows, BG/FG scroll blocks and
// the sprite framebuffer - is indexed off the bitmap origin. Making vcnt 0-based instead
// puts the whole picture 16 lines out and silently shifts every scroll block boundary.
// Keep vcnt == bitmap y and the video chip needs no offsets.

module taitob_video_timing(
    input             clk,
    input             ce_13m,      // clk_sys / 4 = 13.582 MHz

    output            ce_pixel,    // 6.791 MHz

    output reg  [8:0] hcnt,
    output reg  [8:0] vcnt,

    output reg        hsync,
    output reg        vsync,
    output reg        hblank,
    output reg        vblank
);

localparam [8:0] H_TOTAL   = 9'd448;
localparam [8:0] H_VISIBLE = 9'd320;
localparam [8:0] HS_START  = 9'd352;   // 32px front porch after blanking starts
localparam [8:0] HS_END    = 9'd415;   // 64px wide

localparam [8:0] V_TOTAL   = 9'd253;
localparam [8:0] V_START   = 9'd16;    // first visible line - see the note above
localparam [8:0] V_END     = 9'd239;   // last visible line
localparam [8:0] VS_START  = 9'd244;   // 4 lines front porch
localparam [8:0] VS_END    = 9'd246;   // 3 lines wide

reg ce_div;

assign ce_pixel = ce_13m & ce_div;

always_ff @(posedge clk) begin
    if (ce_13m) ce_div <= ~ce_div;

    if (ce_pixel) begin
        hcnt <= hcnt + 9'd1;

        if (hcnt == H_TOTAL - 9'd1) begin
            hcnt <= 9'd0;
            vcnt <= vcnt + 9'd1;

            if (vcnt == V_TOTAL - 9'd1) vcnt <= 9'd0;
        end

        hsync  <= (hcnt >= HS_START) && (hcnt <= HS_END);
        hblank <= (hcnt >= H_VISIBLE);
        vsync  <= (vcnt >= VS_START) && (vcnt <= VS_END);
        vblank <= (vcnt < V_START) || (vcnt > V_END);
    end
end

endmodule
