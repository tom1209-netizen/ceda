`timescale 1ns / 1ns

module row_buffer_3 #(
    parameter DATA_WIDTH = 8,
    parameter LINE_WIDTH = 1920
) (
    input wire                  clk,
    input wire                  rst_n,
    input wire                  enable,
    input wire [DATA_WIDTH-1:0] pixel_in,

    // 3 aligned row outputs
    // row_0 is the oldest row (delayed by 2 lines)
    // row_2 is the newest row (current input)
    output wire [DATA_WIDTH-1:0] row_0,
    output wire [DATA_WIDTH-1:0] row_1,
    output wire [DATA_WIDTH-1:0] row_2
);
    localparam int ROWS = 3;
    localparam int MAX_ROW_DELAY = ROWS - 1;  // 2

    // Line buffer outputs (delayed rows)
    wire [DATA_WIDTH-1:0] lb_out[0:ROWS-1];
    assign lb_out[2] = pixel_in;

    // Line Buffers (2 buffers to create 3 rows)
    // Chain: Input -> LB1 -> LB0

    line_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_lb1 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(lb_out[2]),
        .data_out(lb_out[1])
    );

    line_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_lb0 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(lb_out[1]),
        .data_out(lb_out[0])
    );

    // Alignment delays (similar to row_buffer_5)
    // Row 2 (Input): Needs 2 delays
    // Row 1 (LB1): Needs 1 delay
    // Row 0 (LB0): Needs 0 delays

    reg [DATA_WIDTH-1:0] row_delay[0:ROWS-1][0:MAX_ROW_DELAY-1];
    integer rr, dd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (rr = 0; rr < ROWS; rr = rr + 1) begin
                for (dd = 0; dd < rr; dd = dd + 1) begin
                    row_delay[rr][dd] <= {DATA_WIDTH{1'b0}};
                end
            end
        end else if (enable) begin
            for (rr = 1; rr < ROWS; rr = rr + 1) begin
                row_delay[rr][0] <= lb_out[rr];
                for (dd = 1; dd < rr; dd = dd + 1) begin
                    row_delay[rr][dd] <= row_delay[rr][dd-1];
                end
            end
        end
    end

    assign row_0 = lb_out[0];  // 0 delays
    assign row_1 = row_delay[1][0];  // 1 delay
    assign row_2 = row_delay[2][1];  // 2 delays

endmodule
