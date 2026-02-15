module pe #(
    parameter integer WEIGHT = 1 // Valid values: 1, -1, 2, -2, 0
)(
    input  wire                 clk,
    input  wire                 rst_n,
    
    // Handshake Signals
    input  wire                 compute_valid, // "Start" for this stage
    output reg                  output_valid,
    
    // Data Signals
    input  wire signed [15:0]   y_in,  
    input  wire        [7:0]    x_in,  
    output reg  signed [15:0]   y_out  
);

    wire signed [15:0] x_val;
    assign x_val = $signed({8'b0, x_in}); 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_out        <= 16'sd0;
            
        end else begin
            // 1. Pipeline the Valid Signal (Latency = 1 cycle)
            output_valid <= compute_valid;

            // 2. Perform Computation
            if (compute_valid) begin
                case (WEIGHT)
                    1:       y_out <= y_in + x_val;
                    -1:      y_out <= y_in - x_val;
                    2:       y_out <= y_in + (x_val << 1);
                    -2:      y_out <= y_in - (x_val << 1);
                    0:       y_out <= y_in;
                    default: y_out <= y_in + (WEIGHT * x_val);
                endcase
            end else begin
                // Reset output to 0 if data is invalid (keeps waveform clean)
                y_out <= 16'sd0; 
            end
        end
    end

endmodule