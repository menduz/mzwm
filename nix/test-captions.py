# Finds the captions of title bars in a screenshot, for the tests of kwm.
#
# Usage: test-captions.py <png> <x min> <rrggbb> [<rrggbb> <width>]
#
# A caption is a run of rows with at least 50 pixels of the color at x <x min>
# or more. With a second color, the caption is a gradient from the first
# color to the second one over <width> pixels, as decoration.zig paints the
# caption of the focused window. The script prints one line for each run,
# from the top: "x y rows", with the left end of the color and the top row.
import sys

from PIL import Image


def rgb(hex_color):
    return tuple(int(hex_color[i : i + 2], 16) for i in (0, 2, 4))


def gradient(a, b, x, span):
    return tuple(ca + ((cb - ca) * x + span // 2) // span for ca, cb in zip(a, b))


image = Image.open(sys.argv[1]).convert("RGB")
x_min = int(sys.argv[2])
if len(sys.argv) > 4:
    start, end, span = rgb(sys.argv[3]), rgb(sys.argv[4]), int(sys.argv[5]) - 1
    wanted = {gradient(start, end, x, span) for x in range(span + 1)}
else:
    wanted = {rgb(sys.argv[3])}

pixels = image.load()
width, height = image.size
run_start = None
left = 0
for y in range(height + 1):
    xs = [x for x in range(x_min, width) if y < height and pixels[x, y] in wanted]
    if len(xs) >= 50:
        if run_start is None:
            run_start, left = y, min(xs)
        left = min(left, min(xs))
    elif run_start is not None:
        print(left, run_start, y - run_start)
        run_start = None
