"""
Bedrock Agent action group Lambda: arcgis-geocode

Functions:
  find_place(query, [lat, lon])     - forward geocode a place name to lat/lon
  reverse_geocode(lat, lon)         - reverse geocode coordinates to an address
  route_between(origin, destination) - ArcGIS driving route (distance, time, roads) plus NZTA delays and
                                       closures along it; re-routes around active full closures

ArcGIS OAuth2 credentials are read from AWS Secrets Manager at cold start
and cached. The short-lived access token is refreshed automatically.
"""

import json
import os
import time
import urllib.request
import urllib.parse
import boto3

SECRET_ARN = os.environ.get("ARCGIS_SECRET_ARN", "")
ARCGIS_TOKEN_URL = "https://www.arcgis.com/sharing/rest/oauth2/token"
ARCGIS_SUGGEST_URL = "https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/suggest"
ARCGIS_FORWARD_URL = "https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates"
ARCGIS_REVERSE_URL = "https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/reverseGeocode"

# In-memory token cache (lives for the duration of the Lambda container)
_token_cache: dict = {}


def _get_credentials() -> tuple[str, str]:
    """Read client_id and client_secret from Secrets Manager (cached per container)."""
    if "client_id" in _token_cache:
        return _token_cache["client_id"], _token_cache["client_secret"]
    client = boto3.client("secretsmanager")
    secret = json.loads(client.get_secret_value(SecretId=SECRET_ARN)["SecretString"])
    _token_cache["client_id"] = secret["clientId"]
    _token_cache["client_secret"] = secret["clientSecret"]
    return _token_cache["client_id"], _token_cache["client_secret"]


def _get_token() -> str:
    """Return a valid OAuth2 token, refreshing if expired."""
    now = time.time()
    if _token_cache.get("token") and now < _token_cache.get("token_expires", 0):
        return _token_cache["token"]

    client_id, client_secret = _get_credentials()
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "grant_type": "client_credentials",
        "f": "json",
    }).encode()
    req = urllib.request.Request(ARCGIS_TOKEN_URL, data=body,
                                  headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())

    if "error" in data:
        raise RuntimeError(f"ArcGIS token error: {data['error']}")

    _token_cache["token"] = data["access_token"]
    # Refresh at 90% of expiry
    _token_cache["token_expires"] = now + data["expires_in"] * 0.9
    return _token_cache["token"]


def _fetch(url: str, params: dict) -> dict:
    params["token"] = _get_token()
    params["f"] = "json"
    full_url = url + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(full_url, timeout=10) as resp:
        return json.loads(resp.read())


def _country_from_location(lat: float, lon: float) -> str | None:
    """Reverse geocode to get country code for search bias."""
    try:
        data = _fetch(ARCGIS_REVERSE_URL, {"location": f"{lon},{lat}"})
        return data.get("address", {}).get("CountryCode")
    except Exception:
        return None


def find_place(query: str, lat: float = None, lon: float = None) -> str:
    """Forward geocode: place name → lat/lon + address."""
    # Step 1: suggest to get magicKey
    suggest_params = {"text": query, "maxSuggestions": "3"}
    if lat is not None and lon is not None:
        suggest_params["location"] = f"{lon},{lat}"
        country = _country_from_location(lat, lon)
        if country:
            suggest_params["countryCode"] = country
    suggestions = _fetch(ARCGIS_SUGGEST_URL, suggest_params).get("suggestions", [])

    if not suggestions:
        return f"No results found for '{query}'."

    # Step 2: forward geocode the top suggestion
    top = suggestions[0]
    candidates = _fetch(ARCGIS_FORWARD_URL, {
        "singleLine": top["text"],
        "magicKey": top["magicKey"],
        "maxLocations": "1",
        "outFields": "PlaceName,Place_addr,City,Region,Country",
    }).get("candidates", [])

    if not candidates:
        return f"Could not resolve coordinates for '{query}'."

    c = candidates[0]
    loc = c.get("location", {})
    attrs = c.get("attributes", {})
    name = attrs.get("PlaceName") or top["text"]
    addr = attrs.get("Place_addr", "")
    lat_r = loc.get("y", 0)
    lon_r = loc.get("x", 0)

    result = f"{name}\nCoordinates: {lat_r}, {lon_r}"
    if addr:
        result += f"\nAddress: {addr}"
    return result


def reverse_geocode(lat: float, lon: float) -> str:
    """Reverse geocode: lat/lon → address."""
    data = _fetch(ARCGIS_REVERSE_URL, {"location": f"{lon},{lat}"})

    if "error" in data:
        return f"Reverse geocode failed: {data['error'].get('message', 'unknown error')}"

    addr = data.get("address", {})
    if not addr:
        return "No address found for those coordinates."

    parts = [
        addr.get("Match_addr") or addr.get("Address", ""),
        addr.get("City", ""),
        addr.get("Region", ""),
        addr.get("CountryCode", ""),
    ]
    return ", ".join(p for p in parts if p)


# ---------------------------------------------------------------------------
# route_between: ArcGIS driving route + NZTA road events along the route
# ---------------------------------------------------------------------------

ARCGIS_SOLVE_URL = "https://route-api.arcgis.com/arcgis/rest/services/World/Route/NAServer/Route_World/solve"
NZTA_DELAYS_URL = "https://www.journeys.nzta.govt.nz/assets/map-data-cache/delays.json"

EVENT_NEAR_ROUTE_KM = 1.0      # an NZTA event this close to the route counts as "on or near" it
CLOSURE_ON_ROUTE_KM = 0.3      # a closure this close to the route means the route is blocked
MAX_EVENTS_LISTED = 8
MAX_REROUTES = 3
import re as _re
_OPERATIONAL = _re.compile(r"stop/?go|delay|closed|closure|detour|minutes|one lane|single lane", _re.I)
_SEVERITY = {"Road Closed": 0, "Delays": 1, "Vehicle Restrictions": 2, "Caution": 3}


def _nz_tz():
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("Pacific/Auckland")
    except Exception:
        return _FallbackNZ()


from datetime import tzinfo as _tzinfo, timedelta as _td


class _FallbackNZ(_tzinfo):
    """NZ time without a tz database: NZDT (+13) from the last Sunday of September to the first Sunday of April,
    else NZST (+12). Transition hours are approximated by date."""

    def utcoffset(self, dt):
        from datetime import date
        y, d = dt.year, date(dt.year, dt.month, dt.day)
        sep = date(y, 9, 30)
        sep -= _td(days=(sep.weekday() + 1) % 7)       # last Sunday of September
        apr = date(y, 4, 1)
        apr += _td(days=(6 - apr.weekday()) % 7)       # first Sunday of April
        return _td(hours=13) if (d >= sep or d < apr) else _td(hours=12)

    def dst(self, dt):
        return self.utcoffset(dt) - _td(hours=12)

    def tzname(self, dt):
        return "NZDT" if self.dst(dt) else "NZST"


def _parse_nz(value):
    """NZTA timestamps are local NZ time, 'YYYY-MM-DD HH:MM:SS'. Returns an aware datetime or None."""
    if not value:
        return None
    from datetime import datetime
    try:
        return datetime.strptime(str(value)[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=_nz_tz())
    except ValueError:
        return None


def _post(url: str, params: dict, timeout: int = 20) -> dict:
    params = dict(params)
    params["token"] = _get_token()
    params["f"] = "json"
    req = urllib.request.Request(url, data=urllib.parse.urlencode(params).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _resolve_nz_place(query: str):
    """Place name or 'lat,lon' -> (label, lat, lon). Biased to New Zealand, never to the user's position."""
    import re
    m = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*", query)
    if m:
        lat, lon = float(m.group(1)), float(m.group(2))
        return f"{lat:.4f},{lon:.4f}", lat, lon
    sugg = _fetch(ARCGIS_SUGGEST_URL, {"text": query, "maxSuggestions": "1", "countryCode": "NZL"}).get("suggestions", [])
    if not sugg:
        raise ValueError(f"Could not find a place called '{query}' in New Zealand.")
    cands = _fetch(ARCGIS_FORWARD_URL, {"singleLine": sugg[0]["text"], "magicKey": sugg[0]["magicKey"],
                                        "maxLocations": "1", "outFields": "PlaceName"}).get("candidates", [])
    if not cands:
        raise ValueError(f"Could not resolve coordinates for '{query}'.")
    c = cands[0]
    label = c.get("attributes", {}).get("PlaceName") or sugg[0]["text"]
    if not _name_matches(query, sugg[0]["text"]):
        raise ValueError(f"Could not confidently match '{query}' to a New Zealand place (closest match: '{sugg[0]['text']}'). "
                         f"Ask the user to confirm the place name.")
    return label, c["location"]["y"], c["location"]["x"]


def _name_matches(query: str, matched: str) -> bool:
    """ArcGIS suggest is fuzzy and can return a place sharing only one word with the query. Require that more than
    half of the query's words (4+ letters) appear, allowing for small typos, in the matched text."""
    import re
    from difflib import SequenceMatcher
    words = [w for w in re.findall(r"[a-z\u0101\u0113\u012b\u014d\u016b]+", query.lower()) if len(w) >= 4]
    if not words:
        return True
    cand = re.findall(r"[a-z\u0101\u0113\u012b\u014d\u016b]+", matched.lower())
    hit = sum(1 for w in words if any(SequenceMatcher(None, w, c).ratio() >= 0.8 for c in cand))
    return hit / len(words) > 0.5


def _fetch_nzta_events() -> list:
    with urllib.request.urlopen(NZTA_DELAYS_URL, timeout=10) as resp:
        return json.loads(resp.read()).get("features", [])


def _coords(geometry: dict) -> list:
    """All (lon, lat) vertices of a GeoJSON geometry, line segments densified to ~250 m."""
    t, raw = (geometry or {}).get("type", ""), (geometry or {}).get("coordinates", [])
    if t == "Point":
        return [tuple(raw[:2])]
    if t in ("LineString", "MultiPoint"):
        lines = [raw]
    elif t in ("MultiLineString", "Polygon"):
        lines = raw
    elif t == "MultiPolygon":
        lines = [r for p in raw for r in p]
    else:
        return []
    return _densify(lines, 0.25)


def _densify(lines: list, step_km: float) -> list:
    out = []
    for line in lines:
        for i, p in enumerate(line):
            out.append((p[0], p[1]))
            if i + 1 < len(line):
                q = line[i + 1]
                n = int(haversine_km(p[1], p[0], q[1], q[0]) / step_km)
                for k in range(1, n + 1):
                    f = k / (n + 1)
                    out.append((p[0] + (q[0] - p[0]) * f, p[1] + (q[1] - p[1]) * f))
    return out


def haversine_km(lat1, lon1, lat2, lon2) -> float:
    import math
    dlat, dlon = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    return 6371.0 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


class _PointIndex:
    """Grid index so 'is any route point within X km of this event vertex' is fast in pure Python."""
    CELL = 0.02   # degrees, about 1.5-2.2 km

    def __init__(self, points):
        self.cells = {}
        for lon, lat in points:
            self.cells.setdefault((int(lat // self.CELL), int(lon // self.CELL)), []).append((lon, lat))

    def within(self, lon, lat, max_km) -> bool:
        ci, cj = int(lat // self.CELL), int(lon // self.CELL)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for plon, plat in self.cells.get((ci + di, cj + dj), ()):
                    if haversine_km(lat, lon, plat, plon) <= max_km:
                        return True
        return False


def _near_route(index, geometry, max_km) -> bool:
    return any(index.within(lon, lat, max_km) for lon, lat in _coords(geometry))


def _solve(stops, polyline_barriers=None, point_barriers=None) -> dict:
    params = {
        "stops": ";".join(f"{lon},{lat}" for lat, lon in stops),
        "returnRoutes": "true", "returnDirections": "true", "directionsLanguage": "en",
        "directionsLengthUnits": "esriNAUKilometers", "outputLines": "esriNAOutputLineTrueShape",
        "startTime": "now",    # traffic-aware time for a departure now
    }
    if point_barriers:
        params["barriers"] = ";".join(f"{lon},{lat}" for lon, lat in point_barriers)
    if polyline_barriers:
        params["polylineBarriers"] = json.dumps({
            "spatialReference": {"wkid": 4326},
            "features": [{"geometry": {"paths": [p], "spatialReference": {"wkid": 4326}}} for p in polyline_barriers]})
    data = _post(ARCGIS_SOLVE_URL, params)
    if "error" in data:
        raise RuntimeError(f"ArcGIS routing error: {data['error'].get('message', 'unknown')}")
    feats = (data.get("routes") or {}).get("features") or []
    if not feats:
        return {}
    f = feats[0]
    return {
        "km": f["attributes"]["Total_Kilometers"], "min": f["attributes"]["Total_TravelTime"],
        "path": f["geometry"]["paths"][0],
        "steps": [s["attributes"] for s in (data.get("directions") or [{}])[0].get("features", [])],
    }


def _fmt_min(m: float) -> str:
    m = int(round(m))
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def _road_name(text: str):
    import re
    m = re.match(r".*\b(?:on|onto) (.+?)(?: toward .*)?$", text)
    if not m:
        return None
    name = m.group(1).strip()
    if re.fullmatch(r"\d+[A-Z]?", name):                       # 'merge onto 56'
        return f"SH{name}"
    name = re.sub(r"\((\d+[A-Z]?)\)$", r"(SH\1)", name)         # 'Kingston Road (6)'
    m2 = re.fullmatch(r"(\d+[A-Z]?) \((.+)\)", name)         # '6 (Kingston Road)'
    return f"{m2.group(2)} (SH{m2.group(1)})" if m2 else name


def _via(steps) -> str:
    legs = []
    for s in steps:
        name = _road_name(s.get("text", ""))
        if not name or s.get("length", 0) <= 0:
            continue
        if legs and legs[-1][0] == name:
            legs[-1][1] += s["length"]
        else:
            legs.append([name, s["length"]])
    main = [f"{n} {km:.0f} km" for n, km in legs if km >= 15]
    return ", ".join(main[:6])


def _event_line(props: dict) -> str:
    impact = props.get("Impact") or "Info"
    what = " - ".join(x for x in (props.get("EventType"), props.get("EventDescription")) if x)
    when = ""
    if props.get("StartDateNice") or props.get("EndDateNice"):
        end = props.get("EndDateNice") or "further notice"
        when = f" ({props.get('StartDateNice', '?')} to {end})"
    comment = (props.get("EventComments") or "").strip().replace("\n", " ")
    # Always keep the comment for closures and delays. For lower-severity events keep it only when it says something
    # operational (stop/go, delays, closures), so the result stays short.
    if comment and (impact in ("Road Closed", "Delays") or _OPERATIONAL.search(comment)):
        comment = " " + comment[:160]
    else:
        comment = ""
    alt = f" Alternative: {props['AlternativeRoute'][:80]}" if impact == "Road Closed" and props.get("AlternativeRoute") else ""
    return f"- [{impact}] {props.get('LocationArea', 'unknown location')}: {what}{when}.{comment}{alt}"


def route_between(origin: str, destination: str, _events=None) -> str:
    """Driving route with distance, traffic-aware time, the roads used, and NZTA events along it.

    Active full closures that block the route are avoided with restriction barriers, and the detour is reported.
    `_events` lets tests inject an NZTA feature list.
    """
    from concurrent.futures import ThreadPoolExecutor
    from datetime import datetime, timedelta

    with ThreadPoolExecutor(max_workers=3) as ex:
        f_o = ex.submit(_resolve_nz_place, origin)
        f_d = ex.submit(_resolve_nz_place, destination)
        f_e = ex.submit(lambda: _events if _events is not None else _fetch_nzta_events())
        try:
            o_name, o_lat, o_lon = f_o.result()
            d_name, d_lat, d_lon = f_d.result()
        except ValueError as e:
            return str(e)
        try:
            events = f_e.result()
        except Exception:
            events = None   # route still useful without the event feed

    base = _solve([(o_lat, o_lon), (d_lat, d_lon)])
    if not base:
        return f"No driveable route found between {o_name} and {d_name}."

    now = datetime.now(_nz_tz())
    window_end = now + timedelta(minutes=base["min"])

    def relevant(props):
        start, end = _parse_nz(props.get("StartDate")), _parse_nz(props.get("EndDate") or props.get("ExpectedResolutionDate"))
        return (start is None or start <= window_end) and (end is None or end >= now)

    route = base
    blocking, closures = [], []
    if events is not None:
        usable = [f for f in events if f.get("geometry") and relevant(f.get("properties") or {})]
        closures = [f for f in usable if (f["properties"].get("Impact") == "Road Closed")]
        # Re-route around active full closures that sit on the current route, up to MAX_REROUTES times.
        for _ in range(MAX_REROUTES):
            idx = _PointIndex(_densify([route["path"]], 0.25))
            hit = [c for c in closures if c not in blocking and _near_route(idx, c["geometry"], CLOSURE_ON_ROUTE_KM)]
            if not hit:
                break
            blocking += hit
            lines = [ln for c in blocking for ln in _closure_lines(c["geometry"])]
            pts = [pt for c in blocking for pt in _closure_points(c["geometry"])]
            alt = _solve([(o_lat, o_lon), (d_lat, d_lon)], polyline_barriers=lines, point_barriers=pts)
            if not alt:
                route = None
                break
            route = alt

    out = [f"Route: {o_name} to {d_name} (driving, traffic-aware for a departure now)"]
    if route is None:
        out.append(f"No alternative route exists while these roads are closed. Direct route would be {base['km']:.0f} km, {_fmt_min(base['min'])}.")
    else:
        straight = haversine_km(o_lat, o_lon, d_lat, d_lon)
        out.append(f"Distance: {route['km']:.0f} km by road ({straight:.0f} km as the kea flies). "
                   f"Estimated drive time: {_fmt_min(route['min'])}.")
        via = _via(route["steps"])
        if via:
            out.append(f"Via: {via}.")
    if blocking:
        out.append("ROAD CLOSED on the direct route:")
        out += [_event_line(c["properties"]) for c in blocking]
        if route is not None:
            out.append(f"Detour avoiding the closure: +{route['km'] - base['km']:.0f} km, +{_fmt_min(route['min'] - base['min'])} "
                       f"(direct route {base['km']:.0f} km, {_fmt_min(base['min'])}).")

    if events is None:
        out.append("NZTA road events could not be loaded, so current delays and closures are unknown.")
    elif route is not None:
        idx = _PointIndex(_densify([route["path"]], 0.25))
        along = []
        for f in events:
            p = f.get("properties") or {}
            if f in blocking or not f.get("geometry") or not relevant(p):
                continue
            if _near_route(idx, f["geometry"], EVENT_NEAR_ROUTE_KM):
                along.append(p)
        along.sort(key=lambda p: (_SEVERITY.get(p.get("Impact"), 4), p.get("LocationArea", "")))
        if along:
            out.append(f"NZTA events on or near the route ({len(along)}):")
            out += [_event_line(p) for p in along[:MAX_EVENTS_LISTED]]
            if len(along) > MAX_EVENTS_LISTED:
                out.append(f"- ... and {len(along) - MAX_EVENTS_LISTED} more minor events.")
        else:
            out.append("No other NZTA delays or closures reported on or near the route." if blocking
                       else "No NZTA delays or closures reported on or near the route.")
    return "\n".join(out)


def _closure_lines(geometry: dict) -> list:
    t, raw = geometry.get("type", ""), geometry.get("coordinates", [])
    if t == "LineString":
        return [raw]
    if t == "MultiLineString":
        return [ln for ln in raw if len(ln) >= 2]
    return []


def _closure_points(geometry: dict) -> list:
    return [tuple(geometry["coordinates"][:2])] if geometry.get("type") == "Point" else []


def handler(event: dict, context) -> dict:
    params = {p["name"]: p["value"] for p in event.get("parameters", [])}
    function = event.get("function", "")

    try:
        if function == "route_between":
            origin = params.get("origin", "").strip()
            destination = params.get("destination", "").strip()
            if not origin or not destination:
                body = "Error: origin and destination are required"
            else:
                body = route_between(origin, destination)

        elif function == "find_place":
            query = params.get("query", "").strip()
            if not query:
                body = "Error: query parameter is required"
            else:
                lat = float(params["lat"]) if params.get("lat") else None
                lon = float(params["lon"]) if params.get("lon") else None
                body = find_place(query, lat, lon)

        elif function == "reverse_geocode":
            lat = float(params.get("lat", 0))
            lon = float(params.get("lon", 0))
            body = reverse_geocode(lat, lon)

        else:
            body = f"Unknown function: {function}"

    except Exception as e:
        body = f"Geocode error: {e}"

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup", ""),
            "function": function,
            "functionResponse": {
                "responseBody": {"TEXT": {"body": body}}
            }
        }
    }
