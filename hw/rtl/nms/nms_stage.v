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

    // AXI-Stream Output
    output reg  [7:0] m_tdata,
    output reg        m_tvalid,
    output reg        m_tuser,
    output reg        m_tlast,
    input  wire       m_tready
);

    wire [DATA_WIDTH-1:0] mag_in = s_tdata[DATA_WIDTH-1:0];
    wire [ DIR_WIDTH-1:0] dir_in = s_tdata[14:12];

    // Backpressure / Enable
    assign s_tready = m_tready;
    wire enable = s_tvalid & m_tready;

    // Line Buffering for Magnitude
    wire [DATA_WIDTH-1:0] row_0, row_1, row_2;

    row_buffer_3 #(
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_mag_buf (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .pixel_in(mag_in),
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
        .data_in(dir_in),
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

    // Control Signal Delay
    wire u_out, l_out;
    line_buffer #(
        .DATA_WIDTH(1),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_lb_user (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(s_tuser),
        .data_out(u_out)
    );
    line_buffer #(
        .DATA_WIDTH(1),
        .LINE_WIDTH(IMG_WIDTH)
    ) u_lb_last (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .data_in(s_tlast),
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
        .data_in(s_tvalid),
        .data_out(v_out_lb)
    );

    // Warmup Counter to mask undefined BRAM (X) output
    reg [11:0] warmup_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            warmup_cnt <= 0;
        end else if (enable) begin
            if (warmup_cnt < IMG_WIDTH + 1) begin
                warmup_cnt <= warmup_cnt + 1;
            end
        end
    end

    wire v_out_masked = (warmup_cnt >= IMG_WIDTH + 1) ? v_out_lb : 1'b0;

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
            m_tuser  <= u_pipe[1];
            m_tlast  <= l_pipe[1];
        end
    end

endmodule
