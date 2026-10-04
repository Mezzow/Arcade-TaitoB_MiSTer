// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). See README for credits.
//
// OSD Orientation: one decode for everything the selector changes, kept in its own module
// so sim/orientation_tb.sv tests exactly what is built. Labels, order and status encoding
// follow the Namco NA-1/NA-2 and NB-1 cores.
//
// The Taito B raster is always produced unrotated, at its native timing (440 dots + 17 idle
// clocks x 256 lines at clk_sys/8, 320 x 224 active); no mode changes a sync pulse, a line or
// a frame.
//
//   orient  OSD label      native / analog / DV   HDMI scaler       no_rotate rotate_ccw native_flip
//   00      Horizontal     H                      H                 1         x          0
//   01      Vertical CCW   H                      H turned 90 CCW   0         1          0
//   10      Vertical CW    H                      H turned 90 CW    0         0          0
//   11      Flipped        H turned 180           H turned 180      1         x          1
//   (Direct Video: no_rotate = 1 in every mode - the HDMI then carries the native raster,
//    so it is H in the first three rows and H turned 180 in Flipped, exactly the analog
//    picture. video_rotated, and so the DV1 InfoFrame's "rotated" bit, stays 0.)
//
// H is the raw raster as the board emits it. CW and CCW say which way the PICTURE turns as
// seen by the viewer: Vertical CW moves the top edge of H to the right-hand side, Vertical
// CCW moves it to the left-hand side (screen_rotate rotate_ccw = 0 / 1). A MAME ROT270 set
// - ashura, masterw, ryujin, yukiwo and their clones - stands upright with Vertical CCW,
// a ROT90 set with Vertical CW.
//
// Native vs scaler. Flipped is made in the TC0180VCU's own flip path (tc0180vcu.sv), so it
// is on the raster itself and reaches every output. A 90-degree turn transposes the picture
// and cannot be made on a 15 kHz raster without changing its timing, so CW/CCW exist only
// in the framework's screen_rotate framebuffer (sys/arcade_video.v, MISTER_FB -> DDR3 ->
// HDMI scaler); the analog output keeps H, which is what a physically rotated CRT wants.
//
// Controls follow the game in every mode: the joystick is never re-mapped, and coin, start,
// service and the action buttons are never touched. Each mode exists to present the game
// upright to the viewer - CW/CCW on a horizontal HDMI screen, Flipped on a monitor mounted
// the other way up or rotated the opposite way to the game - and in every one of those the
// game's own up is the viewer's up. The Namco cores reached the same rule (NB-1 M22 removed
// its "Controls: Match display" option).
//
// Default. game_rot is the set's MAME orientation in quarter turns clockwise, from the
// MRA's board record (byte 1: 0 = ROT0, 3 = ROT270). default_orient is the mode that shows
// the set upright on a horizontal HDMI screen: Horizontal for ROT0, Vertical CCW for
// ROT270, Vertical CW for ROT90, Flipped for ROT180. Arcade-TaitoB.sv applies it once per
// load unless the user's saved settings already hold a choice.
module taitob_orientation (
    input  wire [1:0] orient,          // OSD Orientation
    input  wire       direct_video,    // hps_io: MiSTer Direct Video
    input  wire [1:0] game_rot,        // MAME orientation, quarter turns CW

    output wire       no_rotate,       // screen_rotate
    output wire       rotate_ccw,      // screen_rotate
    output wire       native_flip,     // TC0180VCU, both outputs
    output wire [1:0] default_orient
);
    wire vert = (orient == 2'd1) || (orient == 2'd2);
    assign no_rotate   = !vert || direct_video;
    assign rotate_ccw  = (orient == 2'd1);
    assign native_flip = (orient == 2'd3);

    assign default_orient = (game_rot == 2'd3) ? 2'd1 :
                            (game_rot == 2'd1) ? 2'd2 :
                            (game_rot == 2'd2) ? 2'd3 : 2'd0;
endmodule
