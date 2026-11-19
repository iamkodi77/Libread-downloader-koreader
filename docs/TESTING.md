# Testing and Kindle acceptance

## What has been tested

Run from the repository root:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
python scripts/test.py
```

The suite runs the actual plugin code in **LuaJIT 2.1** through Lupa, not a Lua 5.4-only interpreter. It checks syntax for every plugin Lua file. Only development/test hosts need Python or Lupa.

Coverage includes:

- Valid/invalid series URLs, host/path restrictions, relative media links, and filename safety.
- HTML attributes, entities, inline whitespace, common optional closing tags, nested ads, script/form stripping, and bounded nesting.
- Series metadata, pagination, overlapping/repeated pages, speculative last-page 404s, locked rows, and explicit pagination failures.
- Selection validation; text, mixed text/image, and image-only chapters; challenge/missing/empty pages; image signatures.
- HTTP retries, bounded Retry-After, redirects, permanent failures, explicit TLS options, partial/oversized responses, and timeout reset on exceptions.
- Real filesystem cache persistence, corrupt/unsafe metadata, changed image settings, and missing cached assets.
- Resuming partial downloads, retrying gaps, fatal network stops, failed/canceled packaging, and preservation of existing EPUBs.
- KOReader API-contract smoke tests for menu registration, dispatcher action, input/range/confirmation dialogs, worker cancellation/crashes, settings, recent series, reports, and read-now behavior from both file manager and reader contexts.
- Actual EPUB/ZIP generation, independently inspected with Python `zipfile` and `ElementTree`: CRCs, first uncompressed `mimetype` entry, well-formed XML, metadata, manifest targets, spine order, EPUB 3 navigation, NCX order, and local image references.
- Streaming ZIP CRCs over multiple 64 KiB reads, empty entries, and reproducible installation ZIP layout/checksums.

All pages are **synthetic fixtures matching the source downloader's selectors**; no novel text or artwork is bundled. Test files and archives are generated under ignored `.cache/test-output/`.

The filesystem and JSON adapters use the host's real filesystem and Python JSON implementation. KOReader widgets, network manager, subprocess API, and HTTPS transport are stubbed at their interfaces. Thus these tests do **not** exercise a real TLS handshake, Linux fork/kill integration inside KOReader, e-ink rendering, a device's memory budget, or the current live website. XML/manifest checking is not a claim of official EPUBCheck certification.

## Physical Kindle 10th-gen checklist — still required

Use a small series you are authorized to download. Test a Kindle Basic 2019 and/or Paperwhite 4 with a recent official KOReader Kindle build. Record the exact model and KOReader version with results.

- [ ] Copy the plugin into the real `koreader/plugins` directory; confirm it loads after restart without `crash.log` errors.
- [ ] Open it from both the file manager and an already-open book. Verify menu sizing, scrolling, keyboard controls, and folder selection on the six-inch display.
- [ ] Start with Wi-Fi off. Verify KOReader's normal connection prompt and cancellation behavior.
- [ ] Load a real series. Verify title, author, cover, first/last chapter titles, ordering, and pagination beyond 40 chapters against the website.
- [ ] Export `1`, `1-3`, and a range that crosses a catalog page boundary. Verify no missing/duplicated text.
- [ ] Read the EPUB in KOReader. Open its TOC, turn pages, change font size, inspect the cover and mixed/image-only chapters, close, and reopen it offline.
- [ ] Tap progress during a slow request and during packaging. Verify the UI remains responsive and the old EPUB remains readable.
- [ ] Retry the same range; verify completed chapters are reused. Expand to an overlapping range and check the EPUB contains only that requested range.
- [ ] Turn images/cover off and back on; verify the output and resume-cache behavior match those settings.
- [ ] Check a missing/locked chapter and a blocked endpoint. Verify truthful skipped/error reporting, no unlocking, and no repeated requests for the rest of the series after a fatal chapter error.
- [ ] Change the output folder, restart KOReader, and check settings/history and **Open last downloaded book**.
- [ ] Check low-storage handling safely (do not deliberately fill a working Kindle to zero free bytes). Verify failed writes do not replace a known-good EPUB.
- [ ] Try a modest 50-chapter batch while monitoring battery, free space, and `crash.log`; scale up only if appropriate.
- [ ] Remove just `.libread-cache`; verify the existing EPUB still reads and a subsequent export downloads fresh chapters.

## Reporting regressions

Include model, KOReader version, series URL, range, image/cover options, whether the cache was present, observed behavior, and relevant log lines. Avoid credentials and chapter contents. Site markup can change independently of this plugin; update the parser and add a small, original fixture reproducing the structural change.
