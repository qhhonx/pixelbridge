# Photo library loading and rendering

## Metadata and pagination

`BridgeModel.scan()` reads PhotoKit metadata in the background, sorts assets by creation date, and builds the `LibraryItem` index and media-type collections. Index entries contain the stable identifier, dates, media type and modification time, not full-size images. The initial scan indexes the whole library; pagination applies to presentation rather than PhotoKit queries.

`PhotoGrid` embeds `NSScrollView` and `NSCollectionView` through `NSViewRepresentable`. It starts with 200 items and appends another 200 when the viewport approaches within 800 points of the loaded content's bottom edge. Pages use `insertItems` instead of rebuilding the collection. Changing the media filter resets the page size. Library-change notifications, manual refresh and a ten-minute fallback scan refresh the metadata index.

## Cell reuse

- Register `PhotoCell` and use AppKit's `makeItem(withIdentifier:for:)` reuse mechanism.
- `configure` cancels the previous thumbnail request, clears the image and binds the new asset identifier.
- `didEndDisplaying` cancels work for offscreen cells; `prepareForReuse` clears the image and identity again.
- Every thumbnail callback checks cancellation and the cell's current asset identifier to prevent stale callbacks from displaying another photo.
- A `CALayer` presents the image using aspect-fill. Content changes disable implicit animations.
- Transfer-status changes update only visible cells' icons and labels, without reloading the collection or requesting thumbnails again.

## Thumbnail strategy

1. Look up the asset identifier and size tier in `NSCache`. Image limits are 500 entries and 128 MiB; the PHAsset cache holds up to 1,200 entries. These are eviction hints, not a hard app-memory cap or a strict LRU guarantee.
2. On a miss, retrieve the PHAsset in the background and request its thumbnail through a shared `PHCachingImageManager`.
3. Choose a width of 320 or 640 pixels based on tile size and display scale, with height equal to width / 1.37 and `.aspectFill` cropping.
4. `.opportunistic` delivery allows a quick lower-resolution preview followed by a clearer local result. `.fast` resizing permits approximate dimensions. Cache only non-degraded results; a subsequent empty result does not clear an existing preview.
5. `isNetworkAccessAllowed = false`: browsing never requests an iCloud original download. Show a placeholder if no local thumbnail is available. The backup pipeline downloads originals separately.
6. `ThumbnailTicket.cancel()` cancels the Swift task and PhotoKit request. Invalid callbacks cannot update a reused cell.

The current implementation does not proactively call `startCachingImages` or coalesce concurrent requests for the same asset. A gallery-revision change or view reconstruction clears the thumbnail cache. This is simpler than per-asset invalidation, but reduces cache hits after navigation or library changes. Metadata and layout costs grow with library size and browsing depth; cell reuse does not make all memory usage constant.

## Status icons and preferences

SF Symbols are shown by default. Still photos have no media-type marker; motion photos use `livephoto` and videos use `play.fill`.

| Status | SF Symbol |
| --- | --- |
| Not transferred | `clock` |
| Processing | `arrow.triangle.2.circlepath` |
| Queued for retry | `arrow.clockwise` |
| Failed or waiting to retry | `exclamationmark.circle.fill` |
| Transferred to Pixel | `checkmark.circle.fill` |
| Existing cloud-confirmation record | `checkmark.icloud.fill` |

Shape and color both convey status. Media-type icons appear at the top left and transfer status at the bottom right. Tooltips and VoiceOver retain the complete label. The Settings option for icon labels persists through AppStorage and updates immediately without reloading images or modifying the backup queue. A cloud icon requires an existing confirmation record; transfer completion never implies cloud backup. The app does not automatically verify cloud backup.
