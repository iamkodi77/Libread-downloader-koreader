# Architecture and compatibility notes

## Runtime boundary

`libread.koplugin/main.lua` is a normal `WidgetContainer` plugin (`name = "libread"`, `is_doc_only = false`). It registers a Tools/More tools entry and the `ShowLibRead` dispatcher event. All internal modules are namespaced under `libread/` to avoid other plugins' module names.

The installed plugin uses only Lua 5.1 syntax, LuaJIT's built-in `bit`, and modules shipped with official KOReader builds: UI widgets, `ui/trapper`, network manager, LuaSettings/DataStorage, LuaSocket/LuaSec, `socketutil`, `json`, and `libs/libkoreader-lfs`. It does not depend on another optional KOReader plugin, a shell, Python, a command-line downloader, an external ZIP utility, or a separately compiled ARM library.

The intended devices are the 10th-generation Kindle Basic (KOReader's `KindleBasic3`) and Paperwhite 4 (`KindlePaperWhite4`). There is no device-ID whitelist: other supported KOReader platforms may work, but have not been device-tested either. On non-Kindle devices, the default output folder falls back to a `LibRead` folder in KOReader's configured home/data directory.

## Modules

| Module | Responsibility |
| --- | --- |
| `main.lua`, `_meta.lua` | Plugin registration, menus/dialogs, settings/history, Wi-Fi activation, worker boundary, read-now |
| `libread/service.lua` | Catalog pagination, chapter selection/export orchestration, failure policy |
| `libread/http.lua` | Verified HTTPS, sequential delay/retries, manual redirects, response limits |
| `libread/urls.lua` | Series slug parsing, site URLs, chapter validation, media resolution |
| `libread/html.lua`, `entities.lua` | Bounded site-specific HTML reader, entity decoding, whitelist XHTML serialization |
| `libread/parser.lua` | LibRead metadata, `ul#idData` chapter links, pagination links, `div#article`, image signatures |
| `libread/store.lua`, `fs.lua` | JSON cache index, safe deterministic filenames, atomic writes |
| `libread/epub.lua` | EPUB 3 package, cover, XHTML, navigation, NCX, manifest/spine |
| `libread/zip.lua` | Portable streaming ZIP32/CRC32 writer with uncompressed entries |
| `libread/errors.lua` | Serializable errors shared across worker boundaries |

## Work and cancellation

The UI calls `NetworkMgr:runWhenConnected` **before** starting a `Trapper:wrap` job. Catalog pages, individual chapter downloads (including their images), and EPUB packaging each run through `Trapper:dismissableRunInSubprocess`. Workers do not touch UI, activate Wi-Fi, or write KOReader's settings. They return simple serializable tables. A single busy flag prevents overlapping LibRead jobs on the current UI instance.

KOReader handles the subprocess and kill/reap mechanics. Tapping progress cancels the active worker. The parent notices cancellation, clears the busy state, and reports how to resume. No UI blocking `socket.sleep` or HTTP call is used in the parent; request delays/retries happen in the worker.

Individual cache files are written to `.part`, closed, then renamed. The JSON cache index is updated only after the complete chapter and its images are written. A killed worker may leave unindexed files or `.part` files; retries replace them. Chapters are cached by source chapter ID/URL, not by range position. Changing the chapter-image option invalidates that chapter's cached edition.

EPUB construction reads one cached file in 64 KiB chunks and patches each ZIP local-header CRC after writing. It stores only the central-directory metadata and navigation/manifest strings in memory, not the whole book. Required `mimetype` is first, stored without compression or extra fields. The worker creates `<output>.part`; only the parent renames it over the final EPUB after successful worker completion. This is an atomic-rename safeguard, not a promise against power-loss/filesystem corruption.

## Failure policy and trade-offs

- Visibly locked catalog entries are excluded, but not every locked page is recognizable in the catalog.
- Missing/empty/locked chapters or unsupported image data are skipped and reported. Images are never deliberately dropped from a chapter marked complete with images enabled.
- An optional cover can be omitted with a warning. Cover disk errors, cancellation, and rate limits are fatal.
- Chapter network failures, access blocks, rate limits, disk errors, safety limits, and unexpected runtime errors stop the export. Completed chapters remain cached.
- A partial selection with at least one successful chapter still produces an EPUB, and can replace the selected range's previous EPUB after successful packaging; the completion count/report identifies gaps. A built EPUB is not an assertion that every requested chapter was available.
- Cache validity checks metadata and file presence/nonzero length, not a cryptographic digest or upstream modification date. Delete the cache for changed source content or suspected corruption.
- ZIP STORE avoids a changing native archive API and architecture-specific binaries, at the cost of larger EPUBs. Cache/index writes and subprocess startup also make small batches preferable on older e-readers.
- Images are fetched one at a time, with an explicit size limit; HTML parsing is bounded by response size, element count and nesting depth. Covers/chapters remain separate files.
- The parser is not a browser, does not run JavaScript, and does not implement the entire HTML5 parsing specification. Unsupported named entities are escaped as literal text rather than emitted as invalid XML.
- No telemetry, cookies, user accounts, or credentials are stored or transmitted by the plugin. Network requests go to LibRead and media/redirect hosts selected by those pages. Standard TLS verification is explicitly enabled and relies on KOReader's LuaSec hostname checks and CA bundle. IP-literal/local-suffix media URLs and off-site HTML redirects are rejected; this is not a general-purpose SSRF-proof HTTP service.

## Source/API inspection

Implementation references inspected on 2026-11-19:

- Original downloader: [`mrcloudworks-glitch/libread-downloader` at `7d46cd3bfa0e95b05e106b3cd21eddf835cda885`](https://github.com/mrcloudworks-glitch/libread-downloader/tree/7d46cd3bfa0e95b05e106b3cd21eddf835cda885), particularly its catalog URLs/selectors and chapter article structure. No Python source is bundled.
- KOReader: [`koreader/koreader` at `21cc368d388378b6fc8ecdbfc879d8f89c17eca1`](https://github.com/koreader/koreader/tree/21cc368d388378b6fc8ecdbfc879d8f89c17eca1), including plugin loader/hello, OPDS read-now, network manager, widgets, and Trapper's documented worker contract.
- KOReader base: its LuaSec CA-bundle, default-verification, and hostname-verification patches.

The latest published release visible during inspection was `v2026.07.1`. API inspection is **not** device testing or verification of current live LibRead pages. Prefer a current official Kindle build and follow the [acceptance checklist](TESTING.md).
