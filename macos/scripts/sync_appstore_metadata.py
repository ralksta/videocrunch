#!/usr/bin/env python3
"""Sync VideoCrunch metadata, screenshots, review notes, build link, and custom EULA
to App Store Connect via the official App Store Connect REST API v1.

Zero external Python packages required: uses Python stdlib + macOS `openssl` for ES256 JWTs.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE_URL = "https://api.appstoreconnect.apple.com/v1"
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BUNDLE_ID = "io.github.ralksta.videocrunch"
DEFAULT_VERSION = "1.0"
DEFAULT_BUILD = "1"
DEFAULT_METADATA_PATH = REPO_ROOT / "macos" / "appstore" / "APP-STORE-METADATA.md"
DEFAULT_EULA_PATH = REPO_ROOT / "macos" / "legal" / "AppStore-Custom-EULA.local.txt"
DEFAULT_SCREENSHOTS_DIR = REPO_ROOT / "macos" / "appstore" / "screenshots"
DEFAULT_CONFIG_PATH = Path.home() / ".appstoreconnect" / "asc_config.json"


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_ecdsa_to_raw_rs(der: bytes, coord_size: int = 32) -> bytes:
    """Convert an ASN.1 DER-encoded ECDSA signature (SEQUENCE { INTEGER r, INTEGER s })
    into the fixed-width 64-byte raw (r || s) representation required by ES256 JWTs.
    """
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("Invalid DER ECDSA signature header")
    idx = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)

    def read_int(pos: int) -> tuple[bytes, int]:
        if der[pos] != 0x02:
            raise ValueError(f"Expected ASN.1 INTEGER at offset {pos}")
        length = der[pos + 1]
        start = pos + 2
        val = der[start : start + length]
        val = val.lstrip(b"\x00")
        if len(val) > coord_size:
            raise ValueError(f"ECDSA integer larger than {coord_size} bytes")
        return val.rjust(coord_size, b"\x00"), start + length

    r_bytes, next_pos = read_int(idx)
    s_bytes, _ = read_int(next_pos)
    return r_bytes + s_bytes


def generate_asc_jwt(key_id: str, issuer_id: str, p8_path: Path, ttl_sec: int = 900) -> str:
    """Create a short-lived ES256 JWT signed with the App Store Connect .p8 private key."""
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now - 10,
        "exp": now + ttl_sec,
        "aud": "appstoreconnect-v1",
    }
    signing_input = f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}.{_b64url(json.dumps(payload, separators=(',', ':')).encode())}"

    with tempfile.NamedTemporaryFile("wb", delete=False) as tmp_in:
        tmp_in.write(signing_input.encode("ascii"))
        tmp_in_path = tmp_in.name
    try:
        res = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(p8_path), tmp_in_path],
            capture_output=True,
            check=True,
        )
    finally:
        try:
            os.unlink(tmp_in_path)
        except OSError:
            pass

    raw_sig = _der_ecdsa_to_raw_rs(res.stdout, coord_size=32)
    return f"{signing_input}.{_b64url(raw_sig)}"


def parse_appstore_metadata(md_path: Path) -> dict[str, dict[str, str]]:
    """Parse DE/EN Store copy and App Review Notes from APP-STORE-METADATA.md."""
    text = md_path.read_text(encoding="utf-8")
    blocks = re.findall(r"^### ([^\n]+)\n\n```text\n(.*?)\n```", text, re.MULTILINE | re.DOTALL)
    if len(blocks) != 12:
        raise ValueError(f"Expected 12 DE/EN metadata fenced blocks in {md_path}, found {len(blocks)}")

    de_blocks = {hdr: body for hdr, body in blocks[:6]}
    en_blocks = {hdr: body for hdr, body in blocks[6:12]}

    def pick(mapping: dict[str, str], prefix: str) -> str:
        for k, v in mapping.items():
            if k.startswith(prefix):
                return v
        raise KeyError(f"Missing section starting with {prefix!r}")

    review_match = re.search(
        r"^## 4\. App Review Information[^\n]*\n\n```text\n(.*?)\n```",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not review_match:
        raise ValueError(f"Missing Section 4 App Review Notes fenced block in {md_path}")

    privacy_url = "https://github.com/ralksta/videocrunch/blob/main/PRIVACY.md"
    support_url = "https://github.com/ralksta/videocrunch/blob/main/SUPPORT.md"
    marketing_url = "https://github.com/ralksta/videocrunch"

    de_data = {
        "name": pick(de_blocks, "Name"),
        "subtitle": pick(de_blocks, "Subtitle"),
        "promotionalText": pick(de_blocks, "Promotional Text"),
        "keywords": pick(de_blocks, "Keywords"),
        "description": pick(de_blocks, "Description"),
        "whatsNew": pick(de_blocks, "What's New"),
        "privacyPolicyUrl": privacy_url,
        "supportUrl": support_url,
        "marketingUrl": marketing_url,
    }
    en_data = {
        "name": pick(en_blocks, "Name"),
        "subtitle": pick(en_blocks, "Subtitle"),
        "promotionalText": pick(en_blocks, "Promotional Text"),
        "keywords": pick(en_blocks, "Keywords"),
        "description": pick(en_blocks, "Description"),
        "whatsNew": pick(en_blocks, "What's New"),
        "privacyPolicyUrl": privacy_url,
        "supportUrl": support_url,
        "marketingUrl": marketing_url,
    }

    return {
        "de-DE": de_data,
        "en-US": en_data,
        "en-GB": dict(en_data),
        "_review": {"notes": review_match.group(1)},
    }


def load_custom_eula(eula_path: Path) -> str:
    text = eula_path.read_text(encoding="utf-8").strip()
    if "[YOUR " in text:
        raise ValueError(f"{eula_path} still contains unfilled [YOUR ...] placeholders")
    return text


class ASCClient:
    def __init__(self, key_id: str, issuer_id: str, p8_path: Path, dry_run: bool = False):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.p8_path = p8_path
        self.dry_run = dry_run
        self._token = generate_asc_jwt(key_id, issuer_id, p8_path)

    def request(self, method: str, path_or_url: str, payload: dict | None = None) -> dict:
        url = path_or_url if path_or_url.startswith("http") else f"{BASE_URL}{path_or_url}"
        if self.dry_run and method != "GET":
            print(f"  [DRY-RUN] {method} {url}")
            return {"data": {"id": f"dry-{int(time.time())}", "attributes": {}}}

        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/json",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw.decode("utf-8")) if raw else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"ASC API {method} {url} -> HTTP {e.code}:\n{err_body}") from None

    def upload_part(self, method: str, url: str, headers_list: list[dict], chunk: bytes) -> None:
        if self.dry_run:
            print(f"  [DRY-RUN] {method} {url} ({len(chunk)} bytes)")
            return
        headers = {h["name"]: h["value"] for h in headers_list}
        req = urllib.request.Request(url, data=chunk, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=120) as resp:
            if resp.status not in (200, 201, 204):
                raise RuntimeError(f"Asset upload chunk failed: HTTP {resp.status}")


def find_p8_path(key_id: str, explicit_p8: str | None) -> Path:
    if explicit_p8:
        p = Path(explicit_p8).expanduser()
        if p.is_file():
            return p
        raise FileNotFoundError(f".p8 file not found: {p}")
    candidates = [
        Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8",
        Path.home() / ".private_keys" / f"AuthKey_{key_id}.p8",
        Path.home() / "private_keys" / f"AuthKey_{key_id}.p8",
        Path.cwd() / "private_keys" / f"AuthKey_{key_id}.p8",
    ]
    for c in candidates:
        if c.is_file():
            return c
    raise FileNotFoundError(f"Could not find AuthKey_{key_id}.p8 in standard directories")


def resolve_credentials(args: argparse.Namespace) -> tuple[str, str, Path]:
    cfg = {}
    if DEFAULT_CONFIG_PATH.is_file():
        cfg = json.loads(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8"))

    key_id = args.api_key or os.environ.get("ASC_KEY_ID") or cfg.get("key_id")
    issuer_id = args.api_issuer or os.environ.get("ASC_ISSUER_ID") or cfg.get("issuer_id")
    p8_arg = args.p8 or os.environ.get("ASC_P8_PATH") or cfg.get("p8_path")

    if not key_id or not issuer_id:
        raise SystemExit(
            "Missing API credentials. Provide --api-key & --api-issuer, env ASC_KEY_ID/ASC_ISSUER_ID, "
            f"or {DEFAULT_CONFIG_PATH}"
        )
    p8_path = find_p8_path(key_id, p8_arg)
    return key_id, issuer_id, p8_path


def sync_app_info_localizations(
    client: ASCClient,
    app_id: str,
    parsed: dict[str, dict[str, str]],
    locales: tuple[str, ...],
) -> str:
    app_infos = client.request("GET", f"/apps/{app_id}/appInfos?limit=10")["data"]
    if not app_infos:
        raise RuntimeError("No appInfos found for app")
    editable_states = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "WAITING_FOR_REVIEW", "IN_REVIEW"}
    info = next((i for i in app_infos if i["attributes"].get("appStoreState") in editable_states), app_infos[0])
    info_id = info["id"]
    print(f"Using appInfo {info_id} (state={info['attributes'].get('appStoreState')})")

    existing = client.request("GET", f"/appInfos/{info_id}/appInfoLocalizations?limit=50")["data"]
    by_locale = {loc["attributes"]["locale"]: loc for loc in existing}

    for locale in locales:
        m = parsed[locale]
        attrs = {
            "name": m["name"],
            "subtitle": m["subtitle"],
            "privacyPolicyUrl": m["privacyPolicyUrl"],
        }
        if locale in by_locale:
            loc_id = by_locale[locale]["id"]
            print(f"  PATCH appInfoLocalization [{locale}] ({loc_id})")
            client.request(
                "PATCH",
                f"/appInfoLocalizations/{loc_id}",
                {"data": {"type": "appInfoLocalizations", "id": loc_id, "attributes": attrs}},
            )
        else:
            print(f"  POST appInfoLocalization [{locale}]")
            client.request(
                "POST",
                "/appInfoLocalizations",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "attributes": {"locale": locale, **attrs},
                        "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}},
                    }
                },
            )
    return info_id


def sync_app_categories(
    client: ASCClient,
    info_id: str,
    primary_category: str | None,
    secondary_category: str | None,
) -> None:
    relationships: dict[str, dict] = {}
    if primary_category:
        relationships["primaryCategory"] = {"data": {"type": "appCategories", "id": primary_category}}
    if secondary_category:
        relationships["secondaryCategory"] = {"data": {"type": "appCategories", "id": secondary_category}}
    if not relationships:
        return
    print(f"  PATCH appInfo categories -> primary={primary_category}, secondary={secondary_category}")
    client.request(
        "PATCH",
        f"/appInfos/{info_id}",
        {"data": {"type": "appInfos", "id": info_id, "relationships": relationships}},
    )


def sync_version_copyright(client: ASCClient, version_id: str, copyright_text: str | None) -> None:
    if not copyright_text:
        return
    print(f"  PATCH appStoreVersion copyright -> {copyright_text!r}")
    client.request(
        "PATCH",
        f"/appStoreVersions/{version_id}",
        {"data": {"type": "appStoreVersions", "id": version_id, "attributes": {"copyright": copyright_text}}},
    )


def find_target_version(client: ASCClient, app_id: str, version_str: str) -> dict:
    versions = client.request("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=MAC_OS&limit=20")["data"]
    for v in versions:
        if v["attributes"].get("versionString") == version_str:
            return v
    raise RuntimeError(f"macOS appStoreVersion {version_str!r} not found (existing: {[v['attributes'].get('versionString') for v in versions]})")


def sync_version_localizations(
    client: ASCClient,
    version_id: str,
    parsed: dict[str, dict[str, str]],
    locales: tuple[str, ...],
    include_whats_new: bool,
) -> dict[str, str]:
    existing = client.request("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50")["data"]
    by_locale = {loc["attributes"]["locale"]: loc for loc in existing}
    ver_loc_ids: dict[str, str] = {}

    for locale in locales:
        m = parsed[locale]
        attrs = {
            "promotionalText": m["promotionalText"],
            "description": m["description"],
            "keywords": m["keywords"],
            "supportUrl": m["supportUrl"],
            "marketingUrl": m["marketingUrl"],
        }
        if include_whats_new:
            attrs["whatsNew"] = m["whatsNew"]

        if locale in by_locale:
            loc_id = by_locale[locale]["id"]
            print(f"  PATCH appStoreVersionLocalization [{locale}] ({loc_id})")
            try:
                client.request(
                    "PATCH",
                    f"/appStoreVersionLocalizations/{loc_id}",
                    {"data": {"type": "appStoreVersionLocalizations", "id": loc_id, "attributes": attrs}},
                )
            except RuntimeError as exc:
                if include_whats_new and "whatsNew" in str(exc):
                    print("    NOTE: whatsNew not editable on initial release — retrying without whatsNew")
                    attrs.pop("whatsNew", None)
                    client.request(
                        "PATCH",
                        f"/appStoreVersionLocalizations/{loc_id}",
                        {"data": {"type": "appStoreVersionLocalizations", "id": loc_id, "attributes": attrs}},
                    )
                else:
                    raise
            ver_loc_ids[locale] = loc_id
        else:
            print(f"  POST appStoreVersionLocalization [{locale}]")
            res = client.request(
                "POST",
                "/appStoreVersionLocalizations",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "attributes": {"locale": locale, **attrs},
                        "relationships": {
                            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
                        },
                    }
                },
            )
            ver_loc_ids[locale] = res["data"]["id"]
    return ver_loc_ids


def sync_screenshots_for_locale(
    client: ASCClient,
    ver_loc_id: str,
    locale: str,
    png_paths: list[Path],
    replace_existing: bool,
) -> None:
    if not png_paths:
        return
    if ver_loc_id.startswith("dry-"):
        print(f"  [DRY-RUN] Would upload {len(png_paths)} APP_DESKTOP screenshot(s) for new locale [{locale}]")
        return
    sets = client.request("GET", f"/appStoreVersionLocalizations/{ver_loc_id}/appScreenshotSets?limit=20")["data"]
    desktop_set = next((s for s in sets if s["attributes"].get("screenshotDisplayType") == "APP_DESKTOP"), None)

    if desktop_set is None:
        print(f"  POST appScreenshotSet [{locale}] (APP_DESKTOP)")
        created_set = client.request(
            "POST",
            "/appScreenshotSets",
            {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                    "relationships": {
                        "appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations", "id": ver_loc_id}
                        }
                    },
                }
            },
        )
        set_id = created_set["data"]["id"]
        existing_shots = []
    else:
        set_id = desktop_set["id"]
        existing_shots = client.request("GET", f"/appScreenshotSets/{set_id}/appScreenshots?limit=50")["data"]

    if existing_shots and not replace_existing:
        print(f"  Screenshot set [{locale}] already has {len(existing_shots)} item(s); pass --replace-screenshots to overwrite.")
        return

    for old in existing_shots:
        print(f"  DELETE old screenshot [{locale}] {old['id']} ({old['attributes'].get('fileName')})")
        client.request("DELETE", f"/appScreenshots/{old['id']}")

    for png in png_paths:
        raw_bytes = png.read_bytes()
        md5_hex = hashlib.md5(raw_bytes).hexdigest()
        print(f"  UPLOAD [{locale}] {png.name} ({len(raw_bytes) // 1024} KB)")
        reserved = client.request(
            "POST",
            "/appScreenshots",
            {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {"fileName": png.name, "fileSize": len(raw_bytes)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
                }
            },
        )
        shot_id = reserved["data"]["id"]
        ops = reserved["data"]["attributes"].get("uploadOperations", [])
        for op in ops:
            off = int(op["offset"])
            length = int(op["length"])
            client.upload_part(op["method"], op["url"], op.get("requestHeaders", []), raw_bytes[off : off + length])

        client.request(
            "PATCH",
            f"/appScreenshots/{shot_id}",
            {
                "data": {
                    "type": "appScreenshots",
                    "id": shot_id,
                    "attributes": {"uploaded": True, "sourceFileChecksum": md5_hex},
                }
            },
        )

    if not client.dry_run:
        for _ in range(10):
            shots = client.request("GET", f"/appScreenshotSets/{set_id}/appScreenshots?limit=50")["data"]
            states = [s["attributes"].get("assetDeliveryState", {}).get("state") for s in shots]
            if all(st not in (None, "AWAITING_UPLOAD", "UPLOAD_COMPLETE") for st in states):
                break
            time.sleep(2)
        summary = [(s["attributes"].get("fileName"), s["attributes"].get("assetDeliveryState", {}).get("state")) for s in shots]
        print(f"  Screenshots [{locale}] delivery state: {summary}")


def attach_build(client: ASCClient, app_id: str, version_id: str, build_number: str) -> None:
    builds = client.request("GET", f"/apps/{app_id}/builds?limit=50")["data"]
    matching = [b for b in builds if b["attributes"].get("version") == build_number]
    valid = [b for b in matching if b["attributes"].get("processingState") == "VALID"]
    if not valid:
        print(f"  NOTE: No VALID build #{build_number} found yet ({[b['attributes'].get('processingState') for b in builds]})")
        return
    build_id = valid[0]["id"]
    print(f"  PATCH version build -> #{build_number} ({build_id})")
    client.request(
        "PATCH",
        f"/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )


def sync_review_details(
    client: ASCClient,
    version_id: str,
    notes: str,
    contact_first_name: str | None,
    contact_last_name: str | None,
    contact_email: str,
    contact_phone: str | None,
) -> None:
    existing = None
    try:
        res = client.request("GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail")
        existing = res.get("data")
    except RuntimeError:
        existing = None

    ex_attrs = existing.get("attributes", {}) if existing else {}
    attrs: dict[str, object] = {
        "contactEmail": contact_email,
        "demoAccountRequired": False,
        "notes": notes,
    }
    first = contact_first_name or ex_attrs.get("contactFirstName")
    last = contact_last_name or ex_attrs.get("contactLastName")
    phone = contact_phone or ex_attrs.get("contactPhone")
    if first:
        attrs["contactFirstName"] = first
    if last:
        attrs["contactLastName"] = last
    if phone:
        attrs["contactPhone"] = phone

    if existing and existing.get("id"):
        rid = existing["id"]
        print(f"  PATCH appStoreReviewDetail ({rid})")
        client.request(
            "PATCH",
            f"/appStoreReviewDetails/{rid}",
            {"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": attrs}},
        )
    else:
        missing = [k for k in ("contactFirstName", "contactLastName", "contactPhone") if k not in attrs]
        if missing:
            print(
                f"  NOTE: Skipping appStoreReviewDetails create — pass --first-name, --last-name, --phone "
                f"(or save in {DEFAULT_CONFIG_PATH}) to create initial review details."
            )
            return
        print("  POST appStoreReviewDetails")
        client.request(
            "POST",
            "/appStoreReviewDetails",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": attrs,
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
                }
            },
        )


def sync_custom_eula(client: ASCClient, app_id: str, eula_text: str) -> None:
    existing = None
    try:
        res = client.request("GET", f"/apps/{app_id}/endUserLicenseAgreement")
        existing = res.get("data")
    except RuntimeError:
        existing = None

    if existing and existing.get("id"):
        eid = existing["id"]
        print(f"  PATCH endUserLicenseAgreement ({eid})")
        client.request(
            "PATCH",
            f"/endUserLicenseAgreements/{eid}",
            {"data": {"type": "endUserLicenseAgreements", "id": eid, "attributes": {"agreementText": eula_text}}},
        )
    else:
        territories = client.request("GET", "/territories?limit=200")["data"]
        t_refs = [{"type": "territories", "id": t["id"]} for t in territories]
        print(f"  POST endUserLicenseAgreements ({len(t_refs)} territories)")
        client.request(
            "POST",
            "/endUserLicenseAgreements",
            {
                "data": {
                    "type": "endUserLicenseAgreements",
                    "attributes": {"agreementText": eula_text},
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                        "territories": {"data": t_refs},
                    },
                }
            },
        )


def main() -> int:
    ap = argparse.ArgumentParser(description="Sync VideoCrunch metadata, screenshots & EULA via App Store Connect API.")
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    ap.add_argument("--version", default=DEFAULT_VERSION)
    ap.add_argument("--build", default=DEFAULT_BUILD)
    ap.add_argument("--locales", default="de-DE,en-US", help="Comma-separated locales (e.g. de-DE,en-US,en-GB)")
    ap.add_argument("--api-key", help="App Store Connect Key ID (or ASC_KEY_ID / ~/.appstoreconnect/asc_config.json)")
    ap.add_argument("--api-issuer", help="App Store Connect Issuer ID (or ASC_ISSUER_ID)")
    ap.add_argument("--p8", help="Path to AuthKey_<KEY_ID>.p8")
    ap.add_argument("--first-name", help="Review contact first name")
    ap.add_argument("--last-name", help="Review contact last name")
    ap.add_argument("--phone", help="Contact phone for Apple App Review (e.g. +4930...)")
    ap.add_argument("--contact-email", default="videocrunch@ralfus.de")
    ap.add_argument("--copyright", help="Version copyright line (or ASC_COPYRIGHT / ~/.appstoreconnect/asc_config.json)")
    ap.add_argument("--primary-category", default="PHOTO_AND_VIDEO", help="App category ID (empty string to skip)")
    ap.add_argument("--secondary-category", default="UTILITIES", help="Secondary category ID (empty string to skip)")
    ap.add_argument("--include-whats-new", action="store_true", help="Include whatsNew (typically updates >1.0 only)")
    ap.add_argument("--sync-screenshots", action="store_true", help="Upload 2880x1800 PNGs from macos/appstore/screenshots/")
    ap.add_argument("--replace-screenshots", action="store_true", help="Delete existing screenshots in APP_DESKTOP set first")
    ap.add_argument("--sync-eula", action="store_true", help="Sync Custom EULA from AppStore-Custom-EULA.local.txt")
    ap.add_argument("--attach-build", action="store_true", help="Attach specified --build number to the version")
    ap.add_argument("--dry-run", action="store_true", help="Read live state without modifying anything")
    args = ap.parse_args()

    locales = tuple(loc.strip() for loc in args.locales.split(",") if loc.strip())
    parsed = parse_appstore_metadata(DEFAULT_METADATA_PATH)
    for loc in locales:
        if loc not in parsed:
            raise SystemExit(f"Unsupported locale {loc!r}; available: de-DE, en-US, en-GB")
    eula_text = load_custom_eula(DEFAULT_EULA_PATH) if args.sync_eula else None

    cfg = json.loads(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8")) if DEFAULT_CONFIG_PATH.is_file() else {}
    first_name = args.first_name or os.environ.get("ASC_FIRST_NAME") or cfg.get("first_name")
    last_name = args.last_name or os.environ.get("ASC_LAST_NAME") or cfg.get("last_name")
    phone = args.phone or os.environ.get("ASC_PHONE") or cfg.get("phone")
    copyright_text = args.copyright or os.environ.get("ASC_COPYRIGHT") or cfg.get("copyright")

    key_id, issuer_id, p8_path = resolve_credentials(args)
    client = ASCClient(key_id, issuer_id, p8_path, dry_run=args.dry_run)

    apps = client.request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(args.bundle_id)}&limit=5")["data"]
    if not apps:
        raise SystemExit(f"App {args.bundle_id!r} not found in App Store Connect.")
    app_id = apps[0]["id"]
    print(f"Found app {args.bundle_id} -> id={app_id}")

    info_id = sync_app_info_localizations(client, app_id, parsed, locales)
    sync_app_categories(client, info_id, args.primary_category or None, args.secondary_category or None)

    ver = find_target_version(client, app_id, args.version)
    ver_id = ver["id"]
    print(f"Using macOS version {args.version} -> id={ver_id} (state={ver['attributes'].get('appStoreState')})")

    sync_version_copyright(client, ver_id, copyright_text)
    ver_loc_ids = sync_version_localizations(client, ver_id, parsed, locales, include_whats_new=args.include_whats_new)

    if args.sync_screenshots or args.replace_screenshots:
        de_pngs = sorted((DEFAULT_SCREENSHOTS_DIR / "de").glob("*.png"))
        en_pngs = sorted((DEFAULT_SCREENSHOTS_DIR / "en").glob("*.png"))
        for loc in locales:
            pngs = de_pngs if loc == "de-DE" else en_pngs
            sync_screenshots_for_locale(client, ver_loc_ids[loc], loc, pngs, args.replace_screenshots)

    if args.attach_build:
        attach_build(client, app_id, ver_id, args.build)

    sync_review_details(client, ver_id, parsed["_review"]["notes"], first_name, last_name, args.contact_email, phone)

    if eula_text is not None:
        sync_custom_eula(client, app_id, eula_text)

    print("✅ App Store Connect sync complete (not submitted for review — inspect & submit when ready).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
