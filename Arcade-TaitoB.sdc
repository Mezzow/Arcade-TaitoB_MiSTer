derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ------------------------------------------------------------------------------------
# Audio filter multicycle
#
# This is the entire timing failure the core inherited from upstream, and it is not what
# the fork's notes assumed. Every failing path - all of them, from -4.146 ns down - runs
# inside audio_mix's IIR_filter instances, clk_sys to clk_sys, with about 21.8 ns of
# 39-bit multiply-accumulate against an 18.4 ns period.
#
# Those filters are entirely clock-enabled: every register in sys/iir_filter.v is
#     always @(posedge clk) if (ce)
# and audio_mix drives ce from a fractional divider at 4.00 MHz (54.328 * 55/747) - one
# pulse every ~13 clk_sys cycles. STA cannot infer that, so it times a thirteen-cycle path
# as if it had a single cycle. The logic has always had ~245 ns to settle; nothing about
# the hardware changes here, only what the analyser is told.
#
# 4 is deliberately far short of the real 13-cycle budget so the constraint stays true
# even if the mixer's rate is retuned. The paired hold constraint keeps hold analysis on
# the original edge, which is the standard pairing and the one that matters for safety.
# ------------------------------------------------------------------------------------
set_multicycle_path -setup -end 4 -from [get_registers {*IIR_filter:*}] -to [get_registers {*IIR_filter:*}]
set_multicycle_path -hold  -end 3 -from [get_registers {*IIR_filter:*}] -to [get_registers {*IIR_filter:*}]
