/* ****************************************************************************
  This Source Code Form is subject to the terms of the
  Open Hardware Description License, v. 1.0. If a copy
  of the OHDL was not distributed with this file, You
  can obtain one at http://juliusbaxter.net/ohdl/ohdl.txt

  Description: mor1kx control unit for MAROCCHINO pipeline
    a) generate pipeline controls
    b) manage SPRs
    c) issue addresses for exceptions to fetch stage
       control branches going to fetch stage
    d) contains tick timer & PIC logic

  Derived from mor1kx_ctrl_cappuccino.

  Copyright (C) 2012 Julius Baxter <juliusbaxter@gmail.com>
  Copyright (C) 2012-2013 Stefan Kristiansson <stefan.kristiansson@saunalahti.fi>
  Copyright (C) 2015 Andrey Bacherov <avbacherov@opencores.org>

***************************************************************************** */

`include "mor1kx-defines.v"

module mor1kx_ctrl_marocchino
#(
  parameter OPTION_OPERAND_WIDTH = 32,
  parameter OPTION_RESET_PC = {{(OPTION_OPERAND_WIDTH-13){1'b0}},
                               `OR1K_RESET_VECTOR,8'd0},

  parameter FEATURE_SYSCALL = "ENABLED",
  parameter FEATURE_TRAP = "ENABLED",
  parameter FEATURE_RANGE = "ENABLED",

  parameter FEATURE_DATACACHE = "NONE",
  parameter OPTION_DCACHE_BLOCK_WIDTH = 5,
  parameter OPTION_DCACHE_SET_WIDTH = 9,
  parameter OPTION_DCACHE_WAYS = 2,
  parameter FEATURE_DMMU = "NONE",
  parameter OPTION_DMMU_SET_WIDTH = 6,
  parameter OPTION_DMMU_WAYS = 1,
  parameter OPTION_ICACHE_BLOCK_WIDTH = 5,
  parameter OPTION_ICACHE_SET_WIDTH = 9,
  parameter OPTION_ICACHE_WAYS = 2,
  parameter OPTION_IMMU_SET_WIDTH = 6,
  parameter OPTION_IMMU_WAYS = 1,
  parameter FEATURE_TIMER = "ENABLED",
  parameter FEATURE_DEBUGUNIT = "NONE",
  parameter FEATURE_PERFCOUNTERS = "NONE",
  parameter FEATURE_PMU = "NONE",
  parameter FEATURE_MAC = "NONE",
  parameter FEATURE_FPU = "NONE",
  parameter FEATURE_MULTICORE = "NONE",

  parameter FEATURE_PIC = "ENABLED",
  parameter OPTION_PIC_TRIGGER = "LEVEL",
  parameter OPTION_PIC_NMI_WIDTH = 0,

  parameter FEATURE_DSX ="NONE",
  parameter FEATURE_FASTCONTEXTS = "NONE",
  parameter OPTION_RF_NUM_SHADOW_GPR = 0,
  parameter FEATURE_OVERFLOW = "NONE",
  parameter FEATURE_CARRY_FLAG = "ENABLED",

  parameter SPR_SR_WIDTH = 16,
  parameter SPR_SR_RESET_VALUE = 16'h8001
)
(
  input                             clk,
  input                             rst,


  // LSU address, needed for effective address
  input [OPTION_OPERAND_WIDTH-1:0]  lsu_adr_i,
  // Operand B from RF might be jump address, might be value for SPR
  input [OPTION_OPERAND_WIDTH-1:0]  exec_rfb_i,

  input                             wb_flag_set_i,
  input                             wb_flag_clear_i,
  input                             wb_atomic_flag_set_i,
  input                             wb_atomic_flag_clear_i,
  input                             wb_carry_set_i,
  input                             wb_carry_clear_i,
  input                             wb_overflow_set_i,
  input                             wb_overflow_clear_i,

  input [OPTION_OPERAND_WIDTH-1:0]  pc_wb_i,

  input [OPTION_OPERAND_WIDTH-1:0]  alu_nl_result_i,
  input                             exec_op_mfspr_i,
  input                             exec_op_mtspr_i,
  input                             wb_op_rfe_i,

  // Indicate if branch will be taken based on instruction currently in
  // decode stage.
  input                             dcod_branch_i,
  input [OPTION_OPERAND_WIDTH-1:0]  dcod_branch_target_i,

  input                             branch_mispredict_i,
  input [OPTION_OPERAND_WIDTH-1:0]  exec_mispredict_target_i,

  // PC of execute stage (NPC)
  input [OPTION_OPERAND_WIDTH-1:0]  pc_exec_i,

  input                             exec_op_branch_i,
  input                             wb_delay_slot_i,

  // Exception inputs, registered on output of execute stage
  input                             except_ibus_err_i,
  input                             except_itlb_miss_i,
  input                             except_ipagefault_i,
  input                             except_ibus_align_i,
  input                             except_illegal_i,
  input                             except_syscall_i,
  input                             except_dbus_i,
  input                             except_dtlb_miss_i,
  input                             except_dpagefault_i,
  input                             except_trap_i,
  input                             except_align_i,

  input                             wb_excepts_en_i,

  // Inputs from two units that can stall proceedings
  input                             fetch_valid_i,
  input                             exec_valid_i,

  input                             fetch_exception_taken_i,

  input                             dcod_bubble_i,
  input                             exec_bubble_i,

  // External IRQ lines in
  input [31:0]                      irq_i,

  // Exception PC output, used in the lsu to properly signal dbus errors that
  // has went through the store buffer
  output [OPTION_OPERAND_WIDTH-1:0] ctrl_epcr_o,
  // Exception PC input coming from the store buffer
  input [OPTION_OPERAND_WIDTH-1:0]  store_buffer_epcr_i,
  input                             store_buffer_err_i,

  // SPR data out
  output [OPTION_OPERAND_WIDTH-1:0] mfspr_dat_o,

  // WE to RF for l.mfspr
  output                            ctrl_mfspr_ack_o,
  output                            ctrl_mtspr_ack_o,

  // Flag out to branch control, combinatorial
  output                            ctrl_flag_o,
  output                            ctrl_carry_o,

  // FPU Status flags to and from ALU
  output [`OR1K_FPCSR_RM_SIZE-1:0]  ctrl_fpu_round_mode_o,
  input  [`OR1K_FPCSR_WIDTH-1:0]    wb_fpcsr_i,
  input                             wb_fpcsr_set_i,

  // Branch indicator from control unit (l.rfe/exceptions)
  output                            ctrl_branch_exception_o,
  // PC out to fetch stage for l.rfe, exceptions
  output [OPTION_OPERAND_WIDTH-1:0] ctrl_branch_except_pc_o,

  // Clear instructions from decode and fetch stage
  output                            pipeline_flush_o,

  output                            padv_fetch_o,
  output                            padv_decode_o,
  output reg                        exec_new_input_o, // 1-clock delayed of padv-decode
  output                            padv_wb_o,
  output                            wb_new_result_o, // 1-clock delayed of padv-execute

  // Debug bus
  input [15:0]                      du_addr_i,
  input                             du_stb_i,
  input [OPTION_OPERAND_WIDTH-1:0]  du_dat_i,
  input                             du_we_i,
  output [OPTION_OPERAND_WIDTH-1:0] du_dat_o,
  output                            du_ack_o,
  // Stall control from debug interface
  input                             du_stall_i,
  output                            du_stall_o,
  output [OPTION_OPERAND_WIDTH-1:0] du_restart_pc_o,
  output                            du_restart_o,

  // SPR accesses to external units (cache, mmu, etc.)
  output [15:0]                     spr_bus_addr_o,
  output                            spr_bus_we_o,
  output                            spr_bus_stb_o,
  output [OPTION_OPERAND_WIDTH-1:0] spr_bus_dat_o,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_dc_i,
  input                             spr_bus_ack_dc_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_ic_i,
  input                             spr_bus_ack_ic_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_dmmu_i,
  input                             spr_bus_ack_dmmu_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_immu_i,
  input                             spr_bus_ack_immu_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_mac_i,
  input                             spr_bus_ack_mac_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_pmu_i,
  input                             spr_bus_ack_pmu_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_pcu_i,
  input                             spr_bus_ack_pcu_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_bus_dat_fpu_i,
  input                             spr_bus_ack_fpu_i,
  input [OPTION_OPERAND_WIDTH-1:0]  spr_gpr_dat_i,
  input                             spr_gpr_ack_i,
  output [15:0]                     spr_sr_o,

  input [OPTION_OPERAND_WIDTH-1:0]  multicore_coreid_i,
  input [OPTION_OPERAND_WIDTH-1:0]  multicore_numcores_i
);

  // Internal signals
  reg [SPR_SR_WIDTH-1:0]            spr_sr;
  reg [SPR_SR_WIDTH-1:0]            spr_esr;
  reg [OPTION_OPERAND_WIDTH-1:0]    spr_epcr;
  reg [OPTION_OPERAND_WIDTH-1:0]    spr_eear;
  reg [OPTION_OPERAND_WIDTH-1:0]    spr_evbar;

  // Programmable Interrupt Control SPRs
  wire [31:0]                       spr_picmr;
  wire [31:0]                       spr_picsr;

  // Tick Timer SPRs
  wire [31:0]                       spr_ttmr;
  wire [31:0]                       spr_ttcr;

  // FPU Control & Status Register
  // and related exeption signals
  reg [`OR1K_FPCSR_WIDTH-1:0]       spr_fpcsr;
  wire                              except_fpu;

  reg [OPTION_OPERAND_WIDTH-1:0]    spr_ppc;
  reg [OPTION_OPERAND_WIDTH-1:0]    spr_npc;

  reg                               exception_r;
  reg [OPTION_OPERAND_WIDTH-1:0]    exception_pc_addr;
  wire                              exception_re;

  wire                              except_ticktimer;
  wire                              except_pic;

  reg                               doing_rfe_r;

  wire [15:0]                       spr_addr;

  /* Debug SPRs */
  reg [31:0]                        spr_dmr1;
  reg [31:0]                        spr_dmr2;
  reg [31:0]                        spr_dsr;
  reg [31:0]                        spr_drr;

  /* DU internal control signals */
  wire                              du_access;
  reg                               du_cpu_stall;
  wire                              du_restart_from_stall;
  reg [5:0]                         pstep;
  wire                              stepping;
  wire                              stepped_into_delay_slot;
  reg                               stepped_into_exception;
  reg                               stepped_into_rfe;
  wire                              du_npc_write;
  reg                               du_npc_written;
  wire                              du_stall_on_trap;

  /* Wires for SPR management */
  localparam                        SPR_ACCESS_WIDTH = 12;
  wire                              spr_access_valid;
  reg                               spr_we_en; // 1-clock write ensable strobe for local regs
  wire                              spr_we;
  wire                              spr_ack;
  wire   [OPTION_OPERAND_WIDTH-1:0] spr_write_dat;
  reg        [SPR_ACCESS_WIDTH-1:0] spr_access;
  wire       [SPR_ACCESS_WIDTH-1:0] spr_access_ack;
  wire                       [31:0] spr_internal_read_dat [0:SPR_ACCESS_WIDTH-1];
  wire                              spr_read_access;
  wire                              spr_write_access;
  wire                              spr_bus_access;
  reg [OPTION_OPERAND_WIDTH-1:0]    spr_sys_group_read;

  /* Wires from mor1kx_cfgrs module */
  wire [31:0]                       spr_vr;
  wire [31:0]                       spr_vr2;
  wire [31:0]                       spr_avr;
  wire [31:0]                       spr_upr;
  wire [31:0]                       spr_cpucfgr;
  wire [31:0]                       spr_dmmucfgr;
  wire [31:0]                       spr_immucfgr;
  wire [31:0]                       spr_dccfgr;
  wire [31:0]                       spr_iccfgr;
  wire [31:0]                       spr_dcfgr;
  wire [31:0]                       spr_pccfgr;
  wire [31:0]                       spr_isr [0:7];



  // Flag output
  wire   ctrl_flag_clear = wb_flag_clear_i | wb_atomic_flag_clear_i;
  wire   ctrl_flag_set   = wb_flag_set_i   | wb_atomic_flag_set_i;

  assign ctrl_flag_o     = (~ctrl_flag_clear) &
                           (ctrl_flag_set | spr_sr[`OR1K_SPR_SR_F]);

  // Carry output
  assign ctrl_carry_o = (FEATURE_CARRY_FLAG != "NONE") &
                        (~wb_carry_clear_i) &
                        (wb_carry_set_i | spr_sr[`OR1K_SPR_SR_CY]);

  // Overflow
  wire ctrl_overflow = (FEATURE_RANGE != "NONE") & spr_sr[`OR1K_SPR_SR_OVE] &
                       (~wb_overflow_clear_i) &
                       (wb_overflow_set_i | spr_sr[`OR1K_SPR_SR_OV]);


  //-------------------------------------//
  // Exceptions processing support logic //
  //-------------------------------------//

  // to FETCH: exceptions/rfe command and appropriate address
  assign ctrl_branch_exception_o = (exception_r | doing_rfe_r) & ~fetch_exception_taken_i;

  assign ctrl_branch_except_pc_o = exception_r ? exception_pc_addr : spr_epcr;


  // exceptions detection and processing
  wire except_range = ctrl_overflow;

  wire exception =
    wb_excepts_en_i &
    ((except_ibus_err_i | except_ibus_align_i | except_itlb_miss_i | except_ipagefault_i |
      except_illegal_i | except_syscall_i | except_range | except_fpu |except_trap_i |
      except_dbus_i | except_align_i | except_dtlb_miss_i | except_dpagefault_i) |
     ((except_ticktimer | except_pic) & wb_new_result_o));


  assign exception_re = exception & (~exception_r);

  wire deassert_exception = fetch_exception_taken_i & exception_r;
  
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      exception_r <= 1'b0;
    else if (deassert_exception | du_restart_from_stall)
      exception_r <= 1'b0;
    else if (exception_re)
      exception_r <= 1'b1;
  end // @ clock


  always @(posedge clk) begin
    if (exception_re)
      casez({except_itlb_miss_i,
             except_ipagefault_i,
             except_ibus_err_i,
             except_illegal_i,
             except_align_i,
             except_ibus_align_i,
             except_syscall_i,
             except_dtlb_miss_i,
             except_dpagefault_i,
             except_trap_i,
             except_dbus_i,
             except_range,
             except_fpu,
             except_pic,
             except_ticktimer
            })
        15'b1??????????????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_ITLB_VECTOR,8'd0};
        15'b01?????????????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_IPF_VECTOR,8'd0};
        15'b001????????????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_BERR_VECTOR,8'd0};
        15'b0001???????????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_ILLEGAL_VECTOR,8'd0};
        15'b00001??????????,
        15'b000001?????????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_ALIGN_VECTOR,8'd0};
        15'b0000001????????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_SYSCALL_VECTOR,8'd0};
        15'b00000001???????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_DTLB_VECTOR,8'd0};
        15'b000000001??????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_DPF_VECTOR,8'd0};
        15'b0000000001?????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_TRAP_VECTOR,8'd0};
        15'b00000000001????: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_BERR_VECTOR,8'd0};
        15'b000000000001???: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_RANGE_VECTOR,8'd0};
        15'b0000000000001??: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_FP_VECTOR,8'd0};
        15'b00000000000001?: exception_pc_addr <= spr_evbar | {19'd0,`OR1K_INT_VECTOR,8'd0};
        //15'b00000000000001:
        default:             exception_pc_addr <= spr_evbar | {19'd0,`OR1K_TT_VECTOR,8'd0};
      endcase // casex (...
  end // @ clock


  // RFE related logic
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      doing_rfe_r <= 1'b0;
    else if (fetch_exception_taken_i & doing_rfe_r)
      doing_rfe_r <= 1'b0;
    else if (wb_op_rfe_i)
      doing_rfe_r <= 1'b1;
  end // @ clock



  //------------------------//
  // Pipeline control logic //
  //------------------------//

  assign padv_fetch_o =
    // MAROCCHINO_TODO: (~du_cpu_stall) & ((~stepping) | (stepping & pstep[0] & (~fetch_valid_i))) &  // from DU
    exec_valid_i & (~dcod_bubble_i);

  assign padv_decode_o =
    // MAROCCHINO_TODO: (~du_cpu_stall) & ((~stepping) | (stepping & pstep[1])) &  // from DU
    (fetch_valid_i | dcod_bubble_i) & exec_valid_i;

  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      exec_new_input_o <= 1'b0;
    else
      exec_new_input_o <= padv_decode_o;
  end // @ clock

  assign padv_wb_o       = padv_decode_o;
  assign wb_new_result_o = exec_new_input_o; // 1-clock delayed of padv-wb

  // Pipeline flush by DU/exceptions/rfe
  assign pipeline_flush_o = du_cpu_stall | exception_re | wb_op_rfe_i;


  // FPU related: FPCSR and exceptions
generate
 `ifdef OR1K_FPCSR_MASK_FLAGS
  reg [`OR1K_FPCSR_ALLF_SIZE-1:0] spr_fpcsr_mf; // mask for FPU flags
 `endif

/* verilator lint_off WIDTH */
if (FEATURE_FPU != "NONE") begin : fpu_csr_gen
/* verilator lint_on WIDTH */
  assign ctrl_fpu_round_mode_o = spr_fpcsr[`OR1K_FPCSR_RM];

  // select all flags
  // (1) Before issuing l.rfe, an exeption FPU handler
  //     must clean up all exeption flags in FPCSR.
  // (2) Only new arrived flags make sense to detect
  //     FPU exceptions.
 `ifdef OR1K_FPCSR_MASK_FLAGS
  wire [`OR1K_FPCSR_ALLF_SIZE-1:0] fpu_allf =
    wb_fpcsr_i[`OR1K_FPCSR_ALLF] & spr_fpcsr_mf;
 `else
  wire [`OR1K_FPCSR_ALLF_SIZE-1:0] fpu_allf = wb_fpcsr_i[`OR1K_FPCSR_ALLF];
 `endif

  assign except_fpu = wb_fpcsr_set_i &
                      spr_fpcsr[`OR1K_FPCSR_FPEE] &
                      (|fpu_allf);

  // FPU Control & status register
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst) begin
      spr_fpcsr <= `OR1K_FPCSR_RESET_VALUE;
     `ifdef OR1K_FPCSR_MASK_FLAGS
      spr_fpcsr_mf <= `OR1K_FPCSR_MASK_RESET_VALUE;
     `endif
    end
    else if (exception_re) begin
      spr_fpcsr[`OR1K_FPCSR_ALLF] <= fpu_allf;
      spr_fpcsr[`OR1K_FPCSR_RM]   <= spr_fpcsr[`OR1K_FPCSR_RM];
      spr_fpcsr[`OR1K_FPCSR_FPEE] <= 1'b0;
    end
    else if ((spr_we & spr_access[`OR1K_SPR_SYS_BASE] &
            ((spr_sr[`OR1K_SPR_SR_SM] & spr_we_en) | du_access)) &
             (`SPR_OFFSET(spr_addr)==`SPR_OFFSET(`OR1K_SPR_FPCSR_ADDR))) begin
      spr_fpcsr <= spr_write_dat[`OR1K_FPCSR_WIDTH-1:0]; // update all fields
     `ifdef OR1K_FPCSR_MASK_FLAGS
      spr_fpcsr_mf <= spr_write_dat[`OR1K_FPCSR_MASK_ALL];
     `endif
    end
    else if (wb_new_result_o & wb_fpcsr_set_i) begin
      spr_fpcsr[`OR1K_FPCSR_ALLF] <= fpu_allf;
      spr_fpcsr[`OR1K_FPCSR_RM]   <= spr_fpcsr[`OR1K_FPCSR_RM];
      spr_fpcsr[`OR1K_FPCSR_FPEE] <= spr_fpcsr[`OR1K_FPCSR_FPEE];
    end
  end // FPCSR reg's always(@posedge clk)
end
else begin : fpu_csr_none
  assign ctrl_fpu_round_mode_o = {`OR1K_FPCSR_RM_SIZE{1'b0}};
  assign except_fpu = 1'b0;
  // FPU Control & status register
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst) begin
      spr_fpcsr <= {`OR1K_FPCSR_WIDTH{1'b0}};
     `ifdef OR1K_FPCSR_MASK_FLAGS
      spr_fpcsr_mf <= {`OR1K_FPCSR_ALLF_SIZE{1'b0}};
     `endif
    end
  end // FPCSR reg's always(@posedge clk)
end
endgenerate // FPU related: FPCSR and exceptions


  // Supervision register
  assign spr_sr_o = spr_sr;
  //
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_sr <= SPR_SR_RESET_VALUE;
    else if (exception_re) begin
      // Go into supervisor mode, disable interrupts, MMUs
      // it doesn't matter if the next features are enabled or not
      spr_sr[`OR1K_SPR_SR_SM ] <= 1'b1; // supervisor mode
      spr_sr[`OR1K_SPR_SR_TEE] <= 1'b0; // block interrupt from timer
      spr_sr[`OR1K_SPR_SR_IEE] <= 1'b0; // block interrupt from PIC
      spr_sr[`OR1K_SPR_SR_DME] <= 1'b0; // D-MMU is off
      spr_sr[`OR1K_SPR_SR_IME] <= 1'b0; // I-MMU is off
      spr_sr[`OR1K_SPR_SR_OVE] <= 1'b0; // enable overflow excep.
      // depending on feature configuration
      spr_sr[`OR1K_SPR_SR_DSX] <= wb_delay_slot_i & (FEATURE_DSX != "NONE");
    end
    else if ((spr_we & spr_access[`OR1K_SPR_SYS_BASE] &
             ((spr_sr[`OR1K_SPR_SR_SM] & spr_we_en) | du_access)) &
             (`SPR_OFFSET(spr_addr) == `SPR_OFFSET(`OR1K_SPR_SR_ADDR))) begin
      // from SPR bus
      spr_sr[`OR1K_SPR_SR_SM ] <= spr_write_dat[`OR1K_SPR_SR_SM ];
      spr_sr[`OR1K_SPR_SR_F  ] <= spr_write_dat[`OR1K_SPR_SR_F  ];
      spr_sr[`OR1K_SPR_SR_TEE] <= spr_write_dat[`OR1K_SPR_SR_TEE] & (FEATURE_TIMER != "NONE");
      spr_sr[`OR1K_SPR_SR_IEE] <= spr_write_dat[`OR1K_SPR_SR_IEE] & (FEATURE_PIC != "NONE");
      spr_sr[`OR1K_SPR_SR_DCE] <= spr_write_dat[`OR1K_SPR_SR_DCE] & (FEATURE_DATACACHE != "NONE");
      spr_sr[`OR1K_SPR_SR_ICE] <= spr_write_dat[`OR1K_SPR_SR_ICE];
      spr_sr[`OR1K_SPR_SR_DME] <= spr_write_dat[`OR1K_SPR_SR_DME] & (FEATURE_DMMU != "NONE");
      spr_sr[`OR1K_SPR_SR_IME] <= spr_write_dat[`OR1K_SPR_SR_IME];
      spr_sr[`OR1K_SPR_SR_CE ] <= spr_write_dat[`OR1K_SPR_SR_CE ] & (FEATURE_FASTCONTEXTS != "NONE");
      spr_sr[`OR1K_SPR_SR_CY ] <= spr_write_dat[`OR1K_SPR_SR_CY ] & (FEATURE_CARRY_FLAG != "NONE");
      spr_sr[`OR1K_SPR_SR_OV ] <= spr_write_dat[`OR1K_SPR_SR_OV ] & (FEATURE_OVERFLOW != "NONE");
      spr_sr[`OR1K_SPR_SR_OVE] <= spr_write_dat[`OR1K_SPR_SR_OVE] & (FEATURE_OVERFLOW != "NONE");
      spr_sr[`OR1K_SPR_SR_DSX] <= spr_write_dat[`OR1K_SPR_SR_DSX] & (FEATURE_DSX != "NONE");
      spr_sr[`OR1K_SPR_SR_EPH] <= spr_write_dat[`OR1K_SPR_SR_EPH];
    end
    else if (wb_new_result_o) begin
      if (wb_op_rfe_i) begin
        // Skip FO. TODO: make this even more selective.
        spr_sr[14:0] <= spr_esr[14:0];
      end
      else begin
        spr_sr[`OR1K_SPR_SR_F ] <= ctrl_flag_o;
        spr_sr[`OR1K_SPR_SR_CY] <= ctrl_carry_o;
        spr_sr[`OR1K_SPR_SR_OV] <= ctrl_overflow;
      end
    end
  end // @ clock

  // Exception SR
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_esr <= SPR_SR_RESET_VALUE;
    else if (exception_re)
      spr_esr <= spr_sr; // by exceptions
    else if (spr_we & spr_access[`OR1K_SPR_SYS_BASE] &
             (`SPR_OFFSET(spr_addr)==`SPR_OFFSET(`OR1K_SPR_ESR0_ADDR)))
      spr_esr <= spr_write_dat[SPR_SR_WIDTH-1:0];
  end // @ clock


  // Exception PC
  //   PC of last branch insn
  reg [OPTION_OPERAND_WIDTH-1:0] last_branch_insn_pc;
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      last_branch_insn_pc <= {OPTION_OPERAND_WIDTH{1'b0}};
    else if (padv_wb_o & exec_op_branch_i)
      last_branch_insn_pc <= pc_exec_i;
  end // @clock

  //   special case for delay slot:
  //   on l.rfe re-run branch(jump) instruction
  assign ctrl_epcr_o = wb_delay_slot_i ? (pc_wb_i - 4) : pc_wb_i;

  //   E-P-C-R update
  always @(posedge clk) begin
    if (exception_re) begin
      if (except_ibus_err_i)
        spr_epcr <= last_branch_insn_pc;
      // Syscall is a special case, we return back to the instruction _after_
      // the syscall instruction, unless the syscall was in a delay slot
      else if (except_syscall_i)
        spr_epcr <= wb_delay_slot_i ? (pc_wb_i - 4) : (pc_wb_i + 4);
      else if (store_buffer_err_i)
        spr_epcr <= store_buffer_epcr_i;
      // Don't update EPCR on software breakpoint
      else if (~(du_stall_on_trap & except_trap_i))
        spr_epcr <= ctrl_epcr_o;
    end
    else if (spr_we & spr_access[`OR1K_SPR_SYS_BASE] &
             (`SPR_OFFSET(spr_addr)==`SPR_OFFSET(`OR1K_SPR_EPCR0_ADDR))) begin
      spr_epcr <= spr_write_dat;
    end
  end // @ clock

  // Exception Effective Address
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_eear <= {OPTION_OPERAND_WIDTH{1'b0}};
    else if (exception_re) begin
      if (except_ibus_err_i | except_itlb_miss_i | except_ipagefault_i)
        spr_eear <= pc_wb_i;
      else
        spr_eear <= lsu_adr_i;
    end
  end // @ clock


  // Track the PC
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_ppc <= OPTION_RESET_PC;
    else if (wb_new_result_o)
      spr_ppc <= pc_wb_i;
  end // @ clock



  reg [OPTION_OPERAND_WIDTH-1:0] last_branch_target_pc;
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      last_branch_target_pc <= {OPTION_OPERAND_WIDTH{1'b0}};
    else if (padv_wb_o & branch_mispredict_i)
      last_branch_target_pc <= exec_mispredict_target_i;
    else if (padv_decode_o & dcod_branch_i)
      last_branch_target_pc <= dcod_branch_target_i;
  end // @ clock

  // Generate the NPC for SPR accesses
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_npc <= OPTION_RESET_PC;
    else if (du_npc_write)
      spr_npc <= du_dat_i;
    else if (du_npc_written)
      spr_npc <= spr_npc;
    else if (stepping) begin
       if (stepped_into_rfe)
         spr_npc <= spr_epcr;
       else if (stepped_into_delay_slot)
         spr_npc <= last_branch_target_pc;
       else if (stepped_into_exception)
         spr_npc <= exception_pc_addr;
       else
         spr_npc <= pc_wb_i + 4;
    end
    else if (du_stall_on_trap & wb_new_result_o & except_trap_i) // DU related
      spr_npc <= pc_wb_i;
    else if (du_cpu_stall & wb_new_result_o) // DU related
      spr_npc <= ctrl_epcr_o;
    else if (~du_cpu_stall)
      spr_npc <= pc_exec_i;
  end // @ clock

  // Exception Vector Address
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_evbar <= {OPTION_OPERAND_WIDTH{1'b0}};
    else if (spr_we & spr_access[`OR1K_SPR_SYS_BASE] &
             (`SPR_OFFSET(spr_addr) == `SPR_OFFSET(`OR1K_SPR_EVBAR_ADDR)))
      spr_evbar <= {spr_write_dat[OPTION_OPERAND_WIDTH-1:13], 13'd0};
  end // @ clock

  // configuration registers
  mor1kx_cfgrs
  #(
    .FEATURE_PIC                     (FEATURE_PIC),
    .FEATURE_TIMER                   (FEATURE_TIMER),
    .OPTION_PIC_TRIGGER              (OPTION_PIC_TRIGGER),
    .FEATURE_DSX                     (FEATURE_DSX),
    .FEATURE_FASTCONTEXTS            (FEATURE_FASTCONTEXTS),
    .OPTION_RF_NUM_SHADOW_GPR        (OPTION_RF_NUM_SHADOW_GPR),
    .FEATURE_OVERFLOW                (FEATURE_OVERFLOW),
    .FEATURE_DATACACHE               (FEATURE_DATACACHE),
    .OPTION_DCACHE_BLOCK_WIDTH       (OPTION_DCACHE_BLOCK_WIDTH),
    .OPTION_DCACHE_SET_WIDTH         (OPTION_DCACHE_SET_WIDTH),
    .OPTION_DCACHE_WAYS              (OPTION_DCACHE_WAYS),
    .FEATURE_DMMU                    (FEATURE_DMMU),
    .OPTION_DMMU_SET_WIDTH           (OPTION_DMMU_SET_WIDTH),
    .OPTION_DMMU_WAYS                (OPTION_DMMU_WAYS),
    .FEATURE_INSTRUCTIONCACHE        ("ENABLED"), // mor1kx_cfgrs instance: marocchino
    .OPTION_ICACHE_BLOCK_WIDTH       (OPTION_ICACHE_BLOCK_WIDTH),
    .OPTION_ICACHE_SET_WIDTH         (OPTION_ICACHE_SET_WIDTH),
    .OPTION_ICACHE_WAYS              (OPTION_ICACHE_WAYS),
    .FEATURE_IMMU                    ("ENABLED"), // mor1kx_cfgrs instance: marocchino
    .OPTION_IMMU_SET_WIDTH           (OPTION_IMMU_SET_WIDTH),
    .OPTION_IMMU_WAYS                (OPTION_IMMU_WAYS),
    .FEATURE_DEBUGUNIT               (FEATURE_DEBUGUNIT),
    .FEATURE_PERFCOUNTERS            (FEATURE_PERFCOUNTERS),
    .FEATURE_MAC                     (FEATURE_MAC),
    .FEATURE_FPU                     (FEATURE_FPU), // mor1kx_cfgrs instance: marocchino
    .FEATURE_SYSCALL                 (FEATURE_SYSCALL),
    .FEATURE_TRAP                    (FEATURE_TRAP),
    .FEATURE_RANGE                   (FEATURE_RANGE),
    .FEATURE_DELAYSLOT               ("ENABLED"), // mor1kx_cfgrs instance: marocchino
    .FEATURE_EVBAR                   ("ENABLED")
  )
  u_cfgrs
  (
    // Outputs
    .spr_vr                           (spr_vr[31:0]),
    .spr_vr2                          (spr_vr2[31:0]),
    .spr_upr                          (spr_upr[31:0]),
    .spr_cpucfgr                      (spr_cpucfgr[31:0]),
    .spr_dmmucfgr                     (spr_dmmucfgr[31:0]),
    .spr_immucfgr                     (spr_immucfgr[31:0]),
    .spr_dccfgr                       (spr_dccfgr[31:0]),
    .spr_iccfgr                       (spr_iccfgr[31:0]),
    .spr_dcfgr                        (spr_dcfgr[31:0]),
    .spr_pccfgr                       (spr_pccfgr[31:0]),
    .spr_avr                          (spr_avr[31:0])
  );

  // Implementation-specific registers
  assign spr_isr[0] = 0;
  assign spr_isr[1] = 0;
  assign spr_isr[2] = 0;
  assign spr_isr[3] = 0;
  assign spr_isr[4] = 0;
  assign spr_isr[5] = 0;
  assign spr_isr[6] = 0;
  assign spr_isr[7] = 0;


  //-----//
  // PIC //
  //-----//
generate
if (FEATURE_PIC != "NONE") begin : pic
  mor1kx_pic
  #(
    .OPTION_PIC_TRIGGER(OPTION_PIC_TRIGGER),
    .OPTION_PIC_NMI_WIDTH(OPTION_PIC_NMI_WIDTH)
  )
  u_pic
  (
    // Outputs
    .spr_picmr_o        (spr_picmr),
    .spr_picsr_o        (spr_picsr),
    .spr_bus_ack        (spr_access_ack[`OR1K_SPR_PIC_BASE]),
    .spr_dat_o          (spr_internal_read_dat[`OR1K_SPR_PIC_BASE]),
    // Inputs
    .clk                (clk),
    .rst                (rst),
    .irq_i              (irq_i[31:0]),
    .spr_access_i       (spr_access[`OR1K_SPR_PIC_BASE]),
    .spr_we_i           (spr_we),
    .spr_addr_i         (spr_addr),
    .spr_dat_i          (spr_write_dat)
  );

  assign except_pic = (|spr_picsr) & spr_sr[`OR1K_SPR_SR_IEE];
end
else begin
  assign except_pic = 1'b0;
  assign spr_picsr = 0;
  assign spr_picmr = 0;
  assign spr_access_ack[`OR1K_SPR_PIC_BASE] = 1'b1;
  assign spr_internal_read_dat[`OR1K_SPR_PIC_BASE] = 0;
end
endgenerate


  //-------//
  // TIMER //
  //-------//
generate
if (FEATURE_TIMER != "NONE") begin : tt
  mor1kx_ticktimer u_ticktimer
  (
    // Outputs
    .spr_ttmr_o           (spr_ttmr),
    .spr_ttcr_o           (spr_ttcr),
    .spr_bus_ack          (spr_access_ack[`OR1K_SPR_TT_BASE]),
    .spr_dat_o            (spr_internal_read_dat[`OR1K_SPR_TT_BASE]),
    // Inputs
    .clk                  (clk),
    .rst                  (rst),
    .spr_access_i         (spr_access[`OR1K_SPR_TT_BASE]),
    .spr_we_i             (spr_we),
    .spr_addr_i           (spr_addr),
    .spr_dat_i            (spr_write_dat)
  );

  assign except_ticktimer = spr_ttmr[28] & spr_sr[`OR1K_SPR_SR_TEE];
end
else begin
  assign except_ticktimer = 1'b0;
  assign spr_ttmr = 0;
  assign spr_ttcr = 0;
  assign spr_access_ack[`OR1K_SPR_TT_BASE] = 1'b1;
  assign spr_internal_read_dat[`OR1K_SPR_TT_BASE] = 0;
end
endgenerate


  //---------------------------------------------------------------------------//
  // SPR access control                                                        //
  //   Allow accesses from either the instructions or from the debug interface //
  //---------------------------------------------------------------------------//
  // MT(F)SPR command
  reg cmd_op_mfspr;
  reg cmd_op_mtspr;
  // ...
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst) begin
      cmd_op_mfspr <= 1'b0;
      cmd_op_mtspr <= 1'b0;
    end
    else if (padv_decode_o | pipeline_flush_o | spr_ack) begin
      cmd_op_mfspr <= 1'b0;
      cmd_op_mtspr <= 1'b0;
    end
    else if (exec_new_input_o) begin
      cmd_op_mfspr <= exec_op_mfspr_i;
      cmd_op_mtspr <= exec_op_mtspr_i;
    end
  end // @clock

  // Take MT(F)SPR command
  wire take_op_mXspr = (~pipeline_flush_o) &
    exec_new_input_o & (exec_op_mfspr_i | exec_op_mtspr_i);

  // MT(F)SPR address & data
  reg                     [15:0] cmd_op_mXspr_addr;
  reg [OPTION_OPERAND_WIDTH-1:0] cmd_op_mXspr_data;
  // ...
  always @(posedge clk `OR_ASYNC_RST) begin
    if (take_op_mXspr) begin
      cmd_op_mXspr_addr <= alu_nl_result_i[15:0];
      cmd_op_mXspr_data <= exec_rfb_i;
    end
  end // @clock

  //  MTSPR write strob (must be combined with other SPR access flags)
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_we_en <= 1'b0;
    else
      spr_we_en <= (~pipeline_flush_o) & exec_new_input_o & exec_op_mtspr_i;
  end // @clock


  assign spr_addr         = du_access ? du_addr_i : cmd_op_mXspr_addr;
  assign spr_write_dat    = du_access ? du_dat_i  : cmd_op_mXspr_data;

  assign spr_read_access  = (cmd_op_mfspr | (du_access & (~du_we_i)));
  assign spr_write_access = (cmd_op_mtspr | (du_access &   du_we_i ));

  assign spr_we           = spr_write_access & spr_access_valid;


  // Select spr
  always @(*) begin
    spr_access <= {SPR_ACCESS_WIDTH{1'b0}};
    case(`SPR_BASE(spr_addr))
      // system registers
      `OR1K_SPR_SYS_BASE:  spr_access[`OR1K_SPR_SYS_BASE]  <= 1'b1;
      // modules registers
      `OR1K_SPR_DMMU_BASE: spr_access[`OR1K_SPR_DMMU_BASE] <= (FEATURE_DMMU != "NONE");
      `OR1K_SPR_IMMU_BASE: spr_access[`OR1K_SPR_IMMU_BASE] <= 1'b1;
      `OR1K_SPR_DC_BASE:   spr_access[`OR1K_SPR_DC_BASE]   <= (FEATURE_DATACACHE != "NONE");
      `OR1K_SPR_IC_BASE:   spr_access[`OR1K_SPR_IC_BASE]   <= 1'b1;
      `OR1K_SPR_MAC_BASE:  spr_access[`OR1K_SPR_MAC_BASE]  <= (FEATURE_MAC != "NONE");
      `OR1K_SPR_DU_BASE:   spr_access[`OR1K_SPR_DU_BASE]   <= (FEATURE_DEBUGUNIT != "NONE");
      `OR1K_SPR_PC_BASE:   spr_access[`OR1K_SPR_PC_BASE]   <= (FEATURE_PERFCOUNTERS != "NONE");
      `OR1K_SPR_PM_BASE:   spr_access[`OR1K_SPR_PM_BASE]   <= (FEATURE_PMU != "NONE");
      `OR1K_SPR_PIC_BASE:  spr_access[`OR1K_SPR_PIC_BASE]  <= (FEATURE_PIC != "NONE");
      `OR1K_SPR_TT_BASE:   spr_access[`OR1K_SPR_TT_BASE]   <= (FEATURE_TIMER != "NONE");
      `OR1K_SPR_FPU_BASE:  spr_access[`OR1K_SPR_FPU_BASE]  <= (FEATURE_FPU != "NONE");
      // generate invalid if the group is not present in the design
      default:
        spr_access <= {SPR_ACCESS_WIDTH{1'b0}};
    endcase
  end // always

  // Is the SPR in the design?
  assign spr_access_valid = |spr_access;


  // Is a SPR bus access needed, or is the requested SPR in this file?
  assign spr_bus_access = // --- Any of the units we have got in this file ---
                            // --- System group ---
                          ~(spr_access[`OR1K_SPR_SYS_BASE] |
                            // --- Debug Group ---
                            spr_access[`OR1K_SPR_DU_BASE] |
                            // --- PIC Group ---
                            spr_access[`OR1K_SPR_PIC_BASE] |
                            // --- Tick Group ---
                            spr_access[`OR1K_SPR_TT_BASE]) |
                          // *** Any of the units we haven't got in this file ***
                          // *** GPR ***
                          (spr_access[`OR1K_SPR_SYS_BASE] & spr_addr[10:9]==2'h2);

  // A bus out to other units that live outside of the control unit
  assign spr_bus_addr_o = spr_addr;
  assign spr_bus_we_o   = spr_write_access & spr_access_valid & spr_bus_access;
  assign spr_bus_stb_o  = (spr_read_access | spr_write_access) &
                           spr_access_valid & spr_bus_access;
  assign spr_bus_dat_o  = spr_write_dat;


  // SPR access "ACK"
  assign spr_ack = (spr_read_access | spr_write_access) &
                   ((|spr_access_ack) | (~spr_access_valid));

  // System group (0) SPR data out
  always @* begin
    spr_sys_group_read = 0;
    if (spr_access[`OR1K_SPR_SYS_BASE])
      case(`SPR_OFFSET(spr_addr))
        `SPR_OFFSET(`OR1K_SPR_VR_ADDR)      : spr_sys_group_read = spr_vr;
        `SPR_OFFSET(`OR1K_SPR_VR2_ADDR)     : spr_sys_group_read = {spr_vr2[31:8], `MOR1KX_PIPEID_CAPPUCCINO};
        `SPR_OFFSET(`OR1K_SPR_AVR_ADDR)     : spr_sys_group_read = spr_avr;
        `SPR_OFFSET(`OR1K_SPR_UPR_ADDR)     : spr_sys_group_read = spr_upr;
        `SPR_OFFSET(`OR1K_SPR_CPUCFGR_ADDR) : spr_sys_group_read = spr_cpucfgr;
        `SPR_OFFSET(`OR1K_SPR_DMMUCFGR_ADDR): spr_sys_group_read = spr_dmmucfgr;
        `SPR_OFFSET(`OR1K_SPR_IMMUCFGR_ADDR): spr_sys_group_read = spr_immucfgr;
        `SPR_OFFSET(`OR1K_SPR_DCCFGR_ADDR)  : spr_sys_group_read = spr_dccfgr;
        `SPR_OFFSET(`OR1K_SPR_ICCFGR_ADDR)  : spr_sys_group_read = spr_iccfgr;
        `SPR_OFFSET(`OR1K_SPR_DCFGR_ADDR)   : spr_sys_group_read = spr_dcfgr;
        `SPR_OFFSET(`OR1K_SPR_PCCFGR_ADDR)  : spr_sys_group_read = spr_pccfgr;
        `SPR_OFFSET(`OR1K_SPR_NPC_ADDR)     : spr_sys_group_read = spr_npc;
        `SPR_OFFSET(`OR1K_SPR_SR_ADDR)      : spr_sys_group_read = {{(OPTION_OPERAND_WIDTH-SPR_SR_WIDTH){1'b0}},
                                                                    spr_sr};
        `SPR_OFFSET(`OR1K_SPR_PPC_ADDR)     : spr_sys_group_read = spr_ppc;
       `ifdef OR1K_FPCSR_MASK_FLAGS
        `SPR_OFFSET(`OR1K_SPR_FPCSR_ADDR)   : spr_sys_group_read = {{(OPTION_OPERAND_WIDTH-`OR1K_FPCSR_WIDTH-`OR1K_FPCSR_ALLF_SIZE){1'b0}},
                                                                    spr_fpcsr_mf,spr_fpcsr};
       `else
        `SPR_OFFSET(`OR1K_SPR_FPCSR_ADDR)   : spr_sys_group_read = {{(OPTION_OPERAND_WIDTH-`OR1K_FPCSR_WIDTH){1'b0}},
                                                                    spr_fpcsr};
       `endif
        `SPR_OFFSET(`OR1K_SPR_EPCR0_ADDR)   : spr_sys_group_read = spr_epcr;
        `SPR_OFFSET(`OR1K_SPR_EEAR0_ADDR)   : spr_sys_group_read = spr_eear;
        `SPR_OFFSET(`OR1K_SPR_ESR0_ADDR)    : spr_sys_group_read = {{(OPTION_OPERAND_WIDTH-SPR_SR_WIDTH){1'b0}},
                                                                    spr_esr};
        `SPR_OFFSET(`OR1K_SPR_EVBAR_ADDR)   : spr_sys_group_read = spr_evbar;
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR)    : spr_sys_group_read = spr_isr[0];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +1 : spr_sys_group_read = spr_isr[1];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +2 : spr_sys_group_read = spr_isr[2];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +3 : spr_sys_group_read = spr_isr[3];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +4 : spr_sys_group_read = spr_isr[4];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +5 : spr_sys_group_read = spr_isr[5];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +6 : spr_sys_group_read = spr_isr[6];
        `SPR_OFFSET(`OR1K_SPR_ISR0_ADDR) +7 : spr_sys_group_read = spr_isr[7];

        // If the multicore feature is activated this address returns the
        // core identifier, 0 otherwise
        `SPR_OFFSET(`OR1K_SPR_COREID_ADDR)  : spr_sys_group_read = (FEATURE_MULTICORE != "NONE") ?
                                                                    multicore_coreid_i : 0;
        // If the multicore feature is activated this address returns the
        // core identifier, 0 otherwise
        `SPR_OFFSET(`OR1K_SPR_NUMCORES_ADDR) : spr_sys_group_read = (FEATURE_MULTICORE != "NONE") ?
                                                                     multicore_numcores_i : 0;

        default:
          // GPR read
          if (spr_addr[10:9] == 2'h2)
            spr_sys_group_read = spr_gpr_dat_i; // Register file
      endcase
  end // always

  // System group read data MUX in
  assign spr_internal_read_dat[`OR1K_SPR_SYS_BASE] = spr_sys_group_read;

  // System group ack generation
  assign spr_access_ack[`OR1K_SPR_SYS_BASE] = spr_access[`OR1K_SPR_SYS_BASE] &
                                              ((spr_addr[10:9] == 2'h2) ? spr_gpr_ack_i : 1'b1);

  //
  // Generate data to the register file for mfspr operations
  // Read datas are simply ORed since set to 0 when not
  // concerned by spr access.
  //
  wire [OPTION_OPERAND_WIDTH-1:0] mfspr_dat_w =
    spr_internal_read_dat[`OR1K_SPR_SYS_BASE]  |
    spr_internal_read_dat[`OR1K_SPR_DMMU_BASE] |
    spr_internal_read_dat[`OR1K_SPR_IMMU_BASE] |
    spr_internal_read_dat[`OR1K_SPR_DC_BASE]   |
    spr_internal_read_dat[`OR1K_SPR_IC_BASE]   |
    spr_internal_read_dat[`OR1K_SPR_MAC_BASE]  |
    spr_internal_read_dat[`OR1K_SPR_DU_BASE]   |
    spr_internal_read_dat[`OR1K_SPR_PC_BASE]   |
    spr_internal_read_dat[`OR1K_SPR_PM_BASE]   |
    spr_internal_read_dat[`OR1K_SPR_PIC_BASE]  |
    spr_internal_read_dat[`OR1K_SPR_TT_BASE]   |
    spr_internal_read_dat[`OR1K_SPR_FPU_BASE];

  // data provided by either MFSPR or DU acceess
  reg [OPTION_OPERAND_WIDTH-1:0] mfspr_dat_r;
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      mfspr_dat_r <= {OPTION_OPERAND_WIDTH{1'b0}};
    else if (spr_read_access & spr_ack)
      mfspr_dat_r <= mfspr_dat_w;
  end // @clock

  // ready flag for M(T)SPR access
  reg mXspr_ack;
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      mXspr_ack <= 1'b0;
    else if (padv_decode_o | pipeline_flush_o)
      mXspr_ack <= 1'b0;
    else if ((cmd_op_mfspr | cmd_op_mtspr) & spr_ack)
      mXspr_ack <= 1'b1;
  end // @clock

  // M(T)SPR outputs
  assign mfspr_dat_o      = mfspr_dat_r;
  assign ctrl_mfspr_ack_o = mXspr_ack;
  assign ctrl_mtspr_ack_o = mXspr_ack;

// Controls to generate ACKs from units that are external to this module
generate
if (FEATURE_DMMU != "NONE") begin : dmmu_ctrl
  assign spr_access_ack[`OR1K_SPR_DMMU_BASE] = spr_bus_ack_dmmu_i &
                                               spr_access[`OR1K_SPR_DMMU_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_DMMU_BASE] =
    spr_bus_dat_dmmu_i &
    {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_DMMU_BASE]}};
end
else begin
  assign spr_access_ack[`OR1K_SPR_DMMU_BASE] = 1'b0;
  assign spr_internal_read_dat[`OR1K_SPR_DMMU_BASE] = 0;
end
endgenerate


  assign spr_access_ack[`OR1K_SPR_IMMU_BASE] = spr_bus_ack_immu_i &
                                               spr_access[`OR1K_SPR_IMMU_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_IMMU_BASE] =
    spr_bus_dat_immu_i &
    {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_IMMU_BASE]}};


generate
if (FEATURE_DATACACHE != "NONE") begin : datacache_ctrl
  assign spr_access_ack[`OR1K_SPR_DC_BASE] = spr_bus_ack_dc_i &
                                             spr_access[`OR1K_SPR_DC_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_DC_BASE] =
    spr_bus_dat_dc_i & {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_DC_BASE]}};
end
else begin
  assign spr_access_ack[`OR1K_SPR_DC_BASE] = 1'b0;
  assign spr_internal_read_dat[`OR1K_SPR_DC_BASE] = 0;
end
endgenerate


  assign spr_access_ack[`OR1K_SPR_IC_BASE] = spr_bus_ack_ic_i &
                                             spr_access[`OR1K_SPR_IC_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_IC_BASE] =
    spr_bus_dat_ic_i & {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_IC_BASE]}};


generate
if (FEATURE_MAC != "NONE") begin : mac_ctrl
   assign spr_access_ack[`OR1K_SPR_MAC_BASE] = spr_bus_ack_mac_i &
                                               spr_access[`OR1K_SPR_MAC_BASE];
   assign spr_internal_read_dat[`OR1K_SPR_MAC_BASE] =
      spr_bus_dat_mac_i &
      {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_MAC_BASE]}};
end
else begin
  assign spr_access_ack[`OR1K_SPR_MAC_BASE] = 1'b0;
  assign spr_internal_read_dat[`OR1K_SPR_MAC_BASE] = 0;
end
endgenerate

generate
if (FEATURE_PERFCOUNTERS != "NONE") begin : perfcounters_ctrl
  assign spr_access_ack[`OR1K_SPR_PC_BASE] = spr_bus_ack_pcu_i &
                                             spr_access[`OR1K_SPR_PC_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_PC_BASE] =
    spr_bus_dat_pcu_i & {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_PC_BASE]}};
end
else begin
  assign spr_access_ack[`OR1K_SPR_PC_BASE] = 1'b0;
  assign spr_internal_read_dat[`OR1K_SPR_PC_BASE] = 0;
end
endgenerate

generate
if (FEATURE_PMU != "NONE") begin : pmu_ctrl
   assign spr_access_ack[`OR1K_SPR_PM_BASE] = spr_bus_ack_pmu_i &
                                              spr_access[`OR1K_SPR_PM_BASE];
   assign spr_internal_read_dat[`OR1K_SPR_PM_BASE] =
     spr_bus_dat_pmu_i & {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_PM_BASE]}};
end else begin
   assign spr_access_ack[`OR1K_SPR_PM_BASE] = 1'b0;
   assign spr_internal_read_dat[`OR1K_SPR_PM_BASE] = 0;
end
endgenerate

generate
if (FEATURE_FPU != "NONE") begin : fpu_ctrl
  assign spr_access_ack[`OR1K_SPR_FPU_BASE] = spr_bus_ack_fpu_i &
                                              spr_access[`OR1K_SPR_FPU_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_FPU_BASE] =
    spr_bus_dat_fpu_i &
    {OPTION_OPERAND_WIDTH{spr_access[`OR1K_SPR_FPU_BASE]}};
end
else begin
  assign spr_access_ack[`OR1K_SPR_FPU_BASE] = 1'b0;
  assign spr_internal_read_dat[`OR1K_SPR_FPU_BASE] = 0;
end
endgenerate



  //------------//
  // DEBUG unit //
  //------------//
generate
if (FEATURE_DEBUGUNIT != "NONE") begin : du

  reg [OPTION_OPERAND_WIDTH-1:0] du_read_dat;

  reg                            du_ack;
  reg                            du_stall_r;
  reg [1:0]                      branch_step;

  assign du_access = du_stb_i;

  // Generate ack back to the debug interface bus
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      du_ack <= 1'b0;
    else if (du_ack)
      du_ack <= 1'b0;
    else if (du_stb_i) begin
      du_ack <= spr_ack;
    end
  end // @ clock

  assign du_ack_o = du_ack;

  /* Data back to the debug bus */
  always @(posedge clk)
    du_read_dat <= mfspr_dat_o;

  assign du_dat_o = du_read_dat;

  always @(posedge clk) begin
    if (rst)
      du_cpu_stall <= 1'b0;
    else if (~du_stall_i)
      du_cpu_stall <= 1'b0;
    else if ((padv_wb_o & (~exec_bubble_i) & du_stall_i) |
             du_stall_o)
      du_cpu_stall <= 1'b1;
  end // @ clock

  /* goes out to the debug interface and comes back 1 cycle later
     via du_stall_i */
  assign du_stall_o = stepping & pstep[4] |
                     (du_stall_on_trap & wb_new_result_o & except_trap_i); // DU

  /* Pulse to indicate we're restarting after a stall */
  assign du_restart_from_stall = du_stall_r & (~du_stall_i);

  /* NPC debug control logic */
  assign du_npc_write = (du_we_i & (du_addr_i == `OR1K_SPR_NPC_ADDR) &
                         du_ack_o);

  /* Pick the traps-cause-stall bit out of the DSR */
  assign du_stall_on_trap = spr_dsr[`OR1K_SPR_DSR_TE];

  /* record if NPC was written while we were stalled.
     If so, we will use this value for restarting */
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      du_npc_written <= 1'b0;
    else if (du_restart_from_stall)
      du_npc_written <= 1'b0;
    else if (du_npc_write)
      du_npc_written <= 1'b1;
  end // @ clock

  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      stepped_into_exception <= 1'b0;
    else if (du_restart_from_stall)
      stepped_into_exception <= 1'b0;
    else if (stepping & exception & wb_new_result_o) // DU
      stepped_into_exception <= 1'b1;
  end // @ clock

  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      stepped_into_rfe <= 1'b0;
    else if (du_restart_from_stall)
      stepped_into_rfe <= 1'b0;
    else if (stepping)
      stepped_into_rfe <= wb_op_rfe_i; // DU
  end // @ clock

  assign du_restart_pc_o = spr_npc;

  assign du_restart_o = du_restart_from_stall;

  /* Indicate when we're stepping */
  assign stepping = spr_dmr1[`OR1K_SPR_DMR1_ST] &
                    spr_dsr[`OR1K_SPR_DSR_TE];

  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      pstep <= 6'h0;
    else if (du_restart_from_stall & stepping)
      pstep <= 6'h1;
    else if ((pstep[0] & fetch_valid_i) |
             /* decode is always single cycle */
             (pstep[1] & padv_decode_o) |
             pstep[4])
      pstep <= {pstep[4:0],1'b0};
  end // @ clock

  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      branch_step <= 0;
    else if (du_npc_written)
      branch_step <= 0;
    else if (stepping & pstep[2])
      branch_step <= {branch_step[0], dcod_branch_i};
    else if ((~stepping) & wb_new_result_o) // DU
      branch_step <= {branch_step[0], wb_delay_slot_i};// DU
  end // @ clock

  assign stepped_into_delay_slot = branch_step[1] & stepping;

  /* Signals for waveform debuging */
  wire [31:0] spr_read_data_group_0 = spr_internal_read_dat[0];
  wire [31:0] spr_read_data_group_1 = spr_internal_read_dat[1];
  wire [31:0] spr_read_data_group_2 = spr_internal_read_dat[2];
  wire [31:0] spr_read_data_group_3 = spr_internal_read_dat[3];
  wire [31:0] spr_read_data_group_4 = spr_internal_read_dat[4];
  wire [31:0] spr_read_data_group_5 = spr_internal_read_dat[5];
  wire [31:0] spr_read_data_group_6 = spr_internal_read_dat[6];
  wire [31:0] spr_read_data_group_7 = spr_internal_read_dat[7];
  wire [31:0] spr_read_data_group_8 = spr_internal_read_dat[8];
  wire [31:0] spr_read_data_group_9 = spr_internal_read_dat[9];


  /* always single cycle access */
  assign spr_access_ack[`OR1K_SPR_DU_BASE] = spr_access[`OR1K_SPR_DU_BASE];
  assign spr_internal_read_dat[`OR1K_SPR_DU_BASE] =
    (spr_addr==`OR1K_SPR_DMR1_ADDR) ?  spr_dmr1 :
    (spr_addr==`OR1K_SPR_DMR2_ADDR) ?  spr_dmr2 :
    (spr_addr==`OR1K_SPR_DSR_ADDR)  ?  spr_dsr  :
    (spr_addr==`OR1K_SPR_DRR_ADDR)  ?  spr_drr  : 1'b0;

  /* Put the incoming stall signal through a register to detect FE */
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      du_stall_r <= 1'b0;
    else
      du_stall_r <= du_stall_i;
  end // @ clock

  /* DMR1 */
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_dmr1 <= 0;
    else if (spr_we & (spr_addr == `OR1K_SPR_DMR1_ADDR))
      spr_dmr1[23:0] <= spr_write_dat[23:0];
  end // @ clock

  /* DMR2 */
  always @(posedge clk)
    spr_dmr2 <= 0;

  /* DSR */
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_dsr <= 0;
    else if (spr_we & (spr_addr == `OR1K_SPR_DSR_ADDR))
      spr_dsr[13:0] <= spr_write_dat[13:0];
  end // @ clock

  /* DRR */
  always @(posedge clk `OR_ASYNC_RST) begin
    if (rst)
      spr_drr <= 0;
    else if (spr_we & (spr_addr == `OR1K_SPR_DRR_ADDR))
      spr_drr[13:0] <= spr_write_dat[13:0];
    else if (du_stall_on_trap & wb_new_result_o & except_trap_i) // DU
      spr_drr[`OR1K_SPR_DRR_TE] <= 1'b1;
  end // @ clock

end // block: du
else begin : no_du
  assign du_access = 0;
  assign du_stall_o = 0;
  assign du_ack_o = 0;
  assign du_restart_o = 0;
  assign du_restart_pc_o = 0;
  assign stepping = 0;
  assign du_npc_write = 0;
  assign du_stall_on_trap = 0;
  assign stepped_into_delay_slot = 0;
  assign du_dat_o = 0;
  assign du_restart_from_stall = 0;
  assign spr_access_ack[`OR1K_SPR_DU_BASE] = 0;
  assign spr_internal_read_dat[`OR1K_SPR_DU_BASE] = 0;
  always @(posedge clk) begin
    spr_dmr1 <= 0;
    spr_dmr2 <= 0;
    spr_dsr <= 0;
    spr_drr <= 0;
    du_npc_written <= 1'b0;
    du_cpu_stall <= 1'b0;
    pstep <= 6'd0;
    stepped_into_exception <= 1'b0;
    stepped_into_rfe <= 1'b0;
  end // @ clock
end
endgenerate

endmodule // mor1kx_ctrl_marocchino