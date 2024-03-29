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
 * The IO modules handles read/write into the IO space. It forwards time related read/writes to the time module.
 * Additional registers can be defined for UART, I2C, SPI interfaces.
 *
 * clk_i            -- The clock signal.
 * rst_i            -- Reset active high.
 * stb_i            -- The transaction starts on the posedge of this signal.
 * cyc_i            -- This signal is asserted for the duration of a cycle (same as stb_i).
 * addr_i           -- The address from where data is read/written.
 * data_i           -- The input data to write.
 * sel_i            -- The number of bytes to read (1 -> 4'b0001, 2 -> 4'b0011, 3 -> 4'b0111 or 4 bytes -> 4'b1111).
 * we_i             -- 1'b1 to write data, 0 to read.
 * ack_o            -- The transaction completes successfully on the posedge of this signal.
 * err_o            -- The transaction completes with an error on the posedge of this signal.
 * data_o           -- The data that was read (aligned to the least significant byte).
 * timer_clk_i      -- The timer clock generated by the PLL.
 * io_interrupts_o  -- Bits that indicate which interrupt occurred.
 * external_irq_i   -- External interrupts input
***********************************************************************************************************************/
`timescale 1ns / 1ns
`default_nettype none

`include "io.svh"
`include "traps.svh"

module io #(parameter [31:0] CLK_PERIOD_NS = 20,
            parameter [31:0] TIMER_PERIOD_NS = 100) (
    // Wishbone interface
    input logic clk_i,
    input logic rst_i,
    input logic stb_i,
    input logic cyc_i,
    input logic [23:0] addr_i,
    input logic [31:0] data_i,
    input logic [3:0] sel_i,
    input logic we_i,
    output logic ack_o,
    output logic err_o,
    output logic [31:0] data_o,
    // IO clock
    input logic timer_clk_i,
    // Interrupts
    output logic [31:0] io_interrupts_o,
    // UART lines
    output logic uart_txd_o,    // FPGA output: TXD
    input logic uart_rxd_i,     // FPGA input: RXD
    // External interrupts
    input logic external_irq_i);

    // Negate the ack_o as soon as the stb_i is deactivated.
    logic sync_ack_o = 1'b0;
    assign ack_o = sync_ack_o & stb_i;
    // Negate the err_o as soon as the stb_i is deactivated.
    logic sync_err_o = 1'b0;
    assign err_o = sync_err_o & stb_i;

    // The timer module uses the timer clock (timer_clk_i) and it is asynchronous to the main clock.
    logic sync_timer_ack_i, sync_timer_ack_i_pulse;
    DFF_META dff_ack_meta (.reset(rst_i), .D(timer_ack_i), .clk(clk_i), .Q(sync_timer_ack_i),
                                    .Q_pulse(sync_timer_ack_i_pulse));

    logic sync_timer_irq, sync_timer_irq_pulse;
    DFF_META dff_timer_irq_meta (.reset(rst_i), .D(timer_irq_i), .clk(clk_i), .Q(sync_timer_irq),
                                    .Q_pulse(sync_timer_irq_pulse));

    logic sync_external_irq_pulse;
    DFF_META dff_ext_irq_meta (.reset(rst_i), .D(external_irq_i), .clk(clk_i), .Q_pulse(sync_external_irq_pulse));

    logic new_transaction;
    assign new_transaction = stb_i & cyc_i & ~sync_ack_o & ~sync_err_o;

    logic [31:0] io_scratch;
    //==================================================================================================================
    // Module definitions
    //==================================================================================================================
    logic [23:0] timer_addr_o;
    logic [31:0] timer_data_i, timer_data_o;
    logic timer_stb_o, timer_cyc_o, timer_we_o, timer_ack_i, timer_clr_irq_i, timer_irq_i;

    timer #(.TIMER_PERIOD_NS(TIMER_PERIOD_NS)) timer_m (
        // Wishbone interface
        .clk_i      (timer_clk_i),
        .rst_i      (rst_i),
        .addr_i     (timer_addr_o),
        .data_i     (timer_data_o),
        .stb_i      (timer_stb_o),
        .cyc_i      (timer_cyc_o),
        .we_i       (timer_we_o),
        .ack_o      (timer_ack_i),
        .data_o     (timer_data_i),
        // Interrupt
        .clr_irq_i  (timer_clr_irq_i),
        .interrupt_o(timer_irq_i));

    //==================================================================================================================
    // Instantiate the UART TX
    //==================================================================================================================
    localparam BAUD_RATE = 3000000;
    // The UART clock period
    localparam BIT_PERIOD_NS = 1000000000/BAUD_RATE;
    localparam CLKS_PER_BIT = BIT_PERIOD_NS/CLK_PERIOD_NS;

    logic tx_stb_o, tx_cyc_o, tx_ack_i;
    logic [7:0] tx_data_o;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart_tx_m (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .stb_i          (tx_stb_o),
        .cyc_i          (tx_cyc_o),
        .data_i         (tx_data_o),
        .ack_o          (tx_ack_i),
        .uart_txd_o     (uart_txd_o));

    //==================================================================================================================
    // Instantiate the UART RX
    //==================================================================================================================
    logic rx_stb_o, rx_cyc_o, rx_ack_i;
    logic [7:0] rx_data_i;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart_rx_m (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .stb_i          (rx_stb_o),
        .cyc_i          (rx_cyc_o),
        .data_o         (rx_data_i),
        .ack_o          (rx_ack_i),
        .uart_rxd_i     (uart_rxd_i));

    //==================================================================================================================
    // IO
    //==================================================================================================================
    always @(posedge clk_i) begin
        if (rst_i) begin
            {sync_ack_o, sync_err_o} <= 2'b00;
            {timer_stb_o, timer_cyc_o} <= 2'b00;
            {tx_stb_o, tx_cyc_o} <= 2'b00;
            {rx_stb_o, rx_cyc_o} <= 2'b00;

            // Clear interrupts
            io_interrupts_o <= 0;
            io_scratch <= 0;
        end else begin
            io_interrupts_o[`IRQ_TIMER] <= sync_timer_irq_pulse;
            timer_clr_irq_i <= sync_timer_irq;

            io_interrupts_o[`IRQ_EXTERNAL] <= sync_external_irq_pulse;

            if (sync_ack_o) sync_ack_o <= stb_i;
            if (sync_err_o) sync_err_o <= stb_i;

            if (new_transaction) begin
                (* parallel_case, full_case *)
                case (addr_i[23:0])
                    `IO_STD_OUTPUT: begin
                        if (we_i) begin
                            if (~tx_stb_o & ~tx_cyc_o & ~tx_ack_i) begin
`ifdef D_IO
                                $write("%c", data_i[7:0]);
`endif
`ifdef D_IO_FINE
                                $display($time, " IO: TX byte: %h", data_i[7:0]);
`endif
                                {tx_stb_o, tx_cyc_o} <= 2'b11;
                                tx_data_o <= data_i[7:0];
                            end
                        end else begin
                            {sync_ack_o, sync_err_o} <= 2'b10;
                        end
                    end

                    `IO_STD_INPUT: begin
                        if (~we_i) begin
                            if (~rx_stb_o & ~rx_cyc_o & ~rx_ack_i) begin
`ifdef D_IO_FINE
                                $display($time, " IO: RX byte...");
`endif
                                {rx_stb_o, rx_cyc_o} <= 2'b11;
                            end
                        end else begin
                            {sync_ack_o, sync_err_o} <= 2'b10;
                        end
                    end

                    `IO_MTIME, `IO_MTIMEH, `IO_MTIMECMP, `IO_MTIMECMPH: begin
                        if (~timer_stb_o & ~timer_cyc_o & ~sync_timer_ack_i) begin
                            timer_addr_o <= addr_i;
                            timer_data_o <= data_i;
                            timer_we_o <= we_i;

                            {timer_stb_o, timer_cyc_o} <= 2'b11;
                        end
                    end

                    `IO_SCRATCH: begin
                        if (we_i) begin
                            io_scratch <= data_i;
                        end else begin
                            data_o <= io_scratch;
                        end

                        {sync_ack_o, sync_err_o} <= 2'b10;
                    end

                    default: begin
`ifdef D_IO
                        if (we_i) begin
                            $display($time, " IO: Write to unknown address @[%h] -> %h", addr_i, data_i);
                        end else begin
                            $display($time, " IO: Read from unknown address @[%h]", addr_i);
                        end
`endif
                        // An error is not raised if the port does not exist.
                        {sync_ack_o, sync_err_o} <= 2'b10;
                    end
                endcase
            end

            if (timer_stb_o & timer_cyc_o & sync_timer_ack_i_pulse) begin
                {timer_stb_o, timer_cyc_o} <= 2'b00;

                data_o <= timer_data_i;

                {sync_ack_o, sync_err_o} <= 2'b10;
            end

            if (tx_stb_o & tx_cyc_o & tx_ack_i) begin
                {tx_stb_o, tx_cyc_o} <= 2'b00;

                {sync_ack_o, sync_err_o} <= 2'b10;
            end

            if (rx_stb_o & rx_cyc_o & rx_ack_i) begin
                {rx_stb_o, rx_cyc_o} <= 2'b00;

                data_o <= {24'h0, rx_data_i};

                {sync_ack_o, sync_err_o} <= 2'b10;
            end
        end
    end
endmodule
