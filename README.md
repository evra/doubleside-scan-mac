# Duplex Scan

macOS app for scanning to PDF with duplex support, built on [libscanline](https://github.com/klep/scanline) (git submodule in `Vendor/scanline`, pinned to v2.3).

- **Duplex**: manual (fronts, flip stack, backs; interleaved in reversed or same order, backs can be skipped), scanner hardware duplex (`-duplex`), or single-sided. Flatbed is supported.
- **Review**: page thumbnails and preview; remove pages (⌘⌫, multi-select in the sidebar) with undo; scan more pages and append.
- **Naming**: pattern with `{date}`, `{date:FORMAT}`, `{time}`, `{ai}` (libscanline `-autoname`), `{tags}`, `{pages}`, `{counter:N}`. Default `scan-{date:yyyyMMdd-HHmmss}`.
- **Output**: local folder and/or automatic Google Drive upload. An optional Apple Intelligence summary (`-summarize`) becomes the Drive file description.
- **libscanline options in Settings**: `-scanner`, `-exactname`, `-browsesecs`, `-flatbed`, `-duplex`, `-a4/-letter/-legal`, `-resolution`, `-mono`, `-rotate`, `-verbose`, `-autoname`, `-summarize`, tags, and `-open` as "Open the result after saving". `~/.scanline.conf` is ignored; the app settings apply instead.

## Build

Requires Xcode 16+ (macOS 26 SDK for libscanline's Apple Intelligence code) and macOS 15+.

```sh
git submodule update --init
Scripts/build-app.sh          # -> build/Duplex Scan.app (ad-hoc signed)
swift test                    # unit tests
swift run DuplexScan          # run without bundling
```

## Google Drive

This uses the same Google setup as the `scan-doubleside` shell scripts. The OAuth config is `~/.config/doubleside-scan/google-oauth.json`, which you can change in Settings → Output. The Keychain item is also shared, so an existing sign-in keeps working.

1. In Google Cloud Console, enable the **Google Drive API** and **Google Picker API**. Then create an OAuth client of type **Desktop app** and download its JSON.
2. Create an API key that is restricted to the Picker API and the referrer `http://127.0.0.1:43871/*`.
3. Add a top-level `picker` object to the downloaded JSON:
   ```json
   "picker": { "api_key": "YOUR_PICKER_API_KEY", "app_id": "YOUR_PROJECT_NUMBER" }
   ```
   `app_id` is the numeric project number (the prefix of `client_id`), not the project ID. If it isn't numeric, the app uses the `client_id` prefix instead.
4. In Settings → Output, choose **Sign In…** and then **Choose Folder…**. Sign-in uses the `drive.file` scope. The browser callback goes to `127.0.0.1:43871`, and the refresh token is stored in Keychain.
