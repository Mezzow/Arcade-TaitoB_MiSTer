module TC0260DAR(
    input clk,
    input ce_pixel,
    input ce_double,

    // RGB555 vs RGB444
    input bpp15,
    // LSB color in [3:1]
    input bppmix,

    // CPU Interface
    input [15:0] MDin,
    output reg [15:0] MDout,

    input        CS,
    input [13:0] MA,
    input RWn,
    input UDSn,
    input LDSn,

    output DTACKn,

    input ACCMODE,

    // Video Input
    input HBLANKn,
    input VBLANKn,

    output OHBLANKn,
    output OVBLANKn,

    input [13:0] IM,
    output reg [7:0] VIDEOR,
    output reg [7:0] VIDEOG,
    output reg [7:0] VIDEOB,

    // RAM Interface
    // Real hardware uses an 8-bit interface clocked at double the pixel clock, which gives
    // the CPU a slot without costing the raster its read. This uses a 16-bit dual-port RAM
    // instead and gets the same result: port A below is the CPU, RA_VID/RDIN_VID is the
    // raster's own read port. They are independent, so a CPU access can never cost a pixel.
    output [13:0] RA,
    input [15:0] RDin,
    output [15:0] RDout,
    output reg RWELn,
    output reg RWEHn,

    output [13:0] RA_VID,
    input  [15:0] RDIN_VID
);

reg hb1, hb2, hb3, vb1, vb2, vb3;

wire busy = ~ACCMODE ? (HBLANKn & VBLANKn & hb1 & hb2 & hb3 & vb1 & vb2 & vb3) : 0;
reg cpu_access;

assign MDout = RDin;
assign RDout = MDin;
assign RA     = MA;
assign RA_VID = IM;
assign RWELn = cpu_access ? (RWn | LDSn) : 1;
assign RWEHn = cpu_access ? (RWn | UDSn) : 1;
assign DTACKn = CS ? ~cpu_access : 0;
assign OHBLANKn = hb3;
assign OVBLANKn = vb3;


always_ff @(posedge clk) begin
    if (ce_double) begin
        cpu_access <= CS & (~busy | cpu_access);
    end

    if (ce_pixel) begin
        hb1 <= HBLANKn; hb2 <= hb1; hb3 <= hb2;
        vb1 <= VBLANKn; vb2 <= vb1; vb3 <= vb2;

        // No ~cpu_access term. It used to be here, and it is what made a palette write
        // during active display black out the pixel the raster was on. With a dual-port RAM
        // the CPU has its own port and there is nothing to arbitrate: blanking is the only
        // reason to force black. cpu_access still gates the WRITE strobes below, and still
        // drives DTACKn, so CPU timing is untouched.
        if (hb2 & vb2) begin
            if (bpp15 & bppmix) begin
                VIDEOR <= { RDIN_VID[15:12], RDIN_VID[3], RDIN_VID[15:13] };
                VIDEOG <= { RDIN_VID[11:8], RDIN_VID[2], RDIN_VID[11:9] };
                VIDEOB <= { RDIN_VID[7:4], RDIN_VID[1], RDIN_VID[7:5] };
            end else if (bpp15) begin
                VIDEOR <= { RDIN_VID[14:10], RDIN_VID[14:12] };
                VIDEOG <= { RDIN_VID[9:5], RDIN_VID[9:7] };
                VIDEOB <= { RDIN_VID[4:0], RDIN_VID[4:2] };
            end else begin
                VIDEOR <= { RDIN_VID[15:12], RDIN_VID[15:12] };
                VIDEOG <= { RDIN_VID[11:8], RDIN_VID[11:8] };
                VIDEOB <= { RDIN_VID[7:4], RDIN_VID[7:4] };
            end
        end else begin
            VIDEOR <= 8'd0;
            VIDEOG <= 8'd0;
            VIDEOB <= 8'd0;
        end
    end
end

endmodule



