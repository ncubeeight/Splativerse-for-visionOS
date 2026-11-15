#!/usr/bin/env python3
"""Compile/link the exact embedded panel shader for device and simulator."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import textwrap

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--toolchain", type=Path, help="Installed Metal.xctoolchain path if xcrun cannot resolve it")
args = parser.parse_args()
project = Path(__file__).resolve().parents[1]
source = (project / "Splativerse/Rendering/FlightJoystickRenderer.swift").read_text()
marker = 'private static let source = """'
if source.count(marker) != 1:
    raise SystemExit("Cannot locate the flight-panel shader")
shader = textwrap.dedent(source.split(marker, 1)[1].split('"""', 1)[0]).strip() + "\n"

def tool(name, sdk):
    return [str(args.toolchain / "usr/bin" / name)] if args.toolchain else ["xcrun", "--sdk", sdk, name]

with tempfile.TemporaryDirectory(prefix="splativerse-flight-shader-") as directory:
    output = Path(directory)
    metal = output / "FlightPanel.metal"
    metal.write_text(shader)
    for sdk, target in [("xros", "air64-apple-xros26.0"), ("xrsimulator", "air64-apple-xros26.0-simulator")]:
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        air = output / (sdk + ".air")
        subprocess.run(tool("metal", sdk) + [
            "-target", target, "-isysroot", sdk_path, "-std=metal3.2", "-Werror",
            "-fmodules-cache-path=" + str(output / "modules"), "-c", str(metal), "-o", str(air)
        ], check=True)
        subprocess.run(tool("metallib", sdk) + [str(air), "-o", str(output / (sdk + ".metallib"))], check=True)
        print(sdk + ": flight-panel shader compilation and linking passed", flush=True)
