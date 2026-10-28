// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - DDR3 (f2sdram Avalon port) model for simulation.
//
// The memory itself lives in the C++ testbench (sim_ddr_read / sim_ddr_write) so the
// testbench can preload the ROM where Main_MiSTer puts it and read back the
// screen_rotate framebuffer. Timing: a read burst is accepted when BUSY is low and its
// beats come back from 12 clocks later, one per clock; BUSY stays high while a read is
// outstanding. Writes are accepted every clock BUSY is low; a burst write's address and
// count come with its first beat.
module ddr3 (
    input             clk,
    output            busy,
    input       [7:0] burstcnt,
    input      [28:0] addr,
    output reg [63:0] dout,
    output reg        dout_ready,
    input             rd,
    input      [63:0] din,
    input       [7:0] be,
    input             we
);

import "DPI-C" function longint sim_ddr_read(input int addr);
import "DPI-C" function void    sim_ddr_write(input int addr, input longint data, input int be);

reg  [7:0] left = 0;
reg  [4:0] lat;
reg [28:0] ra;
reg  [7:0] wleft = 0;               // beats still to come in a write burst
reg [28:0] wa;

assign busy = left != 0;

initial dout_ready = 0;

always @(posedge clk) begin
    dout_ready <= 1'b0;
    if (left != 0) begin
        if (lat != 0) lat <= lat - 5'd1;
        else begin
            dout       <= sim_ddr_read({3'd0, ra});
            dout_ready <= 1'b1;
            ra         <= ra + 29'd1;
            left       <= left - 8'd1;
        end
    end else if (rd) begin
        left <= (burstcnt == 0) ? 8'd1 : burstcnt;
        lat  <= 5'd12;
        ra   <= addr;
    end else if (we) begin
        // Avalon burst write: the address and count come with the first beat only
        if (wleft != 0) begin
            sim_ddr_write({3'd0, wa}, din, {24'd0, be});
            wa    <= wa + 29'd1;
            wleft <= wleft - 8'd1;
        end else begin
            sim_ddr_write({3'd0, addr}, din, {24'd0, be});
            wa    <= addr + 29'd1;
            wleft <= (burstcnt > 1) ? burstcnt - 8'd1 : 8'd0;
        end
    end
end

endmodule
