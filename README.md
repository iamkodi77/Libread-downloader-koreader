# LibRead Downloader for KOReader

A native Lua plugin inspired by [mrcloudworks-glitch/libread-downloader](https://github.com/mrcloudworks-glitch/libread-downloader). Download accessible LibRead web-novel chapters directly on your reader and export an offline EPUB.

**Target: KOReader on a Kindle 10th generation** — including the Kindle Basic (2019) and Paperwhite 4 (2018). No Python, pip, curl, external ZIP program, or extra native libraries are needed **on the Kindle**.

> **Validation status:** automated LuaJIT 2.1 tests and generated-EPUB checks pass. A physical Kindle and the live LibRead website have **not** been tested in this development environment. The parser implements the page structure used by the linked downloader. See [testing and device checks](docs/TESTING.md).

## Features

- Enter a `libread.com` series URL or just its slug.
- Fetch paginated chapter lists; deduplicate links and stop repeated-page loops.
- Browse chapters or download `all`, one position, or an inclusive range such as `1-50`.
- EPUB 3 output with metadata, navigable contents, an NCX compatibility TOC, and an optional cover.
- Optional chapter images: JPEG, PNG, GIF, and WebP. Mixed text/image chapters retain **both**; illustrated chapters keep their page order.
- Resume from completed, disk-cached chapters. Overlapping ranges reuse the same chapter cache.
- Cancellable network/packaging workers using KOReader's subprocess facilities; progress updates between chapters and catalog pages.
- Atomic output replacement: cancellation or a fatal error does not replace an existing EPUB.
- Recent-series history, configurable download folder, request delay/timeout, and **Read now** from the completion dialog.
- TLS certificate verification, bounded responses, sequential requests, and limited retries.

Only download material you are authorized to save. No account login, DRM removal, paywall unlocking, JavaScript execution, or CAPTCHA/browser-challenge bypass is provided. This is not affiliated with LibRead or KOReader.

## Requirements

1. A Kindle with **KOReader already installed and working**. On Kindle this normally requires a jailbroken device and a working KOReader launcher. This plugin does not install KOReader or jailbreak the device.
2. A recent official KOReader Kindle build, including its normal LuaSocket/LuaSec modules and CA certificate bundle. Update KOReader first if your installation is old.
3. Wi-Fi access to LibRead and its image servers, a correct device clock, and sufficient free storage.

The plugin is architecture-independent Lua 5.1/LuaJIT code. It uses KOReader's built-in modules rather than shipping desktop/ARM binaries. Device support still depends on your KOReader build; no hardware-certification claim is made.

## Install on Kindle 10th gen

1. **Exit KOReader** and connect the Kindle over USB.
2. Extract the provided `libread-koplugin.zip`. Alternatively, copy the `libread.koplugin` directory directly from this repository.
3. Put that **whole directory** inside your existing KOReader `plugins` directory. With the usual Kindle installation, the layout on the USB drive is:

   ```text
   koreader/
     plugins/
       libread.koplugin/
         _meta.lua
         main.lua
         libread/
           entities.lua
           epub.lua
           errors.lua
           fs.lua
           html.lua
           http.lua
           parser.lua
           service.lua
           store.lua
           urls.lua
           zip.lua
   ```

   The on-device path is normally `/mnt/us/koreader/plugins/libread.koplugin/`.
   Do not leave an extra repository/ZIP directory between `plugins` and `libread.koplugin`.
4. Safely eject USB and restart KOReader.
5. Open **Tools → More tools → LibRead downloader**. Menu grouping may differ by KOReader version. If missing, check **Plugin management**, enable **LibRead downloader**, and restart.

To update, exit KOReader and replace only `libread.koplugin`. Books and settings are stored separately. To uninstall, remove that plugin directory and restart.

## Use

1. Enable Wi-Fi, then choose **Add series URL or slug**. KOReader can prompt to connect when a task starts.
2. Enter a series link, for example:

   ```text
   https://libread.com/libread/starting-with-an-sss-rank-goddess-summon-216486
   ```

   Or enter only `starting-with-an-sss-rank-goddess-summon-216486`.
   Chapter URLs and unrelated websites are not accepted.
3. After the catalog loads, choose **Browse chapters**, **Download chapter or range**, or **Download all accessible chapters**.
4. Enter `all`, `12`, or `1-50`, confirm, and wait. **Start with 10–50 chapters on a Kindle.**
5. Choose **Read now**, or open the resulting EPUB from KOReader's file browser later.

**Selection numbers are positions in the plugin's accessible-chapter list**, not necessarily the numbers printed in chapter titles. Visibly locked rows are excluded. Check **Browse chapters** if a novel has a prologue, missing chapters, or changing availability.

### Output and settings

The default Kindle download folder is `/mnt/us/documents/LibRead`, visible over USB as `documents/LibRead`. Change it under the plugin's **Settings → Download folder**; long-press a folder in KOReader's chooser to select it.

```text
LibRead/
  series-slug/
    Series Title [1-50].epub
    .libread-cache/
      index.json
      chapter-1.xhtml
      c1-001.png
      cover.jpg
      ...
```

- EPUBs are for **KOReader**. They are not automatically added as readable books in Amazon's stock Kindle interface.
- Settings/history normally live in `koreader/settings/libread.lua`, not the plugin directory.
- Covers and chapter images default to **on**. Turn chapter images off for a smaller text-only export; image-only chapters then cannot be exported.
- Defaults: **0.5 s delay before every request**, **30 s request timeout**, **3 attempts** for transient errors. Delay is adjustable from 0.3–5 s; timeout from 10–120 s. DNS, backoff, and multiple attempts can extend elapsed time.
- The last download report is available for the current plugin session. It lists skipped chapters and cover warnings.

### Resume, incomplete exports, and storage

Tap a progress window to cancel. Run the **same range again** to reuse completed chapters and retry unfinished ones. To include newly published chapters, reload the series and choose a larger/new range; exports are rebuilt, not appended to an existing EPUB.

Missing/locked chapters or invalid images are reported and skipped. If at least one chapter succeeds, an EPUB containing those successful chapters is produced. **Check the completion count/report**: a successfully built EPUB is not a guarantee every requested chapter was available. A fatal chapter network error, access block, or rate limit stops the task rather than repeatedly hitting every remaining endpoint.

Cache entries are tied to the chapter URL and image setting. They are not periodically refreshed for upstream edits. For a fresh download, delete the series' hidden `.libread-cache` directory while KOReader is idle, then retry. You can also delete this directory over USB after exporting to reclaim space; existing EPUBs remain readable, but the next export will redownload chapters. Show hidden files on your computer to find it.

EPUB ZIP entries use **STORE (no compression)** for a portable, streaming implementation. Allow space for the cache **and** the new EPUB, plus an old EPUB during replacement. Keep the Kindle charged; long illustrated novels can be very large. An interrupted task may leave `.part` files in the cache; retries overwrite them, or they can be removed while the plugin is idle.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Plugin is missing | Folder nesting, `main.lua`/`_meta.lua`, Plugin management, and a full KOReader restart. |
| HTTP 403, CAPTCHA, or “Just a moment” | LibRead is blocking non-browser access. Try later. This plugin does not bypass the challenge. |
| Certificate/TLS error | Check Kindle date/time and update KOReader/its CA bundle. Do not turn off certificate verification. |
| No chapter list/article | Use a **series** URL; the series may be unavailable or the site HTML may have changed. |
| Chapter skipped | Read **Last download report**. The content may be locked/missing, image-only with images disabled, or contain an unsupported/broken image. |
| Worker exits / Kindle runs low on memory | Restart KOReader, export a smaller range, and/or disable images. |
| Write/rename error | Check free space, chosen folder permissions, and that USB storage is not mounted on your computer. |
| EPUB seems out of date | Cached chapters are reused; remove that series' cache for a fresh fetch. |

Safety bounds: 500 catalog pages / 20,000 chapters, 4 MiB per HTML response, 12 MiB per image, 200 images per chapter, and ZIP32 limits (under 4 GiB and at most 65,535 entries per EPUB). Very long slugs (over 150 bytes), SVG/AVIF images, audio/video, and JavaScript-rendered content are not supported. This is a focused site parser, not a general web browser or a complete HTML5 parser.

For a reproducible issue, include the KOReader version, Kindle model, series URL, requested range, and relevant `koreader/crash.log` lines. Do not share credentials or copyrighted chapter dumps.

## Development / build an installation ZIP

These commands run **on a development computer**, not on the Kindle:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
python scripts/test.py
python scripts/package.py
```

`artifacts/libread-koplugin.zip` and its SHA-256 file are generated locally. The ZIP contains only the installable plugin, license, and documentation, not tests or downloaded books. Packaging itself needs only Python's standard library. CI runs the tests and creates the same installable artifact.

See [docs/TESTING.md](docs/TESTING.md) for coverage and the physical-Kindle acceptance checklist, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for implementation notes.

## Attribution and license

Independently implemented in Lua using the workflow and page structure of [the original Python downloader](https://github.com/mrcloudworks-glitch/libread-downloader). The Python source and its dependencies are **not** redistributed. That upstream repository had no declared license when inspected; this project's license does not apply to it.

This implementation is licensed **GPL-3.0-or-later**; see [LICENSE](LICENSE). KOReader and its bundled libraries retain their own licenses. Downloaded text and artwork remain the property of their respective rights holders.
