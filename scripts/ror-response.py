#!/usr/bin/env python3
"""Interpret Return of Reckoning addon release API responses.

Docs: https://addons.returnofreckoning.com/docs/api
- POST /addons/{slug}/releases returns 202 and a status URL.
- GET /addons/{slug}/releases/{version}/status returns pipeline status and checks.
- A moderation-pending pipeline is not a failed upload.
- Public GET /addons/{slug}/releases/{version} is the existence check.
"""

from __future__ import annotations

import json
import sys
import urllib.parse
from pathlib import Path

HOST = "addons.returnofreckoning.com"
PASS_CHECK = {"pass", "passed", "ok", "success", "succeeded", "check_pass"}
WARN_CHECK = {"warn", "warning", "check_warn"}
FAIL_CHECK = {"fail", "failed", "failure", "error", "check_fail"}
PENDING_CHECK = {"pending", "running", "queued", "processing"}
OK_STATUS = {
    "published",
    "passed",
    "success",
    "succeeded",
    "complete",
    "completed",
    "ok",
    "live",
    "approved",
}
WAIT_STATUS = {
    "queued",
    "pending",
    "processing",
    "running",
    "verifying",
    "accepted",
    "uploaded",
    "working",
    "in_progress",
    "started",
    "created",
}
MODERATION_STATUS = {
    "moderation",
    "moderation_pending",
    "pending_moderation",
    "awaiting_moderation",
    "in_moderation",
    "needs_moderation",
    "moderation_required",
    "waiting_for_moderation",
    "pending_review",
    "awaiting_review",
    "in_review",
    "needs_review",
    "review",
    "awaiting_approval",
    "pending_approval",
}
EXISTS_PHRASES = (
    "already exists",
    "already been published",
    "already been taken",
    "has already been",
    "duplicate version",
    "version is already",
    "version already",
)


def norm(value: str) -> str:
    cleaned = []
    last_underscore = False
    for char in value.strip().lower():
        if char.isalnum():
            cleaned.append(char)
            last_underscore = False
        elif not last_underscore:
            cleaned.append("_")
            last_underscore = True
    return "".join(cleaned).strip("_")


def one_line(text: str) -> str:
    return " ".join(text.replace("\r", " ").replace("\n", " ").split())[:400]


def canonical_status_url(version: str) -> str:
    quoted = urllib.parse.quote(version, safe="")
    return f"https://{HOST}/api/v1/addons/stockpiler/releases/{quoted}/status"


def acceptable_status_url(url: str, version: str) -> str | None:
    candidate = url.strip()
    if candidate.startswith("/"):
        candidate = f"https://{HOST}{candidate}"
    parts = urllib.parse.urlsplit(candidate)
    if parts.scheme != "https" or parts.netloc != HOST or parts.username or parts.password:
        return None
    path = urllib.parse.unquote(parts.path.rstrip("/"))
    expected = urllib.parse.urlsplit(canonical_status_url(version)).path.rstrip("/")
    if path != expected:
        return None
    return urllib.parse.urlunsplit(("https", HOST, expected, "", ""))


def load_json(path: str) -> tuple[object | None, str]:
    text = Path(path).read_text(encoding="utf-8")
    if not text.strip():
        return None, text
    try:
        return json.loads(text), text
    except json.JSONDecodeError:
        return None, text


def iter_checks(checks: object) -> list[object]:
    items: list[object] = []
    if isinstance(checks, list):
        items.extend(checks)
    elif isinstance(checks, dict):
        for key, value in checks.items():
            if isinstance(value, dict):
                item = dict(value)
                item.setdefault("id", key)
                items.append(item)
            else:
                items.append({"id": key, "status": value})
    return items


def collect(doc: object) -> tuple[str | None, str | None, list[object]]:
    sources: list[dict] = []
    if isinstance(doc, dict):
        sources.append(doc)
        data = doc.get("data")
        if isinstance(data, dict):
            sources.append(data)
            for key in ("pipeline", "release", "verification"):
                nested = data.get(key)
                if isinstance(nested, dict):
                    sources.append(nested)
        for key in ("pipeline", "release"):
            nested = doc.get(key)
            if isinstance(nested, dict):
                sources.append(nested)

    status = None
    moderation = None
    checks: list[object] = []
    for source in sources:
        if status is None:
            for key in ("status", "state", "pipeline_status", "release_status"):
                value = source.get(key)
                if isinstance(value, str):
                    status = value
                    break
        if moderation is None:
            for key in ("moderation", "moderation_status"):
                value = source.get(key)
                if isinstance(value, str):
                    moderation = value
                    break
        for key in ("checks", "verification", "results"):
            value = source.get(key)
            if isinstance(value, (list, dict)):
                checks.extend(iter_checks(value))
    return status, moderation, checks


def check_state(item: object) -> str:
    if isinstance(item, str):
        return classify_check(norm(item))
    if not isinstance(item, dict):
        return "unknown"
    for key in ("status", "state", "result", "level"):
        value = item.get(key)
        if isinstance(value, str):
            state = classify_check(norm(value))
            if state != "unknown":
                return state
    for key in ("ok", "passed", "success"):
        if item.get(key) is False:
            return "fail"
        if item.get(key) is True:
            return "pass"
    return "unknown"


def classify_check(value: str) -> str:
    if value in FAIL_CHECK or value.endswith("_fail") or value.endswith("_failed"):
        return "fail"
    if value in WARN_CHECK:
        return "warn"
    if value in PASS_CHECK:
        return "pass"
    if value in PENDING_CHECK:
        return "pending"
    return "unknown"


def check_label(item: object) -> str:
    if isinstance(item, dict):
        name = item.get("id") or item.get("name") or item.get("key") or "check"
        message = item.get("message") or item.get("detail") or item.get("text") or ""
        text = f"{name}: {message}".strip(": ").strip()
        return one_line(text or "check failed")
    return one_line(str(item))


def is_fail_status(value: str) -> bool:
    if not value:
        return False
    if any(token in value for token in ("fail", "reject", "error")):
        return True
    return False


def is_moderation_status(value: str) -> bool:
    if not value or is_fail_status(value):
        return False
    if value in MODERATION_STATUS or "moderat" in value:
        return True
    return False


def moderation_field_decision(value: str | None) -> str | None:
    if not value:
        return None
    normalized = norm(value)
    if normalized in {"none", "not_required", "approved", "passed", "skipped"}:
        return None
    if is_fail_status(normalized):
        return "fail"
    if normalized in {"pending", "required", "awaiting", "in_review", "review"} or is_moderation_status(normalized):
        return "moderation"
    return None


def checks_settled(checks: list[object]) -> bool:
    if not checks:
        return False
    for item in checks:
        if check_state(item) not in {"pass", "warn"}:
            return False
    return True


def poll_document(doc: object) -> str:
    if not isinstance(doc, (dict, list)):
        return "fail:status response was not JSON"
    status, moderation, checks = collect(doc)
    failed = [check_label(item) for item in checks if check_state(item) == "fail"]
    if failed:
        label = status or "checks failed"
        return "fail:" + one_line(label + "; " + "; ".join(failed))

    normalized = norm(status or "")
    field = moderation_field_decision(moderation)
    if is_fail_status(normalized) or field == "fail":
        return "fail:" + one_line(status or moderation or "failed")
    if is_moderation_status(normalized):
        return "moderation:" + one_line(status or "moderation pending")
    if normalized in OK_STATUS:
        return "ok:" + one_line(status or "ok")
    if normalized in WAIT_STATUS or normalized == "":
        if field == "moderation":
            return "moderation:" + one_line(moderation or "moderation pending")
        return "wait:" + one_line(status or "pending")
    if field == "moderation":
        return "moderation:" + one_line(moderation or status or "moderation pending")
    if checks_settled(checks):
        return "ok:" + one_line(status or "checks passed")
    return "wait:" + one_line("unrecognized status " + (status or ""))


def find_status_url(doc: object, headers: str, version: str) -> str:
    found: list[str] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                normalized = key.lower().replace("-", "_")
                if isinstance(value, str) and (
                    normalized in {"status_url", "statusurl", "poll_url"}
                    or (normalized in {"url", "href"} and "status" in value)
                ):
                    found.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(doc)
    for line in headers.splitlines():
        if line.lower().startswith("location:"):
            found.append(line.split(":", 1)[1].strip())
    for candidate in found:
        accepted = acceptable_status_url(candidate, version)
        if accepted:
            return accepted
    return canonical_status_url(version)


def is_public_release(doc: object, version: str) -> bool:
    if not isinstance(doc, dict):
        return False
    data = doc.get("data")
    payload = data if isinstance(data, dict) else doc
    return isinstance(payload, dict) and str(payload.get("version", "")) == version


def already_exists(text: str) -> bool:
    lowered = text.lower()
    return any(phrase in lowered for phrase in EXISTS_PHRASES)


def self_test() -> int:
    version = "1.2.3"
    canonical = canonical_status_url(version)
    assert acceptable_status_url(canonical, version) == canonical
    assert acceptable_status_url("http://evil.example/status", version) is None
    assert acceptable_status_url(
        "https://addons.returnofreckoning.com/api/v1/addons/other/releases/1.2.3/status",
        version,
    ) is None
    relative = "/api/v1/addons/stockpiler/releases/1.2.3/status"
    assert acceptable_status_url(relative, version) == canonical

    queued = {"data": {"status": "processing", "checks": [], "status_url": canonical}}
    assert poll_document(queued).startswith("wait:")
    assert find_status_url(queued, "", version) == canonical
    assert find_status_url({}, "Location: http://evil.example/steal\n", version) == canonical

    published = {
        "data": {
            "status": "published",
            "checks": [
                {"id": "archive.paths", "status": "pass", "message": "No unsafe paths."},
                {"id": "warinfo.valid_names", "status": "warn", "message": "ignored"},
                {"id": "mod.parse", "ok": True},
            ],
        }
    }
    assert poll_document(published).startswith("ok:")

    for status in ("moderation_pending", "moderation-pending", "pending_moderation", "awaiting_moderation"):
        body = {"data": {"status": status, "checks": [{"id": "archive.paths", "status": "pass"}]}}
        assert poll_document(body).startswith("moderation:"), status

    moderation_field = {"data": {"status": "pending", "moderation": "pending", "checks": []}}
    assert poll_document(moderation_field).startswith("moderation:")

    failed = {
        "data": {
            "status": "failed",
            "checks": [{"id": "files.forbidden", "status": "fail", "message": "Executable found"}],
        }
    }
    assert poll_document(failed).startswith("fail:")
    early = {
        "data": {
            "status": "processing",
            "checks": [{"id": "archive.paths", "passed": False, "message": "Unsafe path"}],
        }
    }
    assert poll_document(early).startswith("fail:")
    assert poll_document({"data": {"status": "moderation_rejected", "checks": []}}).startswith("fail:")
    assert poll_document({"data": {"status": "rejected"}}).startswith("fail:")

    nested = {
        "data": {
            "status": "published",
            "pipeline": {"checks": {"archive.limits": {"status": "check-pass"}, "mod.present": "check-fail"}},
        }
    }
    assert poll_document(nested).startswith("fail:")

    public = {"data": {"version": "1.0.0", "status": "published"}}
    assert is_public_release(public, "1.0.0")
    assert not is_public_release(public, "1.0.1")
    assert already_exists('{"message":"The version has already been taken."}')
    assert not already_exists('{"message":"changelog_md is invalid"}')
    assert poll_document(None).startswith("fail:")
    print("ror-response self-test ok")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        raise SystemExit(
            "usage: ror-response.py {public-release|already-exists|status-url|poll|self-test} ..."
        )
    command = argv[0]
    if command == "self-test":
        return self_test()
    if command == "public-release":
        doc, _text = load_json(argv[1])
        return 0 if is_public_release(doc, argv[2]) else 1
    if command == "already-exists":
        _doc, text = load_json(argv[1])
        return 0 if already_exists(text) else 1
    if command == "status-url":
        doc, _text = load_json(argv[1])
        headers = Path(argv[2]).read_text(encoding="utf-8")
        print(find_status_url(doc, headers, argv[3]))
        return 0
    if command == "poll":
        doc, _text = load_json(argv[1])
        print(poll_document(doc))
        return 0
    raise SystemExit(f"Unknown command {command}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
