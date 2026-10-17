#!/bin/bash
# Creates the key that signs Feather updates and stores it in your login Keychain. Prints ONLY the public key.
# The private key never touches a file. Back it up yourself (see tools/export-update-key.sh): if it is lost, installed copies
# of Feather can no longer be updated automatically and must be reinstalled by hand.
set -euo pipefail
ACCOUNT=feather-update-signing; SERVICE=dev.feather.update-key
if security find-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null 2>&1; then echo "A key already exists in your Keychain; refusing to replace it." >&2; exit 1; fi
python3 - "$ACCOUNT" "$SERVICE" <<'PY'
import base64, subprocess, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = Ed25519PrivateKey.generate()
seed = k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())
pub = k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
subprocess.run(["security", "add-generic-password", "-a", sys.argv[1], "-s", sys.argv[2], "-l", "Feather update signing key", "-w", base64.b64encode(seed).decode()], check=True)
print("public key (goes into project.yml as UPDATE_PUBLIC_KEY):", base64.b64encode(pub).decode())
PY
