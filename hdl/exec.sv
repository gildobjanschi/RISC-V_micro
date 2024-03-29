/***********************************************************************************************************************
 * Copyright (c) 2024 Virgil Dobjanschi dobjanschivirgil@gmail.com
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
 * documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of
 * the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 * WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS
 * OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 **********************************************************************************************************************/

/***********************************************************************************************************************
 * Execute RISC V instructions.
 *
 * clk_i                    -- The clock signal.
 * rst_i                    -- Reset active high.
 * stb_i                    -- The transaction starts on the posedge of this signal.
 *  --- Instruction execution ports
 * instr_addr_i             -- The address of the instruction to be executed.
 * instr_i                  -- The undecoded instruction.
 * instr_is_compressed_i    -- 1'b1 if the instruction is compressed.
 * instr_op_type_i          -- The decoded instruction type (see instructions.svh).
 * instr_op_rd_i            -- rd for applicable instructions.
 * instr_op_rs1_i           -- rs1 for applicable instructions.
 * instr_op_rs2_i           -- rs2 for applicable instructions.
 * instr_op_imm_i           -- The immediate value for applicable instructions.
 * rs1_i                    -- rs1 register value.
 * rs2_i                    -- rs2 register value.
 * ack_o                    -- The transaction completes successfully on the posedge of this signal.
 * err_o                    -- The transaction completes with an error on the posedge of this signal.
 * jmp_o                    -- 1'b1 if next_addr_o is an instruction address due to a jump.
 * mret_o                   -- 1'b1 if returning from an interrupt.
 * fencei_o                 -- 1'b1 if a fence.i was executed.
 * next_addr_o              -- The address of the next instruction to be executed.
 * rd_o                     -- The destination register value to be written to the regfile (the value of instr_op_rd_i).
 *  --- Trap ports
 * trap_mcause_o            -- The cause of the trap (0 if no synchronous exception occurs).
 * trap_mtval_o             -- Additional exception data.
 *  --- Read/write data for l(b/h/w) s(b/h/w), CSR access instructions
 * data_addr_o              -- The address from where data is read/written.
 * data_addr_tag_o          -- The data tag to write.
 * data_data_o              -- The data to write.
 * data_stb_o               -- The transaction starts on the posedge of this signal.
 * data_cyc_o               -- This signal is asserted for the duration of a cycle.
 * data_sel_o               -- Number of bytes to r/w (1 -> 4'b0001, 2 -> 4'b0011, 3 -> 4'b0111 or 4 bytes -> 4'b1111).
 * data_we_o                -- 1'b1 to write data, 0 to read.
 * data_ack_i               -- The data transaction completes successfully on the posedge of this signal.
 * data_err_i               -- The data transaction completes with an error on the posedge of this signal.
 * data_data_i              -- The data that was read.
 * data_tag_i               -- The data input tag
 **********************************************************************************************************************/
`timescale 1ns/1ns
`default_nettype none

`include "instructions.svh"
`include "traps.svh"
`include "csr.svh"
`include "tags.svh"

module exec #(parameter [31:0] CSR_BEGIN_ADDR = 32'h40000000) (
    input logic clk_i,
    input logic rst_i,
    input logic stb_i,
    // Instruction to be executed
    input logic [31:0] instr_addr_i,
    input logic [31:0] instr_i,
    input logic instr_is_compressed_i,
    input logic [6:0] instr_op_type_i,
    input logic [4:0] instr_op_rd_i,
    input logic [4:0] instr_op_rs1_i,
    input logic [4:0] instr_op_rs2_i,
    input logic [31:0] instr_op_imm_i,
    input logic [31:0] rs1_i,
    input logic [31:0] rs2_i,
    // Execution complete output
    output logic ack_o,
    output logic err_o,
    output logic jmp_o,
    output logic mret_o,
    output logic fencei_o,
    output logic [31:0] next_addr_o,
    output logic [31:0] rd_o,
    // Trap ports
    output logic [31:0] trap_mcause_o,
    output logic [31:0] trap_mtval_o,
    // Read/write RAM/ROM/IO data for l(b/h/w) s(b/h/w) instructions
    output logic [31:0] data_addr_o,
    output logic [`ADDR_TAG_BITS-1:0] data_addr_tag_o,
    output logic [31:0] data_data_o,
    output logic data_stb_o,
    output logic data_cyc_o,
    output logic [3:0] data_sel_o,
    output logic data_we_o,
    input logic data_ack_i,
    input logic data_err_i,
    input logic [31:0] data_data_i,
    input logic data_tag_i);

    localparam STATE_EXEC           = 3'b000;
    localparam STATE_RD_PENDING     = 3'b001;
    localparam STATE_WR_PENDING     = 3'b010;
`ifdef ENABLE_RV32M_EXT
    localparam STATE_MUL_PENDING    = 3'b011;
    localparam STATE_DIV_PENDING    = 3'b100;
`endif
    localparam STATE_DELAYED_STORE  = 3'b101;
    logic [2:0] state_m;

    logic [31:0] next_addr_comb;
    assign next_addr_comb = instr_is_compressed_i ? instr_addr_i + 2 : instr_addr_i + 4;

    logic [31:0] instr_imm_addr_comb;
    assign instr_imm_addr_comb = instr_addr_i + instr_op_imm_i;

`ifdef ENABLE_RV32M_EXT
    logic mul_stb_o, mul_cyc_o, mul_result_upper_o, mul_op_1_is_signed_o, mul_op_2_is_signed_o, mul_ack_i;
    logic [31:0] mul_op_1_o, mul_op_2_o, mul_result_i;

    logic div_stb_o, div_cyc_o, div_is_signed_o, div_ack_i;
    logic [31:0] divident_o, divisor_o, div_result_i, rem_result_i;
`endif

`ifdef ENABLE_ZBB_EXT
    integer i;
`endif

    logic [31:0] tmp;
    logic [31:0] store_addr;
    logic [31:0] store_value;
    logic [`ADDR_TAG_BITS-1:0] store_addr_tag;

`ifdef ENABLE_ZBB_EXT
    logic [31:0] bs_right_out;
    barrel_shifter_right barrel_shifter_right_m (.data(rs1_i), .amt(rs2_i[4:0]), .out(bs_right_out));
    logic [31:0] bs_right_imm_out;
    barrel_shifter_right barrel_shifter_right_imm_m (.data(rs1_i), .amt(instr_op_imm_i[4:0]), .out(bs_right_imm_out));
    logic [31:0] bs_left_out;
    barrel_shifter_left barrel_shifter_left_m (.data(rs1_i), .amt(rs2_i[4:0]), .out(bs_left_out));
    logic [4:0] lz_count;
    count_leading_zeros count_leading_zeros_m (.in(rs1_i), .out(lz_count));
    logic [4:0] tz_count;
    count_trailing_zeros count_trailing_zero_m (.in(rs1_i), .out(tz_count));
`endif
    //==================================================================================================================
    // The first stage of the execution
    //==================================================================================================================
    task exec_task;
        jmp_o <= 1'b0;
        mret_o <= 1'b0;
        fencei_o <= 1'b0;
        trap_mcause_o <= 0;

        (* parallel_case, full_case *)
        case (instr_op_type_i)
            `INSTR_TYPE_LUI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? instr_op_imm_i : 0;
                // IMM was already shifted left by 12 by the decoder
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.lui rdx%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i[15:0],
                                instr_op_rd_i, rd_o, instr_op_imm_i, next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h lui rdx%0d[%h], %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_imm_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? instr_op_imm_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_AUIPC: begin
                // IMM was already shifted left by 12 by the decoder
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? instr_imm_addr_comb : 0;
                $display($time, " [%h]: %h auipc rdx%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i, instr_op_rd_i,
                            rd_o, instr_op_imm_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? instr_imm_addr_comb : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_JAL: begin
`ifdef D_EXEC
                next_addr_o = instr_imm_addr_comb;
                rd_o = |instr_op_rd_i ? next_addr_comb : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.jal rdx%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i[15:0],
                                instr_op_rd_i, rd_o, instr_op_imm_i, next_addr_o);
                end else begin
                    $display($time, " [%h]: %8h jal rdx%0d[%h], imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_imm_i, next_addr_o);
                end
`else
                rd_o <= |instr_op_rd_i ? next_addr_comb : 0;
                next_addr_o <= instr_imm_addr_comb;
`endif
                jmp_o <= 1'b1;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_JALR: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? next_addr_comb : 0;
                next_addr_o = {tmp[31:1], 1'b0};
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.jalr rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_o);
                end else begin
                    $display($time, " [%h]: %8h jalr rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_o);
                end
`else
                rd_o <= |instr_op_rd_i ? next_addr_comb : 0;
                next_addr_o <= {tmp[31:1], 1'b0};
`endif
                jmp_o <= 1'b1;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BEQ: begin
`ifdef D_EXEC
                next_addr_o = rs1_i == rs2_i ? instr_imm_addr_comb : next_addr_comb;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.beq rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                    instr_i[15:0], instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i,
                                    next_addr_o);
                end else begin
                    $display($time, " [%h]: %8h beq rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, next_addr_o);
                end
`else
                next_addr_o <= rs1_i == rs2_i ? instr_imm_addr_comb : next_addr_comb;
`endif
                jmp_o <= rs1_i == rs2_i;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BNE: begin
`ifdef D_EXEC
                next_addr_o = rs1_i != rs2_i ? instr_imm_addr_comb : next_addr_comb;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.bne rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i,
                                next_addr_o);
                end else begin
                    $display($time, " [%h]: %8h bne rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, next_addr_o);
                end
`else
                next_addr_o <= rs1_i != rs2_i ? instr_imm_addr_comb : next_addr_comb;
`endif
                jmp_o <= rs1_i != rs2_i;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BLT: begin
`ifdef D_EXEC
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        next_addr_o = rs1_i[30:0] < rs2_i[30:0] ? instr_imm_addr_comb : next_addr_comb;
                        jmp_o <= rs1_i[30:0] < rs2_i[30:0];
                    end

                    2'b10: begin
                        next_addr_o = instr_imm_addr_comb;
                        jmp_o <= 1'b1;
                    end

                    2'b01: begin
                        next_addr_o = next_addr_comb;
                    end

                    2'b00: begin // Both are positive
                        next_addr_o = rs1_i < rs2_i ? instr_imm_addr_comb : next_addr_comb;
                        jmp_o <= rs1_i < rs2_i;
                    end
                endcase
                $display($time, " [%h]: %h blt rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, next_addr_o);
`else
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        next_addr_o <= rs1_i[30:0] < rs2_i[30:0] ? instr_imm_addr_comb : next_addr_comb;
                        jmp_o <= rs1_i[30:0] < rs2_i[30:0];
                    end

                    2'b10: begin
                        next_addr_o <= instr_imm_addr_comb;
                        jmp_o <= 1'b1;
                    end

                    2'b01: begin
                        next_addr_o <= next_addr_comb;
                    end

                    2'b00: begin // Both are positive
                        next_addr_o <= rs1_i < rs2_i ? instr_imm_addr_comb : next_addr_comb;
                        jmp_o <= rs1_i < rs2_i;
                    end
                endcase
`endif
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BGE: begin
`ifdef D_EXEC
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        next_addr_o = rs1_i[30:0] < rs2_i[30:0] ? next_addr_comb : instr_imm_addr_comb;
                        jmp_o <= ~(rs1_i[30:0] < rs2_i[30:0]);
                    end

                    2'b10: begin
                        next_addr_o = next_addr_comb;
                    end

                    2'b01: begin
                        next_addr_o = instr_imm_addr_comb;
                        jmp_o <= 1'b1;
                    end

                    2'b00: begin // Both are positive
                        next_addr_o = rs1_i < rs2_i ? next_addr_comb : instr_imm_addr_comb;
                        jmp_o <= ~(rs1_i < rs2_i);
                    end
                endcase
                $display($time, " [%h]: %h blt rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, next_addr_o);
`else
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        next_addr_o <= rs1_i[30:0] < rs2_i[30:0] ? next_addr_comb : instr_imm_addr_comb;
                        jmp_o <= ~(rs1_i[30:0] < rs2_i[30:0]);
                    end

                    2'b10: begin
                        next_addr_o <= next_addr_comb;
                    end

                    2'b01: begin
                        next_addr_o <= instr_imm_addr_comb;
                        jmp_o <= 1'b1;
                    end

                    2'b00: begin // Both are positive
                        next_addr_o <= rs1_i < rs2_i ? next_addr_comb : instr_imm_addr_comb;
                        jmp_o <= ~(rs1_i < rs2_i);
                    end
                endcase
`endif
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BLTU: begin
`ifdef D_EXEC
                next_addr_o = rs1_i < rs2_i ? instr_imm_addr_comb : next_addr_comb;
                $display($time, " [%h]: %h bltu rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, next_addr_o);
`else
                next_addr_o <= rs1_i < rs2_i ? instr_imm_addr_comb : next_addr_comb;
`endif
                jmp_o <= rs1_i < rs2_i;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BGEU: begin
`ifdef D_EXEC
                next_addr_o = rs1_i < rs2_i ? next_addr_comb : instr_imm_addr_comb;
                $display($time, " [%h]: %h bgeu rs1x%0d[%h] rs2x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, next_addr_o);
`else
                next_addr_o <= rs1_i < rs2_i ? next_addr_comb : instr_imm_addr_comb;
`endif
                jmp_o <= ~(rs1_i < rs2_i);
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_LB: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h lb rdx%0d rs1x%0d[%h] imm: %h; load @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_imm_i, tmp);
`endif
                load_task (tmp, `ADDR_TAG_NONE, 4'b0001);
            end

            `INSTR_TYPE_LH: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h lh rdx%0d rs1x%0d[%h] imm: %h; load @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_imm_i, tmp);
`endif
                if (tmp[0] == 1'b1) begin
                    trap_mcause_o[`EX_CODE_LOAD_ADDRESS_MISALIGNED] <= 1'b1;
                    trap_mtval_o <= tmp;
                    {ack_o, err_o} <= 2'b01;
                end else begin
                    load_task (tmp, `ADDR_TAG_NONE, 4'b0011);
                end
            end

            `INSTR_TYPE_LW: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.lw rdx%0d rs1x%0d[%h] imm: %h; load @[%h] ...", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_imm_i, tmp);
                end else begin
                    $display($time, " [%h]: %8h lw rdx%0d rs1x%0d[%h] imm: %h; load @[%h] ...", instr_addr_i, instr_i,
                                instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_imm_i, tmp);
                end
`endif
                if (tmp[0] == 1'b1) begin
                    trap_mcause_o[`EX_CODE_LOAD_ADDRESS_MISALIGNED] <= 1'b1;
                    trap_mtval_o <= tmp;
                    {ack_o, err_o} <= 2'b01;
                end else begin
                    load_task (tmp, `ADDR_TAG_NONE, 4'b1111);
                end
            end

            `INSTR_TYPE_LBU: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h lbu rdx%0d rs1x%0d[%h] imm: %h; load @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_imm_i, tmp);
`endif
                load_task (tmp, `ADDR_TAG_NONE, 4'b0001);
            end

            `INSTR_TYPE_LHU: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h lhu rdx%0d rs1x%0d[%h] imm: %h; load @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_imm_i, tmp);
`endif
                if (tmp[0] == 1'b1) begin
                    trap_mcause_o[`EX_CODE_LOAD_ADDRESS_MISALIGNED] <= 1'b1;
                    trap_mtval_o <= tmp;
                    {ack_o, err_o} <= 2'b01;
                end else begin
                    load_task (tmp, `ADDR_TAG_NONE, 4'b0011);
                end
            end

            `INSTR_TYPE_SB: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h sb rs1x%0d[%h] rs2x%0d[%h] imm: %h; store @[%h] ...", instr_addr_i,
                            instr_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, tmp);
`endif
                store_task (tmp, `ADDR_TAG_NONE, rs2_i, 4'b0001);
            end

            `INSTR_TYPE_SH: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h sh rs1x%0d[%h] rs2x%0d[%h] imm: %h; store @[%h] ...", instr_addr_i,
                            instr_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, tmp);
`endif
                if (tmp[0] == 1'b1) begin
                    trap_mcause_o[`EX_CODE_LOAD_ADDRESS_MISALIGNED] <= 1'b1;
                    trap_mtval_o <= tmp;
                    {ack_o, err_o} <= 2'b01;
                end else begin
                    store_task (tmp, `ADDR_TAG_NONE, rs2_i, 4'b0011);
                end
            end

            `INSTR_TYPE_SW: begin
                tmp = rs1_i + instr_op_imm_i;
`ifdef D_EXEC
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.sw rs1x%0d[%h] rs2x%0d[%h] imm: %h; store @[%h] ...", instr_addr_i,
                                instr_i[15:0], instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, tmp);
                end else begin
                    $display($time, " [%h]: %8h sw rs1x%0d[%h] rs2x%0d[%h] imm: %h; store @[%h] ...", instr_addr_i,
                                instr_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, instr_op_imm_i, tmp);
                end
`endif
                if (tmp[0] == 1'b1) begin
                    trap_mcause_o[`EX_CODE_LOAD_ADDRESS_MISALIGNED] <= 1'b1;
                    trap_mtval_o <= tmp;
                    {ack_o, err_o} <= 2'b01;
                end else begin
                    store_task (tmp, `ADDR_TAG_NONE, rs2_i, 4'b1111);
                end
            end

            `INSTR_TYPE_ADDI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i + instr_op_imm_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.addi rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i,
                                next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h addi rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i + instr_op_imm_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SLTI: begin
`ifdef D_EXEC
                (* parallel_case, full_case *)
                case ({rs1_i[31], instr_op_imm_i[31]})
                    2'b11: rd_o = |instr_op_rd_i ? (rs1_i[30:0] < instr_op_imm_i[30:0] ? 1 : 0) : 0;
                    2'b10: rd_o = |instr_op_rd_i ? 1 : 0;
                    2'b01: rd_o = 0;
                    2'b00: rd_o = |instr_op_rd_i ? (rs1_i < instr_op_imm_i ? 1 : 0) : 0;
                endcase

                $display($time, " [%h]: %h slti rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                (* parallel_case, full_case *)
                case ({rs1_i[31], instr_op_imm_i[31]})
                    2'b11: rd_o <= |instr_op_rd_i ? (rs1_i[30:0] < instr_op_imm_i[30:0] ? 1 : 0) : 0;
                    2'b10: rd_o <= |instr_op_rd_i ? 1 : 0;
                    2'b01: rd_o <= 0;
                    2'b00: rd_o <= |instr_op_rd_i ? (rs1_i < instr_op_imm_i ? 1 : 0) : 0;
                endcase
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SLTIU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (rs1_i < instr_op_imm_i ? 1 : 0) : 0;
                $display($time, " [%h]: %h sltiu rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? (rs1_i < instr_op_imm_i ? 1 : 0) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_XORI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i ^ instr_op_imm_i : 0;
                $display($time, " [%h]: %h xori rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs1_i ^ instr_op_imm_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ORI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i | instr_op_imm_i : 0;
                $display($time, " [%h]: %h ori rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs1_i | instr_op_imm_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ANDI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i & instr_op_imm_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.andi rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i,
                                next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h andi rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i & instr_op_imm_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SLLI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i << instr_op_imm_i[4:0] : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.slli rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i,
                                next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h slli rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i << instr_op_imm_i[4:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SRLI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i >> instr_op_imm_i[4:0] : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.srli rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i,
                                next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h srli rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i >> instr_op_imm_i[4:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SRAI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? $signed(rs1_i) >>> instr_op_imm_i[4:0] : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.srai rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i,
                                next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h srai rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? $signed(rs1_i) >>> instr_op_imm_i[4:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ADD: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i + rs2_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.add rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h add rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i + rs2_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SUB: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i - rs2_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.sub rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i,
                                rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h sub rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i - rs2_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SLL: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i << rs2_i[4:0] : 0;
                $display($time, " [%h]: %h sll rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs1_i << rs2_i[4:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SLT: begin
`ifdef D_EXEC
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: rd_o = |instr_op_rd_i ? (rs1_i[30:0] < rs2_i[30:0] ? 1 : 0) : 0;
                    2'b10: rd_o = |instr_op_rd_i ? 1 : 0;
                    2'b01: rd_o = 0;
                    2'b00: rd_o = |instr_op_rd_i ? (rs1_i < rs2_i ? 1 : 0) : 0;
                endcase

                $display($time, " [%h]: %h slt rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: rd_o <= |instr_op_rd_i ? (rs1_i[30:0] < rs2_i[30:0] ? 1 : 0) : 0;
                    2'b10: rd_o <= |instr_op_rd_i ? 1 : 0;
                    2'b01: rd_o <= 0;
                    2'b00: rd_o <= |instr_op_rd_i ? (rs1_i < rs2_i ? 1 : 0) : 0;
                endcase
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SLTU: begin
                // Note SLTU rd, x0, rs2 sets rd to 1 if rs2 is not equal to zero, otherwise sets rd to zero
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (rs1_i < rs2_i ? 1 : 0) : 0;
                $display($time, " [%h]: %h sltu rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? (rs1_i < rs2_i ? 1 : 0) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_XOR: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i ^ rs2_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.xor rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i,
                                rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h xor rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i ^ rs2_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SRL: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i >> rs2_i[4:0] : 0;
                $display($time, " [%h]: %h srl rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs1_i >> rs2_i[4:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SRA: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? $signed(rs1_i) >>> rs2_i[4:0] : 0;
                $display($time, " [%h]: %h sra rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else

                rd_o <= |instr_op_rd_i ? $signed(rs1_i) >>> rs2_i[4:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_OR: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i | rs2_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.or rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o,
                                instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h or rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i | rs2_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_AND: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i & rs2_i : 0;
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.and rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i[15:0], instr_op_rd_i, rd_o, instr_op_rs1_i,
                                rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
                end else begin
                    $display($time, " [%h]: %8h and rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
                end
`else
                rd_o <= |instr_op_rd_i ? rs1_i & rs2_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_FENCE: begin
                // FENCE instruction is implemented as a NOP
`ifdef D_EXEC
                // Note if pred and succ are 0 this is a HINT instruction
                $display($time, " [%h]: %h fence fm: %h pred: %h succ: %h; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_imm_i[31:28], instr_op_imm_i[27:24], instr_op_imm_i[23:20], next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ECALL: begin
                /*
                 * ECALL and EBREAK cause the receiving privilege mode’s instr_addr_i register to be set to the address
                 * of the ECALL or EBREAK instruction itself, not the address of the following instruction.
                 */
`ifdef D_EXEC
                $display($time, " [%h]: %h ecall; PC: [%h]", instr_addr_i, instr_i, instr_addr_i);
`endif
                next_addr_o <= instr_addr_i;

                trap_mcause_o[`EX_CODE_ECALL] <= 1'b1;
                trap_mtval_o <= 0;
                // Return an error so we can handle the exception
                {ack_o, err_o} <= 2'b01;
            end

            `INSTR_TYPE_EBREAK: begin
                /*
                 * ECALL and EBREAK cause the receiving privilege mode’s instr_addr_i register to be set to the address
                 * of the ECALL or EBREAK instruction itself, not the address of the following instruction.
                 */
`ifdef D_EXEC
                if (instr_is_compressed_i) begin
                    $display($time, " [%h]: %8h c.ebreak; PC: [%h]", instr_addr_i, instr_i[15:0], instr_addr_i);
                end else begin
                    $display($time, " [%h]: %8h ebreak; PC: [%h]", instr_addr_i, instr_i, instr_addr_i);
                end
`endif
                next_addr_o <= instr_addr_i;
                trap_mcause_o[`EX_CODE_BREAKPOINT] <= 1'b1;
                trap_mtval_o <= 0;

                // Return an error so we can handle the exception
                {ack_o, err_o} <= 2'b01;
            end

            `INSTR_TYPE_MRET: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h mret; load CSR @[%h] ...", instr_addr_i, instr_i,
                                CSR_BEGIN_ADDR | `CSR_EXIT_TRAP);
`endif
                load_task (CSR_BEGIN_ADDR | `CSR_EXIT_TRAP, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

            `INSTR_TYPE_WFI: begin
                /*
                 * The purpose of the WFI instruction is to provide a hint to the implementation, and so a legal
                 * implementation is to simply implement WFI as a NOP.
                 */
`ifdef D_EXEC
                $display($time, " [%h]: %h wfi; PC: [%h]", instr_addr_i, instr_i, next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

`ifdef ENABLE_ZBA_EXT
            `INSTR_TYPE_SH1ADD: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs2_i + {rs1_i[30:0], 1'b0} : 0;
                $display($time, " [%h]: %h sh1add rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs2_i + {rs1_i[30:0], 1'b0} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SH2ADD: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs2_i + {rs1_i[29:0], 2'b00} : 0;
                $display($time, " [%h]: %h sh2add rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs2_i + {rs1_i[29:0], 2'b00} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SH3ADD: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs2_i + {rs1_i[28:0], 3'b000} : 0;
                $display($time, " [%h]: %h sh3add rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs2_i + {rs1_i[28:0], 3'b000} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end
`endif // ENABLE_ZBA_EXT

`ifdef ENABLE_ZBB_EXT
            `INSTR_TYPE_CLZ: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (|rs1_i ? lz_count : 32) : 0;
                $display($time, " [%h]: %h clz rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? (|rs1_i ? lz_count : 32) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_CPOP: begin
                rd_o = 0;
                if (|instr_op_rd_i) begin
                    for (i=0; i<32; i=i+2) begin
                        (* parallel_case, full_case *)
                        case (rs1_i[i +: 2])
                            2'b01, 2'b10: rd_o = rd_o + 2'b01;
                            2'b11: rd_o = rd_o + 2'b10;
                            default: begin end
                        endcase
                    end
                end
`ifdef D_EXEC
                $display($time, " [%h]: %h cpop rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_CTZ: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (|rs1_i ? tz_count : 32) : 0;
                $display($time, " [%h]: %h ctz rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                            instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? (|rs1_i ? tz_count : 32) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_MAX: begin
`ifdef D_EXEC
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: rd_o = |instr_op_rd_i ? (rs1_i[30:0] > rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                    2'b10: rd_o = |instr_op_rd_i ? rs2_i : 0;
                    2'b01: rd_o = |instr_op_rd_i ? rs1_i : 0;
                    2'b00: rd_o = |instr_op_rd_i ? (rs1_i[30:0] > rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                endcase

                $display($time, " [%h]: %h max rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_o);
`else
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: rd_o <= |instr_op_rd_i ? (rs1_i[30:0] > rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                    2'b10: rd_o <= |instr_op_rd_i ? rs2_i : 0;
                    2'b01: rd_o <= |instr_op_rd_i ? rs1_i : 0;
                    2'b00: rd_o <= |instr_op_rd_i ? (rs1_i[30:0] > rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                endcase
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_MAXU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (rs1_i > rs2_i ? rs1_i : rs2_i) : 0;

                $display($time, " [%h]: %h maxu rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? (rs1_i > rs2_i ? rs1_i : rs2_i) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_MIN: begin
`ifdef D_EXEC
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: rd_o = |instr_op_rd_i ? (rs1_i[30:0] < rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                    2'b10: rd_o = |instr_op_rd_i ? rs2_i : 0;
                    2'b01: rd_o = |instr_op_rd_i ? rs1_i : 0;
                    2'b00: rd_o = |instr_op_rd_i ? (rs1_i[30:0] < rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                endcase

                $display($time, " [%h]: %h min rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_o);
`else
                (* parallel_case, full_case *)
                case ({rs1_i[31], rs2_i[31]})
                    2'b11: rd_o <= |instr_op_rd_i ? (rs1_i[30:0] < rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                    2'b10: rd_o <= |instr_op_rd_i ? rs1_i : 0;
                    2'b01: rd_o <= |instr_op_rd_i ? rs2_i : 0;
                    2'b00: rd_o <= |instr_op_rd_i ? (rs1_i[30:0] < rs2_i[30:0] ? rs1_i : rs2_i) : 0;
                endcase
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_MINU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (rs1_i < rs2_i ? rs1_i : rs2_i) : 0;

                $display($time, " [%h]: %h minu rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? (rs1_i < rs2_i ? rs1_i : rs2_i) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ORC_B: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? ({|rs1_i[31:24] ? 8'hff : 8'h00, |rs1_i[23:16] ? 8'hff : 8'h00,
                                        |rs1_i[15:8] ? 8'hff : 8'h00, |rs1_i[7:0] ? 8'hff : 8'h00}) : 0;

                $display($time, " [%h]: %h orc.b rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? ({|rs1_i[31:24] ? 8'hff : 8'h00, |rs1_i[23:16] ? 8'hff : 8'h00,
                                        |rs1_i[15:8] ? 8'hff : 8'h00, |rs1_i[7:0] ? 8'hff : 8'h00}) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ORN: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rs1_i | ~rs2_i : 0;
                $display($time, " [%h]: %8h orn rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? rs1_i | ~rs2_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_REV8: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? ({rs1_i[7:0], rs1_i[15:8], rs1_i[23:16], rs1_i[31:24]}) : 0;
                $display($time, " [%h]: %h rev8 rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? ({rs1_i[7:0], rs1_i[15:8], rs1_i[23:16], rs1_i[31:24]}) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ROL: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) rd_o = bs_left_out;

                $display($time, " [%h]: %h rol rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_o);
`else
                if (|instr_op_rd_i) rd_o <= bs_left_out;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ROR: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) rd_o = bs_right_out;

                $display($time, " [%h]: %h ror rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_o);
`else
                if (|instr_op_rd_i) rd_o <= bs_right_out;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_RORI: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) rd_o = bs_right_imm_out;

                $display($time, " [%h]: %h rori rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i[4:0], next_addr_o);
`else
                if (|instr_op_rd_i) rd_o <= bs_right_imm_out;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SEXT_B: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {{24{rs1_i[7]}}, rs1_i[7:0]}: 0;
                $display($time, " [%h]: %h sext.b rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? {{24{rs1_i[7]}}, rs1_i[7:0]}: 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_SEXT_H: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {{16{rs1_i[15]}}, rs1_i[15:0]}: 0;
                $display($time, " [%h]: %h sext.b rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? {{16{rs1_i[15]}}, rs1_i[15:0]}: 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_XNOR: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? ~(rs1_i ^ rs2_i) : 0;
                $display($time, " [%h]: %8h xnor rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? ~(rs1_i ^ rs2_i) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ZEXT_H: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {16'h0, rs1_i[15:0]}: 0;

                $display($time, " [%h]: %h zext.h rdx%0d[%h] rs1x%0d[%h]; PC: [%h]", instr_addr_i, instr_i,
                                instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, next_addr_o);
`else
                rd_o <= |instr_op_rd_i ? {16'h0, rs1_i[15:0]}: 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end
`endif // ENABLE_ZBB_EXT

`ifdef ENABLE_ZBC_EXT
            `INSTR_TYPE_CLMUL: begin
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_CLMULH: begin
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_CLMULR: begin
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end
`endif // ENABLE_ZBC_EXT

`ifdef ENABLE_ZBS_EXT
            `INSTR_TYPE_BCLR: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) begin
                    rd_o = rs1_i;
                    rd_o[rs2_i[4:0]] = 1'b0;
                end else begin
                    rd_o = 0;
                end

                $display($time, " [%h]: %8h bclr rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                if (|instr_op_rd_i) begin
                    rd_o <= rs1_i;
                    rd_o[rs2_i[4:0]] <= 1'b0;
                end else begin
                    rd_o <= 0;
                end
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BCLRI: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) begin
                    rd_o = rs1_i;
                    rd_o[instr_op_imm_i[4:0]] = 1'b0;
                end else begin
                    rd_o = 0;
                end

                $display($time, " [%h]: %8h bclri rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                if (|instr_op_rd_i) begin
                    rd_o <= rs1_i;
                    rd_o[instr_op_imm_i[4:0]] <= 1'b0;
                end else begin
                    rd_o <= 0;
                end
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BEXT: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {31'h0, rs1_i[rs2_i[4:0]]} : 0;
                $display($time, " [%h]: %8h bext rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? {31'h0, rs1_i[rs2_i[4:0]]} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BEXTI: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {31'h0, rs1_i[instr_op_imm_i[4:0]]} : 0;
                $display($time, " [%h]: %8h bexti rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? {31'h0, rs1_i[instr_op_imm_i[4:0]]} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BINV: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) begin
                    rd_o = rs1_i;
                    rd_o[rs2_i[4:0]] = ~rs1_i[rs2_i[4:0]];
                end else begin
                    rd_o = 0;
                end

                $display($time, " [%h]: %8h binv rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                if (|instr_op_rd_i) begin
                    rd_o <= rs1_i;
                    rd_o[rs2_i[4:0]] <= ~rs1_i[rs2_i[4:0]];
                end else begin
                    rd_o <= 0;
                end
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BINVI: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) begin
                    rd_o = rs1_i;
                    rd_o[instr_op_imm_i[4:0]] = ~rs1_i[instr_op_imm_i[4:0]];
                end else begin
                    rd_o = 0;
                end

                $display($time, " [%h]: %8h binvi rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                if (|instr_op_rd_i) begin
                    rd_o <= rs1_i;
                    rd_o[instr_op_imm_i[4:0]] <= ~rs1_i[instr_op_imm_i[4:0]];
                end else begin
                    rd_o <= 0;
                end
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BSET: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) begin
                    rd_o = rs1_i;
                    rd_o[rs2_i[4:0]] = 1'b1;
                end else begin
                    rd_o = 0;
                end

                $display($time, " [%h]: %8h bset rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                if (|instr_op_rd_i) begin
                    rd_o <= rs1_i;
                    rd_o[rs2_i[4:0]] <= 1'b1;
                end else begin
                    rd_o <= 0;
                end
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_BSETI: begin
`ifdef D_EXEC
                if (|instr_op_rd_i) begin
                    rd_o = rs1_i;
                    rd_o[instr_op_imm_i[4:0]] = 1'b1;
                end else begin
                    rd_o = 0;
                end

                $display($time, " [%h]: %8h bseti rdx%0d[%h] rs1x%0d[%h] imm: %h; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_imm_i, next_addr_comb);
`else
                if (|instr_op_rd_i) begin
                    rd_o <= rs1_i;
                    rd_o[instr_op_imm_i[4:0]] <= 1'b1;
                end else begin
                    rd_o <= 0;
                end
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end
`endif // ENABLE_ZBS_EXT

`ifdef ENABLE_ZIFENCEI_EXT
            `INSTR_TYPE_FENCE_I: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h fence.i imm: %h; PC: [%h]", instr_addr_i, instr_i, instr_op_imm_i[31:20],
                                next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
                fencei_o <= 1'b1;
                {ack_o, err_o} <= 2'b10;
            end
`endif // ENABLE_ZIFENCEI_EXT

`ifdef ENABLE_ZICOND_EXT
            `INSTR_TYPE_ZERO_EQZ: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (rs2_i == 0 ? 0 : rs1_i) : 0;
                $display($time, " [%h]: %h czero.eqz rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? (rs2_i == 0 ? 0 : rs1_i) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_ZERO_NEZ: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? (rs2_i != 0 ? 0 : rs1_i) : 0;
                $display($time, " [%h]: %h czero.nez rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                            instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? (rs2_i != 0 ? 0 : rs1_i) : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
            end
`endif // ENABLE_ZICOND_EXT

`ifdef ENABLE_RV32M_EXT
            `INSTR_TYPE_MUL: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h mul rdx%0d rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                mul_op_1_o <= rs1_i;
                mul_op_1_is_signed_o <= 1'b1;
                mul_op_2_o <= rs2_i;
                mul_op_2_is_signed_o <= 1'b1;
                mul_result_upper_o <= 1'b0;

                {mul_stb_o, mul_cyc_o} <= 2'b11;
                state_m <= STATE_MUL_PENDING;
            end

            `INSTR_TYPE_MULH: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h mulh rdx%0d rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                mul_op_1_o <= rs1_i;
                mul_op_1_is_signed_o <= 1'b1;
                mul_op_2_o <= rs2_i;
                mul_op_2_is_signed_o <= 1'b1;
                mul_result_upper_o <= 1'b1;

                {mul_stb_o, mul_cyc_o} <= 2'b11;
                state_m <= STATE_MUL_PENDING;
            end

            `INSTR_TYPE_MULHSU: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h mulhsu rdx%0d, rs1x%0d[%h], rs2x%0d[%h] ...", instr_addr_i,
                            instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                mul_op_1_o <= rs1_i;
                mul_op_1_is_signed_o <= 1'b1;
                mul_op_2_o <= rs2_i;
                mul_op_2_is_signed_o <= 1'b0;
                mul_result_upper_o <= 1'b1;

                {mul_stb_o, mul_cyc_o} <= 2'b11;
                state_m <= STATE_MUL_PENDING;
            end

            `INSTR_TYPE_MULHU: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h mulhu rdx%0d rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i, instr_i,
                            instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                mul_op_1_o <= rs1_i;
                mul_op_1_is_signed_o <= 1'b0;
                mul_op_2_o <= rs2_i;
                mul_op_2_is_signed_o <= 1'b0;
                mul_result_upper_o <= 1'b1;

                {mul_stb_o, mul_cyc_o} <= 2'b11;
                state_m <= STATE_MUL_PENDING;
            end

            `INSTR_TYPE_DIV: begin
                if (rs2_i) begin
`ifdef D_EXEC
                    $display($time, " [%h]: %h div rdx%0d rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i,
                                instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                    divident_o <= rs1_i;
                    divisor_o <= rs2_i;
                    div_is_signed_o <= 1'b1;

                    {div_stb_o, div_cyc_o} <= 2'b11;
                    state_m <= STATE_DIV_PENDING;
                end else begin
`ifdef D_EXEC
                    rd_o = |instr_op_rd_i ? 32'hffffffff : 0;
                    $display($time, " [%h]: %h div rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
`else
                    rd_o <= |instr_op_rd_i ? 32'hffffffff : 0;
`endif
                    next_addr_o <= next_addr_comb;
                    {ack_o, err_o} <= 2'b10;
                end
            end

            `INSTR_TYPE_DIVU: begin
                if (rs2_i) begin
                    divident_o <= rs1_i;
                    divisor_o <= rs2_i;
                    div_is_signed_o <= 1'b0;
`ifdef D_EXEC
                    $display($time, " [%h]: %h divu rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                    {div_stb_o, div_cyc_o} <= 2'b11;
                    state_m <= STATE_DIV_PENDING;
                end else begin
`ifdef D_EXEC
                    rd_o = |instr_op_rd_i ? 32'hffffffff : 0;
                    $display($time, " [%h]: %h divu rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
`else
                    rd_o <= |instr_op_rd_i ? 32'hffffffff : 0;
`endif
                    next_addr_o <= next_addr_comb;
                    {ack_o, err_o} <= 2'b10;
                end
            end

            `INSTR_TYPE_REM: begin
                if (rs2_i) begin
`ifdef D_EXEC
                    $display($time, " [%h]: %h rem rdx%0d rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i, instr_i,
                                instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                    divident_o <= rs1_i;
                    divisor_o <= rs2_i;
                    div_is_signed_o <= 1'b1;

                    {div_stb_o, div_cyc_o} <= 2'b11;
                    state_m <= STATE_DIV_PENDING;
                end else begin
`ifdef D_EXEC
                    rd_o = |instr_op_rd_i ? rs1_i : 0;
                    $display($time, " [%h]: %h rem rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
`else
                    rd_o <= |instr_op_rd_i ? rs1_i : 0;
`endif
                    next_addr_o <= next_addr_comb;
                    {ack_o, err_o} <= 2'b10;
                end
            end

            `INSTR_TYPE_REMU: begin
                if (rs2_i) begin
`ifdef D_EXEC
                    $display($time, " [%h]: %h remu rdx%0d rs1x%0d[%h] rs2x%0d[%h] ...", instr_addr_i, instr_i,
                                instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i);
`endif
                    divident_o <= rs1_i;
                    divisor_o <= rs2_i;
                    div_is_signed_o <= 1'b0;

                    {div_stb_o, div_cyc_o} <= 2'b11;
                    state_m <= STATE_DIV_PENDING;
                end else begin
`ifdef D_EXEC
                    rd_o = |instr_op_rd_i ? rs1_i : 0;
                    $display($time, " [%h]: %h remu rdx%0d[%h] rs1x%0d[%h] rs2x%0d[%h]; PC: [%h]", instr_addr_i,
                                instr_i, instr_op_rd_i, rd_o, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                                next_addr_comb);
`else
                    rd_o <= |instr_op_rd_i ? rs1_i : 0;
`endif
                    next_addr_o <= next_addr_comb;
                    {ack_o, err_o} <= 2'b10;
                end
            end
`endif //ENABLE_RV32M_EXT

            `INSTR_TYPE_CSRRW: begin
                store_addr = CSR_BEGIN_ADDR | instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h csrrw rs1x%0d[%h]; load CSR[%h] @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rs1_i, rs1_i, instr_op_imm_i, store_addr);
`endif
                load_task (store_addr, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

            `INSTR_TYPE_CSRRS: begin
                store_addr = CSR_BEGIN_ADDR | instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h csrrs rs1x%0d[%h]; load CSR[%h] @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rs1_i, rs1_i, instr_op_imm_i, store_addr);
`endif
                load_task (store_addr, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

            `INSTR_TYPE_CSRRC: begin
                store_addr = CSR_BEGIN_ADDR | instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h csrrc rs1x%0d[%h]; load CSR[%h] @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rs1_i, rs1_i, instr_op_imm_i, store_addr);
`endif
                load_task (store_addr, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

            `INSTR_TYPE_CSRRWI: begin
                store_addr = CSR_BEGIN_ADDR | instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h csrrwi UIMM: %h; load CSR[%h] @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rs1_i, instr_op_imm_i, store_addr);
`endif
                load_task (store_addr, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

            `INSTR_TYPE_CSRRSI: begin
                store_addr = CSR_BEGIN_ADDR | instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h csrrsi UIMM: %h; load CSR[%h] @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rs1_i, instr_op_imm_i, store_addr);
`endif
                load_task (store_addr, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

            `INSTR_TYPE_CSRRCI: begin
                store_addr = CSR_BEGIN_ADDR | instr_op_imm_i;
`ifdef D_EXEC
                $display($time, " [%h]: %h csrrci UIMM: %h; load CSR[%h] @[%h] ...", instr_addr_i, instr_i,
                            instr_op_rs1_i, instr_op_imm_i, store_addr);
`endif
                load_task (store_addr, `ADDR_TAG_CSR_INSTR, 4'b1111);
            end

`ifdef ENABLE_RV32A_EXT
            `INSTR_TYPE_LR_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h lr.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_LRSC, 4'b1111);
            end

            `INSTR_TYPE_SC_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h sc.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; store %h @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs2_i, rs1_i);
`endif
                store_task (rs1_i, `ADDR_TAG_MODE_LRSC, rs2_i, 4'b1111);
            end

            `INSTR_TYPE_AMOSWAP_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amoswap.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOADD_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amoadd.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOXOR_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amoxor.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOAND_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amoand.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOOR_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amoor.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOMIN_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amomin.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOMAX_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amomax.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOMINU_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amominu.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end

            `INSTR_TYPE_AMOMAXU_W: begin
`ifdef D_EXEC
                $display($time, " [%h]: %h amomaxu.w rdx%0d rs1x%0d[%h] rs2x%0d[%h]; aq:%h; rl:%h; load @[%h] ...",
                            instr_addr_i, instr_i, instr_op_rd_i, instr_op_rs1_i, rs1_i, instr_op_rs2_i, rs2_i,
                            instr_op_imm_i[1], instr_op_imm_i[0], rs1_i);
`endif
                load_task (rs1_i, `ADDR_TAG_MODE_AMO, 4'b1111);
            end
`endif // ENABLE_RV32A_EXT
        endcase
    endtask

    //==================================================================================================================
    // Data read complete task
    //==================================================================================================================
    task data_read_complete_task;

        (* parallel_case, full_case *)
        case (instr_op_type_i)
            `INSTR_TYPE_LB: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {{24{data_data_i[7]}}, data_data_i[7:0]} : 0;
                $display($time, "           :          @[%h] -> rdx%0d[%h]; PC: [%h]",
                            data_addr_o, instr_op_rd_i, rd_o, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? {{24{data_data_i[7]}}, data_data_i[7:0]} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
                state_m <= STATE_EXEC;
            end

            `INSTR_TYPE_LH: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {{16{data_data_i[15]}}, data_data_i[15:0]} : 0;
                $display($time, "           :          @[%h] -> rdx%0d[%h]; PC: [%h]",
                            data_addr_o, instr_op_rd_i, rd_o, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? {{16{data_data_i[15]}}, data_data_i[15:0]} : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
                state_m <= STATE_EXEC;
            end

            `INSTR_TYPE_LW: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> rdx%0d[%h]; PC: [%h]",
                            data_addr_o, instr_op_rd_i, rd_o, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
                state_m <= STATE_EXEC;
            end

            `INSTR_TYPE_LBU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i[7:0] : 0;
                $display($time, "           :          @[%h] -> rdx%0d[%h]; PC: [%h]",
                            data_addr_o, instr_op_rd_i, rd_o, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? data_data_i[7:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
                state_m <= STATE_EXEC;
            end

            `INSTR_TYPE_LHU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i[15:0] : 0;
                $display($time, "           :          @[%h] -> rdx%0d[%h]; PC: [%h]",
                            instr_op_rd_i, rd_o, data_addr_o, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? data_data_i[15:0] : 0;
`endif
                next_addr_o <= next_addr_comb;
                {ack_o, err_o} <= 2'b10;
                state_m <= STATE_EXEC;
            end

            `INSTR_TYPE_MRET: begin
`ifdef D_EXEC
                $display($time, "           :          @[%h] -> %h.", data_addr_o, data_data_i);
`endif
                next_addr_o <= data_data_i;
                jmp_o <= 1'b1;
                mret_o <= 1'b1;

                state_m <= STATE_EXEC;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_CSRRW: begin
                if (instr_op_imm_i[11:10] != 2'b11) begin
                    store_delayed_task(store_addr, `ADDR_TAG_CSR_INSTR, rs1_i);
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, rs1_i, store_addr);
`endif
                end else begin
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, next_addr_comb);
`endif
                    state_m <= STATE_EXEC;
                    {ack_o, err_o} <= 2'b10;
                end

                rd_o <= |instr_op_rd_i ? data_data_i : 0;
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_CSRRS: begin
                if ((instr_op_imm_i[11:10] != 2'b11) && (instr_op_rs1_i != 0)) begin
                    store_delayed_task(store_addr, `ADDR_TAG_CSR_INSTR, data_data_i | rs1_i);
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, data_data_i | rs1_i, store_addr);
`endif
                end else begin
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, next_addr_comb);
`endif
                    state_m <= STATE_EXEC;
                    {ack_o, err_o} <= 2'b10;
                end

                rd_o <= |instr_op_rd_i ? data_data_i : 0;
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_CSRRC: begin
                if ((instr_op_imm_i[11:10] != 2'b11) && (instr_op_rs1_i != 0)) begin
                    store_delayed_task(store_addr, `ADDR_TAG_CSR_INSTR, data_data_i & ~rs1_i);
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, data_data_i & ~rs1_i, store_addr);
`endif
                end else begin
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, next_addr_comb);
`endif
                    state_m <= STATE_EXEC;
                    {ack_o, err_o} <= 2'b10;
                end

                rd_o <= |instr_op_rd_i ? data_data_i : 0;
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_CSRRWI: begin
                if (instr_op_imm_i[11:10] != 2'b11) begin
                    store_delayed_task(store_addr, `ADDR_TAG_CSR_INSTR, instr_op_rs1_i);
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, instr_op_rs1_i, store_addr);
`endif
                end else begin
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, next_addr_comb);
`endif
                    state_m <= STATE_EXEC;
                    {ack_o, err_o} <= 2'b10;
                end

                rd_o <= |instr_op_rd_i ? data_data_i : 0;
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_CSRRSI: begin
                if ((instr_op_imm_i[11:10] != 2'b11) && (instr_op_rs1_i != 0)) begin
                    store_delayed_task(store_addr, `ADDR_TAG_CSR_INSTR, data_data_i | instr_op_rs1_i);
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, data_data_i, data_data_i | instr_op_rs1_i, store_addr);
`endif
                end else begin
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, next_addr_comb);
`endif
                    state_m <= STATE_EXEC;
                    {ack_o, err_o} <= 2'b10;
                end

                rd_o <= |instr_op_rd_i ? data_data_i : 0;
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_CSRRCI: begin
                if ((instr_op_imm_i[11:10] != 2'b11) && (instr_op_rs1_i != 0)) begin
                    store_delayed_task(store_addr, `ADDR_TAG_CSR_INSTR, data_data_i & ~instr_op_rs1_i);
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, data_data_i, data_data_i & ~instr_op_rs1_i, store_addr);
`endif
                end else begin
`ifdef D_EXEC
                    $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]",
                                data_addr_o, data_data_i, instr_op_rd_i, data_data_i, next_addr_comb);
`endif
                    state_m <= STATE_EXEC;
                    {ack_o, err_o} <= 2'b10;
                end

                rd_o <= |instr_op_rd_i ? data_data_i : 0;
                next_addr_o <= next_addr_comb;
            end

`ifdef ENABLE_RV32A_EXT
            `INSTR_TYPE_LR_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? {{16{data_data_i[15]}}, data_data_i[15:0]} : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; PC: [%h]", data_addr_o, data_data_i,
                                instr_op_rd_i, rd_o, next_addr_comb);
`else
                rd_o <= |instr_op_rd_i ? {{16{data_data_i[15]}}, data_data_i[15:0]} : 0;
`endif
                next_addr_o <= next_addr_comb;
                state_m <= STATE_EXEC;
                {ack_o, err_o} <= 2'b10;
            end

            `INSTR_TYPE_AMOSWAP_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, rs2_i);
            end

            `INSTR_TYPE_AMOADD_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, data_data_i + rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i + rs2_i);
            end

            `INSTR_TYPE_AMOXOR_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, data_data_i ^ rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i ^ rs2_i);
            end

            `INSTR_TYPE_AMOAND_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, data_data_i & rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i & rs2_i);
            end

            `INSTR_TYPE_AMOOR_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, data_data_i | rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i | rs2_i);
            end

            `INSTR_TYPE_AMOMIN_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                (* parallel_case, full_case *)
                case ({data_data_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                    data_addr_o, data_data_i, instr_op_rd_i, rd_o,
                                    data_data_i[30:0] < rs2_i[30:0] ? data_data_i : rs2_i, rs1_i);
                    end

                    2'b10: begin
                        // data_data_i is negative, rs2_i is positive
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                    data_addr_o, data_data_i, instr_op_rd_i, rd_o, data_data_i, rs1_i);
                    end

                    2'b01: begin
                        // data_data_i is positive, rs2_i is negative
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                    data_addr_o, data_data_i, instr_op_rd_i, rd_o, rs2_i, rs1_i);
                    end

                    2'b00: begin // Both are positive
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                    data_addr_o, data_data_i, instr_op_rd_i, rd_o,
                                    data_data_i < rs2_i ? data_data_i : rs2_i, rs1_i);
                    end
                endcase
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                (* parallel_case, full_case *)
                case ({data_data_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO,
                                            data_data_i[30:0] < rs2_i[30:0] ? data_data_i : rs2_i);
                    end

                    2'b10: begin
                        // data_data_i is negative, rs2_i is positive
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i);
                    end

                    2'b01: begin
                        // data_data_i is positive, rs2_i is negative
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, rs2_i);
                    end

                    2'b00: begin // Both are positive
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO,
                                            data_data_i < rs2_i ? data_data_i : rs2_i);
                    end
                endcase
            end

            `INSTR_TYPE_AMOMAX_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;

                (* parallel_case, full_case *)
                case ({data_data_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                        data_addr_o, data_data_i, instr_op_rd_i, rd_o,
                                        data_data_i[30:0] > rs2_i[30:0] ? data_data_i : rs2_i, rs1_i);
                    end

                    2'b10: begin
                        // data_data_i is negative, rs2_i is positive
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                        data_addr_o, data_data_i, instr_op_rd_i, rd_o, rs2_i, rs1_i);
                    end

                    2'b01: begin
                        // data_data_i is positive, rs2_i is negative
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                        data_addr_o, data_data_i, instr_op_rd_i, rd_o, data_data_i, rs1_i);
                    end

                    2'b00: begin // Both are positive
                        $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...",
                                        data_addr_o, data_data_i, instr_op_rd_i, rd_o,
                                        data_data_i > rs2_i ? data_data_i : rs2_i, rs1_i);
                    end
                endcase
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                (* parallel_case, full_case *)
                case ({data_data_i[31], rs2_i[31]})
                    2'b11: begin // Both are negative
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO,
                                            data_data_i[30:0] > rs2_i[30:0] ? data_data_i : rs2_i);
                    end

                    2'b10: begin
                        // data_data_i is negative, rs2_i is positive
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, rs2_i);
                    end

                    2'b01: begin
                        // data_data_i is positive, rs2_i is negative
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i);
                    end

                    2'b00: begin // Both are positive
                        store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO,
                                            data_data_i > rs2_i ? data_data_i : rs2_i);
                    end
                endcase
            end

            `INSTR_TYPE_AMOMINU_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, data_data_i < rs2_i ? data_data_i : rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i < rs2_i ? data_data_i : rs2_i);
            end

            `INSTR_TYPE_AMOMAXU_W: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? data_data_i : 0;
                $display($time, "           :          @[%h] -> %8h; rdx%0d[%h]; store %h @[%h] ...", data_addr_o,
                                data_data_i, instr_op_rd_i, rd_o, data_data_i > rs2_i ? data_data_i : rs2_i, rs1_i);
`else
                rd_o <= |instr_op_rd_i ? data_data_i : 0;
`endif
                store_delayed_task(rs1_i, `ADDR_TAG_MODE_AMO, data_data_i > rs2_i ? data_data_i : rs2_i);
            end
`endif // ENABLE_RV32A_EXT

            default: begin
`ifdef D_EXEC
                $display($time, " EXEC: data_read_complete_task instruction not handled %h", instr_op_type_i);
`endif
                state_m <= STATE_EXEC;
                {ack_o, err_o} <= 2'b10;
            end
        endcase
    endtask

    //==================================================================================================================
    // Data read error task
    //==================================================================================================================
    task data_read_error_task;
        (* parallel_case, full_case *)
        case (instr_op_type_i)
/*
            // Handled by default case
            `INSTR_TYPE_LB, `INSTR_TYPE_LH, `INSTR_TYPE_LW, `INSTR_TYPE_LBU, `INSTR_TYPE_LHU: begin
                trap_mcause_o[`EX_CODE_LOAD_ACCESS_FAULT] <= 1'b1;
                trap_mtval_o <= data_addr_o;
            end

`ifdef ENABLE_RV32A_EXT
            // Handled by default case
            `INSTR_TYPE_LR_W, `INSTR_TYPE_SC_W, `INSTR_TYPE_AMOSWAP_W, `INSTR_TYPE_AMOADD_W, `INSTR_TYPE_AMOXOR_W,
            `INSTR_TYPE_AMOAND_W, `INSTR_TYPE_AMOOR_W, `INSTR_TYPE_AMOMIN_W, `INSTR_TYPE_AMOMAX_W,
            `INSTR_TYPE_AMOMINU_W, `INSTR_TYPE_AMOMAXU_W: begin
                trap_mcause_o[`EX_CODE_LOAD_ACCESS_FAULT] <= 1'b1;
                trap_mtval_o <= data_addr_o;
            end
`endif // ENABLE_RV32A_EXT
*/

            `INSTR_TYPE_CSRRW, `INSTR_TYPE_CSRRS, `INSTR_TYPE_CSRRC, `INSTR_TYPE_CSRRWI, `INSTR_TYPE_CSRRSI,
            `INSTR_TYPE_CSRRCI, `INSTR_TYPE_MRET: begin
                trap_mcause_o[`EX_CODE_ILLEGAL_INSTRUCTION] <= 1'b1;
                trap_mtval_o <= instr_i;
            end

            default: begin
                trap_mcause_o[`EX_CODE_LOAD_ACCESS_FAULT] <= 1'b1;
                trap_mtval_o <= data_addr_o;
            end
        endcase

        state_m <= STATE_EXEC;
        {ack_o, err_o} <= 2'b01;
    endtask

    //==================================================================================================================
    // Data write complete task
    //==================================================================================================================
    task data_write_complete_task;
        (* parallel_case, full_case *)
        case (instr_op_type_i)
            `INSTR_TYPE_SB: begin
`ifdef D_EXEC
                $display($time, "           :          rs2x%0d[%2h] -> @[%h]; PC: [%h]",
                            instr_op_rs2_i, rs2_i, data_addr_o, next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_SH: begin
`ifdef D_EXEC
                $display($time, "           :          rs2x%0d[%4h] -> @[%h]; PC: [%h]",
                            instr_op_rs2_i, rs2_i, data_addr_o, next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_SW: begin
`ifdef D_EXEC
                $display($time, "           :          rs2x%0d[%8h] -> @[%h]; PC: [%h]",
                            instr_op_rs2_i, rs2_i, data_addr_o, next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_CSRRW, `INSTR_TYPE_CSRRS, `INSTR_TYPE_CSRRC,
            `INSTR_TYPE_CSRRWI, `INSTR_TYPE_CSRRSI, `INSTR_TYPE_CSRRCI: begin
`ifdef D_EXEC
                $display($time, "           :          %8h -> @[%h]; PC: [%h]", data_data_o, data_addr_o,
                            next_addr_comb);
`endif
            end

`ifdef ENABLE_RV32A_EXT
            `INSTR_TYPE_SC_W: begin
`ifdef D_EXEC
                $display($time, "           :          %8h -> @[%h]; PC: [%h]", data_data_o, data_addr_o,
                                   next_addr_comb);
`endif
                /*
                 * The sc.w succeeds only if the reservation is still valid and the reservation set contains the bytes
                 * being written.
                 */
                if (data_tag_i) begin
                    /*
                     * The failure code with value 1 is reserved to encode an unspecified failure.  Other failure codes
                     * are reserved at this time, and portable software should only assume the failure code will be
                     * non-zero.
                     */
                    rd_o <= 1;
                end else begin
                    /*
                     * If the sc.w succeeds, the instruction writes the word in rs2 to memory, and it writes zero to rd.
                     */
                    rd_o <= 0;
                end
                next_addr_o <= next_addr_comb;
            end

            `INSTR_TYPE_AMOSWAP_W, `INSTR_TYPE_AMOADD_W, `INSTR_TYPE_AMOXOR_W,
            `INSTR_TYPE_AMOAND_W, `INSTR_TYPE_AMOOR_W, `INSTR_TYPE_AMOMIN_W, `INSTR_TYPE_AMOMAX_W,
            `INSTR_TYPE_AMOMINU_W, `INSTR_TYPE_AMOMAXU_W: begin
`ifdef D_EXEC
                $display($time, "           :          %8h -> @[%h]; PC: [%h]", data_data_o, data_addr_o,
                            next_addr_comb);
`endif
                next_addr_o <= next_addr_comb;
            end
`endif // ENABLE_RV32A_EXT

            default: begin
`ifdef D_EXEC
                $display($time, " EXEC: data_write_complete_task instruction not handled %h ", instr_op_type_i);
`endif
            end
        endcase

        {ack_o, err_o} <= 2'b10;

        state_m <= STATE_EXEC;
    endtask

    //==================================================================================================================
    // Data write error task
    //==================================================================================================================
    task data_write_error_task;
        (* parallel_case, full_case *)
        case (instr_op_type_i)
/*
            // Handled by default case
            `INSTR_TYPE_SB, `INSTR_TYPE_SH, `INSTR_TYPE_SW: begin
                trap_mcause_o[`EX_CODE_STORE_ACCESS_FAULT] <= 1'b1;
                trap_mtval_o <= data_addr_o;
            end

`ifdef ENABLE_RV32A_EXT
            // Handled by default case
            `INSTR_TYPE_LR_W, `INSTR_TYPE_SC_W, `INSTR_TYPE_AMOSWAP_W, `INSTR_TYPE_AMOADD_W, `INSTR_TYPE_AMOXOR_W,
            `INSTR_TYPE_AMOAND_W, `INSTR_TYPE_AMOOR_W, `INSTR_TYPE_AMOMIN_W, `INSTR_TYPE_AMOMAX_W,
            `INSTR_TYPE_AMOMINU_W, `INSTR_TYPE_AMOMAXU_W: begin
                trap_mcause_o[`EX_CODE_STORE_ACCESS_FAULT] <= 1'b1;
                trap_mtval_o <= data_addr_o;
            end
`endif // ENABLE_RV32A_EXT
*/
            `INSTR_TYPE_CSRRW, `INSTR_TYPE_CSRRS, `INSTR_TYPE_CSRRC,
            `INSTR_TYPE_CSRRWI, `INSTR_TYPE_CSRRSI, `INSTR_TYPE_CSRRCI, `INSTR_TYPE_MRET: begin
                trap_mcause_o[`EX_CODE_ILLEGAL_INSTRUCTION] <= 1'b1;
                trap_mtval_o <= instr_i;
            end

            default: begin
                trap_mcause_o[`EX_CODE_STORE_ACCESS_FAULT] <= 1'b1;
                trap_mtval_o <= data_addr_o;
            end
        endcase

        {ack_o, err_o} <= 2'b01;

        state_m <= STATE_EXEC;
    endtask

    //==================================================================================================================
    // Load task
    //==================================================================================================================
    task load_task (input [31:0] addr, input [`ADDR_TAG_BITS-1:0] addr_tag, input [3:0] sel);
        data_addr_o <= addr;
        data_sel_o <= sel;
        data_we_o <= 1'b0;
        data_addr_tag_o <= addr_tag;
        {data_stb_o, data_cyc_o} <= 2'b11;

        state_m <= STATE_RD_PENDING;
    endtask

    //==================================================================================================================
    // Store task
    //==================================================================================================================
    task store_task (input [31:0] addr, input [`ADDR_TAG_BITS-1:0] addr_tag, input [31:0] io_data, input [3:0] sel);
        data_addr_o <= addr;
        data_sel_o <= sel;
        data_data_o <= io_data;
        data_we_o <= 1'b1;
        data_addr_tag_o <= addr_tag;
        {data_stb_o, data_cyc_o} <= 2'b11;

        state_m <= STATE_WR_PENDING;
    endtask

    //==================================================================================================================
    // Store delayed task is used when a previous load or store completes.
    //==================================================================================================================
    task store_delayed_task(input [31:0] addr, input [`ADDR_TAG_BITS-1:0] addr_tag, input [31:0] io_data);
        store_addr <= addr;
        store_value <= io_data;
        store_addr_tag <= addr_tag;

        state_m <= STATE_DELAYED_STORE;
    endtask

    //==================================================================================================================
    // Execute instructions
    //==================================================================================================================
    always @(posedge clk_i) begin
        if (rst_i) begin
            {data_stb_o, data_cyc_o} <= 2'b00;
            {ack_o, err_o} <= 2'b00;
`ifdef ENABLE_RV32M_EXT
            {mul_stb_o, mul_cyc_o} <= 2'b00;
            {div_stb_o, div_cyc_o} <= 2'b00;
`endif // ENABLE_RV32M_EXT

            state_m <= STATE_EXEC;
        end else begin
            if (ack_o) ack_o <= 1'b0;
            if (err_o) err_o <= 1'b0;

            (* parallel_case, full_case *)
            case (state_m)
                STATE_EXEC: begin
                    if (stb_i) begin
                        exec_task;
                    end
                end

                STATE_RD_PENDING: begin
                    if (data_stb_o & data_cyc_o & data_ack_i) begin
                        {data_stb_o, data_cyc_o} <= 2'b00;

                        data_read_complete_task;
                    end else if (data_stb_o & data_cyc_o & data_err_i) begin
                        {data_stb_o, data_cyc_o} <= 2'b00;

                        data_read_error_task;
                    end
                end

                STATE_WR_PENDING: begin
                    if (data_stb_o & data_cyc_o & data_ack_i) begin
                        {data_stb_o, data_cyc_o} <= 2'b00;

                        data_write_complete_task;
                    end else if (data_stb_o & data_cyc_o & data_err_i) begin
                        {data_stb_o, data_cyc_o} <= 2'b00;

                        data_write_error_task;
                    end
                end

                STATE_DELAYED_STORE: begin
                    store_task (store_addr, store_addr_tag, store_value, 4'b1111);
                end

`ifdef ENABLE_RV32M_EXT
                STATE_MUL_PENDING: begin
                    if (mul_stb_o & mul_cyc_o & mul_ack_i) begin
                        {mul_stb_o, mul_cyc_o} <= 2'b00;
                        mul_complete_task;
                    end
                end

                STATE_DIV_PENDING: begin
                    if (div_stb_o & div_cyc_o & div_ack_i) begin
                        {div_stb_o, div_cyc_o} <= 2'b00;
                        div_complete_task;
                    end
                end
`endif // ENABLE_RV32M_EXT
            endcase
        end
    end

`ifdef ENABLE_RV32M_EXT
    //==================================================================================================================
    // Multiply complete task
    //==================================================================================================================
    task mul_complete_task;
`ifdef D_EXEC
        rd_o = |instr_op_rd_i ? mul_result_i : 0;
        $display($time, "           :          %8h -> rdx%0d; PC: [%h]", rd_o, instr_op_rd_i, next_addr_comb);
`else
        if (|instr_op_rd_i) rd_o <= mul_result_i;
`endif

        next_addr_o <= next_addr_comb;
        {ack_o, err_o} <= 2'b10;

        state_m <= STATE_EXEC;
    endtask

    //==================================================================================================================
    // Division complete task
    //==================================================================================================================
    task div_complete_task;
        (* parallel_case, full_case *)
        case (instr_op_type_i)
            `INSTR_TYPE_DIV, `INSTR_TYPE_DIVU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? div_result_i : 0;
                $display($time, "           :          %8h -> rdx%0d; PC: [%h]", rd_o, instr_op_rd_i, next_addr_comb);
`else
                if (|instr_op_rd_i) rd_o <= div_result_i;
`endif
            end

            `INSTR_TYPE_REM, `INSTR_TYPE_REMU: begin
`ifdef D_EXEC
                rd_o = |instr_op_rd_i ? rem_result_i : 0;
                $display($time, "           :          %8h -> rdx%0d; PC: [%h]", rd_o, instr_op_rd_i, next_addr_comb);
`else
                if (|instr_op_rd_i) rd_o <= rem_result_i;
`endif
            end
        endcase

        next_addr_o <= next_addr_comb;
        {ack_o, err_o} <= 2'b10;

        state_m <= STATE_EXEC;
    endtask

    //==================================================================================================================
    // Mul/div modules
    //==================================================================================================================
    multiplier mul_m(
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .stb_i              (mul_stb_o),
        .cyc_i              (mul_cyc_o),
        .op_1_i             (mul_op_1_o),
        .op_1_is_signed_i   (mul_op_1_is_signed_o),
        .op_2_i             (mul_op_2_o),
        .op_2_is_signed_i   (mul_op_2_is_signed_o),
        .result_upper_i     (mul_result_upper_o),
        .result_o           (mul_result_i),
        .ack_o              (mul_ack_i));

    divider div_m(
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .stb_i              (div_stb_o),
        .cyc_i              (div_cyc_o),
        .divident_i         (divident_o),
        .divisor_i          (divisor_o),
        .is_signed_i        (div_is_signed_o),
        .div_result_o       (div_result_i),
        .rem_result_o       (rem_result_i),
        .ack_o              (div_ack_i));
`endif // ENABLE_RV32M_EXT
endmodule
