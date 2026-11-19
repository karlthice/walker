#!/usr/bin/env python3
"""Fills a simulator's Walker database with a month of demo walks, for App Store screenshots.

    python3 scripts/make-demo-walks.py <simulator UDID>

Walks follow real streets: each is a walking route between two random spots near a city
centre, from the OpenStreetMap routing service at routing.openstreetmap.de (only those city
coordinates are sent). Routes are cached in scripts/cache/demo/, and the random spots are
seeded, so reruns give the same walks.

Walker must not be running; the script quits it. On the next launch the app sees an old grid
version and rebuilds the fog and stats from the new points.
"""
import json
import math
import os
import random
import sqlite3
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "scripts", "cache", "demo")
BUNDLE_ID = "com.thoroddsen.walker"
ROUTER = "https://routing.openstreetmap.de/routed-foot/route/v1/driving"
USER_AGENT = "Walker-demo-data/1.0"

# (name, centre lat, lon, radius in km, [(days ago, walks that day), ...])
CITIES = [
    ("Reykjavik", 64.1440, -21.9330, 1.7,
     [(d, 1) for d in (0, 1, 2, 3, 4, 7, 8, 9, 11, 14, 15, 16, 18, 19, 21, 22, 26, 27, 28, 29)] + [(0, 1), (8, 1), (15, 1)]),
    ("Paris", 48.8590, 2.3420, 1.8, [(24, 2), (23, 2)]),
    # A trip through Spain, so its city list shows several cities under way and a few still to visit.
    ("Barcelona", 41.3880, 2.1720, 1.5, [(13, 2), (12, 2), (11, 1)]),
    ("Madrid", 40.4170, -3.7035, 1.6, [(14, 2), (15, 1)]),
    ("Valencia", 39.4740, -0.3760, 1.3, [(10, 2)]),
    ("Seville", 37.3880, -5.9930, 1.2, [(9, 2)]),
    ("Granada", 37.1760, -3.5960, 1.0, [(8, 1)]),
    ("Kyoto", 35.0060, 135.7700, 1.8, [(6, 2), (5, 2)]),
]

WALKING_SPEED = 1.4  # m/s
STEP = 18  # metres between points, like a walk recorded every ~20 m

_last_request = 0.0


def route(start, end):
    """Walking route as [(lat, lon)], or None."""
    key = f"{start[0]:.5f},{start[1]:.5f}-{end[0]:.5f},{end[1]:.5f}"
    path = os.path.join(CACHE, key + ".json")
    if os.path.exists(path):
        data = json.load(open(path))
    else:
        global _last_request
        time.sleep(max(0, _last_request + 1.1 - time.time()))
        url = f"{ROUTER}/{start[1]:.5f},{start[0]:.5f};{end[1]:.5f},{end[0]:.5f}?overview=full&geometries=geojson"
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.load(response)
        _last_request = time.time()
        os.makedirs(CACHE, exist_ok=True)
        json.dump(data, open(path, "w"))
    if data.get("code") != "Ok" or not data.get("routes"):
        return None
    return [(lat, lon) for lon, lat in data["routes"][0]["geometry"]["coordinates"]]


def distance(a, b):
    lat = math.radians((a[0] + b[0]) / 2)
    dx = math.radians(b[1] - a[1]) * math.cos(lat) * 6371000
    dy = math.radians(b[0] - a[0]) * 6371000
    return math.hypot(dx, dy)


def densify(line):
    points = [line[0]]
    for a, b in zip(line, line[1:]):
        d = distance(a, b)
        for i in range(1, int(d // STEP) + 1):
            t = i * STEP / d
            points.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
        points.append(b)
    return points


def spot(rng, lat, lon, radius_km):
    r = radius_km * 1000 * math.sqrt(rng.random())
    angle = rng.random() * 2 * math.pi
    return (lat + r * math.cos(angle) / 111320, lon + r * math.sin(angle) / (111320 * math.cos(math.radians(lat))))


def walks():
    rng = random.Random(42)
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    points = []
    total = 0.0
    # When each day's next walk may start, so walks on the same day never overlap in time.
    next_start = {}
    for name, lat, lon, radius, days in CITIES:
        for days_ago, count in days:
            for n in range(count):
                for _ in range(6):
                    line = route(spot(rng, lat, lon, radius), spot(rng, lat, lon, radius))
                    length = sum(distance(a, b) for a, b in zip(line, line[1:])) if line else 0
                    if 1200 <= length <= 5000:
                        break
                else:
                    continue
                # From mid-morning, an hour or two apart; today's from six hours ago, so they end before now.
                first = datetime.now() - timedelta(hours=6) if days_ago == 0 else today - timedelta(days=days_ago) + timedelta(hours=9)
                start = max(next_start.get(days_ago, first), first) + timedelta(hours=rng.random() * 2)
                t = start
                previous = None
                for p in densify(line):
                    if previous:
                        t += timedelta(seconds=distance(previous, p) / WALKING_SPEED)
                    points.append((t.timestamp(), p[0], p[1], round(4 + rng.random() * 8, 1)))
                    previous = p
                next_start[days_ago] = t + timedelta(hours=1)
                total += length
                print(f"{name:<10} {days_ago:>2} days ago  {length / 1000:4.1f} km")
    return sorted(points), total


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    udid = sys.argv[1]
    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"], text=True).strip()
    database = os.path.join(container, "Library", "Application Support", "Walker", "walker.sqlite")
    if not os.path.exists(database):
        sys.exit("Launch Walker in the simulator once first, so it creates its database.")

    points, total = walks()
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], stderr=subprocess.DEVNULL)
    db = sqlite3.connect(database)
    with db:
        db.execute("DELETE FROM points")
        db.executemany("INSERT INTO points (ts, lat, lon, acc) VALUES (?, ?, ?, ?)", points)
        # An unknown grid version makes the app rebuild the fog and stats from the points.
        db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('gridVersion', '0')")
    db.close()
    print(f"{len(points)} points, {total / 1000:.0f} km → {database}")


if __name__ == "__main__":
    main()
