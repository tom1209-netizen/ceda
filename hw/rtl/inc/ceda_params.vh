`ifndef CEDA_PARAMS_VH
`define CEDA_PARAMS_VH

// Image dimensions
parameter IMG_WIDTH = 1920;
parameter IMG_HEIGHT = 1080;

// Pixel precision
parameter PIXEL_WIDTH = 8;
parameter COEFF_WIDTH = 8;
parameter PROD_WIDTH = 16;  // PIXEL_WIDTH + COEFF_WIDTH
parameter ACCUM_WIDTH = 24;  // Enough for sum of 25 products

// Gaussian kernel (5x5, sigma ~ 1.0, sum = 256)
// Stored as 1D array for easy indexing: kernel[row*5 + col]
// Row 0: 1  4  6  4  1
// Row 1: 4 16 24 16  4
// Row 2: 6 24 36 24  6
// Row 3: 4 16 24 16  4
// Row 4: 1  4  6  4  1

`endif  // CEDA_PARAMS_VH
