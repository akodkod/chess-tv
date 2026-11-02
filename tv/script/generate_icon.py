#!/usr/bin/env python3
"""Adapt the Icon Composer queen to tvOS layers. Requires rsvg-convert (librsvg)."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "artwork/ChessTV.icon"
DEST = ROOT / "tv/ChessTV/Assets.xcassets/AppIcon.brandassets"
INFO = {"author": "xcode", "version": 1}


def contents(path, **fields):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps({**fields, "info": INFO}, indent=2) + "\n")


def render(path, width, height, foreground):
    svg = ET.Element("svg", xmlns="http://www.w3.org/2000/svg",
                     width=str(width), height=str(height), viewBox=f"0 0 {width} {height}")
    if foreground:
        queen = ET.parse(SOURCE / "Assets/queen.svg").getroot()
        queen.set("x", str((width - height) / 2))
        queen.set("y", "0")
        queen.set("width", str(height))
        queen.set("height", str(height))
        svg.append(queen)
    else:
        # Retain the Composer background hue with a subtle vertical gradient.
        color = json.loads((SOURCE / "icon.json").read_text())["fill"]["automatic-gradient"]
        rgb = [float(v) for v in color.split(":")[1].split(",")[:3]]
        defs = ET.SubElement(svg, "defs")
        gradient = ET.SubElement(defs, "linearGradient", id="background", x2="0", y2="1")
        for offset, factor in [("0%", 1.3), ("100%", 0.8)]:
            value = "#" + "".join(f"{round(min(1, c * factor) * 255):02x}" for c in rgb)
            ET.SubElement(gradient, "stop", offset=offset, **{"stop-color": value})
        ET.SubElement(svg, "rect", width="100%", height="100%", fill="url(#background)")
    subprocess.run(["rsvg-convert", "-o", str(path)], input=ET.tostring(svg), check=True)


assets = []
for name, width, height, scales in [
    ("Home", 400, 240, [1, 2]),
    ("AppStore", 1280, 768, [1]),
]:
    stack = DEST / f"{name}.imagestack"
    assets.append({"filename": stack.name, "idiom": "tv", "role": "primary-app-icon",
                   "size": f"{width}x{height}"})
    contents(stack, layers=[{"filename": f"{layer}.imagestacklayer"}
                            for layer in ["Queen", "Background"]])
    for layer in ["Queen", "Background"]:
        folder = stack / f"{layer}.imagestacklayer"
        contents(folder)
        imageset = folder / "Content.imageset"
        contents(imageset, images=[{"filename": f"image@{scale}x.png",
                                    "idiom": "tv", "scale": f"{scale}x"} for scale in scales])
        for scale in scales:
            render(imageset / f"image@{scale}x.png", width * scale, height * scale,
                   foreground=layer == "Queen")
contents(DEST, assets=assets)
