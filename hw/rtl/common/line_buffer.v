`timescale 1ns / 1ns

module line_buffer #(
    parameter DATA_WIDTH = 8,
    parameter LINE_WIDTH = 1920
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  enable,
    input  wire [DATA_WIDTH-1:0] data_in,
    output reg  [DATA_WIDTH-1:0] data_out
);
    // Calculate address width needed for LINE_WIDTH
    parameter ADDR_WIDTH = 11;  // 2^11 = 2048 > 1920

    // BRAM storage - inferred as block RAM by synthesis tool
    reg [DATA_WIDTH-1:0] buffer[0:LINE_WIDTH-1];

    // Address counter for circular buffer
    reg [ADDR_WIDTH-1:0] addr;

    // Read-first: output old value, then write new value
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr <= {ADDR_WIDTH{1'b0}};
            data_out <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            // Read current position (delayed output)
            data_out <= buffer[addr];

            // Write new data to same position
            buffer[addr] <= data_in;

            // Increment address with wrap-around
            if (addr == LINE_WIDTH - 1) addr <= {ADDR_WIDTH{1'b0}};
            else addr <= addr + 1'b1;
        end
    end

endmodule
