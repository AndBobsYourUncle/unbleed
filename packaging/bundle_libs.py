#!/usr/bin/env python3
"""Copy every non-system library an app links (recursively) into Contents/Frameworks and rewrite the
load commands to @rpath, so the app is self-contained (no Homebrew needed) and can be signed with one
identity — which the hardened runtime requires.

usage: bundle_libs.py <path/to/App.app>
"""
import os
import shutil
import subprocess
import sys
from collections import deque

SYSTEM = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def deps(binary):
    """Install names this binary loads (excluding its own id line for dylibs)."""
    lines = run("otool", "-L", binary).splitlines()[1:]
    names = [l.strip().split(" (compatibility")[0] for l in lines]
    own_id = run("otool", "-D", binary).splitlines()[1:]
    return [n for n in names if n not in own_id]


def rpaths(binary):
    out, lines = [], run("otool", "-l", binary).splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            entry = lines[i + 2].strip()  # "path @loader_path/../lib (offset 12)"
            out.append(entry.removeprefix("path ").rsplit(" (offset", 1)[0])
    return out


def resolve(name, referrer, referrer_rpaths, exe_dir):
    """Turn an install name into a real file path (or None for system libraries)."""
    if name.startswith(SYSTEM):
        return None
    if name.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(referrer), name[len("@loader_path/"):]))
    if name.startswith("@executable_path/"):
        return os.path.realpath(os.path.join(exe_dir, name[len("@executable_path/"):]))
    if name.startswith("@rpath/"):
        for rp in referrer_rpaths:
            rp = rp.replace("@loader_path", os.path.dirname(referrer)).replace("@executable_path", exe_dir)
            candidate = os.path.join(rp, name[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise SystemExit(f"can't resolve {name} referenced by {referrer}")
    return os.path.realpath(name)


def main():
    app = sys.argv[1].rstrip("/")
    exe_dir = os.path.join(app, "Contents", "MacOS")
    exe = os.path.join(exe_dir, os.listdir(exe_dir)[0])
    frameworks = os.path.join(app, "Contents", "Frameworks")
    os.makedirs(frameworks, exist_ok=True)

    copied = {}  # real source path -> bundled path
    queue = deque([(exe, rpaths(exe))])
    while queue:
        binary, binary_rpaths = queue.popleft()
        for name in deps(binary):
            if name.startswith("@rpath/") and os.path.exists(os.path.join(frameworks, os.path.basename(name))):
                src = os.path.realpath(os.path.join(frameworks, os.path.basename(name)))
                if src.startswith(os.path.realpath(frameworks)):
                    continue  # already bundled and rewritten
            src = resolve(name, binary, binary_rpaths, exe_dir)
            if src is None or src.startswith(os.path.realpath(app)):
                continue
            base = os.path.basename(name)
            if src not in copied:
                dst = os.path.join(frameworks, base)
                shutil.copy2(src, dst)
                os.chmod(dst, 0o755)
                run("install_name_tool", "-id", f"@rpath/{base}", dst)
                copied[src] = dst
                queue.append((dst, rpaths(src) + [os.path.dirname(src)]))
            run("install_name_tool", "-change", name, f"@rpath/{base}", binary)

    # Bundled libraries find each other next to themselves; the app finds them in Frameworks.
    for lib in copied.values():
        for rp in rpaths(lib):
            run("install_name_tool", "-delete_rpath", rp, lib)
        run("install_name_tool", "-add_rpath", "@loader_path", lib)
    for rp in rpaths(exe):
        if not rp.startswith("@"):
            run("install_name_tool", "-delete_rpath", rp, exe)
    if "@executable_path/../Frameworks" not in rpaths(exe):
        run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", exe)

    leftovers = [(b, d) for b in [exe, *copied.values()] for d in deps(b) if d.startswith("/opt/") or d.startswith("/usr/local/")]
    if leftovers:
        raise SystemExit(f"still linking outside the bundle: {leftovers[:3]}")
    print(f"bundled {len(copied)} libraries into {frameworks}")


if __name__ == "__main__":
    main()
