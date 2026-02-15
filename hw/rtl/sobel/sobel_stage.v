module sobel_stage #(
    parameter IMG_WIDTH  = 128,
    parameter IMG_HEIGHT = 128
)(
    input  wire           clk,
    input  wire           resetn,
    
    // Input Stream
    input  wire [7:0]     s_axis_tdata,
    input  wire           s_axis_tvalid,
    output wire           s_axis_tready,
    
    // Outputs
    output reg [14:0]     m_axis_tdata,
    output reg            m_axis_tvalid,
    input  wire           m_axis_tready,
    output reg            m_axis_tlast
);

    reg [7:0]      m_axis_gx_tdata;
    reg            m_axis_gx_tvalid;
    wire           m_axis_gx_tready;
    
    reg [7:0]      m_axis_gy_tdata;
    reg            m_axis_gy_tvalid;
    wire           m_axis_gy_tready;

    wire downstream_ready;
//    assign downstream_ready = m_axis_gx_tready && m_axis_gy_tready && m_axis_tready;
    assign downstream_ready = m_axis_tready;
    
    reg input_paused; 
    reg flush_active = 0;
    
    assign s_axis_tready = downstream_ready && !input_paused && !flush_active;

  
    wire [7:0] lb_top, lb_mid, lb_bot; 
    wire       lb_std_valid;           
    

    wire lb_write_en = (s_axis_tvalid && s_axis_tready) || 
                       (flush_active && downstream_ready && !input_paused);

    line_buffer #(
        .DATA_WIDTH(8),
        .IMG_WIDTH(IMG_WIDTH)
    ) lb_inst (
        .clk(clk),
        .rst_n(resetn),
        .valid_in(lb_write_en), 
        .din(flush_active ? 8'd0 : s_axis_tdata),
        
        
        .dout0(lb_top),  // Buffer 0 -> Top Line
        .dout1(lb_mid),  // Buffer 1 -> Middle Line
        .dout2(lb_bot),  // Input/Buffer 2 -> Bottom Line
        
        .line_buffer_valid(lb_std_valid)
    );

    
    localparam TOTAL_PIXELS = IMG_HEIGHT * IMG_WIDTH;
    localparam S_PAD_LEFT_CROSSLINE  = 0;
    localparam S_PAD_LEFT  = 1;
    localparam S_ACTIVE    = 2;
    localparam S_PAD_RIGHT = 3;
    
    reg [1:0]  h_state;
    reg [11:0] h_cnt;
    reg [31:0] global_pixel_cnt;
    reg        warmup_done; 
    reg [11:0] y_cnt;
    wire start_condition = warmup_done && ((s_axis_tvalid && s_axis_tready) || flush_active || h_state != S_ACTIVE);
    wire compute_pulse   = start_condition && downstream_ready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            global_pixel_cnt <= 0;
            warmup_done      <= 0;
        end else 
        begin
            if (s_axis_tvalid && s_axis_tready) 
            begin
                global_pixel_cnt <= global_pixel_cnt + 1;
                if (global_pixel_cnt == IMG_WIDTH - 1)
                begin
                    warmup_done <= 1'b1;
                end
            end
            if (global_pixel_cnt == TOTAL_PIXELS && !flush_active) 
            begin
                    flush_active <= 1'b1;
            end
            if (flush_active && h_state == S_PAD_RIGHT && y_cnt == IMG_HEIGHT - 1 && compute_pulse) begin
                flush_active <= 1'b0;
            end
        end    
    end

    
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            h_state      <= S_PAD_LEFT;
            h_cnt        <= 0;
            input_paused <= 1'b0; 
        end else begin
            
            if (global_pixel_cnt == IMG_WIDTH - 1) begin
                input_paused <= 1'b1; 
            end
            
            // -----------------------------------------------------
            // NORMAL OPERATION (Once Warmup is Done)
            // -----------------------------------------------------
            if (warmup_done && compute_pulse) begin
                case (h_state)
                
                    S_PAD_LEFT_CROSSLINE: begin
                        input_paused <= 1'b1;
                        h_state <= S_PAD_LEFT;
                        h_cnt <= 0;
                    end

                    S_PAD_LEFT: begin
                        input_paused <= 1'b0; // Unpause for next cycle (Active)
                        h_state      <= S_ACTIVE;
                        h_cnt        <= 0;
                    end
                    
                    S_ACTIVE: begin
                        if (h_cnt == IMG_WIDTH - 2) begin
                            input_paused <= 1'b1; // Pause for Right Pad
                            h_state      <= S_PAD_RIGHT;
                        end else begin
                            input_paused <= 1'b0; // Keep streaming
                        end
                        h_cnt <= h_cnt + 1;
                    end
                    
                    S_PAD_RIGHT: begin
                        input_paused <= 1'b0; // Keep paused for Left Pad of next line
                        h_state      <= S_PAD_LEFT_CROSSLINE;
                        h_cnt        <= 0;
                    end
                endcase
            end
        end
    end


    // Track output rows
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            y_cnt <= 0;
        end else if (compute_pulse && h_state == S_PAD_LEFT_CROSSLINE) begin
            if (y_cnt == IMG_HEIGHT - 1)
                y_cnt <= 0;
            else
                y_cnt <= y_cnt + 1;
        end
    end

    wire [7:0] w_top_row, w_mid_row, w_bot_row;

    assign w_top_row = (y_cnt == 0) ? lb_mid : lb_top;
    assign w_mid_row = lb_mid;
    assign w_bot_row = (y_cnt == IMG_HEIGHT - 1) ? lb_mid : lb_bot;
    
   
    reg [$clog2(IMG_WIDTH + 2)-1:0] input_col_cnt;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            input_col_cnt <= 0;
        end else if (compute_pulse) begin 
            if (input_col_cnt == IMG_WIDTH + 2)
                input_col_cnt <= 1;
            else
                input_col_cnt <= input_col_cnt + 1;
        end
    end

    wire boundary_mask;
    assign boundary_mask = (input_col_cnt >= 3);

    // -------------------------------------------------------------------------
    // Systolic Array (PEs)
    // -------------------------------------------------------------------------
    
    // GX WIRES
    wire signed [15:0] r0_p0_gx, r0_p1_gx, r0_p2_gx;
    wire signed [15:0] r1_p0_gx, r1_p1_gx, r1_p2_gx;
    wire signed [15:0] r2_p0_gx, r2_p1_gx, r2_p2_gx;
    wire col0_gx_valid, col1_gx_valid, col2_gx_valid;

    // GY WIRES
    wire signed [15:0] r0_p0_gy, r0_p1_gy, r0_p2_gy;
    wire signed [15:0] r1_p0_gy, r1_p1_gy, r1_p2_gy;
    wire signed [15:0] r2_p0_gy, r2_p1_gy, r2_p2_gy;
    wire col0_gy_valid, col1_gy_valid, col2_gy_valid;

    // --- GX KERNEL ---
    // Row 0 (Top Window)
    pe #(.WEIGHT(-1)) pe_gx_00 (.clk(clk), .rst_n(resetn), .compute_valid(compute_pulse), .output_valid(col0_gx_valid), .y_in(16'sd0), .x_in(w_top_row), .y_out(r0_p0_gx));
    pe #(.WEIGHT( 0)) pe_gx_01 (.clk(clk), .rst_n(resetn), .compute_valid(col0_gx_valid), .output_valid(col1_gx_valid), .y_in(r0_p0_gx), .x_in(w_top_row), .y_out(r0_p1_gx));
    pe #(.WEIGHT( 1)) pe_gx_02 (.clk(clk), .rst_n(resetn), .compute_valid(col1_gx_valid), .output_valid(col2_gx_valid), .y_in(r0_p1_gx), .x_in(w_top_row), .y_out(r0_p2_gx));

    // Row 1 (Mid Window)
    pe #(.WEIGHT(-2)) pe_gx_10 (.clk(clk), .rst_n(resetn), .compute_valid(compute_pulse), .output_valid(),             .y_in(16'sd0), .x_in(w_mid_row), .y_out(r1_p0_gx));
    pe #(.WEIGHT( 0)) pe_gx_11 (.clk(clk), .rst_n(resetn), .compute_valid(col0_gx_valid), .output_valid(),             .y_in(r1_p0_gx), .x_in(w_mid_row), .y_out(r1_p1_gx));
    pe #(.WEIGHT( 2)) pe_gx_12 (.clk(clk), .rst_n(resetn), .compute_valid(col1_gx_valid), .output_valid(),             .y_in(r1_p1_gx), .x_in(w_mid_row), .y_out(r1_p2_gx));

    // Row 2 (Bot Window)
    pe #(.WEIGHT(-1)) pe_gx_20 (.clk(clk), .rst_n(resetn), .compute_valid(compute_pulse), .output_valid(),             .y_in(16'sd0), .x_in(w_bot_row), .y_out(r2_p0_gx));
    pe #(.WEIGHT( 0)) pe_gx_21 (.clk(clk), .rst_n(resetn), .compute_valid(col0_gx_valid), .output_valid(),             .y_in(r2_p0_gx), .x_in(w_bot_row), .y_out(r2_p1_gx));
    pe #(.WEIGHT( 1)) pe_gx_22 (.clk(clk), .rst_n(resetn), .compute_valid(col1_gx_valid), .output_valid(),             .y_in(r2_p1_gx), .x_in(w_bot_row), .y_out(r2_p2_gx));

    // --- GY KERNEL (Same Logic) ---
    // Row 0
    pe #(.WEIGHT(-1)) pe_gy_00 (.clk(clk), .rst_n(resetn), .compute_valid(compute_pulse), .output_valid(col0_gy_valid), .y_in(16'sd0), .x_in(w_top_row), .y_out(r0_p0_gy));
    pe #(.WEIGHT(-2)) pe_gy_01 (.clk(clk), .rst_n(resetn), .compute_valid(col0_gy_valid), .output_valid(col1_gy_valid), .y_in(r0_p0_gy), .x_in(w_top_row), .y_out(r0_p1_gy));
    pe #(.WEIGHT(-1)) pe_gy_02 (.clk(clk), .rst_n(resetn), .compute_valid(col1_gy_valid), .output_valid(col2_gy_valid), .y_in(r0_p1_gy), .x_in(w_top_row), .y_out(r0_p2_gy));
    // Row 1
    pe #(.WEIGHT( 0)) pe_gy_10 (.clk(clk), .rst_n(resetn), .compute_valid(compute_pulse), .output_valid(),              .y_in(16'sd0), .x_in(w_mid_row), .y_out(r1_p0_gy));
    pe #(.WEIGHT( 0)) pe_gy_11 (.clk(clk), .rst_n(resetn), .compute_valid(col0_gy_valid), .output_valid(),              .y_in(r1_p0_gy), .x_in(w_mid_row), .y_out(r1_p1_gy));
    pe #(.WEIGHT( 0)) pe_gy_12 (.clk(clk), .rst_n(resetn), .compute_valid(col1_gy_valid), .output_valid(),              .y_in(r1_p1_gy), .x_in(w_mid_row), .y_out(r1_p2_gy));
    // Row 2
    pe #(.WEIGHT( 1)) pe_gy_20 (.clk(clk), .rst_n(resetn), .compute_valid(compute_pulse), .output_valid(),              .y_in(16'sd0), .x_in(w_bot_row), .y_out(r2_p0_gy));
    pe #(.WEIGHT( 2)) pe_gy_21 (.clk(clk), .rst_n(resetn), .compute_valid(col0_gy_valid), .output_valid(),              .y_in(r2_p0_gy), .x_in(w_bot_row), .y_out(r2_p1_gy));
    pe #(.WEIGHT( 1)) pe_gy_22 (.clk(clk), .rst_n(resetn), .compute_valid(col1_gy_valid), .output_valid(),              .y_in(r2_p1_gy), .x_in(w_bot_row), .y_out(r2_p2_gy));

    // -------------------------------------------------------------------------
    // Output Summation & Formatting
    // -------------------------------------------------------------------------
    wire signed [15:0] total_sum_gx = r0_p2_gx + r1_p2_gx + r2_p2_gx;
    wire signed [15:0] total_sum_gy = r0_p2_gy + r1_p2_gy + r2_p2_gy;
    
    wire signed [15:0] abs_sum_gx = (total_sum_gx < 0) ? -total_sum_gx : total_sum_gx;
    wire signed [15:0] abs_sum_gy = (total_sum_gy < 0) ? -total_sum_gy : total_sum_gy;
    
    wire signed [11:0] combined_magnitude = abs_sum_gx + abs_sum_gy;
    
    // Gradient Direction Logic
    wire signed [15:0] gx_thresh_low  = (abs_sum_gx >>> 2) + (abs_sum_gx >>> 3); // Approx 0.375 * |gx|
    wire signed [15:0] gx_thresh_high = (abs_sum_gx <<< 1) + (abs_sum_gx >>> 2) + (abs_sum_gx >>> 3); // Approx 2.375 * |gx|
    reg [2:0] gradient_direction;
    
    always @(*) begin
        // Default assignment to prevent latches
        gradient_direction = 3'd0;
        
        if (total_sum_gx > 0) begin
            if (total_sum_gy >= 0) begin
                // Quadrant 1 (gy >= 0)
                if (abs_sum_gy <= gx_thresh_low) 
                    gradient_direction = 3'd0;       // -22.5 to 22.5
                else if (abs_sum_gy < gx_thresh_high) 
                    gradient_direction = 3'd1;       // 22.5 to 67.5
                else 
                    gradient_direction = 3'd2;       // 67.5 to 112.5
            end else begin
                // Quadrant 4 (gy < 0)
                if (abs_sum_gy <= gx_thresh_low) 
                    gradient_direction = 3'd0;       // -22.5 to 22.5
                else if (abs_sum_gy < gx_thresh_high) 
                    gradient_direction = 3'd7;       // 292.5 to 337.5
                else 
                    gradient_direction = 3'd6;       // 247.5 to 292.5
            end
        end else if (total_sum_gx < 0) begin
            if (total_sum_gy >= 0) begin
                // Quadrant 2 (gy >= 0)
                if (abs_sum_gy <= gx_thresh_low) 
                    gradient_direction = 3'd4;       // 157.5 to 202.5
                else if (abs_sum_gy <= gx_thresh_high) 
                    gradient_direction = 3'd3;       // 112.5 to 157.5
                else 
                    gradient_direction = 3'd2;       // 67.5 to 112.5
            end else begin
                // Quadrant 3 (gy < 0)
                if (abs_sum_gy <= gx_thresh_low) 
                    gradient_direction = 3'd4;       // 157.5 to 202.5
                else if (abs_sum_gy < gx_thresh_high) 
                    gradient_direction = 3'd5;       // 202.5 to 247.5
                else 
                    gradient_direction = 3'd6;       // 247.5 to 292.5
            end
        end else begin
            // Edge case where total_sum_gx == 0
            if (total_sum_gy > 0)
                gradient_direction = 3'd2;           // 67.5 to 112.5
            else if (total_sum_gy < 0)
                gradient_direction = 3'd6;           // 247.5 to 292.5
            else
                gradient_direction = 3'd0;           // default (0,0)
        end
    end

    // -------------------------------------------------------------------------
    // Output Registering
    // -------------------------------------------------------------------------
    
    reg [31:0] out_pixel_count = 0;
    
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_axis_gx_tdata  <= 0;
            m_axis_gx_tvalid <= 0;
            m_axis_gy_tdata  <= 0;
            m_axis_gy_tvalid <= 0;
            m_axis_tdata     <= 0;
            m_axis_tvalid    <= 0;
        end else begin
            if (col2_gx_valid && boundary_mask) begin
                m_axis_gx_tdata  <= (abs_sum_gx > 255) ? 8'd255 : abs_sum_gx[7:0]; 
                m_axis_gy_tdata  <= (abs_sum_gy > 255) ? 8'd255 : abs_sum_gy[7:0]; 
                m_axis_tdata     <= {gradient_direction, (combined_magnitude > 255) ? 12'd255 : combined_magnitude};
                
                m_axis_gx_tvalid <= 1'b1;
                m_axis_gy_tvalid <= 1'b1;
                m_axis_tvalid    <= 1'b1;
                
                out_pixel_count <= out_pixel_count + 1;
                if (out_pixel_count == TOTAL_PIXELS - 1)
                    m_axis_tlast <= 1'b1;
            end else begin
                m_axis_gx_tvalid <= 1'b0;
                m_axis_gy_tvalid <= 1'b0;
                m_axis_tvalid    <= 1'b0;
                
                m_axis_tlast <= 1'b0;
            end
        end
    end

endmodule