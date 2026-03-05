"""
Bedrock Agent action group Lambda: arcgis-geocode

Functions:
  find_place(query, [lat, lon])     - forward geocode a place name to lat/lon
  reverse_geocode(lat, lon)         - reverse geocode coordinates to an address

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


def handler(event: dict, context) -> dict:
    params = {p["name"]: p["value"] for p in event.get("parameters", [])}
    function = event.get("function", "")

    try:
        if function == "find_place":
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
