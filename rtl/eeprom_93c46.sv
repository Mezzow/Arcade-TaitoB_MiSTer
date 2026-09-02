// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer (Arcade-TaitoB). AI-generated; see README for credits.
//
// 93C46 serial EEPROM, 16-bit organisation (64 words x 16 bits).
//
// Used by the EEPROM-configured Taito B games in place of DIP switches, so this holds all
// of Puzzle Bobble's operator settings. MAME instantiates it as EEPROM_93C46_16BIT.
//
// Wiring on Taito B (from MAME's taito_b.cpp):
//   DI, CLK, CS  come from bits 2, 3, 4 of the byte written to $500026 (D15-D8)
//   DO           is read back through TC0640FIO register 1, bit 0, ACTIVE HIGH
//
// CS/CLK/DI are driven by 68000 register writes, so they change far more slowly than clk.
// Edges are detected in the clk domain; no synchronisers are needed because the source is
// already synchronous to clk.
//
// The nv_* port is a byte-wide backdoor for MiSTer NVRAM save/restore. Byte order within a
// word is little-endian: nv_addr[0]==0 selects the low byte. The MRA declares
// <nvram index="2" size="128"/> to match.

module eeprom_93c46(
    input             clk,
    input             reset,

    // Serial interface
    input             cs,
    input             sck,
    input             di,
    output reg        dout,

    // NVRAM backdoor (byte addressed, 128 bytes)
    input       [6:0] nv_addr,
    input       [7:0] nv_din,
    input             nv_wr,
    output      [7:0] nv_q,

    // Pulses whenever the GAME changes the contents, so the top level knows there is
    // something worth asking the firmware to save. A host restore does not pulse it -
    // that would immediately ask to save back what was just loaded.
    output reg        nv_changed
);

localparam [1:0] OP_SPECIAL = 2'b00;
localparam [1:0] OP_WRITE   = 2'b01;
localparam [1:0] OP_READ    = 2'b10;
localparam [1:0] OP_ERASE   = 2'b11;

localparam [1:0] ST_START = 2'd0;  // waiting for the start bit
localparam [1:0] ST_CMD   = 2'd1;  // shifting in 2 opcode + 6 address bits
localparam [1:0] ST_READ  = 2'd2;  // shifting data out
localparam [1:0] ST_WRITE = 2'd3;  // shifting data in

// Cold-boot contents are all ones, matching both a physically erased 93C46 and MAME:
// dumping MAME's nvram one second into a run shows 128 bytes of 0xFF, and the game writes
// its own defaults over that later. So an all-ones image is NOT what makes Puzzle Bobble
// report "EEP ROM ERROR".
reg [15:0] mem[64];
initial begin
    for (int i = 0; i < 64; i++) mem[i] = 16'hffff;
end

reg  [1:0] state;
reg [15:0] sr;
reg  [4:0] cnt;
reg  [1:0] opcode;
reg  [5:0] addr;
reg        we_en;      // set by EWEN, cleared by EWDS
reg        wral;       // this write targets every word

reg prev_sck, prev_cs;

assign nv_q = nv_addr[0] ? mem[nv_addr[6:1]][15:8] : mem[nv_addr[6:1]][7:0];

wire sck_rise = sck & ~prev_sck;
wire cs_rise  = cs  & ~prev_cs;

always_ff @(posedge clk) begin
    prev_sck <= sck;
    prev_cs  <= cs;

    nv_changed <= 1'b0;

    if (reset) begin
        state      <= ST_START;
        cnt        <= 5'd0;
        we_en      <= 1'b0;
        wral       <= 1'b0;
        dout       <= 1'b1;   // ready
    end else if (nv_wr) begin
        // Host restore. Deliberately takes priority: a restore only happens while the
        // core is held in reset by the ROM/NVRAM download.
        if (nv_addr[0]) mem[nv_addr[6:1]][15:8] <= nv_din;
        else            mem[nv_addr[6:1]][7:0]  <= nv_din;
    end else if (~cs) begin
        // Deselected: abandon any command in flight and report ready.
        state <= ST_START;
        cnt   <= 5'd0;
        dout  <= 1'b1;
    end else begin
        if (cs_rise) begin
            state <= ST_START;
            cnt   <= 5'd0;
            dout  <= 1'b1;
        end

        if (sck_rise) begin
            case (state)
                ST_START: begin
                    // A start bit is a 1; leading zeros are ignored.
                    if (di) begin
                        state <= ST_CMD;
                        cnt   <= 5'd0;
                    end
                end

                ST_CMD: begin
                    sr  <= {sr[14:0], di};
                    cnt <= cnt + 5'd1;

                    if (cnt == 5'd7) begin
                        // sr[6:0] plus the bit arriving now form opcode(2) + address(6)
                        opcode <= {sr[6], sr[5]};
                        addr   <= {sr[4:0], di};
                        cnt    <= 5'd0;

                        case ({sr[6], sr[5]})
                            OP_READ: begin
                                // The dummy 0 appears ON this clock - the one that shifts
                                // in the last address bit - not on the following one. Data
                                // then starts with D15 on the very next clock.
                                //
                                // Spending an extra clock here shifts the whole word right
                                // by one: the host samples the dummy in place of D15 and
                                // reads 0x7FFF instead of 0xFFFF, which is exactly what a
                                // DO capture showed before this was fixed.
                                dout  <= 1'b0;
                                sr    <= mem[{sr[4:0], di}];
                                state <= ST_READ;
                            end

                            OP_WRITE: begin
                                state <= ST_WRITE;
                                wral  <= 1'b0;
                            end

                            OP_ERASE: begin
                                if (we_en) begin
                                    mem[{sr[4:0], di}] <= 16'hffff;
                                    nv_changed <= 1'b1;
                                end
                                state <= ST_START;
                            end

                            OP_SPECIAL: begin
                                // The top two address bits select the sub-command.
                                case ({sr[4], sr[3]})
                                    2'b00: begin we_en <= 1'b0; state <= ST_START; end  // EWDS
                                    2'b01: begin state <= ST_WRITE; wral <= 1'b1; end   // WRAL
                                    2'b10: begin                                        // ERAL
                                        if (we_en)
                                            for (int i = 0; i < 64; i++) mem[i] <= 16'hffff;
                                            nv_changed <= 1'b1;
                                        state <= ST_START;
                                    end
                                    2'b11: begin we_en <= 1'b1; state <= ST_START; end  // EWEN
                                endcase
                            end
                        endcase
                    end
                end

                ST_READ: begin
                    dout <= sr[15];
                    sr   <= {sr[14:0], 1'b0};
                    cnt  <= cnt + 5'd1;

                    if (cnt == 5'd15) begin
                        // Real parts roll straight on into the next word without a further
                        // dummy bit, so a host can stream the whole device in one command.
                        addr <= addr + 6'd1;
                        cnt  <= 5'd0;
                        sr   <= mem[addr + 6'd1];
                    end
                end

                ST_WRITE: begin
                    sr  <= {sr[14:0], di};
                    cnt <= cnt + 5'd1;

                    if (cnt == 5'd15) begin
                        if (we_en) begin
                            if (wral) begin
                                for (int i = 0; i < 64; i++) mem[i] <= {sr[14:0], di};
                                nv_changed <= 1'b1;
                            end else begin
                                mem[addr] <= {sr[14:0], di};
                                nv_changed <= 1'b1;
                            end
                        end
                        state <= ST_START;
                        cnt   <= 5'd0;
                        dout  <= 1'b1;  // ready
                    end
                end
            endcase
        end
    end
end

endmodule
