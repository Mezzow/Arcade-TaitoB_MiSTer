// Taito B System - global constants, memory region map and per-game enum.
//
// Derived from the Taito F2 core's system_consts.sv. The storage/region mechanism is
// unchanged; the region set and the game enum are Taito B's.
//
// Region indices are the indices into LOAD_REGIONS below, and they are what the .mra
// emits as the first byte of each region header. Keep the MRA generator and this table
// in step -- a mismatch silently loads a ROM to the wrong place.

package system_consts;
    // Save-state slot indices.
    parameter int SSIDX_GLOBAL     = 0;
    parameter int SSIDX_VCU_RAM    = 1;   // TC0180VCU VRAM
    parameter int SSIDX_COLOR_RAM  = 2;   // palette RAM
    parameter int SSIDX_CPU_RAM    = 3;   // 68000 work RAM
    parameter int SSIDX_VCU_CTRL   = 4;   // TC0180VCU control regs + scroll RAM
    parameter int SSIDX_OBJ_RAM    = 5;   // sprite RAM
    parameter int SSIDX_AUDIO_RAM  = 6;   // Z80 work RAM
    parameter int SSIDX_Z80        = 7;
    parameter int SSIDX_YM         = 8;
    parameter int SSIDX_EEPROM     = 9;   // 93C46 contents
    parameter int SSIDX_VCU_FB     = 10;  // sprite framebuffer

    parameter bit [31:0] SS_DDR_BASE       = 32'h3E00_0000;
    parameter bit [31:0] OBJ_FB_DDR_BASE   = 32'h3800_0000;  // TC0180VCU sprite framebuffer
    parameter bit [31:0] DOWNLOAD_DDR_BASE = 32'h3000_0000;

    // SDRAM byte offsets. pbobble is the largest-region case so far:
    //   CPU 0x080000, VCU gfx 0x100000, ADPCM-A 0x100000, Z80 0x020000 (BRAM).
    // Regions are spaced generously so bigger sets in taito_b.cpp still fit.
    parameter bit [31:0] CPU_ROM_SDR_BASE     = 32'h0000_0000;  // 68000 program, <= 1 MB
    // The graphics region needs FOUR megabytes, not two. silentd, sbm and realpunc all
    // declare ROM_REGION 0x400000 for the TC0180VCU, and at the old spacing the audio
    // regions began 2 MB after the graphics base - so the second half of a 4 MB set was
    // written over by ADPCM-A, and the tiles that live there came back as noise. It did
    // not show on the three sets that were on hardware, because all of them are 1 or
    // 2 MB. Addresses are 27 bits here, so there is room to spare.
    parameter bit [31:0] VCU_ROM_SDR_BASE     = 32'h0010_0000;  // TC0180VCU tile/sprite gfx, <= 4 MB
    parameter bit [31:0] ADPCMA_ROM_SDR_BASE  = 32'h0050_0000;  // YM2610 ADPCM-A, <= 2 MB
    parameter bit [31:0] ADPCMB_ROM_SDR_BASE  = 32'h0070_0000;  // YM2610 ADPCM-B (delta-T), <= 1 MB
    parameter bit [31:0] OKI_ROM_SDR_BASE     = 32'h0080_0000;  // M6295 (hitice, viofight)
    parameter bit [31:0] AUDIO_ROM_BLOCK_BASE = 32'h0010_0000;  // Z80 program, BRAM

    // No Taito B game has a split/second 68000 ROM region, so this is unused: TaitoB.sv
    // ties rom_cache's extra_rom_n high. It exists only so the upstream rom_cache.sv,
    // which is shared with the F2 core, still elaborates without being forked.
    parameter bit [31:0] CPU_EXTRA_ROM_SDR_BASE = CPU_ROM_SDR_BASE;

    typedef enum bit [3:0] {
        STORAGE_SDR,
        STORAGE_DDR,
        STORAGE_BLOCK
    } region_storage_t;

    typedef enum bit [3:0] {
        ENCODING_NORMAL
    } region_encoding_t;

    typedef struct packed {
        bit [31:0] base_addr;
        region_storage_t storage;
        region_encoding_t encoding;
    } region_t;

    parameter region_t REGION_CPU_ROM   = '{ base_addr:CPU_ROM_SDR_BASE,     storage:STORAGE_SDR,   encoding:ENCODING_NORMAL };
    parameter region_t REGION_VCU_ROM   = '{ base_addr:VCU_ROM_SDR_BASE,     storage:STORAGE_SDR,   encoding:ENCODING_NORMAL };
    parameter region_t REGION_AUDIO_ROM = '{ base_addr:AUDIO_ROM_BLOCK_BASE, storage:STORAGE_BLOCK, encoding:ENCODING_NORMAL };
    parameter region_t REGION_ADPCMA    = '{ base_addr:ADPCMA_ROM_SDR_BASE,  storage:STORAGE_SDR,   encoding:ENCODING_NORMAL };
    parameter region_t REGION_ADPCMB    = '{ base_addr:ADPCMB_ROM_SDR_BASE,  storage:STORAGE_SDR,   encoding:ENCODING_NORMAL };
    parameter region_t REGION_OKI       = '{ base_addr:OKI_ROM_SDR_BASE,     storage:STORAGE_SDR,   encoding:ENCODING_NORMAL };

    // Index order IS the MRA region index. Do not reorder.
    parameter region_t LOAD_REGIONS[6] = '{
        REGION_CPU_ROM,    // 0
        REGION_VCU_ROM,    // 1
        REGION_AUDIO_ROM,  // 2
        REGION_ADPCMA,     // 3
        REGION_ADPCMB,     // 4
        REGION_OKI         // 5
    };

    // One entry per MAME machine config (18 configs cover all 40 taito_b.cpp sets).
    // The per-game table this drives lives in taitob_board_config.sv.
    typedef enum bit [7:0] {
        GAME_RASTSAG2,
        GAME_MASTERW,
        GAME_ASHURA,
        GAME_CRIMEC,
        GAME_HITICE,
        GAME_RAMBO3P,
        GAME_RAMBO3,
        GAME_PBOBBLE,
        GAME_SPACEDX,
        GAME_SPACEDXO,
        GAME_QZSHOWBY,
        GAME_VIOFIGHT,
        GAME_SELFEENA,
        GAME_SILENTD,
        GAME_SBM,
        GAME_REALPUNC,
        GAME_TETRIST,
        GAME_TETRISTA
    } game_t;

    // I/O chip variants. MASTERW genuinely has none - it reads its ports directly.
    // Plain parameters rather than an enum: enum-typed module ports need a var/cast dance
    // that Quartus 17.0.2's SystemVerilog front end handles inconsistently.
    parameter bit [1:0] IO_NONE      = 2'd0;
    parameter bit [1:0] IO_TC0220IOC = 2'd1;
    parameter bit [1:0] IO_TC0640FIO = 2'd2;
    parameter bit [1:0] IO_TC0510NIO = 2'd3;

    // How the five readable I/O registers are populated. The chip is register-compatible
    // across the family; what changes is which port lands where, and MAME's
    // read_N_callback wiring is the authority.
    //   IOL_FIO   reg0 SERVICE, reg1 COIN+EEPROM, reg2 START, reg3 buttons, reg7 joys
    //             (pbobble, spacedx, qzshowby - TC0640FIO)
    //   IOL_IOC_A reg0 DSWA, reg1 DSWB, reg2 P1 joy+buttons, reg3 P2 joy+buttons,
    //             reg7 system (ashura, crimec, rastsag2, rambo3, tetrist)
    //   IOL_IOC_B reg0 DSWA, reg1 DSWB, reg2 buttons, reg3 system, reg7 joysticks
    //             (selfeena, silentd, ryujin - the East Technology boards)
    //   IOL_SBM   reg0 DSWA, reg1 DSWB, reg2 joysticks, reg3 START, reg7 PHOTOSENSOR
    //   IOL_RPUNC reg0 DSWA, reg1 DSWB, reg2 START+SYSTEM, reg3 unused, reg7 safety switch
    //             and three photosensors - realpunc is a punching machine like sbm, but
    //             the ports are laid out differently and none of its sensors is active high
    //             (sbm - TC0510NIO). The photosensor port is the reason this needs its
    //             own layout: two of its bits are IP_ACTIVE_HIGH while every other input
    //             on the board is active low, so its idle value is 0x9F, not 0xFF.
    parameter bit [2:0] IOL_FIO   = 3'd0;
    parameter bit [2:0] IOL_IOC_A = 3'd1;
    parameter bit [2:0] IOL_IOC_B = 3'd2;
    parameter bit [2:0] IOL_SBM   = 3'd3;
    parameter bit [2:0] IOL_RPUNC = 3'd4;

    typedef struct packed {
        game_t    game;
        bit [7:0] unused;
    } board_cfg_t;

endpackage
