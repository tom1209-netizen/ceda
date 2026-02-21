`timescale 1ns / 1ps

module ceda_top #(
    parameter IMG_WIDTH  = 1920,
    parameter IMG_HEIGHT = 1080
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream Input (8-bit grayscale image)
    input  wire [7:0]  s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,
    input  wire        s_tuser,

    // AXI-Stream Output (15-bit gradient magnitude & direction)
    output wire [7:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire        m_tuser
);

    // Internal AXI-Stream connections between Gaussian and Sobel
    wire [7:0] gaus_sobel_tdata;
    wire       gaus_sobel_tvalid;
    wire       gaus_sobel_tready;
    wire       gaus_sobel_tlast;
    wire       gaus_sobel_tuser;
    
    wire [15:0] sobel_nms_tdata;
    wire        sobel_nms_tvalid;
    wire        sobel_nms_tready;
    wire        sobel_nms_tlast;
    wire        sobel_nms_tuser;
    wire        sobel_nms_teof;

    // Stage 1: Gaussian Blur
    gaussian_stage #(
        .PIXEL_WIDTH(8),
        .IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) u_gaussian (
        .clk(clk),
        .rst_n(rst_n),
        .s_tdata(s_tdata),
        .s_tvalid(s_tvalid),
        .s_tready(s_tready),
        .s_tlast(s_tlast),
        .s_tuser(s_tuser),
        
        .m_tdata(gaus_sobel_tdata),
        .m_tvalid(gaus_sobel_tvalid),
        .m_tready(gaus_sobel_tready),
        .m_tlast(gaus_sobel_tlast),
        .m_tuser(gaus_sobel_tuser)
    );

    // Stage 2: Sobel Filter & Magnitude/Direction Calculation
    sobel_stage #(
        .IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) u_sobel (
        .clk(clk),
        .resetn(rst_n), // Note: Sobel uses 'resetn' instead of 'rst_n'
        .s_axis_tdata(gaus_sobel_tdata),
        .s_axis_tvalid(gaus_sobel_tvalid),
        .s_axis_tready(gaus_sobel_tready),
        .s_axis_tlast(gaus_sobel_tlast),
        .s_axis_tuser(gaus_sobel_tuser),
        
        .m_axis_tdata(sobel_nms_tdata),
        .m_axis_tvalid(sobel_nms_tvalid),
        .m_axis_tready(sobel_nms_tready),
        .m_axis_tlast(sobel_nms_tlast),
        .m_axis_tuser(sobel_nms_tuser),
        .m_axis_teof(sobel_nms_teof)
    );
    
    nms_stage #(
        .IMG_WIDTH(IMG_WIDTH),
        .DATA_WIDTH(12),
        .DIR_WIDTH(3)
    ) u_nms (
       .clk(clk),
        .rst_n(rst_n),
        .s_tdata(sobel_nms_tdata),
        .s_tvalid(sobel_nms_tvalid),
        .s_tready(sobel_nms_tready),
        .s_tlast(sobel_nms_tlast),
        .s_tuser(sobel_nms_tuser),
        .s_teof(sobel_nms_teof),
        
        .m_tdata(m_tdata),
        .m_tvalid(m_tvalid),
        .m_tready(m_tready),
        .m_tlast(m_tlast),
        .m_tuser(m_tuser)
    );    

endmodule
