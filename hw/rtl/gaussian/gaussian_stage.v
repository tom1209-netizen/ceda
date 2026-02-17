`timescale 1ns / 1ns

module gaussian_stage #(
    parameter PIXEL_WIDTH = 8,
    parameter IMG_WIDTH   = 1920,
    parameter IMG_HEIGHT  = 1080
) (
    input wire clk,
    input wire rst_n,

    // AXI-Stream Input
    input  wire [PIXEL_WIDTH-1:0] s_tdata,
    input  wire                   s_tvalid,
    output wire                   s_tready,
    input  wire                   s_tlast,
    input  wire                   s_tuser,

    // AXI-Stream Output
    output wire [PIXEL_WIDTH-1:0] m_tdata,
    output wire                   m_tvalid,
    input  wire                   m_tready,
    output wire                   m_tlast,
    output wire                   m_tuser
);
    // =========================================================================
    // Configuration
    // =========================================================================
    localparam HALF_KERNEL = 2;
    localparam FRAME_PIXELS = IMG_WIDTH * IMG_HEIGHT;

    // Pipeline fill latency: 2 lines + 2 cycles (center tap alignment)
    localparam FILL_LINES = HALF_KERNEL;

    // Horizontal fill to align the 5x5 center tap (win_22) and the registered gaussian output
    // with the (x,y) pixel coordinate. window_5x5 center is delayed by HALF_KERNEL cycles, and
    // gaussian_5x5_core registers the output. The window generator aligns rows with small
    // per-row delay pipelines, which adds a few additional cycles before win_22 corresponds
    // to the (x,y) output pixel coordinate.
    localparam FILL_CYCLES = HALF_KERNEL + 3;
    localparam TOTAL_FILL = (FILL_LINES * IMG_WIDTH) + FILL_CYCLES;

    // Address width
    localparam ADDR_WIDTH = 12;
    localparam LINE_CNT_WIDTH = 11;

    // =========================================================================
    // Control Path
    // =========================================================================
    // NOTE: s_tlast is part of the AXI-Stream interface but this stage derives
    // line boundaries from in_col/out_col counters.
    wire _unused_s_tlast = s_tlast;

    // Input/Core enable split:
    // - input_accept: real input beat accepted from AXI stream
    // - core_enable : core advances on real beats OR synthetic pad beats
    wire input_accept;
    wire core_enable;
    wire [PIXEL_WIDTH-1:0] gauss_out;
    wire                   gauss_valid;
    reg  flush_active;

    // Horizontal padding state (for 5x5 kernel: 2 left pads + 2 right pads)
    localparam [2:0] H_PAD_NONE = 3'd0;
    localparam [2:0] H_PAD_L1 = 3'd1;
    localparam [2:0] H_PAD_L2 = 3'd2;
    localparam [2:0] H_PAD_R1 = 3'd3;
    localparam [2:0] H_PAD_R2 = 3'd4;

    reg [2:0] h_pad_state;
    reg [ADDR_WIDTH-1:0] in_col;

    wire h_pad_left = (h_pad_state == H_PAD_L1) || (h_pad_state == H_PAD_L2);
    wire h_pad_right = (h_pad_state == H_PAD_R1) || (h_pad_state == H_PAD_R2);
    wire h_pad_active = h_pad_left || h_pad_right;

    assign s_tready = m_tready & ~h_pad_active;
    assign input_accept = s_tvalid & s_tready;
    
    // Equivalent simplified form:
    // input_accept | (m_tready & h_pad_active)
    // = m_tready & (s_tvalid | h_pad_active)
    // Keep flush path additive.
    assign core_enable = m_tready & (s_tvalid | h_pad_active | flush_active);

    // Position Counters
    reg [ADDR_WIDTH-1:0] out_col;
    reg [LINE_CNT_WIDTH-1:0] out_row;
    reg frame_active;
    // Must be wide enough for a full 1920x1080 frame; 16 bits will overflow.
    reg [31:0] pixel_cnt;

    wire col_last = (out_col == IMG_WIDTH - 1);
    wire row_last = (out_row == IMG_HEIGHT - 1);

    wire col_first = (out_col == {ADDR_WIDTH{1'b0}});
    wire row_first = (out_row == {LINE_CNT_WIDTH{1'b0}});

    // Horizontal phase counter over core samples in a row.
    // With 2 left + 2 right pad samples, each row has IMG_WIDTH+4 core samples.
    // For 5-tap sequential PE, keep samples when phase >= 4 (drop first 4 samples),
    // resulting in exactly IMG_WIDTH output pixels per row.
    reg [ADDR_WIDTH:0] h_core_phase;
    wire h_phase_wrap = (h_core_phase == (IMG_WIDTH + 3));
    wire h_boundary_mask = (h_core_phase >= 4);

    // Emit one output-coordinate step per valid output pixel.
    wire emit_pulse = frame_active & core_enable & (pixel_cnt >= TOTAL_FILL) & h_boundary_mask;
    wire window_valid_this = emit_pulse & ~(s_tuser);

    // Metadata FIFO decouples stage control from fixed core latency.
    localparam META_FIFO_DEPTH = 16;
    localparam META_FIFO_AW = $clog2(META_FIFO_DEPTH);

    reg [META_FIFO_AW-1:0] meta_wr_ptr;
    reg [META_FIFO_AW-1:0] meta_rd_ptr;
    reg [META_FIFO_AW:0] meta_count;
    reg [2:0] meta_fifo[0:META_FIFO_DEPTH-1];
    reg m_tvalid_r;
    reg m_tlast_r;
    reg m_tuser_r;
    integer mf;

    wire meta_empty = (meta_count == 0);
    wire meta_full = (meta_count == META_FIFO_DEPTH);
    wire meta_pop_do = core_enable & gauss_valid & ~meta_empty;
    wire meta_push_do = core_enable & window_valid_this & (~meta_full | meta_pop_do);
    wire [2:0] meta_out = meta_fifo[meta_rd_ptr];
    wire meta_out_tlast = meta_out[0];
    wire meta_out_tuser = meta_out[1];
    wire meta_out_eof = meta_out[2];
    wire meta_pop_eof = meta_pop_do & meta_out_eof;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_col      <= {ADDR_WIDTH{1'b0}};
            out_row      <= {LINE_CNT_WIDTH{1'b0}};
            frame_active <= 1'b0;
            pixel_cnt    <= 32'd0;
            in_col       <= {ADDR_WIDTH{1'b0}};
            h_pad_state  <= H_PAD_NONE;
            h_core_phase <= {(ADDR_WIDTH + 1) {1'b0}};
            flush_active <= 1'b0;
        end else begin
            if (input_accept && s_tuser) begin
                out_col      <= {ADDR_WIDTH{1'b0}};
                out_row      <= {LINE_CNT_WIDTH{1'b0}};
                frame_active <= 1'b1;
                // Count this accepted SOF beat as column 0 so in_col advances
                // to column 1 for the next incoming beat.
                pixel_cnt    <= 32'd1;
                in_col       <= {{(ADDR_WIDTH - 1) {1'b0}}, 1'b1};
                h_pad_state  <= H_PAD_L1;
                h_core_phase <= {{ADDR_WIDTH{1'b0}}, 1'b1};
                flush_active <= 1'b0;
            end else begin
                if (frame_active) begin
                    if (input_accept) begin
                        pixel_cnt <= pixel_cnt + 1'b1;
                        if (in_col == IMG_WIDTH - 1) in_col <= {ADDR_WIDTH{1'b0}};
                        else in_col <= in_col + 1'b1;
                    end

                    if (core_enable) begin
                        if (h_phase_wrap) h_core_phase <= {(ADDR_WIDTH + 1) {1'b0}};
                        else h_core_phase <= h_core_phase + 1'b1;
                    end

                    if (emit_pulse) begin
                        if (col_last) begin
                            out_col <= {ADDR_WIDTH{1'b0}};
                            if (row_last) frame_active <= 1'b0;
                            else out_row <= out_row + 1'b1;
                        end else begin
                            out_col <= out_col + 1'b1;
                        end
                    end

                    // Horizontal pad insertion
                    if (input_accept) begin
                        if (in_col == 0) h_pad_state <= H_PAD_L1;
                        else if (in_col == IMG_WIDTH - 1) h_pad_state <= H_PAD_R1;
                    end else if (m_tready) begin
                        case (h_pad_state)
                            H_PAD_L1: h_pad_state <= H_PAD_L2;
                            H_PAD_L2: h_pad_state <= H_PAD_NONE;
                            H_PAD_R1: h_pad_state <= H_PAD_R2;
                            H_PAD_R2: h_pad_state <= H_PAD_NONE;
                            default:  h_pad_state <= H_PAD_NONE;
                        endcase
                    end
                end

                // Tail drain:
                // Start once all frame input has been accepted and upstream goes idle.
                // Keep running until an internal EOF marker reaches the output-aligned pipe.
                if (!flush_active && frame_active &&
                    (pixel_cnt >= FRAME_PIXELS) && !s_tvalid && !input_accept) begin
                    flush_active <= 1'b1;
                end else if (flush_active && meta_pop_eof) begin
                    flush_active <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // Datapath
    // =========================================================================
    // Row Buffer (5-tap vertical line buffer)
    wire [PIXEL_WIDTH-1:0] rb_row_0, rb_row_1, rb_row_2, rb_row_3, rb_row_4;

    row_buffer_5 #(
        .DATA_WIDTH(PIXEL_WIDTH),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_row_buf (
        .clk(clk),
        .rst_n(rst_n),
        .enable(input_accept),
        .pixel_in(s_tdata),
        .row_0(rb_row_0),
        .row_1(rb_row_1),
        .row_2(rb_row_2),
        .row_3(rb_row_3),
        .row_4(rb_row_4)
    );

    // Map outputs to array for easy indexing
    wire [PIXEL_WIDTH-1:0] raw_rows[0:4];
    assign raw_rows[0] = rb_row_0;
    assign raw_rows[1] = rb_row_1;
    assign raw_rows[2] = rb_row_2;
    assign raw_rows[3] = rb_row_3;
    assign raw_rows[4] = rb_row_4;

    // Border replication (clamp-to-edge) for ROWS.
    // Horizontal clamp is handled by pad-state insertion (left/right replication).
    function automatic [2:0] win_idx_row(input [LINE_CNT_WIDTH-1:0] y, input integer kr);
        integer signed y_i;
        integer signed pos;
        integer signed clamped;
        begin
            y_i = y;
            pos = y_i + (kr - HALF_KERNEL);
            if (pos < 0) clamped = 0;
            else if (pos > (IMG_HEIGHT - 1)) clamped = IMG_HEIGHT - 1;
            else clamped = pos;
            win_idx_row = clamped - y_i + HALF_KERNEL;
        end
    endfunction

    reg [PIXEL_WIDTH-1:0] rep_col0[0:4];
    reg [PIXEL_WIDTH-1:0] pad_left_col0[0:4];
    reg [PIXEL_WIDTH-1:0] pad_right_col0[0:4];
    wire [PIXEL_WIDTH-1:0] core_col0[0:4];
    integer kr;

    // Select correct row based on clamping
    always @(*) begin
        for (kr = 0; kr < 5; kr = kr + 1) begin
            // Logic: out_row_sel points to the center line of the window.
            // The win_idx_row function computes the *relative* index (0..4) into the window.
            // row_buffer output 0 is oldest, 4 is newest.
            // We map standard window index [0..4] to these.
            rep_col0[kr] = raw_rows[win_idx_row(out_row, kr)];
        end
    end

    // Latch row samples for horizontal left/right clamp replication.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (kr = 0; kr < 5; kr = kr + 1) begin
                pad_left_col0[kr]  <= {PIXEL_WIDTH{1'b0}};
                pad_right_col0[kr] <= {PIXEL_WIDTH{1'b0}};
            end
        end else if (input_accept) begin
            if (in_col == 0) begin
                for (kr = 0; kr < 5; kr = kr + 1) begin
                    pad_left_col0[kr] <= rep_col0[kr];
                end
            end
            for (kr = 0; kr < 5; kr = kr + 1) begin
                pad_right_col0[kr] <= rep_col0[kr];
            end
        end
    end

    assign core_col0[0] = h_pad_left ? pad_left_col0[0] : (h_pad_right ? pad_right_col0[0] : rep_col0[0]);
    assign core_col0[1] = h_pad_left ? pad_left_col0[1] : (h_pad_right ? pad_right_col0[1] : rep_col0[1]);
    assign core_col0[2] = h_pad_left ? pad_left_col0[2] : (h_pad_right ? pad_right_col0[2] : rep_col0[2]);
    assign core_col0[3] = h_pad_left ? pad_left_col0[3] : (h_pad_right ? pad_right_col0[3] : rep_col0[3]);
    assign core_col0[4] = h_pad_left ? pad_left_col0[4] : (h_pad_right ? pad_right_col0[4] : rep_col0[4]);

    // Gaussian 5x5 core
    gaussian_5x5_core #(
        .PIXEL_WIDTH(PIXEL_WIDTH)
    ) u_gauss_core (
        .clk(clk),
        .rst_n(rst_n),
        .enable(core_enable),
        .valid_in(window_valid_this),

        .win_row_0(core_col0[0]),
        .win_row_1(core_col0[1]),
        .win_row_2(core_col0[2]),
        .win_row_3(core_col0[3]),
        .win_row_4(core_col0[4]),

        .pixel_out(gauss_out),
        .valid_out(gauss_valid)
    );

    // Metadata pipeline (event-driven):
    // - push one sideband entry for every valid window launch
    // - pop one sideband entry for every valid core output
    // This keeps output control aligned without stage-side fixed latency constants.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_wr_ptr <= {META_FIFO_AW{1'b0}};
            meta_rd_ptr <= {META_FIFO_AW{1'b0}};
            meta_count  <= {(META_FIFO_AW + 1) {1'b0}};
            m_tvalid_r  <= 1'b0;
            m_tlast_r   <= 1'b0;
            m_tuser_r   <= 1'b0;
            for (mf = 0; mf < META_FIFO_DEPTH; mf = mf + 1) begin
                meta_fifo[mf] <= 3'b000;
            end
        end else if (core_enable) begin
            if (meta_pop_do) begin
                m_tvalid_r <= 1'b1;
                m_tlast_r  <= meta_out_tlast;
                m_tuser_r  <= meta_out_tuser;
            end else begin
                m_tvalid_r <= 1'b0;
                m_tlast_r  <= 1'b0;
                m_tuser_r  <= 1'b0;
            end

            if (meta_push_do) begin
                meta_fifo[meta_wr_ptr] <= {col_last & row_last, col_first & row_first, col_last};
            end

            case ({
                meta_push_do, meta_pop_do
            })
                2'b10: begin
                    meta_wr_ptr <= meta_wr_ptr + 1'b1;
                    meta_count  <= meta_count + 1'b1;
                end
                2'b01: begin
                    meta_rd_ptr <= meta_rd_ptr + 1'b1;
                    meta_count  <= meta_count - 1'b1;
                end
                2'b11: begin
                    meta_wr_ptr <= meta_wr_ptr + 1'b1;
                    meta_rd_ptr <= meta_rd_ptr + 1'b1;
                end
                default: begin
                end
            endcase
        end
    end

    // Output Assignment
    assign m_tdata  = gauss_out;
    assign m_tvalid = m_tvalid_r;
    assign m_tlast  = m_tvalid_r & m_tlast_r;
    assign m_tuser  = m_tvalid_r & m_tuser_r;

endmodule
