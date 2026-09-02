module audio_mix(
    input clk,
    input reset,

    input               fm_sample,
    input signed [15:0] fm_left,
    input signed [15:0] fm_right,
    input        [ 9:0] psg,

    output reg signed [15:0] mono_output

);

// 2mhz, 4mhz
wire ce_2x, ce;
jtframe_frac_cen #(2) mix_cen
(
    .clk(clk),
    .cen_in(1),
    .n(10'd35),
    .m(10'd467),
    .cen({ce, ce_2x}),
    .cenb()
);


reg [15:0] stage1_in_l, stage1_in_r;
wire [15:0] stage1_out_l, stage1_out_r;
reg [15:0] stage2_in_l, stage2_in_r;
wire [15:0] stage2_out_l, stage2_out_r;

// 4th-order Butterworth, -3 dB at 15 kHz, at the ce this actually runs at (2.000021 MHz).
// The previous coefficients swung 15.83 dB across 100 Hz-10 kHz with a +3.80 dB hump at
// 3.6 kHz and a -3 dB corner at 6.0 kHz - measured on the RTL, not derived. That hump also
// cost 3.18 dB of PEAK headroom, which is why re-cornering is not only fidelity work: it is
// what makes the level correction below reachable at all.
//
// coeff_x additionally carries a deliberate +9.33 dB. Cascade DC gain is now 0.7494, not the
// 0.2560 it was - two half-gain sections where sys/iir_filter.v's own defaults are ~unity per
// stage. Measured deficit against MAME after the MB87078 fix was -10.33 (realpunc), -9.68
// (pbobble) and -9.35 dB (silentd), FLAT from 20 Hz to 4.5 kHz with 85-87% of the missing
// energy below 6 kHz - a level error, not a shape one. Stopping 0.5 dB short of closing it
// is what keeps hitice at 15% headroom; see the clamp below.
//
// Do NOT round these to tidy numbers. They are (bilinear Butterworth at 15 kHz) x 1.71100
// per stage, and that second factor IS the level correction.
IIR_filter #( .use_params(1), .stereo(1),
    .coeff_x(0.00310210523959025168),
    .coeff_x0(2), .coeff_x1(1), .coeff_x2(0),
    .coeff_y0(-1.91446199036013342543), .coeff_y1(0.91658959891062974368), .coeff_y2(0.00000000000000000000)
    ) pre_filter (
    .clk(clk),
    .reset(reset),

    .ce(ce_2x),
    .sample_ce(ce),

    .cx(), .cx0(), .cx1(), .cx2(), .cy0(), .cy1(), .cy2(),

    .input_l(stage1_in_l),
    .input_r(stage1_in_r),
    .output_l(stage1_out_l),
    .output_r(stage1_out_r)
);

IIR_filter #( .use_params(1), .stereo(1),
    .coeff_x(0.00317978855791501954),
    .coeff_x0(2), .coeff_x1(1), .coeff_x2(0),
    .coeff_y0(-1.96240419371289731565), .coeff_y1(0.96458508211031479540), .coeff_y2(0.00000000000000000000)
    ) main_filter (
    .clk(clk),
    .reset(reset),

    .ce(ce_2x),
    .sample_ce(ce),

    .cx(), .cx0(), .cx1(), .cx2(), .cy0(), .cy1(), .cy2(),

    .input_l(stage2_in_l),
    .input_r(stage2_in_r),
    .output_l(stage2_out_l),
    .output_r(stage2_out_r)
);


reg  [15:0] fm_left_final, fm_right_final;

// 18 bits, not 16. At the gain above, fm_combined wraps for |audio_left| > 17728, which IS
// reachable. At the old gain the threshold was 41352 - outside int16 - so the old 16-bit
// declaration was safe by accident rather than by design. A gain change converts nodes that
// were safe by construction into nodes that are merely unlikely.
reg signed [17:0] fm_combined;

// mono_output = 1.5 * (L + R) + the PSG term. The PSG bypasses BOTH IIR stages and the
// MB87078 attenuator and is UNSIGNED (0..32736), so it is a one-sided offset on a signed sum.
// Its level is NOT measured, therefore not touched: the sets that look like PSG evidence
// (silentd 4.6-7.0 s, hitice 5.8-7.0 s) have their SSG essentially off in those windows.
//
// This must CLAMP, not wrap. Worst case over the six sounding sets is hitice at 27843 of
// 32767 (15.0% headroom): its YM2203 path sets fm_snd_left = fm_snd_right, so the L+R
// doubling is exact rather than partial. A wrap here inverts to -32768 and clicks; the old
// code wrapped silently and nothing ever reached the rail to expose it.
wire signed [19:0] mono_wide = {{2{fm_combined[17]}}, fm_combined}
                             + {{3{fm_combined[17]}}, fm_combined[17:1]}
                             + $signed({5'd0, psg[9:0], 5'd0});

always @(posedge clk) begin
    if (ce) begin
        stage1_in_l <= fm_left;
        stage1_in_r <= fm_right;

        stage2_in_l <= stage1_out_l;
        stage2_in_r <= stage1_out_r;

        fm_left_final  <= stage2_out_l;
        fm_right_final <= stage2_out_r;

        fm_combined <= $signed({{2{fm_left_final[15]}},  fm_left_final})
                     + $signed({{2{fm_right_final[15]}}, fm_right_final});

        mono_output <= (mono_wide >  20'sd32767) ? 16'sh7FFF
                     : (mono_wide < -20'sd32768) ? 16'sh8000
                     : mono_wide[15:0];
    end
end

endmodule



