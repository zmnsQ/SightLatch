#!/usr/bin/env python3
"""Prepare a PRIVATE per-device Security2 label + factory NVS CSV, offline.

Does not flash, upload or log a pairing secret. Run only when preparing your own
board. Keep label.txt private; do not commit generated output. The CSV contains
salt/verifier, never the pairing password. No third-party Python dependencies.
"""
import argparse
import csv
import hashlib
import os
from pathlib import Path
import secrets

USERNAME = "sightlatch"
# RFC5054's 3072-bit group (RFC3526 MODP prime), generator 5.
N = int("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF", 16)


def derive_verifier(password: str, salt: bytes) -> bytes:
    if len(salt) != 32:
        raise ValueError("salt must retain exactly 32 bytes, including leading zeroes")
    inner = hashlib.sha512((USERNAME + ":" + password).encode("ascii")).digest()
    x = int.from_bytes(hashlib.sha512(salt + inner).digest(), "big")
    return pow(5, x, N).to_bytes(384, "big")


def prepare(destination: Path) -> None:
    # Refuse overwrite; no credentials in arguments or stdout.
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    password = secrets.token_hex(16)
    salt = secrets.token_bytes(32)
    verifier = derive_verifier(password, salt)
    fd = os.open(destination / "label.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("SightLatch S3 USB experimental\nUsername: sightlatch\nPairing code: " + password + "\nKeep this label private. Hold the board button for 3 seconds before pairing.\n")
    fd = os.open(destination / "factory.csv", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["key", "type", "encoding", "value"])
        writer.writerow(["sl_usb_factory", "namespace", "", ""])
        writer.writerow(["salt", "data", "hex2bin", salt.hex()])
        writer.writerow(["verifier", "data", "hex2bin", verifier.hex()])
    # The caller must protect any later generated binary with umask 077 too.
    print("Private label and verifier CSV created. No device was flashed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new PRIVATE directory outside the repository")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    if args.destination.resolve().is_relative_to(repo):
        parser.error("output must be outside the repository")
    prepare(args.destination)
