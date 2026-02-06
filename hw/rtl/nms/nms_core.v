module nms_core #(
    parameter MAG_WIDTH = 12
) (
    input wire [MAG_WIDTH-1:0] mag_00,
    input wire [MAG_WIDTH-1:0] mag_01,
    input wire [MAG_WIDTH-1:0] mag_02,
    input wire [MAG_WIDTH-1:0] mag_10,
    input wire [MAG_WIDTH-1:0] mag_11,
    input wire [MAG_WIDTH-1:0] mag_12,
    input wire [MAG_WIDTH-1:0] mag_20,
    input wire [MAG_WIDTH-1:0] mag_21,
    input wire [MAG_WIDTH-1:0] mag_22,

    input wire [2:0] direction,  // Center pixel (1,1) direction

    output reg [7:0] out_val  // 8-bit thinned output
);
    // Neighbors along gradient
    reg  [MAG_WIDTH-1:0] n1;
    reg  [MAG_WIDTH-1:0] n2;
    wire [MAG_WIDTH-1:0] center = mag_11;

    always @(*) begin
        case (direction)
            3'd0, 3'd7: begin  // E-W (0 deg, 157.5-180 deg?? Check spec)
                // Spec say 0 and 7 are East-West (ish). 
                // Direction 0: [-22.5, 22.5]. Approx Horizontal.
                // Neighbors: West (10) and East (12)
                n1 = mag_10;
                n2 = mag_12;
            end
            3'd1: begin  // NE-SW (45 deg)
                // Neighbors: NE (02) and SW (20)
                n1 = mag_02;
                n2 = mag_20;
            end
            3'd2: begin  // N-S (90 deg)
                // Neighbors: North (01) and South (21)
                n1 = mag_01;
                n2 = mag_21;
            end
            3'd3: begin  // NW-SE (135 deg)
                // Neighbors: NW (00) and SE (22)
                n1 = mag_00;
                n2 = mag_22;
            end
            3'd4: begin  // N-S (Mirror of 2? Or 90 deg range?)
                // Spec: 3'b100 = 90 deg. Compare N-S
                n1 = mag_01;
                n2 = mag_21;
            end
            3'd5: begin  // NW-SE (Mirror of 3?) 
                // Spec: 3'b101 = 112.5. Compare NW-SE
                n1 = mag_00;
                n2 = mag_22;
            end
            3'd6: begin  // NW-SE / Mirror?
                // Spec: 3'b110 = 135 deg. Compare NW-SE
                n1 = mag_00;
                n2 = mag_22;
            end
            default: begin  // 3'd7 included in case 0
                // E-W
                n1 = mag_10;
                n2 = mag_12;
            end
        endcase
    end

    // Suppression Logic
    // If center >= n1 AND center >= n2, keep center. Else 0.
    // Note: Output is 8-bit, but magnitude is 12-bit.
    reg [7:0] center_sat;

    always @(*) begin
        if (center > 12'd255) center_sat = 8'd255;
        else center_sat = center[7:0];

        if ((center >= n1) && (center >= n2)) begin
            out_val = center_sat;
        end else begin
            out_val = 8'd0;
        end
    end

endmodule
