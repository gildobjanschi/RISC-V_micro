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
 * Send UART data operating in 8N1 mode.
 *
 * clk_i        -- The clock signal.
 * rst_i        -- Reset active high.
 * stb_i        -- The transaction starts on the posedge of this signal.
 * cyc_i        -- The transaction starts on the posedge of this signal (same as stb_i).
 * data_i       -- The input data to write.
 * ack_o        -- The transaction completes successfully on the posedge of this signal.
 * uart_txd_o   -- The UART TX line.
 **********************************************************************************************************************/
`timescale 1ns/1ns
`default_nettype none

module uart_tx #(parameter integer CLKS_PER_BIT = 62) (
    input logic clk_i,
    input logic rst_i,
    input logic stb_i,
    input logic cyc_i,
    input logic [7:0] data_i,
    output logic ack_o,
    // The UART TX line
    output logic uart_txd_o);

    // Negate the ack_o as soon as the stb_i is deactivated.
    logic sync_ack_o = 1'b0;
    assign ack_o = sync_ack_o & stb_i;

    // State machine
    localparam TX_IDLE      = 2'b00;
    localparam TX_START_BIT = 2'b01;
    localparam TX_DATA_BITS = 2'b10;
    localparam TX_STOP_BIT  = 2'b11;
    logic [1:0] state_m;

    logic [15:0] clock_count;
    logic [2:0] bit_index;
    logic [7:0] tx_byte_o;
    logic send_tx_byte;

    // TX FIFO
    localparam FIFO_BITS = 4;
    localparam FIFO_SIZE = 2**FIFO_BITS;
    logic [FIFO_BITS-1:0] tx_fifo_rd_ptr, tx_fifo_wr_ptr, next_tx_fifo_wr_ptr, next_tx_fifo_rd_ptr;
    logic [7:0] tx_fifo[0:FIFO_SIZE-1];

    logic tx_fifo_full;
    assign tx_fifo_full = tx_fifo_rd_ptr == next_tx_fifo_wr_ptr;

    logic tx_fifo_has_bytes;
    assign tx_fifo_has_bytes = (tx_fifo_rd_ptr != tx_fifo_wr_ptr) | tx_fifo_full;

    //==================================================================================================================
    // Combinatorial
    //==================================================================================================================
    always_comb begin
        next_tx_fifo_wr_ptr = tx_fifo_wr_ptr + 1;
        next_tx_fifo_rd_ptr = tx_fifo_rd_ptr + 1;
    end

    //==================================================================================================================
    // Service the TX FIFO
    //==================================================================================================================
    task service_tx_fifo;
        if (~send_tx_byte & (state_m == TX_IDLE) & tx_fifo_has_bytes) begin
            // Transmit the first byte from the FIFO.
            tx_byte_o <= tx_fifo[tx_fifo_rd_ptr];
            send_tx_byte <= 1'b1;

            tx_fifo_rd_ptr <= next_tx_fifo_rd_ptr;
`ifdef D_UART
            $display($time, " UART: Tx %h", tx_fifo[tx_fifo_rd_ptr]);
`endif
        end
    endtask

    //==================================================================================================================
    // UART TX
    //==================================================================================================================
    always @(posedge clk_i) begin
        if (rst_i) begin
            state_m <= TX_IDLE;
            tx_fifo_rd_ptr <= 0;
            tx_fifo_wr_ptr <= 0;

            send_tx_byte <= 1'b0;
            uart_txd_o <= 1'b1;
            sync_ack_o <= 1'b0;
        end else begin
            if (sync_ack_o) sync_ack_o <= stb_i;

            // Handle send requests
            if (stb_i & cyc_i & ~sync_ack_o) begin
                if (~tx_fifo_full) begin
                    // Write to the UART TX FIFO
                    tx_fifo[tx_fifo_wr_ptr] <= data_i;
                    tx_fifo_wr_ptr <= next_tx_fifo_wr_ptr;

                    sync_ack_o <= 1'b1;
`ifdef D_UART
                    $display($time, " UART: Write to Tx FIFO: %h", data_i);
`endif
                end else begin
                    service_tx_fifo;
                end
            end else begin
                service_tx_fifo;
            end

            (* parallel_case, full_case *)
            case (state_m)
                TX_IDLE: begin
                    if (send_tx_byte) begin
                        send_tx_byte <= 1'b0;
                        clock_count <= 16'h1;

                        bit_index <= 3'h0;
                        state_m <= TX_START_BIT;
                    end
                end

                TX_START_BIT: begin
                    uart_txd_o <= 1'b0;

                    if (clock_count == CLKS_PER_BIT) begin
                        clock_count <= 16'h1;
                        state_m <= TX_DATA_BITS;
                    end else begin
                        clock_count <= clock_count + 16'h1;
                    end
                end

                TX_DATA_BITS: begin
                    uart_txd_o <= tx_byte_o[bit_index];

                    if (clock_count == CLKS_PER_BIT) begin
                        clock_count <= 16'h1;

                        if (bit_index < 3'h7) begin
                            bit_index <= bit_index + 3'h1;
                        end else begin
                            state_m <= TX_STOP_BIT;
                        end
                    end else begin
                        clock_count <= clock_count + 16'h1;
                    end
                end

                TX_STOP_BIT: begin
                    uart_txd_o <= 1'b1;

                    if (clock_count == CLKS_PER_BIT) begin
                        state_m <= TX_IDLE;
                    end else begin
                        clock_count <= clock_count + 16'h1;
                    end
                end

                default: begin
                    // Invalid state machine
                    state_m <= TX_IDLE;
                end
            endcase
        end
    end
endmodule
