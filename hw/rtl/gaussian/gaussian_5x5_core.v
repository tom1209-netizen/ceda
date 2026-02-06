module gaussian_5x5_core #(
    parameter PIXEL_WIDTH = 8,
    parameter COEFF_WIDTH = 8,
    parameter ACCUM_WIDTH = 24
) (
    input wire clk,
    input wire rst_n,
    input wire enable,

    // Only column 0 of each row is needed for the Sequential PE architecture.
    // The streaming nature (1 pixel/clk) means PE stage 'k' (at time t+k) naturally sees
    // the correct relative pixel from Window(t)[k] by looking at Window(t+k)[0].
    input wire [PIXEL_WIDTH-1:0] win_row_0,
    input wire [PIXEL_WIDTH-1:0] win_row_1,
    input wire [PIXEL_WIDTH-1:0] win_row_2,
    input wire [PIXEL_WIDTH-1:0] win_row_3,
    input wire [PIXEL_WIDTH-1:0] win_row_4,

    output reg [PIXEL_WIDTH-1:0] pixel_out,
    output reg                   valid_out
);
    localparam int ROWS = 5;
    localparam int COLS = 5;

    // Data latency from the presented window edge to pixel_out is:
    // - 5 registered PE stages per row + 1 output register = 6 cycles.
    localparam int OUT_LATENCY = COLS + 1;  // 6

    // Map inputs to a readable array for the generate loop
    wire [PIXEL_WIDTH-1:0] win_row[0:ROWS-1];
    assign win_row[0] = win_row_0;
    assign win_row[1] = win_row_1;
    assign win_row[2] = win_row_2;
    assign win_row[3] = win_row_3;
    assign win_row[4] = win_row_4;

    // Gaussian kernel coefficients (5x5, sum = 256)
    wire [COEFF_WIDTH-1:0] K[0:ROWS-1][0:COLS-1];
    assign K[0][0] = 8'd1;
    assign K[0][1] = 8'd4;
    assign K[0][2] = 8'd6;
    assign K[0][3] = 8'd4;
    assign K[0][4] = 8'd1;
    assign K[1][0] = 8'd4;
    assign K[1][1] = 8'd16;
    assign K[1][2] = 8'd24;
    assign K[1][3] = 8'd16;
    assign K[1][4] = 8'd4;
    assign K[2][0] = 8'd6;
    assign K[2][1] = 8'd24;
    assign K[2][2] = 8'd36;
    assign K[2][3] = 8'd24;
    assign K[2][4] = 8'd6;
    assign K[3][0] = 8'd4;
    assign K[3][1] = 8'd16;
    assign K[3][2] = 8'd24;
    assign K[3][3] = 8'd16;
    assign K[3][4] = 8'd4;
    assign K[4][0] = 8'd1;
    assign K[4][1] = 8'd4;
    assign K[4][2] = 8'd6;
    assign K[4][3] = 8'd4;
    assign K[4][4] = 8'd1;

    // Accumulators per PE stage
    wire [ACCUM_WIDTH-1:0] acc[0:ROWS-1][0:COLS-1];

    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_row
            // Stage 0: start a fresh accumulation for this row.
            pe #(
                .PIXEL_WIDTH(PIXEL_WIDTH),
                .COEFF_WIDTH(COEFF_WIDTH),
                .ACCUM_WIDTH(ACCUM_WIDTH)
            ) u_pe0 (
                .clk(clk),
                .rst_n(rst_n),
                .enable(enable),
                .clear(1'b1),
                .pixel(win_row[gr]),  // Always consume column 0
                .coeff(K[gr][0]),
                .acc_in({ACCUM_WIDTH{1'b0}}),
                .acc_out(acc[gr][0])
            );

            for (gc = 1; gc < COLS; gc = gc + 1) begin : g_col
                // Subsequent stages consume the accum from the previous stage
                // AND still consume column 0 of the current window.
                pe #(
                    .PIXEL_WIDTH(PIXEL_WIDTH),
                    .COEFF_WIDTH(COEFF_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .enable(enable),
                    .clear(1'b0),
                    .pixel(win_row[gr]),  // Always consume column 0
                    .coeff(K[gr][gc]),
                    .acc_in(acc[gr][gc-1]),
                    .acc_out(acc[gr][gc])
                );
            end
        end
    endgenerate

    wire [ACCUM_WIDTH-1:0] sum =
        acc[0][COLS - 1] +
        acc[1][COLS - 1] +
        acc[2][COLS - 1] +
        acc[3][COLS - 1] +
        acc[4][COLS - 1];

    wire [ACCUM_WIDTH-1:0] sum_rounded = sum + {{(ACCUM_WIDTH - 8) {1'b0}}, 8'd128};
    wire [PIXEL_WIDTH-1:0] normalized = sum_rounded[PIXEL_WIDTH+7 : 8];

    reg [OUT_LATENCY-1:0] valid_pipe;
    wire [OUT_LATENCY-1:0] valid_next = {valid_pipe[OUT_LATENCY-2 : 0], 1'b1};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_out  <= {PIXEL_WIDTH{1'b0}};
            valid_out  <= 1'b0;
            valid_pipe <= {OUT_LATENCY{1'b0}};
        end else if (enable) begin
            // Output register adds 1 cycle beyond the PE chain; valid is delayed to match.
            pixel_out  <= normalized;
            valid_pipe <= valid_next;
            valid_out  <= valid_next[OUT_LATENCY-1];
        end
    end
endmodule
