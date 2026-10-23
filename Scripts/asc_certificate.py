#!/usr/bin/env python3
"""Creates an Apple Distribution certificate for App Store uploads via the App Store Connect API – once per team.

Usage: asc_certificate.py KEY_ID ISSUER_ID KEY_PATH OUTPUT_DIR
Writes OUTPUT_DIR/dist.key (the private key never leaves this Mac) and OUTPUT_DIR/dist.pem. This adds a certificate to
the team's account – Apple allows only a few distribution certificates per team – so run it deliberately.
"""
import base64, os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import call, configure  # noqa: E402

if len(sys.argv) != 5:
    sys.exit(__doc__)
KEY_ID, ISSUER, KEY_PATH, OUTPUT = sys.argv[1:5]
configure(KEY_ID, ISSUER, KEY_PATH)

os.makedirs(OUTPUT, exist_ok=True)
key, pem = os.path.join(OUTPUT, "dist.key"), os.path.join(OUTPUT, "dist.pem")
if os.path.exists(pem):
    sys.exit(f"{pem} existiert schon.")
csr = subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-subj", "/CN=Jelly Distribution"],
                     capture_output=True, check=True).stdout.decode()
os.chmod(key, 0o600)
body = "".join(line for line in csr.splitlines() if "CERTIFICATE REQUEST" not in line)
certificate = call("POST", "/certificates", {"data": {"type": "certificates",
                   "attributes": {"certificateType": "DISTRIBUTION", "csrContent": body}}})["data"]
der = base64.b64decode(certificate["attributes"]["certificateContent"])
subprocess.run(["openssl", "x509", "-inform", "der", "-out", pem], input=der, check=True)
print(f"Apple Distribution: {certificate['attributes']['name']} (Seriennummer {certificate['attributes']['serialNumber']}) → {OUTPUT}")
