#!/usr/bin/env python3
"""Converts Natural Earth 1:50m admin-0 countries (public domain) into the compact
countries.json bundled with the app.

    curl -LO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson
    python3 scripts/make-countries.py ne_50m_admin_0_countries.geojson Walker/Resources/countries.json

Output: [{"name", "code", "iso2", "areaKm2", "bbox": [minLon, minLat, maxLon, maxLat],
          "rings": [[lon, lat, lon, lat, ...], ...]}]
Rings include holes; point-in-country uses the even-odd rule across all rings.
"""
import json
import math
import sys

EARTH_RADIUS = 6371008.8


def ring_area(ring):
    """Spherical area of a closed lon/lat ring in m²."""
    total = 0.0
    for (lon1, lat1), (lon2, lat2) in zip(ring, ring[1:] + ring[:1]):
        total += math.radians(lon2 - lon1) * (2 + math.sin(math.radians(lat1)) + math.sin(math.radians(lat2)))
    return abs(total) * EARTH_RADIUS ** 2 / 2


def main(source, destination):
    countries = []
    for feature in json.load(open(source))["features"]:
        props = feature["properties"]
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        rings, area = [], 0.0
        for polygon in polygons:
            for index, ring in enumerate(polygon):
                ring = [(round(lon, 3), round(lat, 3)) for lon, lat in ring[:-1]]
                area += ring_area(ring) * (1 if index == 0 else -1)
                rings.append(ring)
        lons = [lon for ring in rings for lon, _ in ring]
        lats = [lat for ring in rings for _, lat in ring]
        # ISO_A2 is -99 for a few countries (France, Norway); ISO_A2_EH fills those in.
        iso2 = next((c for c in (props.get("ISO_A2_EH"), props.get("ISO_A2")) if c and len(c) == 2 and c.isalpha()), None)
        countries.append({
            "name": props["NAME"],
            "code": props["ADM0_A3"],
            "iso2": iso2,
            "areaKm2": round(area / 1e6, 1),
            "bbox": [min(lons), min(lats), max(lons), max(lats)],
            "rings": [[value for point in ring for value in point] for ring in rings],
        })
    countries.sort(key=lambda c: c["name"])
    json.dump(countries, open(destination, "w"), separators=(",", ":"))


if __name__ == "__main__":
    main(*sys.argv[1:3])
