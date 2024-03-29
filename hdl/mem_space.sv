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
 * This module implements the memory space controller of the processor.
 * For the core it enables:
 * 1. Reading instructions from flash or RAM.
 * 2. Read/write to Machine Registers (CSR) for trap handling.
 * 3. Forwards pending interrupts to the upstream module.
 * 4. Event counting.
 *
 * For the exec module it enables:
 * 1. Reading data from flash.
 * 2. Reading and writing data to RAM.
 * 3. Reading and writing data to IO.
 * 4. Reading and writing data to Machine Registers (CSR).
 *
 * Data and core interfaces are wishbone interfaces. Data has priority over core; the rationale is that we want
 * to complete the currently executing instruction earlier rather than starting work on a new one.
 *
 * clk_i                -- The clock signal.
 * rst_i                -- Reset active high.
 * core_stb_i           -- The transaction starts on the posedge of this signal.
 * core_cyc_i           -- This signal is asserted for the duration of a cycle.
 * core_sel_i           -- The number of bytes to r/w (1 -> 4'b0001, 2 -> 4'b0011, 3 -> 4'b0111 or 4 bytes -> 4'b1111).
 * core_we_i            -- 1 to write data, 0 to read.
 * core_addr_i          -- The address from where data is read/written.
 * core_data_i          -- The input data to write.
 * core_data_tag_o      -- The core data output tag.
 * core_ack_o           -- The core transaction completes successfully on the posedge of this signal.
 * core_err_o           -- The core transaction completes with an error on the posedge of this signal.
 * core_data_o          -- The data that was read.
 * data_stb_i           -- The transaction starts on the posedge of this signal.
 * data_cyc_i           -- This signal is asserted for the duration of a cycle.
 * data_sel_i           -- The number of bytes to r/w (1 -> 4'b0001, 2 -> 4'b0011, 3 -> 4'b0111 or 4 bytes -> 4'b1111).
 * data_we_i            -- 1'b1 to write data, 0 to read.
 * data_addr_i          -- The address from where data is read/written.
 * data_addr_tag_i      -- The address tag.
 * data_data_i          -- The input data to write.
 * data_ack_o           -- The data transaction completes successfully on the posedge of this signal.
 * data_err_o           -- The data transaction completes with an error on the posedge of this signal.
 * data_data_o          -- The data that was read.
 * data_data_tag_o      -- The data output tag
 * RAM wires            -- RAM wires.
 * flash_master_clk_i   -- The flash master clock.
 * flash_device_clk_i   -- Flash clock from the PLL.
 * timer_clk_i          -- IO clock from the PLL.
 * incr_event_counters_i-- Increment counters.
 * interrupts_pending_o -- Pending interrupts from the IO space are waiting to be serviced.
 * Flash wires          -- Flash signals.
 * UART wires           -- UART signals.
***********************************************************************************************************************/
`timescale 1ns / 1ns
`default_nettype none

`include "events.svh"
`include "tags.svh"

module mem_space #(
    parameter [31:0] CLK_PERIOD_NS = 20,
    parameter [31:0] FLASH_CLK_PERIOD_NS = 20,
    parameter [31:0] TIMER_PERIOD_NS = 100) (
    input logic clk_i,
    input logic rst_i,
    // Wishbone interface for reading instructions and read/write CSR
    input logic core_stb_i,
    input logic core_cyc_i,
    input logic [3:0] core_sel_i,
    input logic core_we_i,
    input logic [31:0] core_addr_i,
    input logic [31:0] core_data_i,
    output logic core_ack_o,
    output logic core_err_o,
    output logic [31:0] core_data_o,
    output logic core_data_tag_o,
    // Wishbone interface for reading and writing data from the execution module
    input logic data_stb_i,
    input logic data_cyc_i,
    input logic [3:0] data_sel_i,
    input logic data_we_i,
    input logic [31:0] data_addr_i,
    input logic [`ADDR_TAG_BITS-1:0] data_addr_tag_i,
    input logic [31:0] data_data_i,
    output logic data_ack_o,
    output logic data_err_o,
    output logic [31:0] data_data_o,
    output logic data_data_tag_o,
`ifdef BOARD_ULX3S
    input logic sdram_device_clk_i,
    // SDRAM wires
    output logic sdram_clk,
    output logic sdram_cke,
    output logic sdram_csn,
    output logic sdram_wen,
    output logic sdram_rasn,
    output logic sdram_casn,
    output logic [12:0] sdram_a,
    output logic [1:0] sdram_ba,
    output logic [1:0] sdram_dqm,
    inout logic [15:0] sdram_d,
`else //BOARD_ULX3S
    // LEDs
    output logic [15:0] led,
    // RAM wires
    output logic psram_cen,
    output logic psram_wen,
    output logic psram_oen,
    output logic psram_lbn,
    output logic psram_ubn,
    output logic [21:0] psram_a,
    inout logic [15:0] psram_d,
`endif // BOARD_ULX3S
    // Device clocks
    input logic flash_master_clk_i,
    input logic flash_device_clk_i,
    input logic timer_clk_i,
    // Event counters to increment
    input logic [31:0] incr_event_counters_i,
    // IO interrupts need servicing
    output logic [31:0] io_interrupts_o,
    // Flash wires
    output logic flash_csn,
    output logic flash_clk,
    inout logic flash_mosi,
    inout logic flash_miso,
    inout logic flash_wpn,
    inout logic flash_holdn,
    // UART wires
    output logic uart_txd_o,    // FPGA output: TXD
    input logic uart_rxd_i,     // FPGA input: RXD
    input logic external_irq_i);

    // Negate the ack_o as soon as the stb_i is deactivated.
    logic core_sync_ack_o = 1'b0;
    assign core_ack_o = core_sync_ack_o & core_stb_i;

    logic core_sync_err_o = 1'b0;
    assign core_err_o = core_sync_err_o & core_stb_i;

    logic data_sync_ack_o = 1'b0;
    assign data_ack_o = data_sync_ack_o & data_stb_i;

    logic data_sync_err_o = 1'b0;
    assign data_err_o = data_sync_err_o & data_stb_i;

    logic core_prev_new_transaction, data_prev_new_transaction;
    logic core_pend_transaction_q, data_pend_transaction_q, core_new_transaction, data_new_transaction;
    assign core_new_transaction = core_stb_i & core_cyc_i & ~core_sync_ack_o & ~core_sync_err_o;
    assign data_new_transaction = data_stb_i & data_cyc_i & ~data_sync_ack_o & ~data_sync_err_o;

    // The index of the bit indicating which resource is being access by the core or by the data path.
    localparam ACCESS_FLASH = 2'b00;
    localparam ACCESS_RAM   = 2'b01;
    localparam ACCESS_IO    = 2'b10;
    localparam ACCESS_CSR   = 2'b11;
    logic [3:0] core_access, data_access;

`ifdef ENABLE_MHPM
    logic [31:0] incr_internal_event_counters;
`endif
    // Wishbone flip flop for handling cross domain flash ack
    logic sync_flash_ack_i, sync_flash_ack_i_pulse;
    DFF_META dff_meta_flash_ack (.reset(rst_i), .D(flash_ack_i), .clk(clk_i), .Q(sync_flash_ack_i),
                            .Q_pulse(sync_flash_ack_i_pulse));

    //==================================================================================================================
    // Instantiate the modules
    //==================================================================================================================
    // RAM ports
    logic [31:0] ram_addr_o;
    logic [`ADDR_TAG_BITS-1:0] ram_addr_tag_o;
    logic [31:0] ram_data_o, ram_data_i;
    logic ram_stb_o, ram_cyc_o, ram_we_o, ram_ack_i, ram_data_tag_i;
    logic [3:0] ram_sel_o;
    // Flash ports
    logic flash_stb_o, flash_cyc_o, flash_ack_i;
    logic [23:0] flash_addr_o;
    logic [ 3:0] flash_sel_o;
    logic [31:0] flash_data_i;

    // IO ports
    logic [31:0] io_addr_o;
    logic [`ADDR_TAG_BITS-1:0] io_addr_tag_o;
    logic [31:0] io_data_o, io_data_i;
    logic io_stb_o, io_cyc_o, io_we_o, io_ack_i, io_err_i, io_data_tag_i;
    logic [3:0] io_sel_o;
    logic [31:0] io_interrupts_i;

    // CSR ports
    logic [11:0] csr_addr_o;
    logic [31:0] csr_data_o, csr_data_i;
    logic csr_stb_o, csr_cyc_o, csr_we_o, csr_ack_i, csr_err_i;

    ram_bus #(.CLK_PERIOD_NS(CLK_PERIOD_NS)) ram_bus_m (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .stb_i      (ram_stb_o),
        .cyc_i      (ram_cyc_o),
        .sel_i      (ram_sel_o),
        .we_i       (ram_we_o),
        .addr_i     (ram_addr_o),
        .addr_tag_i (ram_addr_tag_o),
        .data_i     (ram_data_o),
        .ack_o      (ram_ack_i),
        .data_o     (ram_data_i),
        .data_tag_o (ram_data_tag_i),
`ifdef BOARD_ULX3S
        .sdram_device_clk_i (sdram_device_clk_i),
        // SDRAM wires
        .sdram_clk  (sdram_clk),
        .sdram_cke  (sdram_cke),
        .sdram_csn  (sdram_csn),
        .sdram_wen  (sdram_wen),
        .sdram_rasn (sdram_rasn),
        .sdram_casn (sdram_casn),
        .sdram_a    (sdram_a),
        .sdram_ba   (sdram_ba),
        .sdram_dqm  (sdram_dqm),
        .sdram_d    (sdram_d)
`else //BOARD_ULX3S
        // PSRAM signals
        .psram_cen  (psram_cen),
        .psram_wen  (psram_wen),
        .psram_oen  (psram_oen),
        .psram_lbn  (psram_lbn),
        .psram_ubn  (psram_ubn),
        .psram_a    (psram_a),
        .psram_d    (psram_d)
`endif // BOARD_ULX3S
        );

    flash_master #(.FLASH_CLK_PERIOD_NS(FLASH_CLK_PERIOD_NS)) flash_master_m (
        // Wishbone interface
        .clk_i      (flash_master_clk_i),
        .rst_i      (rst_i),
        .addr_i     (flash_addr_o),
        .stb_i      (flash_stb_o),
        .cyc_i      (flash_cyc_o),
        .sel_i      (flash_sel_o),
        .ack_o      (flash_ack_i),
        .data_o     (flash_data_i),
        // Flash clock
        .device_clk_i(flash_device_clk_i),
        // Flash wires
        .flash_csn  (flash_csn),
        .flash_clk  (flash_clk),
        .flash_mosi (flash_mosi),
        .flash_miso (flash_miso),
        .flash_wpn  (flash_wpn),
        .flash_holdn(flash_holdn));

    io_bus #(.CLK_PERIOD_NS(CLK_PERIOD_NS), .TIMER_PERIOD_NS(TIMER_PERIOD_NS)) io_bus_m (
        // Wishbone interface
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .addr_i     (io_addr_o),
        .addr_tag_i (io_addr_tag_o),
        .data_i     (io_data_o),
        .stb_i      (io_stb_o),
        .cyc_i      (io_cyc_o),
        .sel_i      (io_sel_o),
        .we_i       (io_we_o),
        .ack_o      (io_ack_i),
        .err_o      (io_err_i),
        .data_o     (io_data_i),
        .data_tag_o (io_data_tag_i),
        // IO clock
        .timer_clk_i    (timer_clk_i),
        // IO interrupts
        .io_interrupts_o(io_interrupts_i),
        // UART wires
        .uart_txd_o     (uart_txd_o),   // FPGA output: TXD
        .uart_rxd_i     (uart_rxd_i),   // FPGA input: RXD
        .external_irq_i (external_irq_i));

    csr csr_m (
        // Wishbone interface
        .clk_i                  (clk_i),
        .rst_i                  (rst_i),
        .addr_i                 (csr_addr_o),
        .data_i                 (csr_data_o),
        .stb_i                  (csr_stb_o),
        .cyc_i                  (csr_cyc_o),
        .we_i                   (csr_we_o),
        .ack_o                  (csr_ack_i),
        .err_o                  (csr_err_i),
        .data_o                 (csr_data_i),
`ifdef ENABLE_MHPM
        .incr_event_counters_i  (incr_event_counters_i | incr_internal_event_counters),
`else
        .incr_event_counters_i  (incr_event_counters_i),
`endif
        // Interrupt that occured(from IO)
        .io_interrupts_i        (io_interrupts_i),
        // Interrupts pending (to the core)
        .io_interrupts_o        (io_interrupts_o));

    //==================================================================================================================
    // The memory space processor.
    //==================================================================================================================
    task mem_space_task;
`ifdef ENABLE_MHPM
        incr_internal_event_counters <= 0;
`endif
        // Reflect the status of IRQs
        `ifdef ENABLE_LED_EXT led[8] <= |io_interrupts_o;`endif

        if (data_sync_ack_o) data_sync_ack_o <= data_stb_i;
        if (data_sync_err_o) data_sync_err_o <= data_stb_i;
        data_prev_new_transaction <= data_new_transaction;

        if (core_sync_ack_o) core_sync_ack_o <= core_stb_i;
        if (core_sync_err_o) core_sync_err_o <= core_stb_i;
        core_prev_new_transaction <= core_new_transaction;

        // ----------------------------------------- Handle data transactions ------------------------------------------
        if ((data_new_transaction & ~data_prev_new_transaction) | data_pend_transaction_q) begin
            // Latch the core transaction if one was started at the same time with the data transaction.
            // It will be processed in the next clock cycle.
            if (core_new_transaction & ~core_prev_new_transaction) core_pend_transaction_q <= 1'b1;

            (* parallel_case, full_case *)
            casex (data_addr_i[31:20])
                // Flash (32'h0060_0000 to 32'h0100_0000)
                12'h006, 12'h007, 12'h008, 12'h009, 12'h00a, 12'h00b, 12'h00c, 12'h00d, 12'h00e, 12'h00f: begin
                    if (~data_we_i) begin
                        if (~flash_stb_o & ~flash_cyc_o & ~sync_flash_ack_i) begin
`ifdef D_MEM_SPACE
                            $display($time, " MEM_SPACE: Reading flash data @[%h]", data_addr_i);
`endif
                            flash_addr_o <= data_addr_i[23:0];
                            flash_sel_o <= data_sel_i;
                            {flash_stb_o, flash_cyc_o} <= 2'b11;

                            data_pend_transaction_q <= 1'b0;
                            data_access[ACCESS_FLASH] <= 1'b1;

                            `ifdef ENABLE_LED_EXT led[9] <= 1'b1;`endif
                        end else begin
                            data_pend_transaction_q <= 1'b1;
                        end
                    end else begin
`ifdef D_MEM_SPACE
                        $display($time, " MEM_SPACE:   --- Invalid data address. Flash is read only [%h]. ---",
                                    data_addr_i);
`endif
                        data_pend_transaction_q <= 1'b0;
                        // The upstream module will infer an EX_LOAD_ACCESS_FAULT for reads and
                        // EX_STORE_ACCESS_FAULT for writes.
                        {data_sync_ack_o, data_sync_err_o} <= 2'b01;
                    end
                end

`ifdef BOARD_ULX3S
                // RAM (32'h8000_0000 to 32'h8100_0000) // 32MB
                12'h80x, 12'h81x: begin
`else
                // RAM (32'h8000_0000 to 32'h8080_0000) // 8MB
                12'h800, 12'h801, 12'h802, 12'h803, 12'h804, 12'h805, 12'h806, 12'h807: begin
`endif
                    if (~ram_stb_o & ~ram_cyc_o & ~ram_ack_i) begin
`ifdef D_MEM_SPACE
                        if (~data_we_i) begin
                            $display($time, " MEM_SPACE: Reading RAM @[%h]; tag: %h", data_addr_i, data_addr_tag_i);
                        end else begin
                            $display($time, " MEM_SPACE: Writing %h to RAM @[%h]; tag: %h", data_data_i, data_addr_i,
                                        data_addr_tag_i);
                        end
`endif
                        /*
                         * Start the RAM transaction.
                         */
                        ram_addr_o <= data_addr_i;
                        ram_addr_tag_o <= data_addr_tag_i;
                        ram_we_o <= data_we_i;
                        ram_sel_o <= data_sel_i;
                        ram_data_o <= data_data_i;
                        {ram_stb_o, ram_cyc_o} <= 2'b11;

                        data_pend_transaction_q <= 1'b0;
                        data_access[ACCESS_RAM] <= 1'b1;

                        `ifdef ENABLE_LED_EXT led[10] <= ~data_we_i;`endif
                        `ifdef ENABLE_LED_EXT led[11] <= data_we_i;`endif
                    end else begin
                        data_pend_transaction_q <= 1'b1;
                    end
                end

                // IO (32'hc000_0000 to 32'hc0ff_ffff)
                12'hc0x: begin
                    if (~io_stb_o & ~io_cyc_o & ~io_ack_i & ~io_err_i) begin
                        io_addr_o <= data_addr_i;
                        io_addr_tag_o <= data_addr_tag_i;
                        io_we_o <= data_we_i;
                        io_data_o <= data_data_i;
                        io_sel_o <= data_sel_i;
                        {io_stb_o, io_cyc_o} <= 2'b11;

                        data_pend_transaction_q <= 1'b0;
                        data_access[ACCESS_IO] <= 1'b1;

                        `ifdef ENABLE_LED_EXT led[12] <= ~data_we_i;`endif
                        `ifdef ENABLE_LED_EXT led[13] <= data_we_i;`endif
                    end else begin
                        data_pend_transaction_q <= 1'b1;
                    end
                end

                // CSR (32'h400x_x000 to 32'h400x_xfff)
                12'h400: begin
                    if (|(data_addr_tag_i & `ADDR_TAG_CSR_INSTR)) begin
                        if (~csr_stb_o & ~csr_cyc_o & ~csr_ack_i & ~csr_err_i) begin
`ifdef D_MEM_SPACE
                            if (data_we_i) begin
                                $display($time, " MEM_SPACE: Data CSR write @[%h]: %h", data_addr_i[11:0], data_data_i);
                            end
`endif
                            csr_addr_o <= data_addr_i[11:0];
                            csr_we_o <= data_we_i;
                            // data_sel_i is ignored. We assume that 4 bytes are being r/w.
                            csr_data_o <= data_data_i;
                            {csr_stb_o, csr_cyc_o} <= 2'b11;

                            data_pend_transaction_q <= 1'b0;
                            data_access[ACCESS_CSR] <= 1'b1;

                            `ifdef ENABLE_LED_EXT led[14] <= ~data_we_i;`endif
                            `ifdef ENABLE_LED_EXT led[15] <= data_we_i;`endif
                        end else begin
                            data_pend_transaction_q <= 1'b1;
                        end
                    end else begin
`ifdef D_MEM_SPACE
                        $display($time, " MEM_SPACE:   --- Invalid data address. CSR access restricted [%h]. ---",
                                    data_addr_i);
`endif
                        data_pend_transaction_q <= 1'b0;
                        // The upstream module will infer an EX_LOAD_ACCESS_FAULT for reads and
                        // EX_STORE_ACCESS_FAULT for writes.
                        {data_sync_ack_o, data_sync_err_o} <= 2'b01;
                    end
                end

                default: begin
`ifdef D_MEM_SPACE
                    $display($time, " MEM_SPACE:   --- Invalid data address [%h]. ---", data_addr_i);
`endif
                    data_pend_transaction_q <= 1'b0;
                    // The upstream module will infer an EX_LOAD_ACCESS_FAULT for reads and EX_STORE_ACCESS_FAULT for
                    // writes.
                    {data_sync_ack_o, data_sync_err_o} <= 2'b01;
                end
            endcase
        end else if ((core_new_transaction & ~core_prev_new_transaction) | core_pend_transaction_q) begin
            // ----------------------------------------- Handle core transactions --------------------------------------
            (* parallel_case, full_case *)
            casex (core_addr_i[31:20])
                // Flash (32'h0060_0000 to 32'h0100_0000)
                12'h006, 12'h007, 12'h008, 12'h009, 12'h00a, 12'h00b, 12'h00c, 12'h00d, 12'h00e, 12'h00f: begin
                    if (~flash_stb_o & ~flash_cyc_o & ~sync_flash_ack_i) begin
`ifdef D_MEM_SPACE
                        $display($time, " MEM_SPACE: Reading flash instruction @[%h]", core_addr_i);
`endif
                        // Read an instruction from flash
                        flash_addr_o <= core_addr_i[23:0];
                        flash_sel_o <= core_sel_i;
                        {flash_stb_o, flash_cyc_o} <= 2'b11;

                        core_pend_transaction_q <= 1'b0;
                        core_access[ACCESS_FLASH] <= 1'b1;

                        `ifdef ENABLE_LED_EXT led[1] <= 1'b1;`endif
                    end else begin
                        core_pend_transaction_q <= 1'b1;
                    end
                end

`ifdef BOARD_ULX3S
                // RAM (32'h8000_0000 to 32'h8100_0000) // 32MB
                12'h80x, 12'h81x: begin
`else
                // RAM (32'h8000_0000 to 32'h8080_0000) // 8MB
                12'h800, 12'h801, 12'h802, 12'h803, 12'h804, 12'h805, 12'h806, 12'h807: begin
`endif
                    if (~ram_stb_o & ~ram_cyc_o & ~ram_ack_i) begin
`ifdef D_MEM_SPACE
                        $display($time, " MEM_SPACE: Reading RAM instruction @[%h]", core_addr_i);
`endif
                        /*
                         * Start the RAM transaction to read an instruction.
                         */
                        ram_addr_o <= core_addr_i;
                        ram_addr_tag_o <= `ADDR_TAG_NONE;
                        ram_we_o <= 1'b0;
                        ram_sel_o <= 4'b1111;
                        {ram_stb_o, ram_cyc_o} <= 2'b11;

                        core_pend_transaction_q <= 1'b0;
                        core_access[ACCESS_RAM] <= 1'b1;

                        `ifdef ENABLE_LED_EXT led[2] <= ~core_we_i;`endif
                        `ifdef ENABLE_LED_EXT led[3] <= core_we_i;`endif
                    end else begin
                        core_pend_transaction_q <= 1'b1;
                    end
                end

                // IO (32'hc000_0000 to 32'hc0ff_ffff)
                12'hc0x: begin
                    if (~io_stb_o & ~io_cyc_o & ~io_ack_i & ~io_err_i) begin
                        io_addr_o <= core_addr_i;
                        io_addr_tag_o <= `ADDR_TAG_NONE;
                        io_we_o <= core_we_i;
                        io_data_o <= core_data_i;
                        io_sel_o <= core_sel_i;
                        {io_stb_o, io_cyc_o} <= 2'b11;
`ifdef D_MEM_SPACE
                        if (core_we_i) begin
                            $display($time, " MEM_SPACE: Core IO write %0d @[%h]", core_data_i, core_addr_i[23:0]);
                        end
`endif
                        core_pend_transaction_q <= 1'b0;
                        core_access[ACCESS_IO] <= 1'b1;

                        `ifdef ENABLE_LED_EXT led[6] <= ~core_we_i;`endif
                        `ifdef ENABLE_LED_EXT led[7] <= core_we_i;`endif
                    end else begin
                        core_pend_transaction_q <= 1'b1;
                    end
                end

                // CSR (32'h400x_x000 to 32'h400x_xfff)
                12'h400: begin
                    if (~csr_stb_o & ~csr_cyc_o & ~csr_ack_i & ~csr_err_i) begin
`ifdef D_MEM_SPACE
                        if (core_we_i) begin
                            $display($time, " MEM_SPACE: Core CSR write @[%h]: %h", core_addr_i[11:0], core_data_i);
                        end
`endif
                        csr_addr_o <= core_addr_i[11:0];
                        csr_we_o <= core_we_i;
                        // core_sel_i is ignored. We assume that 4 bytes are being r/w.
                        csr_data_o <= core_data_i;
                        {csr_stb_o, csr_cyc_o} <= 2'b11;

                        core_pend_transaction_q <= 1'b0;
                        core_access[ACCESS_CSR] <= 1'b1;

                        `ifdef ENABLE_LED_EXT led[4] <= ~core_we_i;`endif
                        `ifdef ENABLE_LED_EXT led[5] <= core_we_i;`endif
                    end else begin
                        core_pend_transaction_q <= 1'b1;
                    end
                end

                default: begin
`ifdef D_MEM_SPACE
                    $display($time, " MEM_SPACE:    --- Invalid instruction address [%h]. ---", core_addr_i);
`endif
                    core_pend_transaction_q <= 1'b0;
                    // The upstream module will infer an EX_INSTRUCTION_ACCESS_FAULT
                    {core_sync_ack_o, core_sync_err_o} <= 2'b01;
                end
            endcase
        end

        // --------------------------------- Handle flash transaction complete -----------------------------------------
        if (flash_cyc_o & flash_stb_o & sync_flash_ack_i_pulse) begin
            {flash_stb_o, flash_cyc_o} <= 2'b00;

`ifdef D_MEM_SPACE
            $display($time, " MEM_SPACE: Flash data @[%h]: %h", flash_addr_o, flash_data_i);
`endif
            if (core_access[ACCESS_FLASH]) begin
                core_data_o <= flash_data_i;
                core_data_tag_o <= flash_data_i[1:0] != 2'b11;
                {core_sync_ack_o, core_sync_err_o} <= 2'b10;

                core_access[ACCESS_FLASH] <= 1'b0;

                `ifdef ENABLE_LED_EXT led[1] <= 1'b0;`endif
            end else begin
                data_data_o <= flash_data_i;
                {data_sync_ack_o, data_sync_err_o} <= 2'b10;

                data_access[ACCESS_FLASH] <= 1'b0;

                `ifdef ENABLE_LED_EXT led[9] <= 1'b0;`endif
            end

`ifdef ENABLE_MHPM
            if (core_access[ACCESS_FLASH]) begin
                incr_internal_event_counters[`EVENT_INSTR_FROM_ROM] <= 1'b1;
            end else begin
                incr_internal_event_counters[`EVENT_LOAD_FROM_ROM] <= 1'b1;
            end
`endif
        end

        // --------------------------------- Handle RAM transaction complete -----------------------------------------
        if (ram_cyc_o & ram_stb_o & ram_ack_i) begin
            // The transaction is complete
            {ram_stb_o, ram_cyc_o} <= 2'b00;

            if (core_access[ACCESS_RAM]) begin
                core_data_o <= ram_data_i;
                core_data_tag_o <= ram_data_i[1:0] != 2'b11;
                {core_sync_ack_o, core_sync_err_o} <= 2'b10;

                core_access[ACCESS_RAM] <= 1'b0;

`ifdef ENABLE_MHPM
                incr_internal_event_counters[`EVENT_INSTR_FROM_RAM] <= 1'b1;
`endif
                `ifdef ENABLE_LED_EXT led[2] <= 1'b0;`endif
                `ifdef ENABLE_LED_EXT led[3] <= 1'b0;`endif
            end else begin
                data_data_o <= ram_data_i;
                data_data_tag_o <= ram_data_tag_i;
                {data_sync_ack_o, data_sync_err_o} <= 2'b10;

                data_access[ACCESS_RAM] <= 1'b0;

`ifdef ENABLE_MHPM
                if (~ram_we_o) begin
                    incr_internal_event_counters[`EVENT_LOAD_FROM_RAM] <= 1'b1;
                end else begin
                    incr_internal_event_counters[`EVENT_STORE_TO_RAM] <= 1'b1;
                end
`endif
                `ifdef ENABLE_LED_EXT led[10] <= 1'b0;`endif
                `ifdef ENABLE_LED_EXT led[11] <= 1'b0;`endif
            end

`ifdef D_MEM_SPACE
            $display($time, " MEM_SPACE: RAM read @[%h]: %h", ram_addr_o, ram_data_i);
`endif
        end

        // ----------------------------------- Handle IO transaction complete ------------------------------------------
        if (io_cyc_o & io_stb_o & (io_ack_i | io_err_i)) begin
            {io_stb_o, io_cyc_o} <= 2'b00;

`ifdef D_MEM_SPACE
            if (~io_we_o) begin
                $display($time, " MEM_SPACE: IO read @[%h]: %0d", io_addr_o, io_data_i);
            end
`endif
            if (core_access[ACCESS_IO]) begin
                core_data_o <= io_data_i;
                {core_sync_ack_o, core_sync_err_o} <= {io_ack_i, io_err_i};

                core_access[ACCESS_IO] <= 1'b0;

                `ifdef ENABLE_LED_EXT led[6] <= 1'b0;`endif
                `ifdef ENABLE_LED_EXT led[7] <= 1'b0;`endif
            end else begin
                data_data_o <= io_data_i;
                data_data_tag_o <= io_addr_tag_o;
                {data_sync_ack_o, data_sync_err_o} <= {io_ack_i, io_err_i};

                data_access[ACCESS_IO] <= 1'b0;

                `ifdef ENABLE_LED_EXT led[12] <= 1'b0;`endif
                `ifdef ENABLE_LED_EXT led[13] <= 1'b0;`endif
            end

`ifdef ENABLE_MHPM
            if (~io_we_o) begin
                incr_internal_event_counters[`EVENT_IO_LOAD] <= 1'b1;
            end else begin
                incr_internal_event_counters[`EVENT_IO_STORE] <= 1'b1;
            end
`endif
        end

        // ----------------------------------- Handle CSR transaction complete -----------------------------------------
        if (csr_cyc_o & csr_stb_o & (csr_ack_i | csr_err_i)) begin
            {csr_stb_o, csr_cyc_o} <= 2'b00;

`ifdef D_MEM_SPACE
            if (~csr_we_o) begin
                $display($time, " MEM_SPACE: CSR read @[%h]: %h", csr_addr_o, csr_data_i);
            end
`endif
            if (core_access[ACCESS_CSR]) begin
                core_data_o <= csr_data_i;
                {core_sync_ack_o, core_sync_err_o} <= {csr_ack_i, csr_err_i};

                core_access[ACCESS_CSR] <= 1'b0;

                `ifdef ENABLE_LED_EXT led[4] <= 1'b0;`endif
                `ifdef ENABLE_LED_EXT led[5] <= 1'b0;`endif
            end else begin
                data_data_o <= csr_data_i;
                {data_sync_ack_o, data_sync_err_o} <= {csr_ack_i, csr_err_i};

                data_access[ACCESS_CSR] <= 1'b0;

                `ifdef ENABLE_LED_EXT led[14] <= 1'b0;`endif
                `ifdef ENABLE_LED_EXT led[15] <= 1'b0;`endif
            end

`ifdef ENABLE_MHPM
            if (~csr_we_o) begin
                incr_internal_event_counters[`EVENT_CSR_LOAD] <= 1'b1;
            end else begin
                incr_internal_event_counters[`EVENT_CSR_STORE] <= 1'b1;
            end
`endif
        end
    endtask

    //==================================================================================================================
    // Memory space controller
    //==================================================================================================================
    always @(posedge clk_i) begin
        if (rst_i) begin
            {core_sync_ack_o, core_sync_err_o} <= 2'b00;
            {data_sync_ack_o, data_sync_err_o} <= 2'b00;

            {ram_stb_o, ram_cyc_o} <= 2'b00;
            {flash_stb_o, flash_cyc_o} <= 2'b00;
            {io_stb_o, io_cyc_o} <= 2'b00;
            {csr_stb_o, csr_cyc_o} <= 2'b00;

            {core_access, data_access} <= {4'b0000, 4'b0000};

            core_pend_transaction_q <= 1'b0;
            data_pend_transaction_q <= 1'b0;

            core_prev_new_transaction <= 1'b0;
            data_prev_new_transaction <= 1'b0;

            `ifdef ENABLE_LED_EXT led <= 16'h0; `endif
        end else begin
            mem_space_task;
        end
    end
endmodule
