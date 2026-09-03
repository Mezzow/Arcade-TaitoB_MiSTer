// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// Taito B sound subsystem. Two board topologies live here.
//
// YM2610 / YM2610B + TC0140SYT (most sets). Identical to Taito F2: the SYT owns the Z80
// ROM chip selects, the 2-bit bank register at $F200, the work-RAM select at $C000-$DFFF,
// the YM select at $E000 and both YM ADPCM ROM fetches over SDRAM - verified against
// MAME's Taito B sound map, which decodes identically, so the SYT drops in unchanged.
//
// YM2203 + PC060HA (masterw, hitice, viofight, tetrista; hitice and viofight add an
// M6295). MAME implements the PC060HA as
//
//     class pc060ha_device : public tc0140syt_device
//
// with no overridden behaviour, so the same LLE is the mailbox on these boards too - only
// the Z80 page it answers on moves from $E2 to $A0. What does NOT carry over is the rest
// of the chip: on a PC060HA board the Z80 decode is discrete logic on the PCB, and the map
// is a different one entirely (MAME's masterw_sound_map / viofight_sound_map):
//
//     0000-3FFF  ROM, fixed        8000-8FFF  RAM, 4 KiB
//     4000-7FFF  ROM, banked       9000-9001  YM2203
//                                  A000       PC060HA slave port
//                                  A001       PC060HA slave comm
//                                  B000-B001  M6295, both addresses the same chip
//
// so cfg_ym2203 switches the decode below over to a local one and ignores the SYT's
// chip-select pins. The bank register is not a discrete latch either: it is the YM2203's
// own PSG port A masked to two bits
//
//     ymsnd.port_a_write_callback().set_membank(m_audiobank).mask(0x03);
//
// and machine_start() configures four 0x4000 entries from the base of the region, so
// entry N is simply ROM offset N*0x4000 - the same arithmetic the SYT does with
// {ROMCS0n, ROMA15, ROMA14}.
//
// Split out of TaitoB.sv so the sound subsystem can be simulated on its own.

import system_consts::*;

module taitob_sound(
    input             clk,
    input             reset,

    input             ce_8m,        // YM2610 master clock enable
    input             ce_4m,        // TC0140SYT internal timing
    input             ce_z80,       // Z80 - 4 MHz, or 6 on masterw/hitice/viofight/realpunc
    input             ce_12m,       // TC0140SYT
    input             ce_3m,        // YM2203 - 24 MHz XTAL / 8

    input             cfg_ym2610b,  // 6 FM channels out instead of 4
    input             cfg_ym2203,   // YM2203 + PC060HA board instead of YM2610 + TC0140SYT
    input             cfg_m6295,    // viofight, hitice: an OKI M6295 as well

    // ---- 68000 side of the TC0140SYT ------------------------------------------------
    input             cs_snd,
    input             cpu_rw,
    input      [15:0] cpu_data_out,
    input             cpu_addr0,
    output      [3:0] syt_cpu_dout,

    // ---- Z80 program ROM download ----------------------------------------------------
    input      [23:0] bram_addr,
    input       [7:0] bram_data,
    input             bram_wr,

    // ---- ADPCM ROM, over SDRAM --------------------------------------------------------
    output     [26:0] sdr_audio_addr,
    input      [15:0] sdr_audio_q,
    output            sdr_audio_req,
    input             sdr_audio_ack,

    // ---- Output ------------------------------------------------------------------------
    output     [15:0] audio_left,
    output     [15:0] audio_right,
    output      [9:0] psg_snd,
    output            audio_sample
);


wire [15:0] SND_ADD;
wire SRAMn, SNWRn, SNRDn, ROMCS0n, ROMCS1n;
wire ROMA14, ROMA15;
wire SNRESn, SNINTn, SNNMIn, SNMREQn, OP_Tn;

wire [3:0] syt_z80_dout;
wire [7:0] z80_dout, ym_dout, ym3_dout;
wire [7:0] sound_ram_q, sound_rom0_q;
wire [23:0] YAA, YBA;
wire [7:0] YAD, YBD;
wire AOEn, BOEn;

// ---- PC060HA-board Z80 decode ---------------------------------------------------------
// Only meaningful when cfg_ym2203; the muxes below all fall back to the SYT's own chip
// selects otherwise.
wire        a3_rom = ~SND_ADD[15];                        // 0000-7FFF
wire        a3_ram = SND_ADD[15:12] == 4'h8;              // 8000-8FFF
wire        a3_ym  = SND_ADD[15:12] == 4'h9;              // 9000-9001
wire        a3_oki = SND_ADD[15:12] == 4'hB;              // B000-B001

// Decode above is by address alone, as the TC0140SYT's own chip selects are; but a WRITE
// has a side effect, and the Z80's I/O cycles put register B on A15-A8, so an `out (c),a`
// with B = 0x80 or 0xB0 would hit the sound RAM or the OKI. Qualify the write strobe.
wire        z80_wr = ~SNWRn & ~SNMREQn;

// PSG port A, masked to two bits - see the header.
wire [7:0]  ym3_ioa;
wire [1:0]  bank3 = ym3_ioa[1:0];

wire        sel_rom = cfg_ym2203 ? a3_rom : (~ROMCS0n | ~ROMCS1n);
wire        sel_ram = cfg_ym2203 ? a3_ram : ~SRAMn;
wire        sel_ym  = cfg_ym2203 ? a3_ym  : ~OP_Tn;

wire [16:0] rom_rd_addr = cfg_ym2203
    ? (SND_ADD[14] ? {1'b0, bank3, SND_ADD[13:0]}          // 4000-7FFF, banked
                   : {3'b000,     SND_ADD[13:0]})          // 0000-3FFF, fixed
    : {ROMCS0n, ROMA15, ROMA14, SND_ADD[13:0]};

wire [12:0] ram_addr = cfg_ym2203 ? {1'b0, SND_ADD[11:0]} : SND_ADD[12:0];

wire [7:0]  oki_dout;
wire [17:0] oki_rom_addr;

wire        ym3_irq_n;
wire        z80_int_n = cfg_ym2203 ? ym3_irq_n : SNINTn;

wire signed [15:0] snd10_left, snd10_right, snd3_left, snd3_right;
wire         [9:0] psg10, psg3;
wire               sample10, sample3;

wire [7:0] z80_din = sel_rom              ? sound_rom0_q            :
                     sel_ram              ? sound_ram_q             :
                     sel_ym               ? (cfg_ym2203 ? ym3_dout : ym_dout) :
                     (cfg_ym2203 & a3_oki) ? oki_dout                :
                                            {4'd0, syt_z80_dout};

singleport_ram #(.WIDTH(8), .WIDTHAD(13)) sound_ram(
    .clock(clk),
    .wren(sel_ram & (cfg_ym2203 ? z80_wr : ~SNWRn)),
    .address(ram_addr),
    .data(z80_dout),
    .q(sound_ram_q)
);

wire sound_rom0_wr = bram_wr & |(bram_addr[23:0] & AUDIO_ROM_BLOCK_BASE[23:0]);

singleport_ram #(.WIDTH(8), .WIDTHAD(17)) sound_rom(
    .clock(clk),
    .wren(sound_rom0_wr),
    .address(sound_rom0_wr ? bram_addr[16:0] : rom_rd_addr),
    .data(bram_data),
    .q(sound_rom0_q)
);

tv80s z80(
`ifdef USE_AUTO_SS
    // Save states are not implemented. These wrappers are used because they are
    // the variant upstream compiles cleanly under Quartus; the save-state logic itself is
    // held inactive and optimised away.
    .auto_ss_rd(1'b0),
    .auto_ss_wr(1'b0),
    .auto_ss_device_idx(8'd0),
    .auto_ss_state_idx(16'd0),
    .auto_ss_base_device_idx(8'd0),
    .auto_ss_data_in(32'd0),
    .auto_ss_data_out(),
    .auto_ss_ack(),
`endif
    .clk(clk),
    .cen(ce_z80),
    .reset_n(SNRESn),
    .wait_n(1'b1),
    .int_n(z80_int_n),
    .nmi_n(SNNMIn),
    .busrq_n(1'b1),
    .m1_n(),
    .mreq_n(SNMREQn),
    .iorq_n(),
    .rd_n(SNRDn),
    .wr_n(SNWRn),
    .rfsh_n(),
    .halt_n(),
    .busak_n(),
    .A(SND_ADD),
    .di(z80_din),
    .dout(z80_dout)
);

// The YM2610 steals the accumulator slots of FM channels 0 and 4 for its two ADPCM
// streams, which is why it has four FM channels and not six. The YM2610B has all six, so
// in that mode jt10_acc adds the FM output of those channels alongside the ADPCM instead
// of replacing it. See rtl/jt12/hdl/jt10_acc.v.
jt10 jt10(
`ifdef USE_AUTO_SS
    // Save states are not implemented. These wrappers are used because they are
    // the variant upstream compiles cleanly under Quartus; the save-state logic itself is
    // held inactive and optimised away.
    .auto_ss_rd(1'b0),
    .auto_ss_wr(1'b0),
    .auto_ss_device_idx(8'd0),
    .auto_ss_state_idx(16'd0),
    .auto_ss_base_device_idx(8'd0),
    .auto_ss_data_in(32'd0),
    .auto_ss_data_out(),
    .auto_ss_ack(),
`endif
    .rst(~SNRESn),
    .clk(clk),
    .cen(ce_8m),
    .din(z80_dout),
    .addr(SND_ADD[1:0]),
    .cs_n(OP_Tn | cfg_ym2203),
    .wr_n(SNWRn),

    .dout(ym_dout),
    .irq_n(SNINTn),

    .adpcma_addr(YAA[19:0]),
    .adpcma_bank(YAA[23:20]),
    .adpcma_roe_n(AOEn),
    .adpcma_data(YAD),
    .adpcmb_addr(YBA[23:0]),
    .adpcmb_roe_n(BOEn),
    .adpcmb_data(YBD),

    .psg_A(), .psg_B(), .psg_C(),
    .fm_snd(),

    .psg_snd(psg10),
    .snd_right(snd10_right),
    .snd_left(snd10_left),
    .snd_sample(sample10),
    .ch_enable(6'b111111),
    .ym2610b(cfg_ym2610b)
);

// ---- YM2203 ---------------------------------------------------------------------------
// jt03 is exactly this parameterisation of jt12_top, but jt03.v is not part of the
// flattened jt10_auto_ss.sv the Quartus flow compiles (see files.qip for why the flattened
// variant is used) and adding it would redeclare jt12_top. So instantiate jt12_top with
// jt03's own parameters: three FM channels, SSG present, no PCM and no ADPCM - which is
// also what selects the YM2203 accumulator (gen_2203_acc) inside jt12_top.
//
// MAME clocks this at 24_MHz_XTAL/8 = 3 MHz. ce_3m is the halved output of the same
// divider that makes the 6 MHz Z80 enable, so the two stay in exact ratio.
jt12_top #(
    .use_lfo(0), .use_ssg(1), .num_ch(3), .use_pcm(0), .use_adpcm(0), .mask_div(0)
) jt03(
`ifdef USE_AUTO_SS
    .auto_ss_rd(1'b0),
    .auto_ss_wr(1'b0),
    .auto_ss_device_idx(8'd0),
    .auto_ss_state_idx(16'd0),
    .auto_ss_base_device_idx(8'd0),
    .auto_ss_data_out(),
    .auto_ss_ack(),
`endif
    .rst(~SNRESn),
    .clk(clk),
    .cen(ce_3m),
    .din(z80_dout),
    .addr({1'b0, SND_ADD[0]}),
    .cs_n(~(sel_ym & cfg_ym2203)),
    .wr_n(~z80_wr),

    .dout(ym3_dout),
    .irq_n(ym3_irq_n),

    .en_hifi_pcm(1'b0),
    .adpcma_addr(), .adpcma_bank(), .adpcma_roe_n(), .adpcma_data(8'd0),
    .adpcmb_addr(), .adpcmb_roe_n(), .adpcmb_data(8'd0),

    // Port A is the ROM bank register; port B is unused on all four boards.
    .IOA_in(8'hff), .IOB_in(8'hff),
    .IOA_out(ym3_ioa), .IOB_out(), .IOA_oe(), .IOB_oe(),

    .psg_A(), .psg_B(), .psg_C(),
    .fm_snd_left(), .fm_snd_right(),
    .adpcmA_l(), .adpcmA_r(), .adpcmB_l(), .adpcmB_r(),

    .psg_snd(psg3),
    .snd_right(snd3_right),
    .snd_left(snd3_left),
    .snd_sample(sample3),
    .ch_enable(6'd0),
    .ym2610b(1'b0),
    .debug_bus(8'd0),
    .debug_view()
);

// The OKI is summed with the FM before the board's output filter, which is where the two
// meet on the PCB. MAME routes the three FM channels at 0.25 and the OKI at 0.50, so the
// OKI is doubled relative to jt03's already-summed FM output.
//
// Summed in 17 bits and saturated: jt03's output is full-scale 16-bit signed on its own, so
// a loud chord under a loud sample overflows, and an overflow that wraps is not a quiet
// distortion - it is a full-amplitude sign flip, i.e. a click on every peak.
wire signed [15:0] oki_mix = cfg_m6295 ? {{2{oki_snd[13]}}, oki_snd} : 16'sd0;

function automatic signed [15:0] sat_add(input signed [15:0] a, input signed [15:0] b);
    logic signed [16:0] t;
    t = {a[15], a} + {b[15], b};
    sat_add = t[16] != t[15] ? (t[16] ? 16'sh8000 : 16'sh7FFF) : t[15:0];
endfunction

assign audio_left   = cfg_ym2203 ? sat_add(snd3_left,  oki_mix) : snd10_left;
assign audio_right  = cfg_ym2203 ? sat_add(snd3_right, oki_mix) : snd10_right;
assign psg_snd      = cfg_ym2203 ? psg3       : psg10;
assign audio_sample = cfg_ym2203 ? sample3    : sample10;

// ---- OKI M6295 (viofight, hitice) -----------------------------------------------------
// One register, no address input - MAME maps b000 AND b001 to the same chip and says so.
// MAME clocks it at 1056000 Hz with PIN7_HIGH, which is jt6295's ss=1 (divide by 132).
// 54.328 * 9/463 = 1.056052 MHz.
// W=2, not 1: with W=1 the module's own output assignment is
//     cen <= { toggle[W-2:0], 1'b1 };
// which is toggle[-1:0] - an illegal part select that Verilator only tolerates because the
// bench waives SELRANGE. Take the base rate off a W=2 instance and ignore the halved one.
wire ce_1m, ce_500k_unused;
jtframe_frac_cen #(2) cen_oki(
    .clk(clk),
    .cen_in(1'b1),
    .n(10'd9),
    .m(10'd463),
    .cen({ce_500k_unused, ce_1m}),
    .cenb()
);

// Sample ROM, fetched over the SDRAM channel the TC0140SYT owns on every other board. The
// PC060HA boards have no ADPCM at all, so that channel is idle here (YAOEn/YBOEn are forced
// inactive below) and the OKI gets it to itself. One 16-bit read is outstanding at a time;
// jt6295 holds rom_addr until rom_ok, so a hit on the word already fetched costs nothing.
reg  [16:0] oki_word_addr;
reg  [15:0] oki_word;
reg         oki_have, oki_pending, oki_req;
wire        oki_hit  = oki_have & (oki_word_addr == oki_rom_addr[17:1]);
wire [7:0]  oki_data = oki_rom_addr[0] ? oki_word[15:8] : oki_word[7:0];
reg  [26:0] oki_sdr_addr;

always_ff @(posedge clk) begin
    if (reset) begin
        oki_have    <= 1'b0;
        oki_pending <= 1'b0;
        oki_req     <= 1'b0;
    end else if (oki_req == sdr_audio_ack) begin
        if (oki_pending) begin
            oki_word    <= sdr_audio_q;
            oki_pending <= 1'b0;
            oki_have    <= 1'b1;
        end else if (~oki_hit & cfg_m6295) begin
            oki_word_addr <= oki_rom_addr[17:1];
            oki_have      <= 1'b0;
            oki_pending   <= 1'b1;
            oki_sdr_addr  <= OKI_ROM_SDR_BASE[26:0] + {9'd0, oki_rom_addr[17:1], 1'b0};
            oki_req       <= ~oki_req;
        end
    end
end

wire signed [13:0] oki_snd;

jt6295 oki(
    .rst(reset),
    .clk(clk),
    .cen(ce_1m),
    .ss(1'b1),

    .wrn(~(cfg_ym2203 & a3_oki & z80_wr)),
    .din(z80_dout),
    .dout(oki_dout),

    .rom_addr(oki_rom_addr),
    .rom_data(oki_data),
    .rom_ok(oki_hit),

    .sound(oki_snd),
    .sample()
);

// The SYT and the OKI cannot both want the audio SDRAM channel: cfg_m6295 implies
// cfg_ym2203, which forces the SYT's two ADPCM fetches inactive. Hold the SYT's own view of
// the handshake at "idle" anyway, so a toggle the OKI causes can never look to it like the
// completion of a request it did not make.
wire [26:0] syt_sdr_addr;
wire        syt_sdr_req;

assign sdr_audio_addr = cfg_m6295 ? oki_sdr_addr : syt_sdr_addr;
assign sdr_audio_req  = cfg_m6295 ? oki_req      : syt_sdr_req;

TC0140SYT tc0140syt(
    .clk(clk),
    .ce_12m(ce_12m),
    .ce_4m(ce_4m),

    .RESn(~reset),

    .MDin(cpu_data_out[11:8]),
    .MDout(syt_cpu_dout),
    .MA1(cpu_addr0),
    .MCSn(~cs_snd),
    .MRDn(~cpu_rw),
    .MWRn(cpu_rw),

    .MREQn(SNMREQn),
    .RDn(SNRDn),
    .WRn(SNWRn),
    .A(SND_ADD),
    .Din(z80_dout[3:0]),
    .Dout(syt_z80_dout),
    .slave_page(cfg_ym2203 ? 8'hA0 : 8'hE2),

    .NMIn(SNNMIn),
    .ROUTn(SNRESn),
    .ROMCS0n(ROMCS0n),
    .ROMCS1n(ROMCS1n),
    .RAMCSn(SRAMn),
    .ROMA14(ROMA14),
    .ROMA15(ROMA15),

    .OPXn(OP_Tn),
    // A YM2203 has no ADPCM, so nothing must ask the SYT to fetch a sample.
    .YAOEn(AOEn | cfg_ym2203),
    .YBOEn(BOEn | cfg_ym2203),
    .YAA(YAA),
    .YBA(YBA),
    .YAD(YAD),
    .YBD(YBD),

    .CSAn(), .CSBn(), .IOA(), .IOC(),

    .sdr_address(syt_sdr_addr),
    .sdr_data(sdr_audio_q),
    .sdr_req(syt_sdr_req),
    .sdr_ack(cfg_m6295 ? syt_sdr_req : sdr_audio_ack)
);

endmodule
