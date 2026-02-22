module line_buffer_5 #(
    parameter DATA_WIDTH = 8,
    parameter IMG_WIDTH  = 128
) (
    input wire                  clk,
    input wire                  rst_n,
    input wire                  valid_in,
    input wire [DATA_WIDTH-1:0] din,

    // Data Outputs (dout0 is oldest, dout4 is newest input)
    output wire [DATA_WIDTH-1:0] dout0,
    output wire [DATA_WIDTH-1:0] dout1,
    output wire [DATA_WIDTH-1:0] dout2,
    output wire [DATA_WIDTH-1:0] dout3,
    output wire [DATA_WIDTH-1:0] dout4,

    // Status Output
    output wire                  line_buffer_valid // HIGH only when we have 5 valid rows (4 lines filled + 1 active)
);

    reg [DATA_WIDTH-1:0] lb0[0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb1[0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb2[0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb3[0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb4;
    reg [$clog2(IMG_WIDTH)-1:0] ptr;

    // -------------------------------------------------------------------------
    // Warmup Counter
    // -------------------------------------------------------------------------
    // We need to count up to 4 * IMG_WIDTH pixels to know the 4 buffers are full.
    // We use a counter slightly larger than 4*IMG_WIDTH to track total pixels.
    reg [23:0] fill_count;  // 24-bit is enough for 1920*4 (and much larger)

    // The logic: 
    // If fill_count < 4 * IMG_WIDTH, we are still priming the line buffers.
    // Once fill_count hits this number, we stop counting and keep valid high.
    assign line_buffer_valid = (fill_count >= (4 * IMG_WIDTH));

    // -------------------------------------------------------------------------
    // Data Path
    // -------------------------------------------------------------------------
    // When valid_in is 0 (either due to padding logic or downstream backpressure),
    // ptr has already incremented from the last valid read. To hold the same output
    reg [DATA_WIDTH-1:0] dout0_reg, dout1_reg, dout2_reg, dout3_reg;

    always @(posedge clk) begin
        if (valid_in) begin
            dout0_reg <= lb0[ptr];
            dout1_reg <= lb1[ptr];
            dout2_reg <= lb2[ptr];
            dout3_reg <= lb3[ptr];
        end
    end

    assign dout0 = valid_in ? lb0[ptr] : dout0_reg;
    assign dout1 = valid_in ? lb1[ptr] : dout1_reg;
    assign dout2 = valid_in ? lb2[ptr] : dout2_reg;
    assign dout3 = valid_in ? lb3[ptr] : dout3_reg;
    assign dout4 = valid_in ? din : lb4; // Combinationally bypass newest pixel, hold previously bypassed pixel during pauses

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr <= 0;
            fill_count <= 0;
            lb4 <= 0;
        end else if (valid_in) begin

            // Data Movement (Shift rows)
            lb0[ptr] <= lb1[ptr];
            lb1[ptr] <= lb2[ptr];
            lb2[ptr] <= lb3[ptr];
            lb3[ptr] <= din;
            lb4      <= din;

            // Pointer Update
            if (ptr == IMG_WIDTH - 1) ptr <= 0;
            else ptr <= ptr + 1;

            // Warmup Counter Update
            // Stop incrementing once we reach the threshold to save power/logic
            if (fill_count < (4 * IMG_WIDTH)) begin
                fill_count <= fill_count + 1;
            end
        end
    end

endmodule
