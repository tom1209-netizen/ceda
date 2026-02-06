module pe #(
    parameter PIXEL_WIDTH = 8,
    parameter COEFF_WIDTH = 8,
    parameter ACCUM_WIDTH = 24
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   enable,
    input  wire                   clear,
    input  wire [PIXEL_WIDTH-1:0] pixel,
    input  wire [COEFF_WIDTH-1:0] coeff,
    input  wire [ACCUM_WIDTH-1:0] acc_in,
    output wire [ACCUM_WIDTH-1:0] acc_out
);
    wire [PIXEL_WIDTH+COEFF_WIDTH-1:0] product;
    wire [ACCUM_WIDTH-1:0] product_ext;
    wire [ACCUM_WIDTH-1:0] sum;

    // Multiply current pixel with coefficient
    assign product = pixel * coeff;
    assign product_ext = {{(ACCUM_WIDTH - (PIXEL_WIDTH + COEFF_WIDTH)) {1'b0}}, product};

    // Add to incoming accumulator value
    assign sum = acc_in + product_ext;

    reg [ACCUM_WIDTH-1:0] acc_out_r;
    assign acc_out = acc_out_r;

    // Registered output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out_r <= {ACCUM_WIDTH{1'b0}};
        end else if (enable) begin
            if (clear) acc_out_r <= product_ext;  // Start fresh: just the product
            else acc_out_r <= sum;  // Accumulate: add to previous
        end
    end

endmodule
