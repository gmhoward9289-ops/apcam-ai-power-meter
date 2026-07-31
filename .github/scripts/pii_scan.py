#!/usr/bin/env python3
"""Layer-2 scan: public IPs, emails, credentialed connection strings, and
credential-shaped filenames, across full git history (default), staged
changes (--staged), or explicit files (--files). Complements gitleaks."""

import argparse
import ipaddress
import re
import subprocess
import sys
from collections import defaultdict

MAX_BLOB = 5 * 1024 * 1024
MAX_PER_CATEGORY = 200

SKIP_PATH = re.compile(
    r"(^|/)(node_modules|vendor|dist)/"
    r"|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock"
    r"|Cargo\.lock|composer\.lock|Gemfile\.lock|go\.sum)$"
    r"|\.min\.(js|css)$|\.map$"
)

IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])")
IPV6 = re.compile(r"(?<![0-9A-Za-z:.])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7})(?![0-9A-Za-z:])")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
EMAIL_IGNORE = re.compile(
    r"@example\.(com|org|net)$|@test(\.|$)|^noreply@|^no-reply@"
    r"|@users\.noreply\.github\.com$|^git@",
    re.I,
)
CONN = re.compile(
    r"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?|mssql|ftp"
    r"|jdbc:[a-z]+)://([^\s'\"@/]+):([^\s'\"@]+)@[^\s'\"]+",
    re.I,
)
PASSWORD_KV = re.compile(r"(?i)((?:password|pwd)\s*=\s*)[^;\s'\"]+")
CRED_NAME = re.compile(
    r"(^|/)(id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.npmrc|\.pypirc|\.htpasswd"
    r"|credentials\.json|service[-_]?account[^/]*\.json)$"
    r"|\.(pem|p12|pfx|jks|keystore|tfvars)$"
    r"|(^|/)\.env(\..+)?$",
    re.I,
)
CRED_NAME_OK = re.compile(
    r"\.pub$|\.env\.(example|sample|template|dist|test)$", re.I
)


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, check=True
    ).stdout


def is_global_ip(s):
    try:
        return ipaddress.ip_address(s).is_global
    except ValueError:
        return False


def scan_text(path, text, findings):
    for i, line in enumerate(text.splitlines(), 1):
        low = line.lower()
        if "version" not in low:
            for m in IPV4.finditer(line):
                if is_global_ip(m.group(1)):
                    findings["public-ip"].append((path, i, m.group(1)))
        for m in IPV6.finditer(line):
            if is_global_ip(m.group(1)):
                findings["public-ip"].append((path, i, m.group(1)))
        conn_spans = []
        for m in CONN.finditer(line):
            conn_spans.append(m.span())
            findings["conn-string"].append(
                (path, i, m.group(0).replace(m.group(2), "***", 1))
            )
        for m in EMAIL.finditer(line):
            # user:pass@host inside a conn string is email-shaped; reporting it
            # here would reprint the password the conn-string finding redacted
            if any(a <= m.start() < b for a, b in conn_spans):
                continue
            if not EMAIL_IGNORE.search(m.group(0)):
                findings["email"].append((path, i, m.group(0)))
        if ("password=" in low or "pwd=" in low) and any(
            k in low for k in ("server=", "host=", "data source=", "uid=", "user id=")
        ):
            findings["conn-string"].append(
                (path, i, PASSWORD_KV.sub(r"\1***", line.strip())[:100])
            )


def check_file(path, data, findings, cred_paths):
    if CRED_NAME.search(path) and not CRED_NAME_OK.search(path):
        cred_paths.add(path)
    if b"\0" in data[:8000]:
        return
    scan_text(path, data.decode("utf-8", "replace"), findings)


def history_blobs(repo):
    pairs = []
    for ln in git(repo, "rev-list", "--objects", "--all").decode("utf-8", "replace").splitlines():
        sha, _, path = ln.partition(" ")
        if path:
            pairs.append((sha, path))
    proc = subprocess.run(
        ["git", "-C", repo, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        input="\n".join(sha for sha, _ in pairs).encode(),
        capture_output=True,
        check=True,
    )
    sizes = {}
    for ln in proc.stdout.decode().splitlines():
        parts = ln.split()
        if len(parts) == 3 and parts[1] == "blob":
            sizes[parts[0]] = int(parts[2])
    seen, order, path_of = set(), [], {}
    for sha, path in pairs:
        if sha in sizes and sha not in seen:
            seen.add(sha)
            order.append(sha)
            path_of[sha] = path
    return order, path_of, sizes, [p for _, p in pairs]


def blob_stream(repo, shas):
    p = subprocess.Popen(
        ["git", "-C", repo, "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    try:
        for sha in shas:
            p.stdin.write((sha + "\n").encode())
            p.stdin.flush()
            header = p.stdout.readline().split()
            size = int(header[2])
            data = p.stdout.read(size)
            p.stdout.read(1)
            yield sha, data
    finally:
        p.stdin.close()
        p.wait()


def last_touch(repo, path, _cache={}):
    if path not in _cache:
        r = subprocess.run(
            ["git", "-C", repo, "log", "--all", "-1", "--format=%h %as %an <%ae>", "--", path],
            capture_output=True,
        )
        _cache[path] = r.stdout.decode().strip() or "uncommitted"
    return _cache[path]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo", nargs="?", default=".")
    ap.add_argument("--staged", action="store_true", help="scan staged changes only")
    ap.add_argument("--files", nargs="*", help="scan these working-tree files")
    a = ap.parse_args()

    findings = defaultdict(list)
    cred_paths = set()

    if a.files:
        for f in a.files:
            try:
                with open(f, "rb") as fh:
                    check_file(f, fh.read(), findings, cred_paths)
            except OSError:
                pass
    elif a.staged:
        names = git(a.repo, "diff", "--cached", "--name-only", "--diff-filter=ACMR")
        for f in names.decode("utf-8", "replace").splitlines():
            if SKIP_PATH.search(f):
                continue
            try:
                check_file(f, git(a.repo, "show", f":{f}"), findings, cred_paths)
            except subprocess.CalledProcessError:
                pass
    else:
        order, path_of, sizes, all_paths = history_blobs(a.repo)
        for path in set(all_paths):
            if CRED_NAME.search(path) and not CRED_NAME_OK.search(path) and not SKIP_PATH.search(path):
                cred_paths.add(path)
        todo = [s for s in order if not SKIP_PATH.search(path_of[s]) and sizes[s] <= MAX_BLOB]
        for sha, data in blob_stream(a.repo, todo):
            if b"\0" in data[:8000]:
                continue
            scan_text(path_of[sha], data.decode("utf-8", "replace"), findings)

    total = sum(len(v) for v in findings.values()) + len(cred_paths)
    for cat in sorted(findings):
        items = findings[cat]
        print(f"\n== {cat} ({len(items)}) ==")
        for path, ln, val in items[:MAX_PER_CATEGORY]:
            print(f"{path}:{ln}  {val}   [{last_touch(a.repo, path)}]")
        if len(items) > MAX_PER_CATEGORY:
            print(f"... and {len(items) - MAX_PER_CATEGORY} more")
    if cred_paths:
        print(f"\n== credential-shaped filenames ({len(cred_paths)}) ==")
        for path in sorted(cred_paths):
            print(f"{path}   [{last_touch(a.repo, path)}]")

    if total == 0:
        print("pii_scan: clean — no public IPs, emails, connection strings, or credential-shaped filenames.")
    else:
        print(f"\npii_scan: {total} finding(s). Triage per SKILL.md before publishing.")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
