#!/usr/bin/env python3
"""App Store Connect API helpers shared by asc_profile.py and asc_certificate.py: a JWT from the API key and JSON calls.
Only the standard library and the openssl CLI are used."""
import base64, json, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

KEY_ID = ISSUER = KEY_PATH = ""


def configure(key_id, issuer, key_path):
    global KEY_ID, ISSUER, KEY_PATH
    KEY_ID, ISSUER, KEY_PATH = key_id, issuer, key_path


API = "https://api.appstoreconnect.apple.com/v1"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    # ECDSA DER (SEQUENCE of two INTEGERs) -> 64-byte r||s as JWS requires.
    def read_int(offset):
        assert der[offset] == 0x02
        length = der[offset + 1]
        value = der[offset + 2: offset + 2 + length].lstrip(b"\x00")
        return value.rjust(32, b"\x00"), offset + 2 + length
    offset = 2 if der[1] < 0x80 else 3
    r, offset = read_int(offset)
    s, _ = read_int(offset)
    return r + s


def token() -> str:
    header = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    now = int(time.time())
    payload = b64(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY_PATH], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64(der_to_raw(der))}"


def call(method, path, body=None, fatal=True):
    """One API request; `path` may also be a full URL (pagination links). Errors end the script unless `fatal` is
    False, then they are printed and None is returned."""
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    request.add_header("Authorization", f"Bearer {token()}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        text = f"App Store Connect {method} {url.split('?')[0].replace(API, '')}: {error.code} {error.read().decode()[:600]}"
        if fatal:
            sys.exit(text)
        print("  ! " + text)
        return None


def find(path):
    """The resource a to-one link points to, or None while it doesn't exist yet (404 or `"data": null`)."""
    request = urllib.request.Request(API + path)
    request.add_header("Authorization", f"Bearer {token()}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read()).get("data")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        sys.exit(f"App Store Connect GET {path.split('?')[0]}: {error.code} {error.read().decode()[:600]}")


def pages(path):
    """Every item of a list endpoint, following the `next` links."""
    items, included = [], []
    while path:
        result = call("GET", path)
        items += result.get("data", [])
        included += result.get("included", [])
        path = result.get("links", {}).get("next")
    return items, included


def upload(operations, data):
    """Sends a file to the upload operations App Store Connect handed out for an asset reservation."""
    for operation in operations:
        chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
        request = urllib.request.Request(operation["url"], method=operation["method"], data=chunk)
        for header in operation.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        urllib.request.urlopen(request, timeout=120).read()


def query(path, **filters):
    return path + "?" + urllib.parse.urlencode({f"filter[{k}]": v for k, v in filters.items()})
