// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - exhaustive check of rtl/taitob_orientation.sv against
// its truth table, every orient x direct_video x game_rot combination.
//
// Run with sim/run_unit.sh (Verilator --binary).
module orientation_tb;
    logic [1:0] orient, game_rot, default_orient;
    logic       direct_video, no_rotate, rotate_ccw, native_flip;
    int errors = 0;

    taitob_orientation dut(.*);

    initial begin
        for (int o = 0; o < 4; o++)
        for (int dv = 0; dv < 2; dv++)
        for (int g = 0; g < 4; g++) begin
            bit e_no_rotate, e_flip, e_rotated;
            logic [1:0] e_def;
            orient = o[1:0]; direct_video = dv[0]; game_rot = g[1:0];
            #1;
            // table: 00 H, 01 CCW, 10 CW, 11 Flipped; DV never rotates on the scaler
            e_no_rotate = (o == 0 || o == 3) || dv;
            e_flip      = (o == 3);
            e_def       = (g == 3) ? 2'd1 : (g == 1) ? 2'd2 : (g == 2) ? 2'd3 : 2'd0;
            if (no_rotate !== e_no_rotate) begin errors++; $display("FAIL o=%0d dv=%0d g=%0d no_rotate=%b", o, dv, g, no_rotate); end
            if (!no_rotate && rotate_ccw !== (o == 1)) begin errors++; $display("FAIL o=%0d rotate_ccw=%b", o, rotate_ccw); end
            if (native_flip !== e_flip) begin errors++; $display("FAIL o=%0d dv=%0d native_flip=%b", o, dv, native_flip); end
            if (default_orient !== e_def) begin errors++; $display("FAIL g=%0d default=%0d", g, default_orient); end
        end
        // the default must stand each MAME orientation upright: ROT270 needs a 90-degree
        // counter-clockwise turn (screen_rotate rotate_ccw = 1), ROT90 a clockwise one
        orient = 2'd0; direct_video = 0; game_rot = 2'd3; #1;
        orient = default_orient; #1;
        if (no_rotate || !rotate_ccw) begin errors++; $display("FAIL ROT270 default is not Vertical CCW"); end
        game_rot = 2'd1; #1; orient = default_orient; #1;
        if (no_rotate || rotate_ccw) begin errors++; $display("FAIL ROT90 default is not Vertical CW"); end
        $display("orientation_tb: %0d combinations, %0d errors", 4 * 2 * 4, errors);
        if (errors) $fatal(1, "orientation_tb FAILED");
        $finish;
    end
endmodule
