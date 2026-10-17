#!/usr/bin/env python3
"""Creates and signs the update manifest for a release zip.

  python3 tools/make-update.py <Feather-X.Y.Z-alpha.zip> <outdir>

Writes <outdir>/update.json and <outdir>/update.json.sig. The version and build are read from the app inside the zip (not typed
by hand), so the manifest always describes what is really in the zip. The signing key comes from your login Keychain
(tools/new-update-key.sh), or from the file named in FEATHER_UPDATE_KEY_FILE (tests only: a base64 seed).
Requires: pip install cryptography
"""
import base64, hashlib, json, os, plistlib, subprocess, sys, tempfile, zipfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

def seed():
    path = os.environ.get("FEATHER_UPDATE_KEY_FILE")
    if path:
        return base64.b64decode(open(path).read().strip())
    out = subprocess.run(["security", "find-generic-password", "-a", "feather-update-signing", "-s", "dev.feather.update-key", "-w"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("No signing key in the Keychain. Run tools/new-update-key.sh first.")
    return base64.b64decode(out.stdout.strip())

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    zip_path, outdir = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(zip_path) as z:
        plist = plistlib.loads(z.read("Feather.app/Contents/Info.plist"))
    data = open(zip_path, "rb").read()
    manifest = {
        "schema": 1,
        "bundleID": plist["CFBundleIdentifier"],
        "version": plist["CFBundleShortVersionString"],
        "build": int(plist["CFBundleVersion"]),
        "asset": os.path.basename(zip_path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    }
    body = json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
    signature = Ed25519PrivateKey.from_private_bytes(seed()).sign(body)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "update.json"), "wb").write(body)
    open(os.path.join(outdir, "update.json.sig"), "w").write(base64.b64encode(signature).decode() + "\n")
    print(json.dumps(manifest, indent=2))

main()
