#!/usr/bin/env python3
"""Generate a ghcup release-channel metadata file for the `plinth` tool.

uplc-ghc is distributed as a *custom third-party ghcup tool* named `plinth`
(installable with stock ghcup >= 0.2.1.0 -- no ghcup fork). This script turns
a set of per-platform bindist tarballs into the ghcup channel YAML that users
add with:

    ghcup config add-release-channel <url>/ghcup-plinth.yaml
    ghcup install plinth <version>

See Note [Ghcup channel metadata] below for the schema rationale.

Usage:
    generate-ghcup-metadata.py \
        --version 9.6.7-plinth1.66 \
        --base-url https://github.com/ican-group/ghc-plinth/releases/download/v1.66 \
        [--db ghcup-plinth.versions.json] \
        [--output ghcup-plinth.yaml] \
        [--release-day 2026-07-29] [--changelog <url>] \
        [--tags Latest,Recommended] \
        [--set-latest] \
        TARBALL [TARBALL ...]

Each TARBALL is a local `ghc-<ghcver>-<target-platform>[-musl].tar.xz` file (as
produced by plinth-build.sh). The script reads its name + sha256, records the
version into the JSON accumulator DB, then re-emits the full channel YAML from
the DB so that every previously released version stays available.
"""

import argparse
import hashlib
import json
import os
import re
import sys

# Note [Ghcup channel metadata]
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# A channel file is a ghcup `GHCupInfo` document: a top-level `ghcupDownloads:`
# map from tool name to {toolDetails, toolVersions}. `plinth` is a custom tool
# (Tool is `newtype Tool String` in ghcup, lowercased), so unlike ghc/cabal it
# has NO built-in install logic -- we MUST supply a `dlInstallSpec` (the
# "installer DSL") per platform. For a GHC-shaped bindist we mirror ghcup's own
# `defaultGHCInstallSpec`:
#   - Unix: run `./configure --prefix=${PREFIX}` then `make DESTDIR=${TMPDIR} install`
#   - Windows: copy `bin/**` + data dirs (GHC's Windows bindist is copy-relocatable)
# then symlink the uplc-* wrappers into ~/.ghcup/bin via `exeSymLinked`.
# ${PREFIX}/${TMPDIR}/${PKGVER} are ghcup substitution variables.

TOOL_NAME = "plinth"

TOOL_DETAILS = {
    "toolHomepage": "https://github.com/ican-group/ghc-plinth",
    "toolRepository": "https://github.com/ican-group/ghc-plinth",
    "toolDescription": "GHC fork that compiles Haskell directly to Plutus Core (uplc-ghc)",
    "toolAuthor": "IOG",
    "toolLicense": "BSD-3-Clause",
}

# Note [Finding ghc-pkg on Windows]
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# With `with-compiler: uplc-ghc`, cabal looks for the matching ghc-pkg next to
# the *symlink-resolved* compiler path (guessToolFromGhcPath in Cabal). On Unix
# this works by accident: ~/.ghcup/bin/uplc-ghc is a symlink into the install
# dir, where the correct ghc-pkg sits under its stock name. On Windows ghcup
# creates shim executables, not symlinks. Cabal cannot see through a shim, so
# it searches ghcup's bin dir only and picks up ghc-pkg.exe from the user's
# *set* GHC. Configuration then fails with a ghc/ghc-pkg version mismatch
# (issue #29).
#
# The fix: also link the bindist's ghc-pkg into ghcup's bin dir, under the
# name `uplc-ghc-pkg` so that it cannot shadow the user's GHC, and point cabal
# at it explicitly:
#
#     with-compiler: uplc-ghc
#     with-hc-pkg:   uplc-ghc-pkg

# The binaries ghcup must link into ~/.ghcup/bin, as (target, link) pairs:
# `target` is the binary name in the installed bindist's bin/, `link` is the
# base name of the created links. `setName` is the unversioned link created by
# `ghcup set plinth <ver>`.
#
# Keep this in sync with the fixup in plinth-build.sh and with EXPECTED_BINS in
# plinth-ghcup-test.sh. Only uplc-prefixed link names are safe: the bindist's
# other tools (haddock, hsc2hs, hpc, ...) keep their stock names, and linking
# them under those names would hijack the user's GHC toolchain. Listing a
# target the bindist does not ship makes ghcup create a *dangling* link, which
# it does silently.
LINKED_BINARIES = [
    ("uplc-ghc", "uplc-ghc"),
    # See Note [Finding ghc-pkg on Windows]
    ("ghc-pkg", "uplc-ghc-pkg"),
]

# arch component (first field of the GHC target platform) -> ghcup Architecture
ARCH_MAP = {
    "x86_64": "A_64",
    "amd64": "A_64",
    "i386": "A_32",
    "i686": "A_32",
    "aarch64": "A_ARM64",
    "arm64": "A_ARM64",
    "armv7l": "A_ARM",
}


def version_key(ver):
    """A best-effort ordering key for version strings like "9.6.7-plinth1.66".

    Splits into alternating numeric / non-numeric chunks; numeric chunks compare
    as integers, others lexically. Each chunk is tagged (0/1) so int and str
    chunks never compare against each other (which Python 3 forbids)."""
    key = []
    for tok in re.findall(r"\d+|\D+", ver):
        if tok.isdigit():
            key.append((0, int(tok), ""))
        else:
            key.append((1, 0, tok))
    return key


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_bindist_name(basename):
    """Parse `ghc-<ghcver>-<target-platform>[-musl].tar.xz`.

    Returns (subdir, ghc_arch, ghcup_arch, ghcup_platform).
    `subdir` is the top-level directory inside the tarball (== name sans .tar.xz),
    which plinth-build.sh sets to the bindist name.
    """
    m = re.match(r"^(ghc-.+?)\.tar\.xz$", basename)
    if not m:
        raise ValueError(f"not a bindist tarball name: {basename}")
    subdir = m.group(1)  # e.g. ghc-9.6.7-x86_64-unknown-linux-musl

    is_musl = subdir.endswith("-musl")
    core = subdir[: -len("-musl")] if is_musl else subdir

    # core = ghc-<ghcver>-<arch>-<vendor>-<os>[-<abi>]
    m = re.match(r"^ghc-(?P<ghcver>[^-]+)-(?P<target>.+)$", core)
    if not m:
        raise ValueError(f"cannot parse bindist name: {basename}")
    target = m.group("target")  # e.g. x86_64-unknown-linux
    arch_component = target.split("-", 1)[0]

    ghcup_arch = ARCH_MAP.get(arch_component)
    if ghcup_arch is None:
        raise ValueError(f"unknown architecture '{arch_component}' in {basename}")

    if re.search(r"(mingw|windows|w64|msys)", target):
        ghcup_platform = "Windows"
    elif re.search(r"(darwin|apple|osx|macos)", target):
        ghcup_platform = "Darwin"
    elif "linux" in target:
        ghcup_platform = "Linux_Alpine" if is_musl else "Linux_UnknownLinux"
    else:
        raise ValueError(f"unknown OS in target '{target}' ({basename})")

    return subdir, arch_component, ghcup_arch, ghcup_platform


def install_spec(ghcup_platform):
    """The installer DSL (dlInstallSpec) for one platform, mirroring
    ghcup's defaultGHCInstallSpec but symlinking the uplc-* wrappers."""
    exe_ext = ".exe" if ghcup_platform == "Windows" else ""
    exe_symlinked = [
        {
            "target": f"bin/{target}{exe_ext}",
            "linkName": f"{link}-${{PKGVER}}{exe_ext}",
            "pVPMajorLinks": True,
            "setName": f"{link}{exe_ext}",
        }
        for target, link in LINKED_BINARIES
    ]

    if ghcup_platform == "Windows":
        # Windows GHC bindists are copy-relocatable: no configure/make.
        return {
            "exeRules": [{"installPattern": ["bin/**"]}],
            "dataRules": [{"installPattern": ["doc/**", "lib/**", "man/**", "mingw/**"]}],
            "exeSymLinked": exe_symlinked,
            "preserveMtimes": True,
        }

    return {
        "exeRules": [],
        "dataRules": [],
        "configure": {
            "configFile": "configure",
            "configArgs": ["--prefix=${PREFIX}", "--disable-ld-override"],
        },
        "make": {
            "makeArgs": ["install"],
            "makeEnv": {"env": [["DESTDIR", "${TMPDIR}"]], "union": "PreferSpec"},
        },
        "exeSymLinked": exe_symlinked,
        "preserveMtimes": True,
    }


def build_version_record(version, base_url, tarballs, release_day, changelog):
    """Assemble the DB record for one released version from its tarballs."""
    arches = {}
    for tb in tarballs:
        basename = os.path.basename(tb)
        subdir, _arch_comp, ghcup_arch, ghcup_platform = parse_bindist_name(basename)
        dl = {
            "dlUri": f"{base_url.rstrip('/')}/{basename}",
            "dlHash": sha256_file(tb),
            "dlSubdir": subdir,
            "dlInstallSpec": install_spec(ghcup_platform),
        }
        arch = arches.setdefault(ghcup_arch, {})
        if ghcup_platform in arch:
            raise ValueError(
                f"duplicate {ghcup_arch}/{ghcup_platform} bindist for version {version}"
            )
        arch[ghcup_platform] = {"unknown_versioning": dl}

    if not arches:
        raise ValueError("no tarballs provided for this version")

    rec = {"viArch": arches}
    if release_day:
        rec["viReleaseDay"] = release_day
    if changelog:
        rec["viChangeLog"] = changelog
    return rec


# ---------------------------------------------------------------------------
# Minimal deterministic YAML emitter (stdlib only; no PyYAML dependency).
# Only the value shapes used above are supported: dict, list, str, bool.
# ---------------------------------------------------------------------------

_SAFE_UNQUOTED = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./+-]*$")


def _yaml_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    # Always quote when the value could be misread (contains ${}, :, *, leading
    # special char, or reserved words) -- cheapest to just quote unless clearly safe.
    if s and _SAFE_UNQUOTED.match(s) and s not in ("true", "false", "null", "yes", "no"):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _emit(v, indent, out, inline_key=None):
    pad = "  " * indent
    if isinstance(v, dict):
        if not v:
            out.append(f"{pad}{{}}")
            return
        for k, val in v.items():
            key = _yaml_scalar(k)
            if isinstance(val, (dict, list)) and val:
                out.append(f"{pad}{key}:")
                _emit(val, indent + 1, out)
            elif isinstance(val, (dict, list)):  # empty
                out.append(f"{pad}{key}: {'{}' if isinstance(val, dict) else '[]'}")
            else:
                out.append(f"{pad}{key}: {_yaml_scalar(val)}")
    elif isinstance(v, list):
        if not v:
            out.append(f"{pad}[]")
            return
        for item in v:
            if isinstance(item, dict) and item:
                # "- key: val" with the rest of the dict aligned under it
                first = True
                for k, val in item.items():
                    key = _yaml_scalar(k)
                    lead = f"{pad}- " if first else f"{pad}  "
                    first = False
                    if isinstance(val, (dict, list)) and val:
                        out.append(f"{lead}{key}:")
                        _emit(val, indent + 2, out)
                    elif isinstance(val, (dict, list)):
                        out.append(f"{lead}{key}: {'{}' if isinstance(val, dict) else '[]'}")
                    else:
                        out.append(f"{lead}{key}: {_yaml_scalar(val)}")
            elif isinstance(item, list):
                out.append(f"{pad}-")
                _emit(item, indent + 1, out)
            else:
                out.append(f"{pad}- {_yaml_scalar(item)}")


def emit_yaml(doc):
    out = ["# Auto-generated by generate-ghcup-metadata.py -- do not edit by hand."]
    _emit(doc, 0, out)
    return "\n".join(out) + "\n"


def render_channel(db):
    """Turn the accumulator DB into the ghcup channel document.

    DB shape: {"versions": {<ver>: {"viArch":..., "viReleaseDay":..., ...}},
               "latest": <ver>}
    The `latest` version carries the Latest+Recommended tags; all others get [].
    """
    versions = db.get("versions", {})
    latest = db.get("latest")
    tool_versions = {}
    # Emit versions in DB insertion order but keep latest tag on the marked one.
    for ver, rec in versions.items():
        entry = {"viTags": list(rec.get("tags", []))}
        if ver == latest and not entry["viTags"]:
            entry["viTags"] = ["Latest", "Recommended"]
        for k in ("viReleaseDay", "viChangeLog"):
            if k in rec:
                entry[k] = rec[k]
        entry["viArch"] = rec["viArch"]
        tool_versions[ver] = entry

    return {
        "ghcupDownloads": {
            TOOL_NAME: {
                "toolDetails": TOOL_DETAILS,
                "toolVersions": tool_versions,
            }
        }
    }


def main(argv=None):
    p = argparse.ArgumentParser(description="Generate ghcup channel metadata for the plinth tool")
    p.add_argument("--version", required=True, help="ghcup tool version key, e.g. 9.6.7-plinth1.66")
    p.add_argument("--base-url", required=True, help="URL prefix the tarballs are published under")
    p.add_argument("--db", default="ghcup-plinth.versions.json", help="JSON accumulator of all versions")
    p.add_argument("--output", default="ghcup-plinth.yaml", help="channel YAML to write")
    p.add_argument("--release-day", help="YYYY-MM-DD (optional)")
    p.add_argument("--changelog", help="changelog URL (optional)")
    p.add_argument("--tags", default="", help="comma-separated tags for this version (default: none)")
    p.add_argument("--set-latest", action="store_true", help="mark this version as Latest+Recommended")
    p.add_argument("tarballs", nargs="+", help="local ghc-*.tar.xz bindist files")
    args = p.parse_args(argv)

    rec = build_version_record(
        args.version, args.base_url, args.tarballs, args.release_day, args.changelog
    )
    tags = [t.strip() for t in args.tags.split(",") if t.strip()]
    if tags:
        rec["tags"] = tags

    db = {"versions": {}, "latest": None}
    if os.path.exists(args.db):
        with open(args.db) as f:
            db = json.load(f)
    db.setdefault("versions", {})
    db["versions"][args.version] = rec
    # Claim the Latest/Recommended tags only when there is no current latest, or
    # when explicitly asked AND this version is not older than the current one.
    # This keeps re-running an *old* tag's release from stealing `latest`.
    cur = db.get("latest")
    if cur is None:
        db["latest"] = args.version
    elif args.set_latest and version_key(args.version) >= version_key(cur):
        db["latest"] = args.version
    else:
        print(f"keeping latest={cur} (not overriding with {args.version})")

    with open(args.db, "w") as f:
        json.dump(db, f, indent=2, sort_keys=False)
        f.write("\n")

    with open(args.output, "w") as f:
        f.write(emit_yaml(render_channel(db)))

    print(f"wrote {args.output} ({len(db['versions'])} version(s); latest={db['latest']})")
    print(f"updated DB {args.db}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
