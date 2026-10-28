// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - simulation stand-in for sys/hps_io.sv.
//
// Same module name and the ports emu uses, driven from the C++ testbench through DPI:
// status word, joysticks, Direct Video / forced scandoubler, and ROM / DIP downloads
// with the ioctl handshake the real module presents (one ioctl_wr pulse per byte,
// address advancing after it, the next byte held off while ioctl_wait is high).
// A core-initiated status update (status_set rising) is handled as Main_MiSTer's
// check_status_change() does: the core's word becomes the status, bit 0 cleared.

module hps_io #(parameter CONF_STR="", CONF_STR_BRAM=0, PS2DIV=0, WIDE=0, VDNUM=1, BLKSZ=2, PS2WE=0, STRLEN=0, F12KEYMOD=0)
(
    input             clk_sys,
    inout      [45:0] HPS_BUS,
    inout      [35:0] EXT_BUS,

    output reg [31:0] joystick_0,
    output reg [31:0] joystick_1,
    output reg [31:0] joystick_2,
    output reg [31:0] joystick_3,
    output reg [15:0] joystick_l_analog_0,
    output reg [15:0] joystick_l_analog_1,
    output reg  [7:0] paddle_0,
    output reg  [7:0] paddle_1,
    output reg  [8:0] spinner_0,
    output reg  [8:0] spinner_1,
    output reg [10:0] ps2_key,

    output      [1:0] buttons,
    output reg        forced_scandoubler,
    output reg        direct_video,
    input             video_rotated,
    input             new_vmode,
    inout      [21:0] gamma_bus,

    output reg [127:0] status,
    input      [127:0] status_in,
    input              status_set,
    input       [15:0] status_menumask,

    input             info_req,
    input       [7:0] info,

    output reg        ioctl_download,
    output reg  [7:0] ioctl_index,
    output reg        ioctl_wr,
    output reg [24:0] ioctl_addr,
    output reg  [7:0] ioctl_dout,
    output reg        ioctl_upload,
    input             ioctl_upload_req,
    input       [7:0] ioctl_upload_index,
    input       [7:0] ioctl_din,
    output reg        ioctl_rd,
    input             ioctl_wait
);

import "DPI-C" function int  sim_status_word(input int i);
import "DPI-C" function int  sim_joy(input int n);
import "DPI-C" function int  sim_video_flags();
import "DPI-C" function int  sim_download_start();          // -1 none, else ioctl index
import "DPI-C" function int  sim_download_size(input int index);
import "DPI-C" function int  sim_download_ddr(input int index);    // 1: Main put the data in DDR3 itself
import "DPI-C" function int  sim_download_byte(input int index, input int addr);
import "DPI-C" function void sim_download_done(input int index);
import "DPI-C" function void sim_core_status(input int w0, input int w1, input int w2, input int w3);
import "DPI-C" function void sim_video_rotated(input int r);

assign buttons = 2'b00;
// gamma disabled: bit 19 (gamma_en) low; clk field is ignored by gamma_corr when disabled
assign gamma_bus[20:0] = {clk_sys, 1'b0, 1'b0, 10'd0, 8'd0};   // [21] is video_mixer's, as in sys/hps_io.sv

initial begin
    ioctl_download = 0; ioctl_wr = 0; ioctl_addr = 0; ioctl_index = 0; ioctl_dout = 0;
    ioctl_upload = 0; ioctl_rd = 0; status = 0; ps2_key = 0;
end

reg        old_set = 0;
reg [31:0] dl_size;
reg [19:0] pace;
reg        dl_ddr;
reg        dl_wait_wr;
reg        old_rot = 0;

always @(posedge clk_sys) begin
    int f;
    f = sim_video_flags();
    direct_video       <= f[0];
    forced_scandoubler <= f[1];

    joystick_0 <= sim_joy(0);
    joystick_1 <= sim_joy(1);
    joystick_2 <= 0;
    joystick_3 <= 0;
    joystick_l_analog_0 <= 0; joystick_l_analog_1 <= 0;
    paddle_0 <= 0; paddle_1 <= 0; spinner_0 <= 0; spinner_1 <= 0;

    old_set <= status_set;
    if (~old_set & status_set) begin
        sim_core_status(status_in[31:0], status_in[63:32], status_in[95:64], status_in[127:96]);
    end
    status <= {sim_status_word(3), sim_status_word(2), sim_status_word(1), sim_status_word(0)};

    old_rot <= video_rotated;
    if (old_rot != video_rotated) sim_video_rotated({31'd0, video_rotated});

    ioctl_wr <= 1'b0;
    if (!ioctl_download) begin
        int idx;
        idx = sim_download_start();
        if (idx >= 0) begin
            ioctl_index    <= idx[7:0];
            dl_size        <= sim_download_size(idx);
            dl_ddr         <= sim_download_ddr(idx) != 0;
            // byte mode: the first write lands at address 0. DDR mode (MRA address=):
            // Main_MiSTer copies the file into DDR3 itself, then reports only its length.
            ioctl_addr     <= sim_download_ddr(idx) != 0 ? sim_download_size(idx)[24:0] : 25'h1ffffff;
            ioctl_download <= 1'b1;
            pace           <= 20'd0;
        end
    end else begin
        pace <= dl_ddr ? pace + 20'd1 : {16'd0, pace[3:0] + 4'd1};
        if (dl_ddr) begin
            // the HPS-side copy of a 3 MB set takes tens of ms; 0.5M clocks (~9 ms) stands in
            if (pace == 20'd500000) begin
                ioctl_download <= 1'b0;
                sim_download_done({24'd0, ioctl_index});
            end
        end else if (pace[3:0] == 4'd15 && !ioctl_wait) begin
            if (ioctl_addr + 25'd1 == dl_size[24:0]) begin
                ioctl_download <= 1'b0;
                sim_download_done({24'd0, ioctl_index});
            end else begin
                ioctl_addr <= ioctl_addr + 25'd1;
                ioctl_dout <= sim_download_byte({24'd0, ioctl_index}, {7'd0, ioctl_addr + 25'd1})[7:0];
                ioctl_wr   <= 1'b1;
            end
        end
    end
end

endmodule
