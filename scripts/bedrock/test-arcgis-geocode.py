#!/usr/bin/env python3
"""Local test for arcgis-geocode Lambda logic (bypasses Secrets Manager)."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambda/arcgis-geocode'))

# Inject credentials directly into the cache to bypass Secrets Manager
import index as geocode
geocode._token_cache["client_id"] = "<client_id>"
geocode._token_cache["client_secret"] = "<client_secret>"

print("=== find_place: Manapouri Airport ===")
print(geocode.find_place("Manapouri Airport"))

print("\n=== find_place: Burnham Military Camp ===")
print(geocode.find_place("Burnham Military Camp"))

print("\n=== find_place: Linton Military Camp ===")
print(geocode.find_place("Linton Military Camp"))

print("\n=== reverse_geocode: Wellington CBD ===")
print(geocode.reverse_geocode(-41.2784, 174.7767))

print("\n=== reverse_geocode: Manapouri ===")
print(geocode.reverse_geocode(-45.5333, 167.6167))
