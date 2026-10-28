// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - simulation stand-in for rtl/pll.v.
// The testbench drives CLK_50M with clk_sdr (108.656 MHz); clk_sys is exactly half,
// rising with every other clk_sdr edge as the real PLL's two outputs do.
module pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire locked
);
reg div = 1'b0;
always @(posedge refclk) div <= ~div;
assign outclk_0 = refclk;
assign outclk_1 = div;
assign locked   = 1'b1;
endmodule
