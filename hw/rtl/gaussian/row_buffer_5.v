`timescale 1ns / 1ns

module row_buffer_5 #(
    parameter DATA_WIDTH = 8,
    parameter LINE_WIDTH = 1920
) (
    input wire                  clk,
    input wire                  rst_n,
    input wire                  enable,
    input wire [DATA_WIDTH-1:0] pixel_in,

    // 5 aligned row outputs
    // row_0 is the oldest row (delayed by 4 lines)
    // row_4 is the newest row (current input)
    output wire [DATA_WIDTH-1:0] row_0,
    output wire [DATA_WIDTH-1:0] row_1,
    output wire [DATA_WIDTH-1:0] row_2,
    output wire [DATA_WIDTH-1:0] row_3,
    output wire [DATA_WIDTH-1:0] row_4
);
    // =========================================================================
    // Configuration
    // =========================================================================
    localparam int ROWS = 5;
    localparam int MAX_ROW_DELAY = ROWS - 1;  // 4

    // =========================================================================
    // Control Path
    // =========================================================================
    // Single global enable gates both the line-buffer chain and delay alignment
    // registers so row timing remains coherent under stalls.
    wire lb_enable = enable;

    // =========================================================================
    // Datapath: Line Buffer Chain
    // =========================================================================
    // Line buffer outputs (delayed rows)
    wire [DATA_WIDTH-1:0] lb_out[0:ROWS-1];
    assign lb_out[4] = pixel_in;

    // Line Buffers (4 buffers to create 5 rows)
    // Chain: Input -> LB3 -> LB2 -> LB1 -> LB0
    // Result:
    // row[4] = Input (Line N)
    // row[3] = LB3 Out (Line N-1)
    // row[2] = LB2 Out (Line N-2)
    // ...

    line_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_lb3 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(lb_enable),
        .data_in(lb_out[4]),
        .data_out(lb_out[3])
    );

    line_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_lb2 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(lb_enable),
        .data_in(lb_out[3]),
        .data_out(lb_out[2])
    );

    line_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_lb1 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(lb_enable),
        .data_in(lb_out[2]),
        .data_out(lb_out[1])
    );

    line_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_lb0 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(lb_enable),
        .data_in(lb_out[1]),
        .data_out(lb_out[0])
    );

    // =========================================================================
    // Datapath: Per-Row Delay Alignment
    // =========================================================================
    // The chained line buffers are registered ("Read-first" BRAM behavior in line_buffer.v),
    // which introduces an extra cycle of latency per row relative to the previous one.
    // Compensate with per-row delay pipelines so all rows are horizontally aligned.
    // Row 4 (Input): No delay from LB. Needs 4 cycles to align with Row 0.
    // Row 3 (LB3): 1 cycle delay from LB. Needs 3 cycles.
    // Row 0 (LB0): 4 cycles delay from chain. Needs 0 cycles.

    reg [DATA_WIDTH-1:0] row_delay[0:ROWS-1][0:MAX_ROW_DELAY-1];
    integer rr, dd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (rr = 0; rr < ROWS; rr = rr + 1) begin
                for (dd = 0; dd < rr; dd = dd + 1) begin
                    row_delay[rr][dd] <= {DATA_WIDTH{1'b0}};
                end
            end
        end else if (lb_enable) begin
            for (rr = 1; rr < ROWS; rr = rr + 1) begin
                // Input to delay line is the LB output
                row_delay[rr][0] <= lb_out[rr];
                for (dd = 1; dd < rr; dd = dd + 1) begin
                    row_delay[rr][dd] <= row_delay[rr][dd-1];
                end
            end
        end
    end

    // =========================================================================
    // Output Mapping
    // =========================================================================
    // Assign aligned outputs
    // row_0 comes from lb_out[0], which is already delayed by 4 LB cycles (horizontal latency).
    // So it needs 0 extra delays.
    assign row_0 = lb_out[0];

    // row_1 comes from lb_out[1]. Needs 1 delay to match row_0's 4-cycle horizontal offset.
    assign row_1 = row_delay[1][0];

    // row_2 needs 2 delays
    assign row_2 = row_delay[2][1];

    // row_3 needs 3 delays
    assign row_3 = row_delay[3][2];

    // row_4 needs 4 delays
    assign row_4 = row_delay[4][3];

endmodule
