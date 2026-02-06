import numpy as np
from scipy import ndimage


# 5x5 Gaussian kernel (sigma ~ 1.0, sum = 256)
GAUSSIAN_KERNEL = np.array([
    [1,  4,  6,  4, 1],
    [4, 16, 24, 16, 4],
    [6, 24, 36, 24, 6],
    [4, 16, 24, 16, 4],
    [1,  4,  6,  4, 1]
], dtype=np.int32)


def gaussian_filter_ref(image: np.ndarray, use_rounding: bool = True) -> np.ndarray:
    """
    Reference Gaussian filter implementation matching hardware behavior.
    
    Args:
        image: Input grayscale image (uint8)
        use_rounding: If True, use (sum + 128) >> 8; else just >> 8
        
    Returns:
        Filtered image (uint8)
    """
    # Ensure input is int32 to prevent overflow
    img = image.astype(np.int32)
    
    # Apply convolution with replicate border (constant mode uses nearest)
    result = ndimage.convolve(img, GAUSSIAN_KERNEL, mode='nearest')
    
    # Normalize with rounding
    if use_rounding:
        result = (result + 128) >> 8
    else:
        result = result >> 8
    
    # Clip to uint8 range
    result = np.clip(result, 0, 255).astype(np.uint8)
    
    return result


def gaussian_single_window(window: np.ndarray, use_rounding: bool = True) -> int:
    """
    Compute Gaussian filter output for a single 5x5 window.
    
    Args:
        window: 5x5 numpy array of pixel values
        use_rounding: If True, use rounding normalization
        
    Returns:
        Filtered pixel value (0-255)
    """
    assert window.shape == (5, 5), "Window must be 5x5"
    
    # Compute weighted sum
    total = np.sum(window.astype(np.int32) * GAUSSIAN_KERNEL)
    
    # Normalize with rounding
    if use_rounding:
        result = (total + 128) >> 8
    else:
        result = total >> 8
    
    # Clip to uint8 range
    return int(np.clip(result, 0, 255))


def pe_ref(pixel: int, coeff: int) -> int:
    """
    Reference PE (Processing Element) computation.
    
    Args:
        pixel: 8-bit pixel value (0-255)
        coeff: 8-bit coefficient value (0-255)
        
    Returns:
        16-bit product
    """
    return pixel * coeff


def generate_test_image(width: int, height: int, pattern: str = 'random') -> np.ndarray:
    """
    Generate test images for verification.
    
    Args:
        width: Image width
        height: Image height
        pattern: 'random', 'gradient', 'checkerboard', 'uniform'
        
    Returns:
        Test image as uint8 numpy array
    """
    if pattern == 'random':
        return np.random.randint(0, 256, (height, width), dtype=np.uint8)
    elif pattern == 'gradient':
        row = np.linspace(0, 255, width, dtype=np.uint8)
        return np.tile(row, (height, 1))
    elif pattern == 'checkerboard':
        img = np.zeros((height, width), dtype=np.uint8)
        img[::2, ::2] = 255
        img[1::2, 1::2] = 255
        return img
    elif pattern == 'uniform':
        return np.full((height, width), 128, dtype=np.uint8)
    else:
        raise ValueError(f"Unknown pattern: {pattern}")
