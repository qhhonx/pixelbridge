import AppKit
import Photos
import SwiftUI

@MainActor
final class ThumbnailTicket {
    var task: Task<Void, Never>?
    var request: PHImageRequestID?
    var cancelled = false
    func cancel() {
        cancelled = true; task?.cancel()
        if let request { ThumbnailStore.manager.cancelImageRequest(request) }
    }
}

@MainActor
enum ThumbnailStore {
    static let manager: PHCachingImageManager = {
        let manager = PHCachingImageManager(); manager.allowsCachingHighQualityImages = false; return manager
    }()
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.totalCostLimit = 128 * 1024 * 1024; cache.countLimit = 500; return cache
    }()
    static let assets: NSCache<NSString, PHAsset> = {
        let cache = NSCache<NSString, PHAsset>(); cache.countLimit = 1200; return cache
    }()
    static func invalidate() { images.removeAllObjects(); assets.removeAllObjects(); manager.stopCachingImagesForAllAssets() }
    static func load(_ id: String, pixels: CGFloat, completion: @escaping (NSImage?) -> Void) -> ThumbnailTicket {
        let ticket = ThumbnailTicket()
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { return ticket }
        let size: CGFloat = pixels <= 320 ? 320 : 640
        let key = "\(id)-\(Int(size))" as NSString
        if let image = images.object(forKey: key) { completion(image); return ticket }
        ticket.task = Task { @MainActor in
            let cached = assets.object(forKey: id as NSString)
            let asset: PHAsset?
            if let cached { asset = cached }
            else {
                asset = await Task.detached(priority: .userInitiated) {
                    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: libraryFetchOptions()).firstObject
                }.value
            }
            guard !Task.isCancelled, !ticket.cancelled, let asset else { return }
            assets.setObject(asset, forKey: id as NSString)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .opportunistic; options.resizeMode = .fast
            ticket.request = manager.requestImage(for: asset, targetSize: CGSize(width: size, height: size / 1.37), contentMode: .aspectFill, options: options) { image, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                Task { @MainActor in
                    guard !ticket.cancelled, !cancelled else { return }
                    if let image, !degraded { images.setObject(image, forKey: key, cost: Int(size * size / 1.37 * 4)) }
                    if let image { completion(image) }
                }
            }
        }
        return ticket
    }
}

// Owned by the window, not the representable, so navigation can recreate the grid.
struct GalleryBookmark {
    let assetID: String
    let index: Int
    let offset: CGFloat
    let loaded: Int
}
@MainActor final class GalleryPosition: ObservableObject {
    var bookmarks: [String: GalleryBookmark] = [:]
}

// NSCollectionView reuses visible cells; the full Photos metadata index never
// becomes tens of thousands of SwiftUI views or retained decoded images.
struct PhotoGrid: NSViewRepresentable {
    let items: [LibraryItem]
    let revision: Int
    let filter: String
    let tileSize: CGFloat
    let language: String
    let phases: [String: String]
    let retryIDs: Set<String>
    let activeID: String?
    var position: GalleryPosition? = nil
    var activeIDs: Set<String> = []
    var showLabels: Bool = false
    let onLoaded: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        collection.autoresizingMask = [.width]
        let layout = PhotoFlowLayout(); collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]; collection.isSelectable = false
        collection.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        scroll.documentView = collection
        context.coordinator.collection = collection; context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            Task { @MainActor in
                coordinator?.savePosition()
                coordinator?.loadNearEnd()
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.savePosition()
        coordinator.dismantled = true
        coordinator.restoreTask?.cancel()
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        for case let cell as PhotoCell in coordinator.collection?.visibleItems() ?? [] { cell.cancel() }
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var collection: NSCollectionView?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var state: PhotoGrid?
        var loaded = 0
        var revision = -1
        var filter = ""
        var reporting = false
        var dismantled = false
        var restoring = false
        var restoreTask: Task<Void, Never>?
        let pageSize = 200
        func update(_ value: PhotoGrid) {
            guard let collection else { return }
            let layoutChanged = (collection.collectionViewLayout as? PhotoFlowLayout)?.minimumTile != value.tileSize
            let changed = revision != value.revision || filter != value.filter || layoutChanged
            let appearanceChanged = state?.language != value.language || state?.showLabels != value.showLabels
            if changed { savePosition() }
            let localBookmark = changed && filter == value.filter ? bookmark() : nil
            let saved = value.position?.bookmarks[value.filter] ?? localBookmark
            state = value
            if let layout = collection.collectionViewLayout as? PhotoFlowLayout, layoutChanged {
                layout.minimumTile = value.tileSize; layout.invalidateLayout()
            }
            if changed {
                if revision != value.revision { ThumbnailStore.invalidate() }
                revision = value.revision; filter = value.filter
                let anchorIndex = saved.flatMap { saved in
                    value.items.firstIndex(where: { $0.id == saved.assetID })
                        ?? (value.items.isEmpty ? nil : min(saved.index, value.items.count - 1))
                }
                loaded = min(value.items.count, max(pageSize, saved?.loaded ?? pageSize, (anchorIndex ?? 0) + pageSize))
                restoring = true
                restoreTask?.cancel()
                collection.reloadData()
                guard saved != nil else {
                    scroll?.contentView.scroll(to: .zero)
                    restoring = false
                    reportLoaded()
                    return
                }
                restoreTask = Task { @MainActor [weak self] in
                    // SwiftUI must first assign the recreated scroll view its window size.
                    await Task.yield()
                    guard !Task.isCancelled, let self, !self.dismantled,
                          let collection = self.collection, let scroll = self.scroll else { return }
                    scroll.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded()
                    var targetY: CGFloat = 0
                    if let anchorIndex,
                       let attributes = collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: anchorIndex, section: 0)) {
                        targetY = attributes.frame.minY + min(max(0, saved?.offset ?? 0), max(0, attributes.frame.height - 1))
                    }
                    let height = collection.collectionViewLayout?.collectionViewContentSize.height ?? 0
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, targetY), max(0, height - scroll.contentSize.height))))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    self.restoring = false
                    self.savePosition()
                    self.reportLoaded()
                }
                reportLoaded()
            } else {
                // Backup progress only updates visible badges. No grid reload,
                // layout pass, or thumbnail request for each queue transition.
                for case let cell as PhotoCell in collection.visibleItems() {
                    cell.updateStatus(phase: value.phases[cell.assetID], retry: value.retryIDs.contains(cell.assetID), active: value.activeID == cell.assetID || value.activeIDs.contains(cell.assetID), showLabels: value.showLabels, appearanceChanged: appearanceChanged)
                }
            }
        }
        func bookmark() -> GalleryBookmark? {
            guard !restoring, !dismantled, let state, let collection, let scroll else { return nil }
            let bounds = scroll.contentView.bounds
            // Visible-item callbacks can lag a programmatic scroll by one frame.
            // Query the layout geometry to avoid bookmarking a recycled/offscreen cell.
            let visible = (collection.collectionViewLayout?.layoutAttributesForElements(in: bounds) ?? [])
                .compactMap { attributes -> (IndexPath, NSRect)? in
                    guard attributes.representedElementCategory == .item,
                          let path = attributes.indexPath, attributes.frame.intersects(bounds) else { return nil }
                    return (path, attributes.frame)
                }.sorted { $0.0 < $1.0 }.first
            guard let (path, frame) = visible, path.item < state.items.count else { return nil }
            return GalleryBookmark(assetID: state.items[path.item].id, index: path.item,
                offset: bounds.minY - frame.minY, loaded: loaded)
        }
        func savePosition() {
            guard let saved = bookmark(), let state else { return }
            state.position?.bookmarks[state.filter] = saved
        }
        func reportLoaded() {
            guard !reporting else { return }; reporting = true
            Task { @MainActor [weak self] in
                guard let self else { return }; self.reporting = false
                self.state?.onLoaded(self.loaded)
            }
        }
        func loadNearEnd() {
            guard !restoring, !dismantled, let collection, let scroll, let state, loaded < state.items.count,
                  scroll.contentView.bounds.height > 0,
                  scroll.contentView.bounds.maxY + 800 >= (collection.collectionViewLayout?.collectionViewContentSize.height ?? .infinity) else { return }
            let previous = loaded; loaded = min(state.items.count, loaded + pageSize)
            NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0
            collection.insertItems(at: Set((previous..<loaded).map { IndexPath(item: $0, section: 0) }))
            NSAnimationContext.endGrouping()
            reportLoaded()
        }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { loaded }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath) as! PhotoCell
            if let state, indexPath.item < state.items.count {
                let item = state.items[indexPath.item]
                cell.configure(item, pixels: state.tileSize * (collectionView.window?.backingScaleFactor ?? 2), phase: state.phases[item.id], retry: state.retryIDs.contains(item.id), active: state.activeID == item.id || state.activeIDs.contains(item.id), showLabels: state.showLabels)
            }
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) { (item as? PhotoCell)?.cancel() }
    }
}

private final class PhotoFlowLayout: NSCollectionViewFlowLayout {
    var minimumTile: CGFloat = 280
    private var width: CGFloat = 0
    override func prepare() {
        let available = collectionView?.enclosingScrollView?.contentSize.width ?? 1000
        let gap: CGFloat = 28 / 3
        let columns = max(1, floor((available + gap) / (minimumTile + gap)))
        let side = floor((available - (columns - 1) * gap) / columns)
        width = available
        itemSize = NSSize(width: max(1, side), height: max(1, side / 1.37))
        minimumInteritemSpacing = gap; minimumLineSpacing = gap
        super.prepare()
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { abs(newBounds.width - width) > 1 }
}

// A stable SF Symbol per meaning; never use the cloud mark for device delivery.
func photoStatusSymbol(_ state: TextKey) -> String {
    switch state {
    case .metric_delivered: return "checkmark.circle.fill"
    case .queue_backed_up: return "checkmark.icloud.fill"
    case .gallery_processing: return "arrow.triangle.2.circlepath"
    case .queue_retry_queued: return "arrow.clockwise"
    case .queue_failed: return "exclamationmark.circle.fill"
    case .queue_skipped: return "minus.circle"
    default: return "clock"
    }
}

private final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("photo")
    private(set) var assetID = ""
    private var item: LibraryItem?
    private var ticket: ThumbnailTicket?
    private let imageLayer = CALayer()
    private let mediaIcon = NSImageView()
    private let mediaLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let mediaPill = NSView()
    private let statusPill = NSView()
    private var statusIdentity = ""
    override func loadView() {
        view = NSView(); view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        view.layer?.cornerRadius = 7; view.layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill; imageLayer.masksToBounds = true
        view.layer?.addSublayer(imageLayer)
        mediaLabel.font = .systemFont(ofSize: 11, weight: .medium); mediaLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        configurePill(mediaPill, icon: mediaIcon, label: mediaLabel, background: NSColor.black.withAlphaComponent(0.48))
        configurePill(statusPill, icon: statusIcon, label: statusLabel, background: NSColor.white.withAlphaComponent(0.94))
        mediaIcon.contentTintColor = .white
        NSLayoutConstraint.activate([
            mediaPill.topAnchor.constraint(equalTo: view.topAnchor, constant: 9), mediaPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            statusPill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9), statusPill.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9)
        ])
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
    }
    private func configurePill(_ pill: NSView, icon: NSImageView, label: NSTextField, background: NSColor) {
        pill.translatesAutoresizingMaskIntoConstraints = false; pill.wantsLayer = true
        pill.layer?.backgroundColor = background.cgColor; pill.layer?.cornerRadius = 7
        view.addSubview(pill)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown
        let stack = NSStackView(views: [icon, label]); stack.orientation = .horizontal
        stack.alignment = .centerY; stack.spacing = 5; stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false; pill.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6), stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5), stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5)
        ])
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin(); CATransaction.setDisableActions(true); imageLayer.frame = view.bounds; CATransaction.commit()
    }
    func configure(_ item: LibraryItem, pixels: CGFloat, phase: String?, retry: Bool, active: Bool, showLabels: Bool) {
        cancel(); self.item = item; assetID = item.id
        imageLayer.contents = nil; statusIdentity = ""
        updateStatus(phase: phase, retry: retry, active: active, showLabels: showLabels, appearanceChanged: true)
        let id = item.id
        ticket = ThumbnailStore.load(id, pixels: pixels) { [weak self] image in
            guard let self, self.assetID == id else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            CATransaction.commit()
        }
    }
    func updateStatus(phase: String?, retry: Bool, active: Bool, showLabels: Bool, appearanceChanged: Bool) {
        let state = photoDeliveryState(phase: phase, retry: retry, active: active)
        let identity = state.rawValue + L10n.language + String(showLabels)
        guard identity != statusIdentity || appearanceChanged, let item else { return }
        statusIdentity = identity
        let statusText = tr(state)
        statusIcon.image = NSImage(systemSymbolName: photoStatusSymbol(state), accessibilityDescription: statusText)
        let tint: NSColor
        switch state {
        case .metric_delivered, .queue_backed_up: tint = NSColor(srgbRed: 0.12, green: 0.43, blue: 0.26, alpha: 1)
        case .queue_failed: tint = NSColor(srgbRed: 0.65, green: 0.35, blue: 0.04, alpha: 1)
        case .gallery_processing, .queue_retry_queued: tint = NSColor(srgbRed: 0.16, green: 0.35, blue: 0.85, alpha: 1)
        default: tint = .secondaryLabelColor
        }
        statusIcon.contentTintColor = tint; statusLabel.textColor = tint
        statusLabel.stringValue = statusText; statusLabel.isHidden = !showLabels
        statusPill.toolTip = statusText
        let mediaText = mediaLabelText(item.kind)
        mediaPill.isHidden = item.kind == "photo"
        mediaIcon.image = NSImage(systemSymbolName: item.kind == "motion" ? "livephoto" : "play.fill", accessibilityDescription: mediaText)
        mediaLabel.stringValue = mediaText; mediaLabel.isHidden = !showLabels
        mediaPill.toolTip = mediaText
        view.toolTip = item.date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: L10n.language))) + " · " + mediaText + " · " + statusText
        view.setAccessibilityLabel(view.toolTip)
    }
    private func mediaLabelText(_ kind: String) -> String { tr(TextKey(rawValue: "media_" + kind) ?? .media_photo) }
    func cancel() { ticket?.cancel(); ticket = nil }
    override func prepareForReuse() { cancel(); imageLayer.contents = nil; assetID = ""; item = nil; super.prepareForReuse() }
}
