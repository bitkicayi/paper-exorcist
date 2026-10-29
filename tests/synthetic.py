"""Fake phone photos of paper, so the repository needs no binary fixtures."""
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def make_page(lines, size=(1240, 1754), font_size=34):
    page = Image.new("RGB", size, "white")
    draw = ImageDraw.Draw(page)
    font = ImageFont.truetype(FONT, font_size)
    for i, line in enumerate(lines):
        draw.text((90, 100 + i * round(font_size * 1.5)), line, fill="black", font=font)
    return page


def make_photo(path, lines, rotate=0, quality=90):
    """A tilted page on a dark table with a shadow falling from the left."""
    page = np.asarray(make_page(lines))
    h, w = page.shape[:2]
    table = np.full((2400, 1900, 3), (60, 45, 35), np.uint8)
    source = np.float32([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]])
    target = np.float32([[300, 250], [1550, 330], [1650, 2150], [200, 2050]])
    matrix = cv2.getPerspectiveTransform(source, target)
    warped = cv2.warpPerspective(page, matrix, (1900, 2400))
    mask = cv2.warpPerspective(np.full((h, w), 255, np.uint8), matrix, (1900, 2400))
    table[mask > 0] = warped[mask > 0]
    shade = np.tile(np.linspace(0.55, 1, 1900), (2400, 1))[..., None]
    photo = Image.fromarray((table * shade).astype(np.uint8))
    if rotate:
        # Pillow rotates counter-clockwise; this mimics a phone held sideways.
        photo = photo.rotate(-rotate, expand=True)
    photo.save(path, quality=quality)
    return path
