//      // verilator_coverage annotation
        /*
        
        Copyright (c) 2014-2021 Alex Forencich
        
        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:
        
        The above copyright notice and this permission notice shall be included in
        all copies or substantial portions of the Software.
        
        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
        THE SOFTWARE.
        
        */
        
        // Language: Verilog 2001
        
        `resetall
        `timescale 1ns / 1ps
        `default_nettype none
        
        /*
         * Arbiter module
         */
        module arbiter #
        (
            parameter PORTS = 4,
            // select round robin arbitration
            parameter ARB_TYPE_ROUND_ROBIN = 0,
            // blocking arbiter enable
            parameter ARB_BLOCK = 0,
            // block on acknowledge assert when nonzero, request deassert when 0
            parameter ARB_BLOCK_ACK = 1,
            // LSB priority selection
            parameter ARB_LSB_HIGH_PRIORITY = 0
        )
        (
            input  wire                     clk,
            input  wire                     rst,
        
            input  wire [PORTS-1:0]         request,
            input  wire [PORTS-1:0]         acknowledge,
        
            output wire [PORTS-1:0]         grant,
            output wire                     grant_valid,
            output wire [$clog2(PORTS)-1:0] grant_encoded
        );
        
 000002 reg [PORTS-1:0] grant_reg = 0, grant_next;
 000002 reg grant_valid_reg = 0, grant_valid_next;
 000002 reg [$clog2(PORTS)-1:0] grant_encoded_reg = 0, grant_encoded_next;
        
        assign grant_valid = grant_valid_reg;
        assign grant = grant_reg;
        assign grant_encoded = grant_encoded_reg;
        
        wire request_valid;
        wire [$clog2(PORTS)-1:0] request_index;
        wire [PORTS-1:0] request_mask;
        
        priority_encoder #(
            .WIDTH(PORTS),
            .LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
        )
        priority_encoder_inst (
            .input_unencoded(request),
            .output_valid(request_valid),
            .output_encoded(request_index),
            .output_unencoded(request_mask)
        );
        
 000002 reg [PORTS-1:0] mask_reg = 0, mask_next;
        
        wire masked_request_valid;
        wire [$clog2(PORTS)-1:0] masked_request_index;
        wire [PORTS-1:0] masked_request_mask;
        
        priority_encoder #(
            .WIDTH(PORTS),
            .LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
        )
        priority_encoder_masked (
            .input_unencoded(request & mask_reg),
            .output_valid(masked_request_valid),
            .output_encoded(masked_request_index),
            .output_unencoded(masked_request_mask)
        );
        
 15613222 always @* begin
 15613222     grant_next = 0;
 15613222     grant_valid_next = 0;
 15613222     grant_encoded_next = 0;
 15613222     mask_next = mask_reg;
        
%000000     if (ARB_BLOCK && !ARB_BLOCK_ACK && grant_reg & request) begin
                // granted request still asserted; hold it
%000000         grant_valid_next = grant_valid_reg;
%000000         grant_next = grant_reg;
%000000         grant_encoded_next = grant_encoded_reg;
 000054     end else if (ARB_BLOCK && ARB_BLOCK_ACK && grant_valid && !(grant_reg & acknowledge)) begin
                // granted request not yet acknowledged; hold it
 000054         grant_valid_next = grant_valid_reg;
 000054         grant_next = grant_reg;
 000054         grant_encoded_next = grant_encoded_reg;
 15613150     end else if (request_valid) begin
~000018         if (ARB_TYPE_ROUND_ROBIN) begin
%000000             if (masked_request_valid) begin
%000000                 grant_valid_next = 1;
%000000                 grant_next = masked_request_mask;
%000000                 grant_encoded_next = masked_request_index;
%000000                 if (ARB_LSB_HIGH_PRIORITY) begin
%000000                     mask_next = {PORTS{1'b1}} << (masked_request_index + 1);
%000000                 end else begin
%000000                     mask_next = {PORTS{1'b1}} >> (PORTS - masked_request_index);
                        end
%000000             end else begin
%000000                 grant_valid_next = 1;
%000000                 grant_next = request_mask;
%000000                 grant_encoded_next = request_index;
%000000                 if (ARB_LSB_HIGH_PRIORITY) begin
%000000                     mask_next = {PORTS{1'b1}} << (request_index + 1);
%000000                 end else begin
%000000                     mask_next = {PORTS{1'b1}} >> (PORTS - request_index);
                        end
                    end
 000018         end else begin
 000018             grant_valid_next = 1;
 000018             grant_next = request_mask;
 000018             grant_encoded_next = request_index;
                end
            end
        end
        
 1718758 always @(posedge clk) begin
 1718758     grant_reg <= grant_next;
 1718758     grant_valid_reg <= grant_valid_next;
 1718758     grant_encoded_reg <= grant_encoded_next;
 1718758     mask_reg <= mask_next;
        
 1715800     if (rst) begin
 002958         grant_reg <= 0;
 002958         grant_valid_reg <= 0;
 002958         grant_encoded_reg <= 0;
 002958         mask_reg <= 0;
            end
        end
        
        endmodule
        
        `resetall
        
