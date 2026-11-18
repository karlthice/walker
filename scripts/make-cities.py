#!/usr/bin/env python3
"""Builds the cities.json bundled with the app from the curated list in scripts/cities.csv.

    python3 scripts/make-cities.py

Each row names a city in a country (the `code` from countries.json). The boundary is the
OpenStreetMap relation in `osm_relation`; when that is empty, the city is looked up by name
with Nominatim and the relation found is written back into the CSV, so check those rows.
`search` overrides the name used for that lookup.

Boundaries are simplified to about 50 m: regions don't need to be exact, and it keeps the
file small. Where a large boundary reaches far out to sea (like Kanazawa's territorial waters), the
area is clipped to the country's coastline so percentages count land only.

Responses are cached in scripts/cache/, so a rebuild only fetches new cities.
Output: [{"id", "name", "local", "country", "area" (m²), "bbox", "rings"}]
Boundary data © OpenStreetMap contributors, ODbL.
"""
import csv
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV_PATH = os.path.join(ROOT, "scripts", "cities.csv")
CACHE = os.path.join(ROOT, "scripts", "cache")
COUNTRIES = os.path.join(ROOT, "Walker", "Resources", "countries.json")
OUTPUT = os.path.join(ROOT, "Walker", "Resources", "cities.json")

ENDPOINT = "https://nominatim.openstreetmap.org"
USER_AGENT = "Walker-region-builder/1.0"
# Degrees; about 50 m. Regions don't need to be exact.
SIMPLIFY = 0.0005
# 4 decimals is about 10 m, well under the simplification.
DECIMALS = 4
# Below this share of land, the boundary includes sea...
SEA_CLIP_THRESHOLD = 0.8
# ...but only boundaries this large are clipped: the 1:50m coastline is too coarse for small
# coastal cities, and would cut central Istanbul in half.
SEA_CLIP_MIN_AREA = 300e6
EARTH_RADIUS = 6371008.8
METRES_PER_DEGREE = 111_320.0

_last_request = 0.0


def get(path, params):
    """GET from Nominatim, at most one request per second as its usage policy asks."""
    global _last_request
    wait = _last_request + 1.1 - time.time()
    if wait > 0:
        time.sleep(wait)
    url = f"{ENDPOINT}/{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                _last_request = time.time()
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            _last_request = time.time()
            busy = not isinstance(error, urllib.error.HTTPError) or error.code in (429, 500, 502, 503, 504)
            if not busy or attempt == 5:
                raise
            print(f"   (Nominatim busy: {error}; retrying in {10 * attempt} s)")
            time.sleep(10 * attempt)


# Boundary types that are the city itself, best first; anything else (a province, a county)
# is only taken when nothing better turns up, and is flagged for review.
CITY_TYPES = ["city", "town", "municipality", "village", "borough", "city_district"]


def find_relation(name, iso2):
    """The boundary relation of the city, with what it is, or None."""
    candidates = []
    for params in ({"city": name}, {"q": name}):
        results = get("search", {**params, "countrycodes": iso2.lower(), "format": "jsonv2", "limit": 10})
        candidates = [r for r in results
                      if r.get("osm_type") == "relation" and r.get("category", r.get("class")) == "boundary"]
        if candidates:
            break
    if not candidates:
        return None, None, None
    rank = lambda r: CITY_TYPES.index(r.get("addresstype")) if r.get("addresstype") in CITY_TYPES else len(CITY_TYPES)
    best = min(candidates, key=rank)
    return best["osm_id"], best.get("display_name", ""), best.get("addresstype")


def boundary(relation):
    path = os.path.join(CACHE, f"R{relation}.json")
    if os.path.exists(path):
        return json.load(open(path))
    results = get("lookup", {
        "osm_ids": f"R{relation}", "format": "jsonv2", "polygon_geojson": 1,
        "polygon_threshold": SIMPLIFY, "namedetails": 1,
    })
    if not results:
        sys.exit(f"Relation {relation} not found")
    os.makedirs(CACHE, exist_ok=True)
    json.dump(results[0], open(path, "w"))
    return results[0]


def ring_area(ring):
    """Spherical area of a flattened lon, lat ring in m²."""
    total = 0.0
    n = len(ring)
    for i in range(0, n, 2):
        j = (i - 2) % n
        lon1, lat1, lon2, lat2 = ring[j], ring[j + 1], ring[i], ring[i + 1]
        total += math.radians(lon2 - lon1) * (2 + math.sin(math.radians(lat1)) + math.sin(math.radians(lat2)))
    return abs(total) * EARTH_RADIUS ** 2 / 2


def edges(rings, min_lat, max_lat):
    result = []
    for ring in rings:
        n = len(ring)
        for i in range(0, n, 2):
            j = (i - 2) % n
            x1, y1, x2, y2 = ring[j], ring[j + 1], ring[i], ring[i + 1]
            if max(y1, y2) >= min_lat and min(y1, y2) <= max_lat:
                result.append((x1, y1, x2, y2))
    return result


def intervals(edge_list, latitude):
    crossings = sorted(
        x1 + (latitude - y1) * (x2 - x1) / (y2 - y1)
        for x1, y1, x2, y2 in edge_list if (y1 > latitude) != (y2 > latitude)
    )
    return [(crossings[i], crossings[i + 1]) for i in range(0, len(crossings) - 1, 2)]


def overlap(a, b):
    i = j = 0
    total = 0.0
    while i < len(a) and j < len(b):
        total += max(0.0, min(a[i][1], b[j][1]) - max(a[i][0], b[j][0]))
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return total


def land_area(rings, bbox, country_rings, step=200):
    """Approximate area in m² of the shape's overlap with the country, by strips of `step` m."""
    min_lat, max_lat = bbox[1], bbox[3]
    rows = min(max(int((max_lat - min_lat) * METRES_PER_DEGREE / step), 50), 2000)
    height = (max_lat - min_lat) / rows
    city_edges = edges(rings, min_lat, max_lat)
    country_edges = edges(country_rings, min_lat, max_lat)
    total = 0.0
    for row in range(rows):
        latitude = min_lat + (row + 0.5) * height
        width = overlap(intervals(city_edges, latitude), intervals(country_edges, latitude))
        total += width * METRES_PER_DEGREE * math.cos(math.radians(latitude)) * height * METRES_PER_DEGREE
    return total


def shape(geojson):
    if geojson["type"] == "Polygon":
        polygons = [geojson["coordinates"]]
    elif geojson["type"] == "MultiPolygon":
        polygons = geojson["coordinates"]
    else:
        return None, 0.0
    rings, area = [], 0.0
    for polygon in polygons:
        for index, positions in enumerate(polygon):
            # GeoJSON rings repeat the first position at the end; ours don't.
            ring = [round(value, DECIMALS) for position in positions[:-1] for value in position[:2]]
            if len(ring) < 6:
                continue
            area += ring_area(ring) * (1 if index == 0 else -1)
            rings.append(ring)
    return rings, area


def save_rows(rows):
    with open(CSV_PATH, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["country", "name", "osm_relation", "search"], lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main():
    countries = {c["code"]: c for c in json.load(open(COUNTRIES))}
    rows = list(csv.DictReader(open(CSV_PATH, encoding="utf-8")))
    cities = []
    for row in rows:
        country = countries.get(row["country"])
        if not country:
            sys.exit(f"{row['name']}: unknown country code {row['country']}")
        if not row["osm_relation"]:
            relation, found, kind = find_relation(row["search"] or row["name"], country["iso2"])
            if not relation:
                print(f"!! {row['name']}: no boundary found, skipped")
                continue
            flag = "" if kind in CITY_TYPES else "  <-- check: not a city boundary"
            print(f"   {row['name']}: found relation {relation}, {kind} ({found}){flag}")
            row["osm_relation"] = str(relation)
            # Saved right away, so an interrupted build doesn't look it up again.
            save_rows(rows)
        relations = [int(r) for r in row["osm_relation"].split()]
        rings, area, local = [], 0.0, None
        for relation in relations:
            place = boundary(relation)
            part_rings, part_area = shape(place["geojson"])
            rings += part_rings or []
            area += part_area
            if len(relations) == 1:
                local = (place.get("namedetails") or {}).get("name") or place.get("name")
        if not rings:
            print(f"!! {row['name']}: relation {row['osm_relation']} has no area, skipped")
            continue
        bbox = [
            min(r[i] for r in rings for i in range(0, len(r), 2)),
            min(r[i] for r in rings for i in range(1, len(r), 2)),
            max(r[i] for r in rings for i in range(0, len(r), 2)),
            max(r[i] for r in rings for i in range(1, len(r), 2)),
        ]
        land = land_area(rings, bbox, country["rings"])
        clipped = area > SEA_CLIP_MIN_AREA and 0 < land < area * SEA_CLIP_THRESHOLD
        cities.append({
            "id": relations[0],
            "name": row["name"],
            "local": local if local and local != row["name"] else None,
            "country": row["country"],
            "area": round(land if clipped else area),
            "bbox": bbox,
            "rings": rings,
        })
        points = sum(len(r) // 2 for r in rings)
        print(f"{row['country']} {row['name']:<14} {local or '':<20} {area / 1e6:8.1f} km²"
              f"{f' → {land / 1e6:.1f} km² land' if clipped else '':<22} {points:6} points"
              f"{'  <-- check: large' if (land if clipped else area) > 1500e6 else ''}")

    with open(OUTPUT, "w", encoding="utf-8") as f:
        json.dump(cities, f, separators=(",", ":"), ensure_ascii=False)
    print(f"{len(cities)} cities, {os.path.getsize(OUTPUT) / 1024:.0f} KB → {os.path.relpath(OUTPUT, ROOT)}")


if __name__ == "__main__":
    main()
