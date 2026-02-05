module pe #(
    parameter integer WEIGHT = 1 // Valid values: 1, -1, 2, -2, 0
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire signed [15:0]   y_in,  // Partial sum in
    input  wire        [7:0]    x_in,  // Broadcast pixel input (unsigned 8-bit)
    output reg  signed [15:0]   y_out  // Partial sum out
);

    // We extend x_in to a signed 16-bit representation for safe arithmetic
    wire signed [15:0] x_val;
    assign x_val = $signed({8'b0, x_in}); // Zero-pad to keep it positive

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_out <= 16'sd0;
        end else begin
            // Compile-time optimization based on the WEIGHT parameter.
            // The synthesis tool will only implement the logic for the matching case.
            case (WEIGHT)
                1: begin
                    // y + 1*x
                    y_out <= y_in + x_val;
                end
                
                -1: begin
                    // y - 1*x
                    y_out <= y_in - x_val;
                end
                
                2: begin
                    // y + 2*x (Left shift x by 1)
                    y_out <= y_in + (x_val << 1);
                end
                
                -2: begin
                    // y - 2*x (Left shift x by 1)
                    y_out <= y_in - (x_val << 1);
                end
                
                0: begin
                    // Just pass the sum through
                    y_out <= y_in;
                end
                
                default: begin
                    // Fallback for generic weights (uses multiplier if needed)
                    y_out <= y_in + (WEIGHT * x_val);
                end
            endcase
        end
    end

endmodule