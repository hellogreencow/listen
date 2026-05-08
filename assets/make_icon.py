"""Generate app icon for Listen."""

from PIL import Image, ImageDraw

# Create a 1024x1024 icon with a gradient circle and microphone symbol
size = 1024
img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Gradient background circle
for y in range(size):
    ratio = y / size
    r = int(30 + ratio * 80)
    g = int(30 + ratio * 40)
    b = int(60 + ratio * 100)
    draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

# Mask to circle
mask = Image.new("L", (size, size), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.ellipse((4, 4, size-4, size-4), fill=255)
img.putalpha(mask)

draw = ImageDraw.Draw(img)

# Microphone body (rounded rectangle)
cx, cy = size // 2, size // 2
body_w, body_h = 180, 280
body_left = cx - body_w // 2
body_top = cy - body_h // 2 - 40
body_right = body_left + body_w
body_bottom = body_top + body_h
draw.rounded_rectangle(
    [body_left, body_top, body_right, body_bottom],
    radius=90,
    fill=(255, 255, 255, 240),
)

# Microphone top (circle)
top_y = body_top
draw.ellipse(
    [cx - 100, top_y - 100, cx + 100, top_y + 100],
    fill=(255, 255, 255, 240),
)

# Stand (small rectangle at bottom)
stand_w, stand_h = 20, 60
stand_left = cx - stand_w // 2
stand_top = body_bottom - 10
draw.rounded_rectangle(
    [stand_left, stand_top, stand_left + stand_w, stand_top + stand_h],
    radius=10,
    fill=(255, 255, 255, 200),
)

# Base (horizontal line)
base_w, base_h = 200, 24
base_left = cx - base_w // 2
base_top = stand_top + stand_h - 4
draw.rounded_rectangle(
    [base_left, base_top, base_left + base_w, base_top + base_h],
    radius=12,
    fill=(255, 255, 255, 200),
)

# Save master
img.save("/Users/oli/listen/assets/icon_1024x1024.png")

# Create iconset
import os
iconset = "/Users/oli/listen/assets/Listen.iconset"
os.makedirs(iconset, exist_ok=True)

sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes:
    scaled = img.resize((s, s), Image.LANCZOS)
    scaled.save(f"{iconset}/icon_{s}x{s}.png")
    if s <= 512:
        scaled2 = img.resize((s*2, s*2), Image.LANCZOS)
        scaled2.save(f"{iconset}/icon_{s}x{s}@2x.png")

print("Iconset created.")
