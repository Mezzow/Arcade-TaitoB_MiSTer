// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// TC0640FIO - Taito I/O chip used by the EEPROM-configured Taito B games
// (pbobble, bublbust, spacedx, spacedxj, qzshowby).
//
// Functionally a 4-player sibling of the TC0220IOC without the rotary/paddle inputs, so
// the port shape here deliberately matches rtl/tc0220ioc.sv to keep the two muxable at
// the call site.
//
// Behaviour transcribed from MAME src/mame/taito/taitoio.cpp:
//
//   read : 0..3 -> input ports, 4 -> the last value written to reg 4, 7 -> input port,
//          everything else reads 0xff (NOT 0x00 - the TC0220IOC model differs here)
//   write: every offset latches into regs[]; offset 0 additionally kicks the watchdog and
//          offset 4 drives the coin counters and lockouts
//
// On the 68000 side these registers are reached through halfword_byteswap_r/w, i.e. the
// byte lives in D15-D8 and a word read returns { reg, 8'h00 }. That packing is done by
// the bus decode in TaitoB.sv, not here.

module TC0640FIO(
    input             clk,

    input             RES_INn,

    input       [3:0] A,
    input             WEn,        // active low write
    input             CSn,
    input             OEn,

    input       [7:0] Din,
    output reg  [7:0] Dout,

    output reg        COIN_LOCK_A,
    output reg        COIN_LOCK_B,
    output reg        COINMETER_A,
    output reg        COINMETER_B,

    // Watchdog kick - one clk pulse on any write to register 0.
    output reg        watchdog_kick,

    input       [7:0] INB,        // register 7
    input      [31:0] IN          // registers 0..3, little end first
);

reg [7:0] regs[16];

always_ff @(posedge clk) begin
    watchdog_kick <= 1'b0;

    if (~RES_INn) begin
        for (int i = 0; i < 16; i++) regs[i] <= 8'd0;
        COIN_LOCK_A <= 1'b0;
        COIN_LOCK_B <= 1'b0;
        COINMETER_A <= 1'b0;
        COINMETER_B <= 1'b0;
        Dout        <= 8'd0;
    end else if (~CSn) begin
        if (WEn) begin
            case (A)
                4'd0: Dout <= IN[7:0];
                4'd1: Dout <= IN[15:8];
                4'd2: Dout <= IN[23:16];
                4'd3: Dout <= IN[31:24];
                4'd4: Dout <= regs[4];
                4'd7: Dout <= INB;
                default: Dout <= 8'hff;
            endcase
        end else begin
            regs[A] <= Din;

            case (A)
                4'd0: watchdog_kick <= 1'b1;
                4'd4: begin
                    // bit0 = ~lockout1, bit1 = ~lockout2, bit2 = counter1, bit3 = counter2
                    COIN_LOCK_A <= ~Din[0];
                    COIN_LOCK_B <= ~Din[1];
                    COINMETER_A <=  Din[2];
                    COINMETER_B <=  Din[3];
                end
                default: begin end
            endcase
        end
    end
end

endmodule
