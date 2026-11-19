#!/usr/bin/env python3
"""Build a deterministic, directly installable KOReader plugin ZIP (stdlib only)."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "libread.koplugin"


def package(output: Path) -> Path:
    sources = [(path, path.relative_to(ROOT).as_posix()) for path in PLUGIN.rglob("*.lua")]
    sources.extend((ROOT / name, f"libread.koplugin/{name}") for name in ("README.md", "LICENSE"))
    sources.extend((path, "libread.koplugin/" + path.relative_to(ROOT).as_posix())
                   for path in (ROOT / "docs").glob("*.md"))
    assert {"libread.koplugin/main.lua", "libread.koplugin/_meta.lua"} <= {name for _, name in sources}
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".part")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path, name in sorted(sources, key=lambda entry: entry[1]):
                if path.is_symlink() or not path.is_file():
                    raise ValueError(f"Not a regular source file: {path}")
                info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                archive.writestr(info, path.read_bytes(), compresslevel=9)
        with zipfile.ZipFile(temporary) as archive:
            assert archive.testzip() is None
            assert all(name.startswith("libread.koplugin/") for name in archive.namelist())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="ascii")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts" / "libread-koplugin.zip")
    args = parser.parse_args()
    output = package(args.output.resolve())
    print(f"Created {output} ({output.stat().st_size:,} bytes)")
    print(f"SHA-256: {output.with_suffix(output.suffix + '.sha256').read_text().strip()}")


if __name__ == "__main__":
    main()
