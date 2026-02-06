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
    // Parameters
    localparam KERNEL_SIZE = 5;
    localparam HALF_KERNEL = 2;

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

    // Pipeline Enable
    wire pipeline_enable = s_tvalid & m_tready;
    assign s_tready = m_tready;

    // Position Counters
    reg [ADDR_WIDTH-1:0] out_col;
    reg [LINE_CNT_WIDTH-1:0] out_row;
    reg frame_active;
    // Must be wide enough for a full 1920x1080 frame; 16 bits will overflow.
    reg [31:0] pixel_cnt;

    wire col_last = (out_col == IMG_WIDTH - 1);
    wire row_last = (out_row == IMG_HEIGHT - 1);

    // Border replication is based on the (x,y) coordinate of the output pixel. With the
    // window generator updating on the negative edge, the first output pixel of a new
    // line is computed while the counters are still at the previous line's last column.
    // Use a wrap-adjusted view for border decisions.
    wire advance_xy = pipeline_enable & frame_active & (pixel_cnt >= TOTAL_FILL);
    wire [ADDR_WIDTH-1:0] out_col_sel =
        advance_xy ? (col_last ? {ADDR_WIDTH{1'b0}} : (out_col + 1'b1)) : out_col;
    wire [LINE_CNT_WIDTH-1:0] out_row_sel =
        advance_xy
            ? (col_last ? (row_last ? out_row : (out_row + 1'b1)) : out_row)
            : out_row;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_col      <= {ADDR_WIDTH{1'b0}};
            out_row      <= {LINE_CNT_WIDTH{1'b0}};
            frame_active <= 1'b0;
            pixel_cnt    <= 32'd0;
        end else if (pipeline_enable) begin
            if (s_tuser) begin
                out_col      <= {ADDR_WIDTH{1'b0}};
                out_row      <= {LINE_CNT_WIDTH{1'b0}};
                frame_active <= 1'b1;
                pixel_cnt    <= 32'd0;
            end else if (frame_active) begin
                pixel_cnt <= pixel_cnt + 1'b1;
                if (pixel_cnt >= TOTAL_FILL) begin
                    if (col_last) begin
                        out_col <= {ADDR_WIDTH{1'b0}};
                        if (row_last) frame_active <= 1'b0;
                        else out_row <= out_row + 1'b1;
                    end else begin
                        out_col <= out_col + 1'b1;
                    end
                end
            end
        end
    end

    // Row Buffer (5-tap vertical line buffer)
    wire [PIXEL_WIDTH-1:0] rb_row_0, rb_row_1, rb_row_2, rb_row_3, rb_row_4;

    row_buffer_5 #(
        .DATA_WIDTH(PIXEL_WIDTH),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_row_buf (
        .clk(clk),
        .rst_n(rst_n),
        .enable(pipeline_enable),
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

    // Border replication (clamp-to-edge) for ROWS only.
    // Horizontal clamping is not supported in streaming Sequential PE mode;
    // we process the stream as-is.
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
    integer kr;

    // Select correct row based on clamping
    always @(*) begin
        for (kr = 0; kr < 5; kr = kr + 1) begin
            // Logic: out_row_sel points to the center line of the window.
            // The win_idx_row function computes the *relative* index (0..4) into the window.
            // row_buffer output 0 is oldest, 4 is newest.
            // We map standard window index [0..4] to these.
            rep_col0[kr] = raw_rows[win_idx_row(out_row_sel, kr)];
        end
    end

    // Gaussian 5x5 Core
    wire [PIXEL_WIDTH-1:0] gauss_out;
    wire                   gauss_valid;

    gaussian_5x5_core #(
        .PIXEL_WIDTH(PIXEL_WIDTH)
    ) u_gauss_core (
        .clk(clk),
        .rst_n(rst_n),
        .enable(pipeline_enable),

        .win_row_0(rep_col0[0]),
        .win_row_1(rep_col0[1]),
        .win_row_2(rep_col0[2]),
        .win_row_3(rep_col0[3]),
        .win_row_4(rep_col0[4]),

        .pixel_out(gauss_out),
        .valid_out(gauss_valid)
    );

    // Valid Signal Generation (window-valid) + metadata pipelining to match gaussian_5x5_core latency.
    // gaussian_5x5_core output is pipelined; keep output metadata aligned.
    localparam CORE_LATENCY = 6;

    reg [CORE_LATENCY-1:0] valid_pipe;
    reg [ADDR_WIDTH-1:0] col_pipe[0:CORE_LATENCY-1];
    reg [LINE_CNT_WIDTH-1:0] row_pipe[0:CORE_LATENCY-1];
    integer p;

    wire window_valid_this = frame_active & pipeline_enable & ~(s_tuser) & (pixel_cnt >= TOTAL_FILL);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= {CORE_LATENCY{1'b0}};
            for (p = 0; p < CORE_LATENCY; p = p + 1) begin
                col_pipe[p] <= {ADDR_WIDTH{1'b0}};
                row_pipe[p] <= {LINE_CNT_WIDTH{1'b0}};
            end
        end else if (pipeline_enable) begin
            valid_pipe  <= {valid_pipe[CORE_LATENCY-2:0], window_valid_this};
            col_pipe[0] <= out_col_sel;
            row_pipe[0] <= out_row_sel;
            for (p = 1; p < CORE_LATENCY; p = p + 1) begin
                col_pipe[p] <= col_pipe[p-1];
                row_pipe[p] <= row_pipe[p-1];
            end
        end
    end

    wire [ADDR_WIDTH-1:0] out_col_m = col_pipe[CORE_LATENCY-1];
    wire [LINE_CNT_WIDTH-1:0] out_row_m = row_pipe[CORE_LATENCY-1];
    wire output_valid_m = valid_pipe[CORE_LATENCY-1];

    // Output Assignment
    assign m_tdata  = gauss_out;
    assign m_tvalid = output_valid_m & pipeline_enable;
    assign m_tlast  = m_tvalid & (out_col_m == IMG_WIDTH - 1);
    assign m_tuser  = m_tvalid & (out_col_m == 0) & (out_row_m == 0);

endmodule
