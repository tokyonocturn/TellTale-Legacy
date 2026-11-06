#!/usr/bin/env python3
"""Classify a game frame, and its difference from the previous one, for the unattended runner.

Emits one JSON object on stdout:

    {"diff": 2.41,            # mean absolute grey difference, 0-255, vs. the previous frame
     "changed": 18342,        # pixels differing by more than 12 levels (on the 480 px wide copy)
     "choice_lines": 3,       # separated text rows in the dialogue-response band
     "subtitle_rows": 7,      # text rows in the subtitle band at the bottom
     "line_ys": [176, 205, 234]}

This is geometric measurement of rendered text, not OCR: a response row is a run of bright
pixels wide enough to be a line of dialogue and thick enough to be glyphs. It exists so an
unattended run can tell "a choice is on screen" from "a cinematic is playing" from "the shot
is static", without a person looking at the picture.
"""
import json
import sys

from PIL import Image, ImageChops

BRIGHT = 190          # luminance of dialogue text on the dark response band
MIN_ROW_PIXELS = 18   # bright pixels in a row, at 480 px wide, before it counts as text
MIN_GROUP_ROWS = 3    # glyphs are at least this many scan lines tall
PROCESS_WIDTH = 480

# The response list sits above the subtitle line; the subtitle sits at the very bottom.
CHOICE_BAND = (0.46, 0.88)
SUBTITLE_BAND = (0.88, 0.99)


def parse_band(value, fallback):
    """A band is 'lo,hi' in fractions of the frame height."""
    if not value:
        return fallback
    lo, hi = value.split(",")
    return (float(lo), float(hi))


def load_grey(path, size=None):
    image = Image.open(path).convert("L")
    if size is None:
        height = max(2, round(image.height * PROCESS_WIDTH / image.width))
        size = (PROCESS_WIDTH, height)
    return image.resize(size, Image.BILINEAR)


def text_groups(image, band):
    """Contiguous runs of scan lines that contain text, inside a vertical band."""
    width, height = image.size
    pixels = image.load()
    x0, x1 = int(width * 0.16), int(width * 0.84)
    y0, y1 = int(height * band[0]), int(height * band[1])

    rows = []
    for y in range(y0, y1):
        bright = 0
        for x in range(x0, x1):
            if pixels[x, y] >= BRIGHT:
                bright += 1
                if bright >= MIN_ROW_PIXELS:
                    rows.append(y)
                    break

    groups = []
    for y in rows:
        if groups and y - groups[-1][-1] <= 3:
            groups[-1].append(y)
        else:
            groups.append([y])
    return [g for g in groups if len(g) >= MIN_GROUP_ROWS]


def main(argv):
    # Optional --choice-band lo,hi so a caller can look at a different part of the frame.
    if "--choice-band" in argv:
        index = argv.index("--choice-band")
        try:
            choice_band = parse_band(argv[index + 1], CHOICE_BAND)
        except Exception:
            print(json.dumps({"error": "bad --choice-band value"}))
            return 2
        argv = argv[:index] + argv[index + 2:]
    else:
        choice_band = CHOICE_BAND

    if len(argv) < 2:
        print(json.dumps({"error": "usage: classify_frame.py <current.png> [previous.png]"}))
        return 2

    current = load_grey(argv[1])
    result = {
        "diff": 0.0,
        "changed": 0,
        "choice_lines": 0,
        "subtitle_rows": 0,
        "line_ys": [],
    }

    if len(argv) >= 3:
        previous = load_grey(argv[2], current.size)
        delta = ImageChops.difference(previous, current)
        histogram = delta.histogram()
        total = float(current.size[0] * current.size[1])
        result["diff"] = round(sum(i * n for i, n in enumerate(histogram)) / total, 3)
        result["changed"] = int(sum(histogram[13:]))

    choice = text_groups(current, choice_band)
    subtitle = text_groups(current, SUBTITLE_BAND)
    result["choice_lines"] = len(choice)
    result["subtitle_rows"] = sum(len(g) for g in subtitle)
    result["line_ys"] = [g[len(g) // 2] for g in choice]

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
