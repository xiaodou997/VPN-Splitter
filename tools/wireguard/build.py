#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""WG-INT-02: isolated native compilation. Never executes the built VPN code.

--fetch explicitly permits pinned public-source and Go-module downloads. Without
it only previously verified caches are used. User workspaces and Keychain are
not read. All work goes under this checkout's .local/wireguard-engine.
"""
from __future__ import annotations
import argparse
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
from contextlib import contextmanager
from policy_hook import git_blob, patch_adapter, patch_manifest
from runtime_hook import checked_support, patch_runtime_adapter
from bridge_assets import checked_bridge, stage_bridge

ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "third-party/wireguard-go/build-lock.json"
APPLE_PATHS = ["Package.swift", "COPYING", "Sources/WireGuardKit", "Sources/WireGuardKitC", "Sources/WireGuardKitGo"]
REQUIRED_SYMBOLS = {"_wgTurnOn", "_wgTurnOff", "_wgSetConfig", "_wgGetConfig", "_wgBumpSockets", "_wgVersion",
                    "_wgSetLogger", "_wgDisableSomeRoamingForBrokenMobileSemantics"}


class BuildError(Exception):
    pass


def clean_environment() -> dict[str, str]:
    # Public HTTPS fetches must not inherit credentials, alternate repositories,
    # custom go workspaces, toolchain downloads or arbitrary compiler flags.
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(("GIT_", "GO", "CGO_", "SWIFT_", "DYLD_")) or key in {
            "CC", "CXX", "CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"
        }:
            env.pop(key, None)
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT="0", GIT_NO_REPLACE_OBJECTS="1", GOENV="off",
               GOTOOLCHAIN="local", GOWORK="off", GOSUMDB="sum.golang.org",
               GOPROXY="off", GONOSUMDB="", GONOPROXY="", GOPRIVATE="")
    return env


class Commands:
    def __init__(self, env: dict[str, str], log: Path | None = None):
        self.env, self.log = env, log

    def run(self, args: list[str], cwd: Path | None = None, timeout: int = 120,
            extra: dict[str, str] | None = None) -> str:
        env = dict(self.env); env.update(extra or {})
        try:
            process = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as error:
            raise BuildError("E_COMMAND: " + Path(args[0]).name + " unavailable") from error
        try:
            output, _ = process.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            # Only the process group created for this command is terminated. Do not
            # leave compiler descendants writing after the build lock is released.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            output, _ = process.communicate()
            self.record(args, output)
            if isinstance(error, KeyboardInterrupt):
                raise
            raise BuildError("E_COMMAND: " + Path(args[0]).name + " timed out") from error
        self.record(args, output)
        text = output.decode("utf-8", errors="replace")
        if process.returncode:
            detail = "; inspect this run's build.log" if self.log else "; preflight command failed"
            raise BuildError("E_COMMAND: " + Path(args[0]).name + " exit " + str(process.returncode) + detail)
        return text.strip()

    def record(self, args: list[str], output: bytes) -> None:
        if self.log:
            with self.log.open("ab") as handle:
                handle.write(("\n$ " + shlex.join(args) + "\n").encode())
                handle.write(output)

    def git(self, args: list[str], **kwargs) -> str:
        return self.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                         "-c", "http.sslVerify=true", "-c", "protocol.allow=never",
                         "-c", "protocol.https.allow=always"] + args, **kwargs)


def preflight(commands: Commands, lock: dict) -> dict[str, str]:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise BuildError("E_PLATFORM: requires an Apple Silicon Mac, macOS 26+ and full Xcode")
    version = commands.run(["/usr/bin/sw_vers", "-productVersion"])
    if int(version.split(".")[0]) < 26:
        raise BuildError("E_PLATFORM: requires macOS 26+")
    sdk = commands.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
    sdk_version = commands.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
    if int(sdk_version.split(".")[0]) < 26:
        raise BuildError("E_SDK: select full Xcode with macOS SDK 26+")
    go = shutil.which("go")
    if not go:
        raise BuildError("E_GO: install Go 1.26.8 or 1.27.1; no toolchain is installed automatically")
    go_version = commands.run([go, "env", "GOVERSION"])
    if go_version not in lock["go_toolchains"]:
        raise BuildError("E_GO: supported build candidates are " + ", ".join(lock["go_toolchains"]))
    return dict(os_version=version, sdk=sdk, sdk_version=sdk_version, go=go, go_version=go_version,
                swift=commands.run(["/usr/bin/xcrun", "--find", "swift"]),
                clang=commands.run(["/usr/bin/xcrun", "--find", "clang"]),
                xcode=commands.run(["/usr/bin/xcodebuild", "-version"]),
                swift_version=commands.run(["/usr/bin/xcrun", "swift", "--version"]))


def private_directory(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise BuildError("E_PATH: expected an ordinary build directory")
    path.mkdir(mode=0o700, exist_ok=True)


@contextmanager
def build_lock(path: Path):
    # The advisory lock file is never removed, preventing split-lock races.
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BuildError("E_BUSY: another WireGuard build is active; do not delete the lock") from error
        yield
    finally:
        os.close(descriptor)


def validate_spec(spec: dict) -> None:
    if spec["url"] not in {"https://github.com/WireGuard/wireguard-apple.git",
                            "https://github.com/WireGuard/wireguard-go.git"}:
        raise BuildError("E_SOURCE: unexpected source URL")
    if not all(re.fullmatch(r"[0-9a-f]{40}", spec[field]) for field in ("revision", "tree")):
        raise BuildError("E_SOURCE: require exact revision and tree")


def source_repository(commands: Commands, cache: Path, name: str, spec: dict, fetch: bool) -> Path:
    validate_spec(spec)
    repository = cache / (name + "-" + spec["revision"] + ".git")
    if repository.is_symlink():
        raise BuildError("E_SOURCE: symlink cache refused")
    if not repository.exists():
        if not fetch:
            raise BuildError("E_CACHE: source not cached; rerun build --fetch for explicit public downloads")
        temporary = Path(tempfile.mkdtemp(prefix=name + ".fetch.", dir=cache))
        commands.git(["init", "--bare", str(temporary)])
        commands.git(["--git-dir=" + str(temporary), "fetch", "--depth", "1", "--no-tags",
                      spec["url"], spec["revision"]], timeout=600)
        verify_repository(commands, temporary, spec)
        # Keep incomplete downloads on error. Never overwrite an existing cache.
        if repository.exists():
            raise BuildError("E_CACHE: concurrent source publication")
        temporary.rename(repository)
    verify_repository(commands, repository, spec)
    return repository


def verify_repository(commands: Commands, repository: Path, spec: dict) -> None:
    tree = commands.git(["--git-dir=" + str(repository), "rev-parse", spec["revision"] + "^{tree}"])
    if tree != spec["tree"]:
        raise BuildError("E_SOURCE: upstream tree mismatch")
    commands.git(["--git-dir=" + str(repository), "fsck", "--full", "--no-reflogs"], timeout=300)


def unpack(archive: Path, destination: Path) -> None:
    # Validate the whole archive before writing anything. No links, devices,
    # traversal, duplicate names or unbounded extraction are accepted.
    with tarfile.open(archive, "r:") as source:
        entries = source.getmembers()
        seen: set[str] = set()
        if len(entries) > 20000 or sum(item.size for item in entries) > 256 * 1024 * 1024:
            raise BuildError("E_ARCHIVE_LIMIT")
        for item in entries:
            path = PurePosixPath(item.name)
            if (path.is_absolute() or ".." in path.parts or ".git" in path.parts
                    or not path.parts or item.size < 0 or not (item.isfile() or item.isdir()) or path.as_posix() in seen):
                raise BuildError("E_ARCHIVE_PATH")
            seen.add(path.as_posix())
        destination.mkdir(mode=0o700)
        for item in entries:
            target = destination / item.name
            if item.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with source.extractfile(item) as content, target.open("xb") as out:
                    shutil.copyfileobj(content, out)
                target.chmod(0o600)


def export_source(commands: Commands, repository: Path, spec: dict,
                  target: Path, paths: list[str] | None = None) -> None:
    archive = target.with_suffix(".tar")
    commands.git(["--git-dir=" + str(repository), "archive", "--format=tar",
                  "--output=" + str(archive), spec["revision"]] + (paths or []), timeout=300)
    unpack(archive, target)
    listing = commands.git(["--git-dir=" + str(repository), "ls-tree", "-r", "-z",
                            spec["revision"], "--"] + (paths or []))
    expected_files = tree_files(listing)
    actual_files = {p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()}
    if actual_files != set(expected_files):
        raise BuildError("E_SOURCE_FILE_SET")
    for name, expected in expected_files.items():
        if git_blob((target / name).read_bytes()) != expected:
            raise BuildError("E_SOURCE_BLOB: " + name)
    if any(expected_files.get(name) != sha for name, sha in spec["blobs"].items()):
        raise BuildError("E_SOURCE_LOCK")


def tree_files(listing: str) -> dict[str, str]:
    files: dict[str, str] = {}
    for row in listing.split("\0"):
        if not row:
            continue
        header, path = row.split("\t", 1)
        mode, kind, sha = header.split()
        if mode not in ("100644", "100755") or kind != "blob" or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise BuildError("E_SOURCE_TYPE")
        if path in files:
            raise BuildError("E_SOURCE_FILE_SET")
        files[path] = sha
    return files


def create_probe(probe: Path, root: Path) -> None:
    probe.mkdir(mode=0o700)
    # JSON escaping is valid for Swift string literals for ordinary filesystem paths.
    managed = json.dumps(str(root / "Packages/ManagedSettings"), ensure_ascii=False)
    manifest = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WGLinkProbe", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../wireguard-apple"), .package(path: MANAGED_PATH)],
    targets: [.executableTarget(name: "WGLinkProbe", dependencies: [
        .product(name: "WireGuardKit", package: "wireguard-apple"),
        .product(name: "ManagedSettings", package: "ManagedSettings"),
        .product(name: "ManagedSettingsApple", package: "ManagedSettings")
    ], linkerSettings: [.linkedLibrary("resolv"), .linkedFramework("Security"),
                         .linkedFramework("CoreFoundation")])],
    swiftLanguageModes: [.v6]
)
'''.replace("MANAGED_PATH", managed)
    (probe / "Package.swift").write_text(manifest)
    sources = probe / "Sources/WGLinkProbe"; sources.mkdir(parents=True, mode=0o700)
    shutil.copyfile(root / "tools/wireguard/Probe.swift", sources / "main.swift")


def require_symbols(text: str) -> None:
    # Only globally DEFINED symbols are supplied by nm -gU. An undefined reference
    # alone must not be counted as a successfully linked bridge.
    symbols = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 3 and re.fullmatch(r"[0-9a-fA-F]+", fields[-3]) and fields[-2] != "U":
            symbols.add(fields[-1])
    if not REQUIRED_SYMBOLS <= symbols:
        raise BuildError("E_LINK_SYMBOLS: missing " + ", ".join(sorted(REQUIRED_SYMBOLS - symbols)))


def compile_native(commands: Commands, tools: dict, run: Path, root: Path, fetch: bool) -> Path:
    engine, apple = run / "wireguard-go", run / "wireguard-apple"
    before = {name: (engine / name).read_bytes() for name in ("go.mod", "go.sum")}
    bridge = engine / "splitterbridge"
    lock = json.loads((root / "third-party/wireguard-go/build-lock.json").read_text())
    sources = checked_bridge(root, lock)
    stage_bridge(sources, (apple / "Sources/WireGuardKitGo/api-apple.go").read_bytes(), bridge)
    # Test only the shared lifecycle against in-memory devices; no C entrypoints,
    # upstream device, TUN or network code is compiled or executed by this step.
    commands.run([tools["go"], "test", "-race", "-count=1", "-timeout=60s",
                  "lifecycle.go", "lifecycle_test.go"], cwd=bridge, timeout=180,
                 extra={"CGO_ENABLED": "1"})
    # Build against the newer engine's locked module graph, NOT the Apple 2023
    # go.mod or Makefile. The system Go installation/runtime is never patched.
    if fetch:
        commands.run([tools["go"], "mod", "download"], cwd=engine, timeout=900,
                     extra={"GOPROXY": "https://proxy.golang.org"})
    commands.run([tools["go"], "mod", "verify"], cwd=engine, timeout=300)
    for name, data in before.items():
        if (engine / name).read_bytes() != data:
            raise BuildError("E_MODULE_LOCK_CHANGED: " + name)
    flags = "-isysroot " + shlex.quote(tools["sdk"]) + " -arch arm64 -mmacosx-version-min=26.0"
    cgo = dict(GOOS="darwin", GOARCH="arm64", CGO_ENABLED="1", CC=shlex.quote(tools["clang"]),
               CGO_CFLAGS=flags, CGO_LDFLAGS=flags)
    library_dir = run / "lib"; library_dir.mkdir(mode=0o700)
    archive = library_dir / "libwg-go.a"
    commands.run([tools["go"], "build", "-mod=readonly", "-trimpath", "-buildvcs=false",
                  "-buildmode=c-archive", "-o", str(archive), "./splitterbridge"],
                 cwd=engine, timeout=1200, extra=cgo)
    for name, data in before.items():
        if (engine / name).read_bytes() != data:
            raise BuildError("E_MODULE_LOCK_CHANGED: " + name)
    if commands.run(["/usr/bin/xcrun", "lipo", "-archs", str(archive)]) != "arm64":
        raise BuildError("E_ARCH: expected arm64 static archive")
    require_symbols(commands.run(["/usr/bin/xcrun", "nm", "-gU", str(archive)]))
    create_probe(run / "probe", root)
    swift_args = [tools["swift"], "build", "--package-path", str(run / "probe"),
                  "--scratch-path", str(run / "swift-build"), "--configuration", "debug",
                  "--triple", "arm64-apple-macosx26.0", "--sdk", tools["sdk"],
                  "-Xlinker", "-L" + str(library_dir), "-Xlinker", "-force_load", "-Xlinker", str(archive)]
    commands.run(swift_args, timeout=1200)
    binary_dir = commands.run(swift_args + ["--show-bin-path"], timeout=120).splitlines()[-1]
    executable = Path(binary_dir) / "WGLinkProbe"
    if not executable.is_file() or executable.is_symlink():
        raise BuildError("E_LINK: executable not produced")
    if commands.run(["/usr/bin/xcrun", "lipo", "-archs", str(executable)]) != "arm64":
        raise BuildError("E_ARCH: expected arm64 executable")
    require_symbols(commands.run(["/usr/bin/xcrun", "nm", "-gU", str(executable)]))
    return executable


def build(commands: Commands, lock: dict, tools: dict, output: Path, run: Path, fetch: bool) -> dict:
    support = checked_support(ROOT, lock)
    checked_bridge(ROOT, lock)  # Reject asset drift before any public download.
    cache = output / "sources"; private_directory(cache)
    for name in ("apple", "engine"):
        spec = lock[name]
        repository = source_repository(commands, cache, name, spec, fetch)
        target = run / ("wireguard-apple" if name == "apple" else "wireguard-go")
        export_source(commands, repository, spec, target, APPLE_PATHS if name == "apple" else None)
    # Verify upstream bytes first; patch only this run's exported snapshot.
    # A new run re-exports from the unchanged cache, so no manual .local edit is needed.
    manifest = run / "wireguard-apple/Package.swift"
    if manifest.is_symlink():
        raise BuildError("E_WG_MANIFEST_PATH")
    modified_manifest = patch_manifest(manifest.read_bytes())
    if git_blob(modified_manifest) != lock["patched_manifest_blob"]:
        raise BuildError("E_WG_MANIFEST_LOCK")
    manifest.write_bytes(modified_manifest)
    adapter = run / "wireguard-apple/Sources/WireGuardKit/WireGuardAdapter.swift"
    original = adapter.read_bytes(); modified = patch_runtime_adapter(patch_adapter(original))
    adapter.write_bytes(modified)
    # Same owned source as the standalone concurrency tests; reject collisions.
    with adapter.with_name("SplitterSettingsCompletion.swift").open("xb") as destination:
        destination.write(support)
    (run / "policy-settings.patch").write_text("".join(difflib.unified_diff(
        original.decode().splitlines(True), modified.decode().splitlines(True),
        fromfile="a/Sources/WireGuardKit/WireGuardAdapter.swift", tofile="b/Sources/WireGuardKit/WireGuardAdapter.swift")))
    executable = compile_native(commands, tools, run, ROOT, fetch)
    return dict(schema="wireguard-native-build-v1", result="PASS", tools=tools,
                apple_revision=lock["apple"]["revision"], engine_revision=lock["engine"]["revision"],
                lock_sha256=hashlib.sha256(LOCK_PATH.read_bytes()).hexdigest(),
                patched_manifest_blob=git_blob(modified_manifest),
                patched_adapter_blob=git_blob(modified), settings_completion_blob=git_blob(support),
                runtime_hook_blob=lock["runtime_hook_blob"], bridge=lock["bridge"],
                bridge_lifecycle_tests="PASS", artifact=str(executable),
                artifact_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                execution="NOT_RUN", provider="NOT_LINKED", runtime_approval="NOT_GRANTED",
                network_settings="NOT_APPLIED", extension_activation="NOT_REQUESTED")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("preflight", "build"), nargs="?", default="preflight")
    parser.add_argument("--fetch", action="store_true", help="allow pinned public source/module downloads")
    args = parser.parse_args()
    run = None
    try:
        if args.fetch and args.mode != "build":
            raise BuildError("E_ARGUMENT: --fetch is only valid with build")
        lock = json.loads(LOCK_PATH.read_text())
        env = clean_environment(); commands = Commands(env)
        tools = preflight(commands, lock)  # No directories/downloads before this succeeds.
        if args.mode == "preflight":
            print("schema=wireguard-native-build-v1\npreflight=PASS\nartifact=NOT_BUILT\nnetwork_settings=NOT_APPLIED")
            return 0
        private_directory(ROOT / ".local")
        output = ROOT / ".local/wireguard-engine"; private_directory(output)
        with build_lock(output / "build.lock"):
            run = Path(tempfile.mkdtemp(prefix="build.", dir=output))
            for name in ("gopath", "gocache", "gomodcache"):
                private_directory(output / name)
            env.update(GOPATH=str(output / "gopath"), GOCACHE=str(output / "gocache"),
                       GOMODCACHE=str(output / "gomodcache"), GIT_CEILING_DIRECTORIES=str(output))
            commands = Commands(env, run / "build.log")
            result = build(commands, lock, tools, output, run, args.fetch)
            (run / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
            print("schema=wireguard-native-build-v1\ncompile_link=PASS\nbridge_lifecycle_tests=PASS\nartifact_execution=NOT_RUN\n"
                  "provider=NOT_LINKED\nnetwork_settings=NOT_APPLIED\nextension_activation=NOT_REQUESTED")
            print("Local results: " + str(run))
            return 0
    except (BuildError, ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        if run:
            # No PASS marker survives a failed build, including an interrupted retry.
            (run / "failure.txt").write_text(type(error).__name__ + ": " + str(error) + "\n")
            print("Local failure results: " + str(run), file=sys.stderr)
        return 2


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
