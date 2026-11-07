#!/usr/bin/env python3
"""Adapt the Warm mint pawn to tvOS layers. Requires rsvg-convert (librsvg)."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "artwork/ChessTV.icon"
DEST = ROOT / "tv/ChessTV/Assets.xcassets/AppIcon.brandassets"
INFO = {"author": "xcode", "version": 1}
ET.register_namespace("", "http://www.w3.org/2000/svg")


def contents(path, **fields):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps({**fields, "info": INFO}, indent=2) + "\n")


def render(path, width, height, foreground):
    svg = ET.Element("{http://www.w3.org/2000/svg}svg",
                     width=str(width), height=str(height), viewBox=f"0 0 {width} {height}")
    if foreground:
        # Keep the shadow attached to the pawn as tvOS moves this parallax layer.
        for filename in ["cast-shadow.svg", "ivory-pawn.svg"]:
            layer = ET.parse(SOURCE / "Assets" / filename).getroot()
            layer.set("x", str((width - height) / 2))
            layer.set("y", "0")
            layer.set("width", str(height))
            layer.set("height", str(height))
            svg.append(layer)
    else:
        # Extend the selected gradient across the landscape tile without letterboxing.
        background = ET.parse(SOURCE / "Assets/soft-mint-field.svg").getroot()
        background.set("width", str(width))
        background.set("height", str(height))
        background.set("preserveAspectRatio", "none")
        svg.append(background)
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
                            for layer in ["Pawn", "Background"]])
    for layer in ["Pawn", "Background"]:
        folder = stack / f"{layer}.imagestacklayer"
        contents(folder)
        imageset = folder / "Content.imageset"
        contents(imageset, images=[{"filename": f"image@{scale}x.png",
                                    "idiom": "tv", "scale": f"{scale}x"} for scale in scales])
        for scale in scales:
            render(imageset / f"image@{scale}x.png", width * scale, height * scale,
                   foreground=layer == "Pawn")
contents(DEST, assets=assets)
