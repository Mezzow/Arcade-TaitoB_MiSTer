// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// MB87077 / MB87078 - Fujitsu 6-bit, 4-channel electronic volume controller.
//
// Present on pbobble, spacedx and qzshowby. The 68000 writes it at $600000/$600002 with
// the byte in D15-D8 (umask16(0xff00)), so the register offset is address bit 1.
//
// MAME emulates both parts in one device, src/devices/sound/mb87077.cpp - which is why an
// earlier search for "mb87078.cpp" came up empty and this module sat at unity gain with a
// TODO. The two parts differ only in the analogue pinout (MB87078 pin 8 is AGND, pin 17 is
// 1/2 VDD); the digital behaviour modelled here is identical.
//
// Datasheet, via MAME's header comment: gain is variable from 0 dB to -32 dB in 0.5 dB
// steps, or -infinity. Two latch groups selected by DSEL, which is the register offset:
//
//   offset 1 (control, 5 bits) : b1-0 channel select, b2 EN, b3 C0, b4 C32
//   offset 0 (data,    6 bits) : the gain code, and the write that commits the latch
//
// A data write commits {C32, C0, EN, gain[5:0]} into the latch of the channel the control
// register currently selects. Gain resolution is then, in priority order (gain_recalc()):
//
//   EN  = 0  ->  -infinity        (index 65)
//   C32 = 1  ->  -32 dB           (index 64)
//   C0  = 1  ->  0 dB             (index 0)
//   else     ->  index = ~gain[5:0]   - the code is active low
//
// Reset writes 0x7f to every channel latch: EN set, C0 and C32 clear, gain code 0x3f -
// which is active low, so it inverts to index 0. That is 0 dB, matching the datasheet's
// "Data is initialized by reset signal (all channels are set to 0dB)".
//
// The Taito B driver applies **channel 1** to all three YM2610 output channels:
//
//     void taitob_state::mb87078_gain_changed(offs_t offset, uint8_t data)
//     {
//         if (offset == 1) { sound->set_output_gain(0..2, data / 100.0); }
//     }
//
// MAME converts the gain to a whole percentage and divides by 100. That rounding is MAME's
// interface, not the chip's behaviour, so gain_q8 is the linear gain in Q8 instead - 256 is
// unity - and the mixer multiplies and shifts.

module mb87078(
    input             clk,
    input             reset,

    input             cs,       // one clk pulse per write
    input       [1:0] a,        // register offset, from address bit 1
    input       [7:0] din,      // byte from D15-D8

    output      [8:0] gain_q8,  // linear gain, Q8 (256 = unity), channel 1
    output      [7:0] gain_pct, // the same gain as MAME's percentage, for the bench
    output reg  [7:0] regs_0,
    output reg  [7:0] regs_1
);

reg [4:0] control;
reg [8:0] latch [0:3];   // {C32, C0, EN, gain[5:0]}

integer i;
always_ff @(posedge clk) begin
    if (reset) begin
        // MAME's device_reset() writes 0x7f to all four latches; see the header note on
        // why that resolves to 0 dB rather than to the C0 path.
        for (i = 0; i < 4; i = i + 1) latch[i] <= 9'h07f;
        control <= 5'd0;
        regs_0  <= 8'd0;
        regs_1  <= 8'd0;
    end else if (cs) begin
        if (a[0]) begin
            control <= din[4:0];
            regs_1  <= din;
        end else begin
            // The control register's EN/C0/C32 bits land at latch bits 6/7/8.
            latch[control[1:0]] <= {control[4:2], din[5:0]};
            regs_0 <= din;
        end
    end
end

// Channel 1 is the one the Taito B driver routes to the YM2610.
wire [8:0] ch1 = latch[1];

reg [6:0] gain_index;
always_comb begin
    if (~ch1[6])     gain_index = 7'd65;             // EN  = 0 -> -infinity
    else if (ch1[8]) gain_index = 7'd64;             // C32 = 1 -> -32 dB
    else if (ch1[7]) gain_index = 7'd0;              // C0  = 1 ->   0 dB
    else             gain_index = {1'b0, ~ch1[5:0]}; // the gain code is active low
end

reg [8:0] gain_q8_r;
always_comb begin
    case (gain_index)
        7'd0 : gain_q8_r = 9'd256;  //  -0.0 dB
        7'd1 : gain_q8_r = 9'd242;  //  -0.5 dB
        7'd2 : gain_q8_r = 9'd228;  //  -1.0 dB
        7'd3 : gain_q8_r = 9'd215;  //  -1.5 dB
        7'd4 : gain_q8_r = 9'd203;  //  -2.0 dB
        7'd5 : gain_q8_r = 9'd192;  //  -2.5 dB
        7'd6 : gain_q8_r = 9'd181;  //  -3.0 dB
        7'd7 : gain_q8_r = 9'd171;  //  -3.5 dB
        7'd8 : gain_q8_r = 9'd162;  //  -4.0 dB
        7'd9 : gain_q8_r = 9'd152;  //  -4.5 dB
        7'd10: gain_q8_r = 9'd144;  //  -5.0 dB
        7'd11: gain_q8_r = 9'd136;  //  -5.5 dB
        7'd12: gain_q8_r = 9'd128;  //  -6.0 dB
        7'd13: gain_q8_r = 9'd121;  //  -6.5 dB
        7'd14: gain_q8_r = 9'd114;  //  -7.0 dB
        7'd15: gain_q8_r = 9'd108;  //  -7.5 dB
        7'd16: gain_q8_r = 9'd102;  //  -8.0 dB
        7'd17: gain_q8_r = 9'd96 ;  //  -8.5 dB
        7'd18: gain_q8_r = 9'd91 ;  //  -9.0 dB
        7'd19: gain_q8_r = 9'd86 ;  //  -9.5 dB
        7'd20: gain_q8_r = 9'd81 ;  // -10.0 dB
        7'd21: gain_q8_r = 9'd76 ;  // -10.5 dB
        7'd22: gain_q8_r = 9'd72 ;  // -11.0 dB
        7'd23: gain_q8_r = 9'd68 ;  // -11.5 dB
        7'd24: gain_q8_r = 9'd64 ;  // -12.0 dB
        7'd25: gain_q8_r = 9'd61 ;  // -12.5 dB
        7'd26: gain_q8_r = 9'd57 ;  // -13.0 dB
        7'd27: gain_q8_r = 9'd54 ;  // -13.5 dB
        7'd28: gain_q8_r = 9'd51 ;  // -14.0 dB
        7'd29: gain_q8_r = 9'd48 ;  // -14.5 dB
        7'd30: gain_q8_r = 9'd46 ;  // -15.0 dB
        7'd31: gain_q8_r = 9'd43 ;  // -15.5 dB
        7'd32: gain_q8_r = 9'd41 ;  // -16.0 dB
        7'd33: gain_q8_r = 9'd38 ;  // -16.5 dB
        7'd34: gain_q8_r = 9'd36 ;  // -17.0 dB
        7'd35: gain_q8_r = 9'd34 ;  // -17.5 dB
        7'd36: gain_q8_r = 9'd32 ;  // -18.0 dB
        7'd37: gain_q8_r = 9'd30 ;  // -18.5 dB
        7'd38: gain_q8_r = 9'd29 ;  // -19.0 dB
        7'd39: gain_q8_r = 9'd27 ;  // -19.5 dB
        7'd40: gain_q8_r = 9'd26 ;  // -20.0 dB
        7'd41: gain_q8_r = 9'd24 ;  // -20.5 dB
        7'd42: gain_q8_r = 9'd23 ;  // -21.0 dB
        7'd43: gain_q8_r = 9'd22 ;  // -21.5 dB
        7'd44: gain_q8_r = 9'd20 ;  // -22.0 dB
        7'd45: gain_q8_r = 9'd19 ;  // -22.5 dB
        7'd46: gain_q8_r = 9'd18 ;  // -23.0 dB
        7'd47: gain_q8_r = 9'd17 ;  // -23.5 dB
        7'd48: gain_q8_r = 9'd16 ;  // -24.0 dB
        7'd49: gain_q8_r = 9'd15 ;  // -24.5 dB
        7'd50: gain_q8_r = 9'd14 ;  // -25.0 dB
        7'd51: gain_q8_r = 9'd14 ;  // -25.5 dB
        7'd52: gain_q8_r = 9'd13 ;  // -26.0 dB
        7'd53: gain_q8_r = 9'd12 ;  // -26.5 dB
        7'd54: gain_q8_r = 9'd11 ;  // -27.0 dB
        7'd55: gain_q8_r = 9'd11 ;  // -27.5 dB
        7'd56: gain_q8_r = 9'd10 ;  // -28.0 dB
        7'd57: gain_q8_r = 9'd10 ;  // -28.5 dB
        7'd58: gain_q8_r = 9'd9  ;  // -29.0 dB
        7'd59: gain_q8_r = 9'd9  ;  // -29.5 dB
        7'd60: gain_q8_r = 9'd8  ;  // -30.0 dB
        7'd61: gain_q8_r = 9'd8  ;  // -30.5 dB
        7'd62: gain_q8_r = 9'd7  ;  // -31.0 dB
        7'd63: gain_q8_r = 9'd7  ;  // -31.5 dB
        7'd64: gain_q8_r = 9'd6  ;  // -32.0 dB
        7'd65: gain_q8_r = 9'd0  ;  // -inf  
        default: gain_q8_r = 9'd256;
    endcase
end

assign gain_q8  = gain_q8_r;
// MAME rounds to a whole percent; reproduced only so the bench can print the same number.
assign gain_pct = 8'((({8'd0, gain_q8_r} * 16'd100) + 16'd128) >> 8);

endmodule
