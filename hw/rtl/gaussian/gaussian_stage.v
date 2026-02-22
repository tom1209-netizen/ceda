`timescale 1ns / 1ns

module gaussian_stage #(
    parameter IMG_WIDTH  = 1920,
    parameter IMG_HEIGHT = 1080
) (
    input wire clk,
    input wire rst_n,

    // Input Stream
    input  wire [7:0] s_tdata,
    input  wire       s_tvalid,
    output wire       s_tready,
    input  wire       s_tlast,
    input  wire       s_tuser,

    // Outputs
    output reg  [7:0] m_tdata,
    output reg        m_tvalid,
    input  wire       m_tready,
    output reg        m_tlast,
    output reg        m_tuser
);

    wire downstream_ready;
    assign downstream_ready = m_tready;

    reg input_paused;
    reg flush_active;

    assign s_tready = downstream_ready && !input_paused && !flush_active;

    wire [7:0] lb_row0, lb_row1, lb_row2, lb_row3, lb_row4;
    wire lb_std_valid;

    wire lb_write_en = (s_tvalid && s_tready) || 
                       (flush_active && downstream_ready && !input_paused);

    line_buffer_5 #(
        .DATA_WIDTH(8),
        .IMG_WIDTH (IMG_WIDTH)
    ) lb_inst (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(lb_write_en),
        .din(flush_active ? 8'd0 : s_tdata),

        // 0 is oldest, 4 is newest
        .dout0(lb_row0),
        .dout1(lb_row1),
        .dout2(lb_row2),
        .dout3(lb_row3),
        .dout4(lb_row4),

        .line_buffer_valid(lb_std_valid)
    );

    localparam TOTAL_PIXELS = IMG_HEIGHT * IMG_WIDTH;
    localparam S_PAD_LEFT_CROSSLINE = 0;
    localparam S_PAD_LEFT_2 = 1;
    localparam S_PAD_LEFT_1 = 2;
    localparam S_ACTIVE = 3;
    localparam S_PAD_RIGHT_1 = 4;
    localparam S_PAD_RIGHT_2 = 5;
    localparam S_PAD_RIGHT_3 = 6;
    localparam S_PAD_RIGHT_4 = 7;

    reg [2:0] h_state;
    reg [11:0] h_cnt;
    reg [31:0] global_pixel_cnt;
    reg warmup_done;
    reg [11:0] y_cnt;

    // We consider warmup_done when we have filled exactly 2 lines minus 1 pixel
    wire start_condition = warmup_done && ((s_tvalid && s_tready) || flush_active || h_state != S_ACTIVE);
    wire compute_pulse = start_condition && downstream_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_pixel_cnt <= 0;
            warmup_done      <= 0;
            flush_active     <= 0;
        end else begin
            if (s_tvalid && s_tready) begin
                global_pixel_cnt <= global_pixel_cnt + 1;
                if (global_pixel_cnt == (2 * IMG_WIDTH) - 1) begin
                    warmup_done <= 1'b1;
                end
            end
            if (global_pixel_cnt == TOTAL_PIXELS && !flush_active) begin
                flush_active <= 1'b1;
            end
            if (flush_active && h_state == S_PAD_RIGHT_4 && y_cnt == IMG_HEIGHT - 1 && compute_pulse) begin
                flush_active <= 1'b0;
                warmup_done <= 1'b0;  // Reset for next frame
                global_pixel_cnt <= 0;
            end
        end
    end

    // FSM State Tracking
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_state      <= S_PAD_LEFT_CROSSLINE;
            h_cnt        <= 0;
            input_paused <= 1'b0;
        end else begin

            // Once frame is completely drained, re-arm FSM zero state
            if (flush_active && h_state == S_PAD_RIGHT_4 && y_cnt == IMG_HEIGHT - 1 && compute_pulse) begin
                h_state <= S_PAD_LEFT_CROSSLINE;
                h_cnt <= 0;
                input_paused <= 1'b0;
            end else if (warmup_done && compute_pulse) begin
                case (h_state)
                    S_PAD_LEFT_CROSSLINE: begin
                        input_paused <= 1'b1;
                        h_state <= S_PAD_LEFT_2;
                        h_cnt <= 0;
                    end

                    S_PAD_LEFT_2: begin
                        input_paused <= 1'b1;
                        h_state      <= S_PAD_LEFT_1;
                        h_cnt        <= 0;
                    end

                    S_PAD_LEFT_1: begin
                        input_paused <= 1'b0;  // Unpause for next cycle (S_ACTIVE)
                        h_state      <= S_ACTIVE;
                        h_cnt        <= 0;
                    end

                    S_ACTIVE: begin
                        if (h_cnt == IMG_WIDTH - 2) begin
                            input_paused <= 1'b1;  // Pause for Right Pad_1
                            h_state      <= S_PAD_RIGHT_1;
                        end else begin
                            input_paused <= 1'b0;  // Keep streaming
                        end
                        h_cnt <= h_cnt + 1;
                    end

                    S_PAD_RIGHT_1: begin
                        input_paused <= 1'b1;  // Keep paused for Right Pad_2
                        h_state      <= S_PAD_RIGHT_2;
                        h_cnt        <= 0;
                    end

                    S_PAD_RIGHT_2: begin
                        input_paused <= 1'b1;  // Keep paused for Right Pad_3
                        h_state      <= S_PAD_RIGHT_3;
                        h_cnt        <= 0;
                    end

                    S_PAD_RIGHT_3: begin
                        input_paused <= 1'b1;  // Keep paused for Right Pad_4
                        h_state      <= S_PAD_RIGHT_4;
                        h_cnt        <= 0;
                    end

                    S_PAD_RIGHT_4: begin
                        input_paused <= 1'b0;  // Unpause for Left Pad CROSSLINE of next line
                        h_state      <= S_PAD_LEFT_CROSSLINE;
                        h_cnt        <= 0;
                    end
                endcase
            end
        end
    end

    // Y Counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_cnt <= 0;
        end else if (compute_pulse && h_state == S_PAD_RIGHT_4) begin
            if (y_cnt == IMG_HEIGHT - 1) y_cnt <= 0;
            else y_cnt <= y_cnt + 1;
        end
    end

    // Vertcal padding logic mapping
    wire [7:0] w_row0, w_row1, w_row2, w_row3, w_row4;

    assign w_row2 = lb_row2;

    // Top border padding
    // If y=0, w_row0 (-2) mirrors to 0 (lb_row2)
    // If y=1, w_row0 (-1) mirrors to 0 (lb_row1)
    assign w_row0 = (y_cnt == 0) ? lb_row2 : ((y_cnt == 1) ? lb_row1 : lb_row0);
    assign w_row1 = (y_cnt == 0) ? lb_row2 : lb_row1;

    // Bottom border padding
    // If y=IMG_HEIGHT-1, w_row4 (+2) mirrors to IMG_HEIGHT-1 (lb_row2)
    // If y=IMG_HEIGHT-2, w_row4 (+2) mirrors to IMG_HEIGHT-1 (lb_row3)
    assign w_row3 = (y_cnt == IMG_HEIGHT - 1) ? lb_row2 : lb_row3;
    assign w_row4 = (y_cnt == IMG_HEIGHT - 1) ? lb_row2 : ((y_cnt == IMG_HEIGHT - 2) ? lb_row3 : lb_row4);

    wire [7:0] core_out;
    wire       core_valid;

    gaussian_5x5_core #(
        .PIXEL_WIDTH(8)
    ) core_inst (
        .clk(clk),
        .rst_n(rst_n),
        .enable(downstream_ready),
        .valid_in(compute_pulse),

        .win_row_0(w_row0),
        .win_row_1(w_row1),
        .win_row_2(w_row2),
        .win_row_3(w_row3),
        .win_row_4(w_row4),

        .pixel_out(core_out),
        .valid_out(core_valid)
    );

    // -------------------------------------------------------------------------
    // Output Timing & Control
    // -------------------------------------------------------------------------
    reg  [31:0] out_pixel_count;
    reg  [11:0] compute_col;

    // The systolic array computes result exactly 4 cycles after S_PAD_LEFT_CROSSLINE.
    // Result is available in pixel_out on the next cycle.
    // This means valid pixels are generated starting when the NEXT compute_col is 5.
    wire [11:0] next_col = (h_state == S_PAD_LEFT_CROSSLINE) ? 12'd1 : compute_col + 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata         <= 0;
            m_tvalid        <= 0;
            m_tlast         <= 0;
            m_tuser         <= 0;
            compute_col     <= 0;
            out_pixel_count <= 0;
        end else if (downstream_ready) begin

            // 1) Track absolute compute cycle per row
            if (compute_pulse) begin
                if (h_state == S_PAD_LEFT_CROSSLINE) begin
                    compute_col <= 1;
                end else begin
                    compute_col <= compute_col + 1;
                end
            end

            // Update valid output states based on next_col
            // The systolic array computes result exactly 4 cycles after S_PAD_LEFT_CROSSLINE.
            // Result is available in pixel_out on the next cycle, and m_tdata intercepts it.
            // Mathematical trace proves x=0 is in core_out during compute_col=6.
            // Therefore we capture core_out at the end of compute_col=6 (next_col=7).
            if (compute_pulse) begin

                if (next_col >= 7 && next_col <= IMG_WIDTH + 6) begin
                    m_tdata  <= core_out;
                    m_tvalid <= 1'b1;
                    m_tlast  <= (next_col == IMG_WIDTH + 6) ? 1'b1 : 1'b0;
                    m_tuser  <= (out_pixel_count == 0) ? 1'b1 : 1'b0;

                    if (out_pixel_count == TOTAL_PIXELS - 1) begin
                        out_pixel_count <= 0;
                    end else begin
                        out_pixel_count <= out_pixel_count + 1;
                    end
                end else begin
                    m_tvalid <= 1'b0;
                    m_tlast  <= 1'b0;
                    m_tuser  <= 1'b0;
                end
            end

        end
    end

endmodule
