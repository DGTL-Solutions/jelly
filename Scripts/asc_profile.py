#!/usr/bin/env python3
"""Creates (or reuses) the bundle ID and a tvOS profile via the App Store Connect API.

Usage: asc_profile.py KEY_ID ISSUER_ID KEY_PATH BUNDLE_ID CERT_PEM DEVICE_UDID OUTPUT.mobileprovision [PROFILE_NAME] [PROFILE_TYPE]
PROFILE_TYPE defaults to TVOS_APP_DEVELOPMENT; TVOS_APP_STORE needs no device (pass - as DEVICE_UDID).
Prints the profile name. Only the standard library and the openssl CLI are used.
"""
import base64, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import call, configure, query  # noqa: E402

KEY_ID, ISSUER, KEY_PATH, BUNDLE_ID, CERT_PEM, UDID, OUTPUT = sys.argv[1:8]
PROFILE_NAME = sys.argv[8] if len(sys.argv) > 8 else "Jelly tvOS Development"
PROFILE_TYPE = sys.argv[9] if len(sys.argv) > 9 else "TVOS_APP_DEVELOPMENT"
FOR_DEVICES = PROFILE_TYPE.endswith("DEVELOPMENT") or PROFILE_TYPE.endswith("ADHOC")
configure(KEY_ID, ISSUER, KEY_PATH)

# Bundle ID (tvOS apps use the IOS platform in the API).
found = [b for b in call("GET", query("/bundleIds", identifier=BUNDLE_ID))["data"] if b["attributes"]["identifier"] == BUNDLE_ID]
bundle = found[0] if found else call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
    "identifier": BUNDLE_ID, "name": PROFILE_NAME.replace(" Development", "").replace(" App Store", ""), "platform": "IOS"}}})["data"]

# The certificate whose private key we hold, matched by serial number.
serial = subprocess.run(["openssl", "x509", "-in", CERT_PEM, "-noout", "-serial"], capture_output=True, text=True,
                        check=True).stdout.strip().split("=")[1].lstrip("0").upper()
certificates = call("GET", "/certificates?limit=200")["data"]
certificate = next((c for c in certificates if c["attributes"]["serialNumber"].lstrip("0").upper() == serial), None)
if not certificate:
    sys.exit("Das Zertifikat ist im Account nicht (mehr) vorhanden.")

# The Apple TV, registered if needed (development profiles only).
device = None
if FOR_DEVICES:
    devices = call("GET", query("/devices", udid=UDID))["data"]
    device = devices[0] if devices else call("POST", "/devices", {"data": {"type": "devices", "attributes": {
        "name": "Apple TV", "udid": UDID, "platform": "IOS"}}})["data"]

# One profile named after the app, reused while active; replaced when Apple marks it invalid or it nears expiry.
name = PROFILE_NAME
profile = None
for existing in call("GET", query("/profiles", name=name))["data"]:
    attributes = existing["attributes"]
    expires = time.mktime(time.strptime(attributes["expirationDate"][:19], "%Y-%m-%dT%H:%M:%S"))
    if attributes["profileState"] == "ACTIVE" and expires - time.time() > 7 * 86400 and profile is None:
        profile = existing
    else:
        call("DELETE", f"/profiles/{existing['id']}")
if profile is None:
    relationships = {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                     "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]}}
    if device:
        relationships["devices"] = {"data": [{"type": "devices", "id": device["id"]}]}
    profile = call("POST", "/profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": PROFILE_TYPE},
        "relationships": relationships}})["data"]
with open(OUTPUT, "wb") as file:
    file.write(base64.b64decode(profile["attributes"]["profileContent"]))
print(name)
