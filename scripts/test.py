#!/usr/bin/env python3
"""Run real plugin Lua on LuaJIT 2.1, then independently inspect generated EPUBs.

KOReader-only filesystem/JSON/UI interfaces are bridged or stubbed; no live
LibRead access or physical Kindle is required. The network is fixture-driven.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TEMP = ROOT / ".cache" / "test-output"


def main() -> None:
    try:
        from lupa.luajit21 import LuaRuntime, lua_type
    except ImportError:
        sys.exit("Install test dependencies first: python3 -m pip install -r requirements-dev.txt")
    os.chdir(ROOT)
    if TEMP.exists():
        shutil.rmtree(TEMP)
    TEMP.mkdir(parents=True)
    (TEMP / "pixel.png").write_bytes(base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    ))
    (TEMP / "test-ca.crt").write_text("Fixture only: HTTPS transport is mocked.\n")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().PROJECT_ROOT = str(ROOT)
    lua.globals().TEST_ROOT = str(TEMP)

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({key: to_lua(val) for key, val in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(val) for val in value])
        return value

    def from_lua(value):
        if lua_type(value) != "table":
            return value
        keys = list(value.keys())
        if keys and all(isinstance(key, (int, float)) for key in keys) and set(keys) == set(range(1, len(keys) + 1)):
            return [from_lua(value[i]) for i in range(1, len(keys) + 1)]
        return {str(key): from_lua(val) for key, val in value.items()}

    def attributes(path, key=None):
        try:
            value = Path(path).stat()
        except OSError:
            return None
        mode = "directory" if stat.S_ISDIR(value.st_mode) else "file" if stat.S_ISREG(value.st_mode) else "other"
        result = {"mode": mode, "size": value.st_size}
        return result.get(key) if key else to_lua(result)

    def mkdir(path):
        try:
            Path(path).mkdir()
            return True
        except OSError as error:
            return None, str(error)

    lua.globals()._test_attributes = attributes
    lua.globals()._test_mkdir = mkdir
    lua.globals()._test_json_encode = lambda value: json.dumps(from_lua(value), ensure_ascii=False)
    lua.globals()._test_json_decode = lambda value: to_lua(json.loads(value))
    lua.execute('''
        package.preload["libs/libkoreader-lfs"] = function()
            return { attributes = _test_attributes, mkdir = _test_mkdir }
        end
        package.preload["json"] = function()
            return { encode = _test_json_encode, decode = _test_json_decode }
        end
    ''')
    for source in sorted((ROOT / "libread.koplugin").rglob("*.lua")):
        lua.globals()._source = str(source)
        lua.execute("assert(loadfile(_source))")
    lua.execute("dofile('tests/run.lua')")
    lua.execute("io.flush()")
    archives = sorted(TEMP.rglob("*.epub"))
    assert archives, "No EPUB integration-test output"
    for archive in archives:
        validate_epub(archive)
    with zipfile.ZipFile(TEMP / "stream.zip") as archive:
        assert archive.testzip() is None
        assert archive.read("empty") == b""
        assert archive.read("stream.txt") == b"stream-data\n" * 100000
    print(f"Validated {len(archives)} real EPUB archives: ZIP CRCs, XML, manifest, spine, TOC and local assets.")
    print("Validated multi-chunk streaming ZIP and empty-entry CRCs.")
    validate_package()


def validate_epub(path: Path) -> None:
    ns = {"opf": "http://www.idpf.org/2007/opf", "h": "http://www.w3.org/1999/xhtml",
          "ncx": "http://www.daisy.org/z3986/2005/ncx/", "dc": "http://purl.org/dc/elements/1.1/"}
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, path
        infos = archive.infolist()
        assert infos[0].filename == "mimetype" and infos[0].compress_type == zipfile.ZIP_STORED
        assert infos[0].extra == b"" and archive.read("mimetype") == b"application/epub+zip"
        names = set(archive.namelist())
        assert len(names) == len(infos), "Duplicate archive entry"
        for name in names:
            assert not name.startswith("/") and ".." not in PurePosixPath(name).parts
            if name.endswith((".xml", ".opf", ".ncx", ".xhtml")):
                ET.fromstring(archive.read(name))
        package = ET.fromstring(archive.read("OEBPS/content.opf"))
        assert package.attrib["version"] == "3.0"
        for field in ("identifier", "title", "creator", "language"):
            assert package.find(f"opf:metadata/dc:{field}", ns).text, field
        items = package.findall("opf:manifest/opf:item", ns)
        by_id = {item.attrib["id"]: item for item in items}
        assert len(by_id) == len(items)
        for item in items:
            assert "OEBPS/" + item.attrib["href"] in names, item.attrib
        spine = package.findall("opf:spine/opf:itemref", ns)
        assert spine
        chapter_files = []
        for ref in spine:
            assert ref.attrib["idref"] in by_id
            if ref.attrib.get("linear") != "no":
                chapter_files.append(by_id[ref.attrib["idref"]].attrib["href"])
        nav = ET.fromstring(archive.read("OEBPS/nav.xhtml"))
        assert [a.attrib["href"] for a in nav.findall(".//h:nav/h:ol/h:li/h:a", ns)] == chapter_files
        toc = ET.fromstring(archive.read("OEBPS/toc.ncx"))
        assert [c.attrib["src"] for c in toc.findall(".//ncx:content", ns)] == chapter_files
        for name in names:
            if name.endswith(".xhtml"):
                doc = ET.fromstring(archive.read(name))
                for image in doc.findall(".//h:img", ns):
                    src = image.attrib["src"]
                    assert ":" not in src and "OEBPS/" + src in names, src
                assert doc.find(".//h:script", ns) is None
    print("EPUB OK", path.relative_to(ROOT))


def validate_package() -> None:
    first, second = TEMP / "install-1.zip", TEMP / "install-2.zip"
    for path in (first, second):
        subprocess.run([sys.executable, str(ROOT / "scripts/package.py"), "--output", str(path)], check=True,
                       stdout=subprocess.PIPE, text=True)
    assert first.read_bytes() == second.read_bytes(), "Packaging is not reproducible"
    expected = {path.relative_to(ROOT).as_posix() for path in (ROOT / "libread.koplugin").rglob("*.lua")}
    expected.update({"libread.koplugin/README.md", "libread.koplugin/LICENSE"})
    expected.update("libread.koplugin/" + path.relative_to(ROOT).as_posix() for path in (ROOT / "docs").glob("*.md"))
    with zipfile.ZipFile(first) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == expected, "Installation ZIP includes missing or unexpected files"
        assert archive.read("libread.koplugin/main.lua") == (ROOT / "libread.koplugin/main.lua").read_bytes()
    checksum = first.with_suffix(".zip.sha256").read_text().split()[0]
    assert checksum == hashlib.sha256(first.read_bytes()).hexdigest()
    print("Installation ZIP OK: deterministic bytes, plugin folder layout, source contents and SHA-256.")


if __name__ == "__main__":
    main()
