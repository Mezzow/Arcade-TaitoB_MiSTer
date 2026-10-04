// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - simulation stand-in for rtl/sdram.sv.
//
// Channel-level model with the controller's own contract, so no SDRAM pin model is
// needed: a request is a toggle of chN_req, completion is chN_ack following it. One
// request is served at a time with the controller's priority (ch1, ch2, ch4, ch3) and
// roughly its latency (ACTIVE, one wait, READ, CAS 3, then the burst), and reads use the
// chip's sequential burst of 4 that wraps inside an aligned 4-word block - which is what
// ch1's 2-word and the 64-bit channels' 4-word reads actually return. A ch3 write is one
// 16-bit word with ch3_be as the byte enables, exactly as the controller drives DQM.
// 32M x 16 = 64 MB, the whole module.

module sdram
(
    input             init,
    input             clk,
    input             doRefresh,

    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output      [1:0] SDRAM_BA,
    output            SDRAM_nCS,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_CKE,
    output            SDRAM_CLK,

    input      [26:0] ch1_addr,
    output reg [31:0] ch1_dout,
    input             ch1_req,
    output reg        ch1_ack,

    input      [26:0] ch2_addr,
    output reg [15:0] ch2_dout,
    input             ch2_req,
    output reg        ch2_ack,

    input      [26:0] ch3_addr,
    output reg [63:0] ch3_dout,
    input      [15:0] ch3_din,
    input      [ 1:0] ch3_be,
    input             ch3_req,
    input             ch3_rnw,
    output reg        ch3_ack,

    input      [26:0] ch4_addr,
    output reg [63:0] ch4_dout,
    input             ch4_req,
    output reg        ch4_ack
);

assign SDRAM_DQ = 16'hZZZZ;
assign SDRAM_A = 0;
assign {SDRAM_DQML, SDRAM_DQMH, SDRAM_BA, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS} = '1;
assign SDRAM_CKE = 1;
assign SDRAM_CLK = clk;

reg [15:0] mem [0:(1<<25)-1];

function [15:0] rd(input [24:0] base, input [1:0] k);
    rd = mem[{base[24:2], base[1:0] + k}];
endfunction

initial begin
    ch1_ack = 0; ch2_ack = 0; ch3_ack = 0; ch4_ack = 0;
end

reg        r1, r2, r3, r4;          // pending, as the controller's chN_rq
reg        p1, p2, p3, p4;          // previous req
reg  [4:0] busy;                    // cycles left on the current access
reg  [2:0] ch;
reg [24:0] a;
reg        wr;
reg [15:0] wd;
reg  [1:0] wbe;

always @(posedge clk) begin
    p1 <= ch1_req; p2 <= ch2_req; p3 <= ch3_req; p4 <= ch4_req;
    if (ch1_req != p1) r1 <= 1;
    if (ch2_req != p2) r2 <= 1;
    if (ch3_req != p3) r3 <= 1;
    if (ch4_req != p4) r4 <= 1;

    if (init) begin
        busy <= 0; r1 <= 0; r2 <= 0; r3 <= 0; r4 <= 0;
    end else if (busy != 0) begin
        busy <= busy - 5'd1;
        if (busy == 5'd1) begin
            case (ch)
                3'd1: begin ch1_dout <= {rd(a, 2'd1), rd(a, 2'd0)}; ch1_ack <= ch1_req; end
                3'd2: begin ch2_dout <= rd(a, 2'd0); ch2_ack <= ch2_req; end
                3'd3: begin
                    if (wr) begin
                        if (wbe[0]) mem[a][7:0]  <= wd[7:0];
                        if (wbe[1]) mem[a][15:8] <= wd[15:8];
                    end else
                        ch3_dout <= {rd(a, 2'd3), rd(a, 2'd2), rd(a, 2'd1), rd(a, 2'd0)};
                    ch3_ack <= ch3_req;
                end
                3'd4: begin ch4_dout <= {rd(a, 2'd3), rd(a, 2'd2), rd(a, 2'd1), rd(a, 2'd0)}; ch4_ack <= ch4_req; end
                default: ;
            endcase
        end
    end else if (r1) begin r1 <= 0; ch <= 3'd1; a <= ch1_addr[25:1]; wr <= 0; busy <= 5'd11; end
    else if (r2)     begin r2 <= 0; ch <= 3'd2; a <= ch2_addr[25:1]; wr <= 0; busy <= 5'd12; end
    else if (r4)     begin r4 <= 0; ch <= 3'd4; a <= ch4_addr[25:1]; wr <= 0; busy <= 5'd10; end
    else if (r3)     begin
        r3 <= 0; ch <= 3'd3; a <= ch3_addr[25:1];
        wr <= ~ch3_rnw; wd <= ch3_din; wbe <= ch3_be;
        busy <= ch3_rnw ? 5'd10 : 5'd4;
    end
end

endmodule
