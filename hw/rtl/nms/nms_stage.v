module nms_stage #(
    parameter DATA_WIDTH = 12,
    parameter DIR_WIDTH  = 3,
    parameter IMG_WIDTH  = 1920
) (
    input wire clk,
    input wire rst_n,

    // AXI-Stream Input (Packed: {Dir[2:0], Mag[11:0]})
    input  wire [15:0] s_tdata,
    input  wire        s_tvalid,
    input  wire        s_tuser,
    input  wire        s_tlast,
    output wire        s_tready,
    input  wire        s_teof,

    // AXI-Stream Output
    output reg  [7:0] m_tdata,
    output reg        m_tvalid,
    output reg        m_tuser,
    output reg        m_tlast,
    input  wire       m_tready
);

    // =========================================================================
    // Datapath Inputs
    // =========================================================================
    wire [DATA_WIDTH-1:0] mag_in = s_tdata[DATA_WIDTH-1:0];
    wire [DIR_WIDTH-1:0] dir_in = s_tdata[14:12];

    // =========================================================================
    // Control Path
    // =========================================================================
    // Backpressure / step-enable control
    reg flush_active;
    reg frame_active;
    reg [31:0] pending_count;

    wire input_accept;
    wire output_accept;
    wire flush_start;
    wire enable;
    
    reg s_teof_prev;
    
    always @(posedge clk)
    begin
        s_teof_prev <= s_teof;
    end

    // Do not accept new input while draining tail beats of the current frame.
    assign flush_start = ~flush_active & frame_active & ~s_tvalid & s_teof_prev & (pending_count != 0);
    assign s_tready = m_tready & ~(flush_active | flush_start);
    assign input_accept = s_tvalid & s_tready;
    assign output_accept = m_tvalid & m_tready;
    // Advance datapath either on real input or on flush padding beats.
    assign enable = m_tready & (input_accept | flush_active | flush_start);

    wire [DATA_WIDTH-1:0] mag_in_step = input_accept ? mag_in : {DATA_WIDTH{1'b0}};
    wire [DIR_WIDTH-1:0] dir_in_step = input_accept ? dir_in : {DIR_WIDTH{1'b0}};
    wire user_in_step = input_accept & s_tuser;
    wire last_in_step = input_accept & s_tlast;
    wire valid_in_step = input_accept;

    // =========================================================================
    // Datapath: 3x3 Window Generation
    // =========================================================================
    // Line Buffering for Magnitude
    wire [DATA_WIDTH-1:0] row_0, row_1, row_2;

    row_buffer_3 #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_mag_buf (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .pixel_in(mag_in_step),
        .row_0(row_0),
        .row_1(row_1),
        .row_2(row_2)
    );

    // Direction Delay (Line Buffer)
    wire [DIR_WIDTH-1:0] dir_delayed_line;

    line_buffer #(
        .DATA_WIDTH(DIR_WIDTH),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_dir_lb (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(dir_in_step),
        .data_out(dir_delayed_line)
    );

    // Window Formation
    reg [DATA_WIDTH-1:0] w00, w01, w02;
    reg [DATA_WIDTH-1:0] w10, w11, w12;
    reg [DATA_WIDTH-1:0] w20, w21, w22;

    reg [DIR_WIDTH-1:0] dir_window[0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w00 <= 0;
            w01 <= 0;
            w02 <= 0;
            w10 <= 0;
            w11 <= 0;
            w12 <= 0;
            w20 <= 0;
            w21 <= 0;
            w22 <= 0;
            dir_window[0] <= 0;
            dir_window[1] <= 0;
            dir_window[2] <= 0;
        end else if (enable) begin
            // Shift right
            w02 <= w01;
            w01 <= w00;
            w00 <= row_0;
            w12 <= w11;
            w11 <= w10;
            w10 <= row_1;
            w22 <= w21;
            w21 <= w20;
            w20 <= row_2;

            // Delay direction to match w11
            dir_window[0] <= dir_delayed_line;
            dir_window[1] <= dir_window[0];
            // dir_window[2] <= dir_window[1];
        end
    end

    // =========================================================================
    // Datapath: NMS Core Compute
    // =========================================================================
    // Core Logic
    wire [7:0] nms_out;
    nms_core u_core (
        .mag_00(w02),
        .mag_01(w01),
        .mag_02(w00),
        .mag_10(w12),
        .mag_11(w11),
        .mag_12(w10),
        .mag_20(w22),
        .mag_21(w21),
        .mag_22(w20),
        .direction(dir_window[1]),
        .out_val(nms_out)
    );

    // =========================================================================
    // Datapath: Sideband Alignment
    // =========================================================================
    // Control Signal Delay
    wire u_out, l_out;
    line_buffer #(
        .DATA_WIDTH(1),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_lb_user (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(user_in_step),
        .data_out(u_out)
    );
    line_buffer #(
        .DATA_WIDTH(1),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_lb_last (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(last_in_step),
        .data_out(l_out)
    );

    wire v_out_lb;
    line_buffer #(
        .DATA_WIDTH(1),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_lb_valid (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(valid_in_step),
        .data_out(v_out_lb)
    );

    // =========================================================================
    // Control Path: Priming and Tail Drain
    // =========================================================================
    // Frame priming state:
    // - seen_first_line rises once first input line has completed.
    // - stream_primed rises once first line plus one extra pixel is accepted.
    // This replaces counter-based warmup masking.
    reg [11:0] in_col;
    reg seen_first_line;
    reg stream_primed;
    // Assert primed on the first accepted beat after line 0 has completed.
    wire first_line_plus_one = seen_first_line & (in_col == 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_col          <= 0;
            seen_first_line <= 1'b0;
            stream_primed   <= 1'b0;
        end else if (input_accept) begin
            if (s_tuser) begin
                in_col          <= 0;
                seen_first_line <= 1'b0;
                stream_primed   <= 1'b0;
            end else begin
                if (s_tlast) begin
                    in_col <= 0;
                    seen_first_line <= 1'b1;
                end else begin
                    in_col <= in_col + 1'b1;
                end
                if (first_line_plus_one) begin
                    stream_primed <= 1'b1;
                end
            end
        end
    end

    // Event-driven tail drain:
    // - Track how many input beats have been accepted but not yet emitted.
    // - When source goes idle and pending beats remain, inject zero-pad beats
    //   until pending_count drains to zero.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_active  <= 1'b0;
            flush_active  <= 1'b0;
            pending_count <= 32'd0;
        end else begin
            if (input_accept && s_tuser) begin
                frame_active  <= 1'b1;
                flush_active  <= 1'b0;
                pending_count <= 32'd1;
            end else begin
                case ({
                    input_accept, output_accept
                })
                    2'b10: pending_count <= pending_count + 1'b1;
                    2'b01: begin
                        if (pending_count != 0) begin
                            pending_count <= pending_count - 1'b1;
                        end
                    end
                    default: begin
                    end
                endcase

                if (!flush_active && flush_start) begin
                    flush_active <= 1'b1;
                end else if (
                    flush_active &&
                    ((pending_count == 0) || ((pending_count == 1) && output_accept && !input_accept))
                ) begin
                    flush_active <= 1'b0;
                    frame_active <= 1'b0;
                end
            end
        end
    end

    wire v_out_masked = stream_primed ? v_out_lb : 1'b0;

    // =========================================================================
    // Datapath: Output Register Stage
    // =========================================================================
    // Output Pipeline
    reg [1:0] u_pipe, l_pipe, v_pipe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_pipe   <= 0;
            l_pipe   <= 0;
            v_pipe   <= 0;
            m_tvalid <= 0;
            m_tdata  <= 0;
            m_tuser  <= 0;
            m_tlast  <= 0;
        end else if (enable) begin
            // Shift pipe
            u_pipe   <= {u_pipe[0], u_out};
            l_pipe   <= {l_pipe[0], l_out};
            v_pipe   <= {v_pipe[0], v_out_masked};

            // Output assignments
            m_tdata  <= nms_out;
            m_tvalid <= v_pipe[1];
            m_tuser  <= v_pipe[1] & u_pipe[1];
            m_tlast  <= v_pipe[1] & l_pipe[1];
        end else if (m_tready) begin
            // No accepted input this cycle: clear output-valid sideband so
            // stale values do not repeat when source goes idle.
            m_tvalid <= 1'b0;
            m_tuser  <= 1'b0;
            m_tlast  <= 1'b0;
        end
    end

endmodule
