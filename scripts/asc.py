#!/usr/bin/env python3
"""Minimal App Store Connect API client for the release pipeline.

Reads ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID from the environment (see
scripts/lib.sh, which fetches the key from 1Password). Standard library plus
`cryptography` only.

Subcommands:
  latest-build                 print the highest uploaded build number
  status                       print recent versions and builds
  wait-build <build>           block until that build finishes processing
  submit --version V --build N --whats-new-file F [--release manual|auto] [--dry-run]
                               create/rename the macOS version record, set What's New
                               for every localization, attach the build, and submit
                               for review
"""
import argparse, base64, json, os, sys, time, urllib.error, urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.ToWatchList.SimpleComic")
BASE = "https://api.appstoreconnect.apple.com"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def token():
    now = int(time.time())
    hdr = _b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
    pl = _b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900,
                          "aud": "appstoreconnect-v1"}).encode())
    key = serialization.load_pem_private_key(open(os.environ["ASC_KEY_PATH"], "rb").read(), None)
    r, s = utils.decode_dss_signature(key.sign(hdr + b"." + pl, ec.ECDSA(hashes.SHA256())))
    return (hdr + b"." + pl + b"." + _b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()


def api(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(),
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"ASC API {method} {path} failed: {e.code} {e.read().decode()[:800]}")


def app_id():
    d = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not d:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    return d[0]["id"]


def builds(aid, limit=10):
    return api("GET", f"/v1/builds?filter[app]={aid}&sort=-uploadedDate&limit={limit}")["data"]


def versions(aid):
    return api("GET", f"/v1/apps/{aid}/appStoreVersions?filter[platform]=MAC_OS&limit=10")["data"]


def cmd_latest_build(_):
    nums = [int(b["attributes"]["version"]) for b in builds(app_id(), 50)
            if b["attributes"]["version"].isdigit()]
    print(max(nums) if nums else 0)


def cmd_status(_):
    aid = app_id()
    for v in versions(aid):
        print("version", v["attributes"]["versionString"], v["attributes"]["appStoreState"])
    for b in builds(aid, 5):
        a = b["attributes"]
        print("build", a["version"], a["processingState"], a["uploadedDate"])


def find_build(aid, number):
    for b in builds(aid, 50):
        if b["attributes"]["version"] == str(number):
            return b
    return None


def cmd_wait_build(a):
    aid = app_id()
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        b = find_build(aid, a.build)
        state = b["attributes"]["processingState"] if b else "NOT_VISIBLE_YET"
        print(f"build {a.build}: {state}", flush=True)
        if state == "VALID":
            return
        if state in ("FAILED", "INVALID"):
            sys.exit(f"build {a.build} processing {state}")
        time.sleep(30)
    sys.exit(f"timed out waiting for build {a.build}")


def cmd_submit(a):
    aid = app_id()
    notes = open(a.whats_new_file).read().strip()
    build = find_build(aid, a.build)
    if not build or build["attributes"]["processingState"] != "VALID":
        sys.exit(f"build {a.build} is not uploaded and processed; run wait-build first")
    release_type = "MANUAL" if a.release == "manual" else "AFTER_APPROVAL"

    existing = {v["attributes"]["versionString"]: v for v in versions(aid)}
    ver = existing.get(a.version)
    if ver is None:
        editable = [v for v in existing.values() if v["attributes"]["appStoreState"] in EDITABLE]
        if editable:
            ver = editable[0]
            print(f"renaming editable version {ver['attributes']['versionString']} -> {a.version}")
            if not a.dry_run:
                api("PATCH", f"/v1/appStoreVersions/{ver['id']}", {"data": {
                    "type": "appStoreVersions", "id": ver["id"],
                    "attributes": {"versionString": a.version, "releaseType": release_type}}})
        else:
            print(f"creating version {a.version}")
            if a.dry_run:
                ver = {"id": "(dry-run)"}
            else:
                ver = api("POST", "/v1/appStoreVersions", {"data": {
                    "type": "appStoreVersions",
                    "attributes": {"platform": "MAC_OS", "versionString": a.version, "releaseType": release_type},
                    "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})["data"]
    else:
        state = ver["attributes"]["appStoreState"]
        if state not in EDITABLE:
            sys.exit(f"version {a.version} already exists and is {state}; nothing to do")
    vid = ver["id"]

    if not a.dry_run:
        locs = api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
        for loc in locs:
            api("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {
                "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}})
        print(f"set What's New on {len(locs)} localization(s)")
        api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
            {"data": {"type": "builds", "id": build["id"]}})
        print(f"attached build {a.build}")
        sub = api("POST", "/v1/reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "MAC_OS"},
            "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})["data"]
        api("POST", "/v1/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                              "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
        api("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {
            "type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}})
        print(f"submitted {a.version} ({a.build}) for review, release={a.release}")
    else:
        print(f"[dry-run] would set What's New, attach build {a.build}, and submit {a.version} for review")


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("latest-build").set_defaults(fn=cmd_latest_build)
    sp.add_parser("status").set_defaults(fn=cmd_status)
    w = sp.add_parser("wait-build"); w.add_argument("build"); w.add_argument("--timeout", type=int, default=3600)
    w.set_defaults(fn=cmd_wait_build)
    s = sp.add_parser("submit")
    s.add_argument("--version", required=True); s.add_argument("--build", required=True)
    s.add_argument("--whats-new-file", required=True)
    s.add_argument("--release", choices=["manual", "auto"], default="manual")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_submit)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
