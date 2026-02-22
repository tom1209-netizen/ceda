module line_buffer_sobel #(
    parameter DATA_WIDTH = 8,
    parameter IMG_WIDTH  = 128
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  valid_in, 
    input  wire [DATA_WIDTH-1:0] din,      
    
    // Data Outputs
    output wire [DATA_WIDTH-1:0] dout0,    
    output wire [DATA_WIDTH-1:0] dout1,    
    output wire [DATA_WIDTH-1:0] dout2,
    
    // Status Output
    output wire                  line_buffer_valid // HIGH only when we have 3 valid rows
);

    reg [DATA_WIDTH-1:0] lb0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb1 [0:IMG_WIDTH-1];
    reg [$clog2(IMG_WIDTH)-1:0] ptr;

    // -------------------------------------------------------------------------
    // New Feature: Warmup Counter
    // -------------------------------------------------------------------------
    // We need to count up to 2 * IMG_WIDTH pixels to know the buffers are full.
    // We use a counter slightly larger than IMG_WIDTH to track total pixels.
    reg [15:0] fill_count; // 16-bit is enough for 128*2 (and much larger)

    // The logic: 
    // If fill_count < 256 (for 128w), we are still priming the pump. 
    // Once fill_count hits 256, we stop counting and keep valid high.
    assign line_buffer_valid = (fill_count >= (2 * IMG_WIDTH));

    // -------------------------------------------------------------------------
    // Data Path
    // -------------------------------------------------------------------------
    assign dout0 = lb0[ptr]; 
    assign dout1 = lb1[ptr];
    assign dout2 = din;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr <= 0;
            fill_count <= 0;
        end else if (valid_in) begin
            
            // 1. Data Movement
            lb0[ptr] <= lb1[ptr];
            lb1[ptr] <= din;
            
            // 2. Pointer Update
            if (ptr == IMG_WIDTH - 1)
                ptr <= 0;
            else
                ptr <= ptr + 1;

            // 3. Warmup Counter Update
            // Stop incrementing once we reach the threshold to save power/logic
            if (fill_count < (2 * IMG_WIDTH)) begin
                fill_count <= fill_count + 1;
            end
        end
    end

endmodule