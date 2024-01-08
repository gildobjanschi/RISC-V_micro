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

//==================================================================================================================
// Metastability flip-flop
//==================================================================================================================
module DFF_META (input logic reset, input logic D, input logic clk, output logic Q, output logic Q_pulse);
    logic Q_pipe = 1'b0;
    always @(posedge clk) begin
        if (reset) begin
            Q <= 1'b0;
            Q_pipe <= 1'b0;
            Q_pulse <= 1'b0;
        end else begin
            Q_pipe <= D;
            Q <= Q_pipe;

            if (Q_pipe & ~Q) Q_pulse <= 1'b1;

            if (Q_pulse) Q_pulse <= 1'b0;
        end
    end
endmodule
