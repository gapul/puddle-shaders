#!/usr/bin/env python3
"""Bake the world coastline into two packed uint32 tables for the MSL wallpapers.

  SDF_TABLE   signed distance to the coastline, u8, +/- SDF_RANGE cells,
              negative on land. The distance is measured *on the sphere*, in
              units of one grid cell of arc (360/SW degrees), not in the
              equirectangular image: an image-space distance means a different
              thing at every latitude, which the shader cannot undo and which
              shows up as smeared, hairy polar coastlines as soon as the field
              is reprojected onto a globe or an equal-area map.
  PHASE_TABLE cyclic arc length along the nearest coastline, u8, 1.0 = one
              pulse cycle; continuous around each closed contour so a shader
              can run lights along the outline with `fract(phase - speed*time)`.

Both are equirectangular, row 0 at +90 deg, x wrapping at +/-180 deg, packed
4 cells per uint32 (x-major, little end first).

    curl -LO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_land.geojson
    uv run --with numpy,scipy,pillow,scikit-image python bake_world_sdf.py \
        ne_50m_land.geojson tables.txt

Then splice tables.txt into the shader bodies: tools/assemble.sh replaces the
`// __TABLES__` marker line with it.
"""
import json
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree
from skimage import measure

SRC = sys.argv[1] if len(sys.argv) > 1 else "ne50_land.geojson"
OUT = sys.argv[2] if len(sys.argv) > 2 else "tables.txt"
SW, SH = 1024, 512     # distance field grid: this is what the coastline's
                       # sharpness costs, and constant tables compile fast
                       # (half a million entries adds under a second)
PW, PH = 512, 256      # phase grid: arc length varies slowly, so it stays coarse
SS = 8                 # supersample factor for the rasterisation
RANGE = 20.0           # +/- clamp of the stored distance, in SDF cells. Wide
                       # enough that the halo has faded to nothing before the
                       # field flattens, or the clamp draws a ring round every
                       # island; u8 still leaves the step at a third of a pixel.
SPACING = 98.0         # target arc length of one pulse cycle, in degrees


def rings(geom):
    if geom["type"] == "Polygon":
        yield geom["coordinates"]
    elif geom["type"] == "MultiPolygon":
        for poly in geom["coordinates"]:
            yield poly


def rasterize():
    feats = json.load(open(SRC))["features"]
    W, H = SW * SS, SH * SS
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    for f in feats:
        for poly in rings(f["geometry"]):
            for i, ring in enumerate(poly):
                pts = [((lon + 180.0) / 360.0 * W, (90.0 - lat) / 180.0 * H)
                       for lon, lat, *_ in ring]
                if len(pts) >= 3:
                    d.polygon(pts, fill=255 if i == 0 else 0)
    return np.array(img) > 127


def unit_vectors(lat_deg, lon_deg):
    lat = np.radians(lat_deg)
    lon = np.radians(lon_deg)
    c = np.cos(lat)
    return np.stack([c * np.cos(lon), np.sin(lat), c * np.sin(lon)], axis=-1)


def raster_to_lonlat(rows, cols, shape):
    h, w = shape
    return (90.0 - (rows + 0.5) / h * 180.0,
            (cols + 0.5) / w * 360.0 - 180.0)


def grid_vectors(w, h):
    gy, gx = np.mgrid[0:h, 0:w]
    lat = 90.0 - (gy.ravel() + 0.5) / h * 180.0
    lon = (gx.ravel() + 0.5) / w * 360.0 - 180.0
    return unit_vectors(lat, lon)


def contours(land):
    """Coastline polylines at raster resolution, all wound the same way."""
    out = []
    for c in measure.find_contours(land.astype(float), 0.5):
        if len(c) < 8:
            continue
        if np.allclose(c[0], c[-1]):
            c = c[:-1]
        # Consistent handedness (positive shoelace area) so every landmass's
        # lights travel the same way round.
        y, x = c[:, 0], c[:, 1]
        if np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)) < 0:
            c = c[::-1]
        out.append(c)
    return out


def arc_degrees(v):
    """Great-circle length of each segment of a closed polyline of unit vectors."""
    chord = np.linalg.norm(np.roll(v, -1, axis=0) - v, axis=1)
    return np.degrees(2.0 * np.arcsin(np.clip(chord / 2.0, 0.0, 1.0)))


def bake_sdf(land, cs):
    """Great-circle distance to the coastline, in SDF cells, signed by the mask."""
    pts = np.concatenate(cs)
    lat, lon = raster_to_lonlat(pts[:, 0], pts[:, 1], land.shape)
    tree = cKDTree(unit_vectors(lat, lon))
    chord, _ = tree.query(grid_vectors(SW, SH), workers=-1)
    arc = 2.0 * np.arcsin(np.clip(chord / 2.0, 0.0, 1.0))     # radians
    cells = arc / (2.0 * np.pi / SW)
    # The sign has to come from the raster at the cell centre, not from a block
    # average: the magnitude is an exact distance to the coastline, so a sign
    # boundary that sits half a cell away from it makes the reconstructed field
    # jump by a whole cell there, which draws hard square patches along coasts.
    inside = land[SS // 2::SS, SS // 2::SS]
    return np.where(inside, -1.0, 1.0) * cells.reshape(SH, SW)


def bake_phase(land, cs):
    """Nearest-coastline cyclic arc length, in cycles, on the phase grid."""
    vecs, phase = [], []
    for c in cs:
        lat, lon = raster_to_lonlat(c[:, 0], c[:, 1], land.shape)
        v = unit_vectors(lat, lon)
        seg = arc_degrees(v)
        length = seg.sum()
        if length < 0.05:
            continue
        s = np.concatenate([[0.0], np.cumsum(seg)[:-1]])
        # An integer number of cycles round the loop keeps the phase continuous
        # across the seam.
        k = max(1.0, round(length / SPACING))
        vecs.append(v)
        phase.append(s / length * k)
    vecs = np.concatenate(vecs)
    phase = np.concatenate(phase) % 1.0
    print(f"contour points {len(vecs)}")

    _, idx = cKDTree(vecs).query(grid_vectors(PW, PH), workers=-1)
    return phase[idx].reshape(PH, PW)


def pack(u8):
    f = u8.reshape(-1).astype(np.uint32)
    return f[0::4] | (f[1::4] << 8) | (f[2::4] << 16) | (f[3::4] << 24)


def emit(fh, name, packed):
    fh.write(f"constant uint {name}[{len(packed)}] = {{\n")
    for i in range(0, len(packed), 8):
        fh.write("    " + " ".join(f"0x{v:08x}u," for v in packed[i:i + 8]) + "\n")
    fh.write("};\n\n")


def main():
    land = rasterize()
    print(f"raster {land.shape[1]}x{land.shape[0]}, land fraction {land.mean():.3f}")
    cs = contours(land)

    sdf = bake_sdf(land, cs)
    sdf_u8 = np.rint((np.clip(sdf / RANGE, -1, 1) * 0.5 + 0.5) * 255).astype(np.uint8)

    ph = bake_phase(land, cs)
    ph_u8 = np.rint(ph * 256.0).astype(np.int32) % 256

    with open(OUT, "w") as fh:
        fh.write(f"constant uint  SDF_W     = {SW}u;\n")
        fh.write(f"constant uint  SDF_H     = {SH}u;\n")
        fh.write(f"constant uint  PH_W      = {PW}u;\n")
        fh.write(f"constant uint  PH_H      = {PH}u;\n")
        fh.write(f"constant float SDF_RANGE = {RANGE};   // SDF cells of arc\n")
        fh.write(f"constant float SPACING   = {SPACING};   // degrees of arc per pulse cycle\n\n")
        emit(fh, "SDF_TABLE", pack(sdf_u8))
        emit(fh, "PHASE_TABLE", pack(ph_u8))
    print(f"wrote {OUT}")


main()
