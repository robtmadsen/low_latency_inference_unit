//      // verilator_coverage annotation
        /*
        
        Copyright (c) 2014-2018 Alex Forencich
        
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
         * ARP cache
         */
        module arp_cache #(
            parameter CACHE_ADDR_WIDTH = 9
        )
        (
            input  wire        clk,
            input  wire        rst,
        
            /*
             * Cache query
             */
            input  wire        query_request_valid,
            output wire        query_request_ready,
            input  wire [31:0] query_request_ip,
        
            output wire        query_response_valid,
            input  wire        query_response_ready,
            output wire        query_response_error,
            output wire [47:0] query_response_mac,
        
            /*
             * Cache write
             */
            input  wire        write_request_valid,
            output wire        write_request_ready,
            input  wire [31:0] write_request_ip,
            input  wire [47:0] write_request_mac,
        
            /*
             * Configuration
             */
            input  wire        clear_cache
        );
        
 000001 reg mem_write = 0;
 000001 reg store_query = 0;
 000001 reg store_write = 0;
        
 000001 reg query_ip_valid_reg = 0, query_ip_valid_next;
 000001 reg [31:0] query_ip_reg = 0;
 000001 reg write_ip_valid_reg = 0, write_ip_valid_next;
 000001 reg [31:0] write_ip_reg = 0;
 000001 reg [47:0] write_mac_reg = 0;
 000001 reg clear_cache_reg = 0, clear_cache_next;
        
 000001 reg [CACHE_ADDR_WIDTH-1:0] wr_ptr_reg = {CACHE_ADDR_WIDTH{1'b0}}, wr_ptr_next;
 000001 reg [CACHE_ADDR_WIDTH-1:0] rd_ptr_reg = {CACHE_ADDR_WIDTH{1'b0}}, rd_ptr_next;
        
        reg valid_mem[(2**CACHE_ADDR_WIDTH)-1:0];
        reg [31:0] ip_addr_mem[(2**CACHE_ADDR_WIDTH)-1:0];
        reg [47:0] mac_addr_mem[(2**CACHE_ADDR_WIDTH)-1:0];
        
 000001 reg query_request_ready_reg = 0, query_request_ready_next;
        
 000001 reg query_response_valid_reg = 0, query_response_valid_next;
 000001 reg query_response_error_reg = 0, query_response_error_next;
 000001 reg [47:0] query_response_mac_reg = 0;
        
 000001 reg write_request_ready_reg = 0, write_request_ready_next;
        
        wire [31:0] query_request_hash;
        wire [31:0] write_request_hash;
        
        assign query_request_ready = query_request_ready_reg;
        
        assign query_response_valid = query_response_valid_reg;
        assign query_response_error = query_response_error_reg;
        assign query_response_mac = query_response_mac_reg;
        
        assign write_request_ready = write_request_ready_reg;
        
        lfsr #(
            .LFSR_WIDTH(32),
            .LFSR_POLY(32'h4c11db7),
            .LFSR_CONFIG("GALOIS"),
            .LFSR_FEED_FORWARD(0),
            .REVERSE(1),
            .DATA_WIDTH(32),
            .STYLE("AUTO")
        )
        rd_hash (
            .data_in(query_request_ip),
            .state_in(32'hffffffff),
            .data_out(),
            .state_out(query_request_hash)
        );
        
        lfsr #(
            .LFSR_WIDTH(32),
            .LFSR_POLY(32'h4c11db7),
            .LFSR_CONFIG("GALOIS"),
            .LFSR_FEED_FORWARD(0),
            .REVERSE(1),
            .DATA_WIDTH(32),
            .STYLE("AUTO")
        )
        wr_hash (
            .data_in(write_request_ip),
            .state_in(32'hffffffff),
            .data_out(),
            .state_out(write_request_hash)
        );
        
        integer i;
        
 000001 initial begin
 000512     for (i = 0; i < 2**CACHE_ADDR_WIDTH; i = i + 1) begin
 000512         valid_mem[i] = 1'b0;
 000512         ip_addr_mem[i] = 32'd0;
 000512         mac_addr_mem[i] = 48'd0;
            end
        end
        
 7806611 always @* begin
 7806611     mem_write = 1'b0;
 7806611     store_query = 1'b0;
 7806611     store_write = 1'b0;
        
 7806611     wr_ptr_next = wr_ptr_reg;
 7806611     rd_ptr_next = rd_ptr_reg;
        
 7806611     clear_cache_next = clear_cache_reg | clear_cache;
        
 7806611     query_ip_valid_next = query_ip_valid_reg;
        
 7806611     query_request_ready_next = (~query_ip_valid_reg || ~query_request_valid || query_response_ready) && !clear_cache_next;
        
 7806611     query_response_valid_next = query_response_valid_reg & ~query_response_ready;
 7806611     query_response_error_next = query_response_error_reg;
        
~7806611     if (query_ip_valid_reg && (~query_request_valid || query_response_ready)) begin
%000000         query_response_valid_next = 1;
%000000         query_ip_valid_next = 0;
%000000         if (valid_mem[rd_ptr_reg] && ip_addr_mem[rd_ptr_reg] == query_ip_reg) begin
%000000             query_response_error_next = 0;
%000000         end else begin
%000000             query_response_error_next = 1;
                end
            end
        
~7806611     if (query_request_valid && query_request_ready && (~query_ip_valid_reg || ~query_request_valid || query_response_ready)) begin
%000000         store_query = 1;
%000000         query_ip_valid_next = 1;
%000000         rd_ptr_next = query_request_hash[CACHE_ADDR_WIDTH-1:0];
            end
        
 7806611     write_ip_valid_next = write_ip_valid_reg;
        
 7806611     write_request_ready_next = !clear_cache_next;
        
 7806584     if (write_ip_valid_reg) begin
 000027         write_ip_valid_next = 0;
 000027         mem_write = 1;
            end
        
 7806584     if (write_request_valid && write_request_ready) begin
 000027         store_write = 1;
 000027         write_ip_valid_next = 1;
 000027         wr_ptr_next = write_request_hash[CACHE_ADDR_WIDTH-1:0];
            end
        
%000000     if (clear_cache) begin
%000000         clear_cache_next = 1'b1;
%000000         wr_ptr_next = 0;
 7432459     end else if (clear_cache_reg) begin
 374152         wr_ptr_next = wr_ptr_reg + 1;
 374152         clear_cache_next = wr_ptr_next != 0;
 374152         mem_write = 1;
            end
        end
        
 859379 always @(posedge clk) begin
 857900     if (rst) begin
 001479         query_ip_valid_reg <= 1'b0;
 001479         query_request_ready_reg <= 1'b0;
 001479         query_response_valid_reg <= 1'b0;
 001479         write_ip_valid_reg <= 1'b0;
 001479         write_request_ready_reg <= 1'b0;
 001479         clear_cache_reg <= 1'b1;
 001479         wr_ptr_reg <= 0;
 857900     end else begin
 857900         query_ip_valid_reg <= query_ip_valid_next;
 857900         query_request_ready_reg <= query_request_ready_next;
 857900         query_response_valid_reg <= query_response_valid_next;
 857900         write_ip_valid_reg <= write_ip_valid_next;
 857900         write_request_ready_reg <= write_request_ready_next;
 857900         clear_cache_reg <= clear_cache_next;
 857900         wr_ptr_reg <= wr_ptr_next;
            end
        
 859379     query_response_error_reg <= query_response_error_next;
        
~859379     if (store_query) begin
%000000         query_ip_reg <= query_request_ip;
            end
        
 859376     if (store_write) begin
 000003         write_ip_reg <= write_request_ip;
 000003         write_mac_reg <= write_request_mac;
            end
        
 859379     rd_ptr_reg <= rd_ptr_next;
        
 859379     query_response_mac_reg <= mac_addr_mem[rd_ptr_reg];
        
 823234     if (mem_write) begin
 036145         valid_mem[wr_ptr_reg] <= !clear_cache_reg;
 036145         ip_addr_mem[wr_ptr_reg] <= write_ip_reg;
 036145         mac_addr_mem[wr_ptr_reg] <= write_mac_reg;
            end
        end
        
        endmodule
        
        `resetall
        
