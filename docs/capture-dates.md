# Capture dates

PhotoKit `creationDate` is an absolute instant, independent of an original's EXIF.
New jobs snapshot it in `capture-date.json` as milliseconds since the Unix epoch.
The delivery still receives missing EXIF/XMP capture dates in UTC, including the
UTC offset and three fractional digits. Existing valid capture dates, creation
and editing tags remain unchanged. ExifTool writes only an independent copy;
the exported original is never edited or re-encoded.

Live Photo stills receive dates before Motion Photo packaging calculates video
offsets. Every burst frame receives its own capture instant. Videos retain their
embedded container dates: a valid conflicting video date requires a separate
review and is not overwritten automatically.

The Pixel transfer verifies staged bytes, sets and verifies the modification
time, then publishes the file. Same-hash retries restore that time again before
requesting the Android scan. A failed timestamp write stops publication/scanning.
Android `DATE_TAKEN` uses milliseconds, while its indexed `DATE_MODIFIED` uses
seconds. Pixel XL / Android 10 testing found JPEG and HEIC capture dates survive
rescanning; PNG retains EXIF/XMP and a correct file-time fallback, while Android
10's scanner leaves its `DATE_TAKEN` empty. This does not prove every format's
Google Photos cloud display behavior.

An existing queue hash is a delivery proof. Legacy pending jobs retain those
exact bytes, including after rebuilding an evicted cache. Their filesystem date
can be restored, but adding embedded metadata is deferred to historical review.
Unknown PhotoKit dates are never replaced by the current time.

## Historical audit

A successful library scan writes `State/capture-date-inventory.json` locally.
`scripts/audit-capture-dates.py --state-dir STATE --adb ADB --device SERIAL
--output DIRECTORY` joins that inventory to delivered queue proofs and reads the
Pixel media index. It exports CSV and JSON, without downloading, rewriting,
deleting or re-uploading user media. Files absent from the Pixel, unknown source
dates, and conflicting valid embedded dates remain explicitly unresolved.
The optional `--known-dates` accepts separately reviewed identity/date mappings.
A filename or an upload date alone is not an adequate source identity.

Review the cloud item against this mapping before changing anything. For a cloud
item with correct pixels but a wrong date, prefer [Google's date-editing operation](https://support.google.com/photos/answer/6128850?co=GENIE.Platform%3DDesktop)
once its exact identity is confirmed. Altering a Pixel file does not guarantee an
already-backed-up cloud item will change. Re-uploading a modified file can create
a duplicate; never delete or re-upload historical items automatically.

Reference reviewed: PhotoBridge commit
[`5f33898`](https://github.com/qhhonx/photobridge/commit/5f33898f2a84adbea37b2540ff58b83cd9a0ab23),
particularly `MediaDates.kt`, HEIC date handling and Android rescan tests.
PixelBridge uses its existing Mac ExifTool and ADB transport; the Android receiver
implementation was not copied wholesale.
