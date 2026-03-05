"""
Bedrock Agent action group Lambda: query_geojson

Fetches a GeoJSON FeatureCollection from a URL, optionally filters by:
  - proximity (lat/lon + radius_km) using haversine distance on feature geometry
  - keyword text match on any property value

Returns a plain-text summary of matching features, stripped of geometry,
sized to fit within Bedrock's 25KB action group response limit.
"""

import json
import math
import urllib.request
from typing import Any


MAX_RESPONSE_CHARS = 20_000
KEEP_PROPS = None  # None = keep all; set to a list to whitelist specific keys


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def nearest_distance_km(geometry: dict, lat: float, lon: float) -> float:
    """Return the minimum haversine distance from (lat, lon) to any coordinate in the geometry."""
    coords = []
    geom_type = geometry.get("type", "")
    raw = geometry.get("coordinates", [])

    if geom_type == "Point":
        coords = [raw]
    elif geom_type in ("MultiPoint", "LineString"):
        coords = raw
    elif geom_type in ("MultiLineString", "Polygon"):
        coords = [c for ring in raw for c in ring]
    elif geom_type == "MultiPolygon":
        coords = [c for poly in raw for ring in poly for c in ring]

    if not coords:
        return float("inf")
    return min(haversine_km(lat, lon, c[1], c[0]) for c in coords if len(c) >= 2)


def props_match_text(props: dict, text: str) -> bool:
    text_lower = text.lower()
    return any(text_lower in str(v).lower() for v in props.values())


def clean_vms_message(msg: str) -> str:
    """Replace VMS display codes with readable equivalents."""
    import re
    msg = re.sub(r'\[jl\d+\]', ' ', msg)
    msg = msg.replace('[nl]', ' ').replace('[np]', ' | ')
    return re.sub(r' +', ' ', msg).strip()


def feature_to_text(props: dict) -> str:
    lines = []
    for k, v in props.items():
        if v is None or v == "" or v == [] or v == {}:
            continue
        if k == 'currentMessage' and isinstance(v, str):
            v = clean_vms_message(v)
        lines.append(f"  {k}: {v}")
    return "\n".join(lines)


def handler(event: dict, context: Any) -> dict:
    # Bedrock action group passes parameters as a list of {name, value} dicts
    params = {p["name"]: p["value"] for p in event.get("parameters", [])}

    url = params.get("url", "").strip()
    if not url:
        return _response(event, "Error: url parameter is required")

    lat = float(params["lat"]) if params.get("lat") else None
    lon = float(params["lon"]) if params.get("lon") else None
    radius_km = float(params.get("radius_km", 50))
    filter_text = params.get("filter_text", "").strip()

    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        return _response(event, f"Error fetching {url}: {e}")

    features = data.get("features", [])
    last_updated = data.get("lastUpdated", "")

    results = []
    for feature in features:
        props = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}

        # Proximity filter
        if lat is not None and lon is not None and geometry:
            dist = nearest_distance_km(geometry, lat, lon)
            if dist > radius_km:
                continue

        # Text filter
        if filter_text and not props_match_text(props, filter_text):
            continue

        results.append(props)

    if not results:
        msg = "No matching features found."
        if filter_text:
            msg += f" (filter: '{filter_text}')"
        if lat is not None:
            msg += f" (within {radius_km}km of {lat},{lon})"
        return _response(event, msg)

    lines = [f"Found {len(results)} feature(s)"]
    if last_updated:
        lines.append(f"Last updated: {last_updated}")
    lines.append("")

    body = "\n".join(lines)
    for i, props in enumerate(results, 1):
        entry = f"[{i}]\n{feature_to_text(props)}\n"
        if len(body) + len(entry) > MAX_RESPONSE_CHARS:
            body += f"\n... ({len(results) - i + 1} more results truncated)"
            break
        body += entry

    return _response(event, body)


def _response(event: dict, body: str) -> dict:
    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup", ""),
            "function": event.get("function", ""),
            "functionResponse": {
                "responseBody": {
                    "TEXT": {"body": body}
                }
            }
        }
    }
