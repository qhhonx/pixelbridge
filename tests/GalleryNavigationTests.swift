import AppKit
import SwiftUI

@main struct GalleryNavigationTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let memory = GalleryPosition()
        let items = (0..<5000).map { LibraryItem(id: "photo-\($0)", name: "sample", date: .distantPast, kind: "photo") }
        func content(_ filter: String = "all", _ photos: [LibraryItem]? = nil, revision: Int = 1) -> AnyView {
            AnyView(PhotoGrid(items: photos ?? items, revision: revision, filter: filter, tileSize: 180, language: "en", phases: [:], retryIDs: [], activeID: nil, position: memory, onLoaded: { _ in }).frame(width: 1000, height: 700))
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
        func find(_ view: NSView) -> NSCollectionView? {
            (view as? NSCollectionView) ?? view.subviews.compactMap { find($0) }.first
        }
        await settle()
        var grid = find(host)!
        for _ in 0..<6 {
            let scroll = grid.enclosingScrollView!
            let bottom = grid.collectionViewLayout!.collectionViewContentSize.height - scroll.contentSize.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
            await settle()
        }
        let scroll = grid.enclosingScrollView!
        let frame = grid.collectionViewLayout!.layoutAttributesForItem(at: IndexPath(item: 800, section: 0))!.frame
        scroll.contentView.scroll(to: NSPoint(x: 0, y: frame.minY + 35)); scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        let before = memory.bookmarks["all"]!
        let origin = scroll.contentView.bounds.minY
        precondition(before.index >= 790 && before.loaded >= 1000)
        host.rootView = AnyView(Text("Overview").frame(width: 1000, height: 700)); await settle()
        host.rootView = content(); await settle(); await settle()
        let recreated = find(host)!
        precondition(recreated !== grid)
        grid = recreated
        precondition(abs(grid.enclosingScrollView!.contentView.bounds.minY - origin) < 2)
        precondition(grid.numberOfItems(inSection: 0) >= before.loaded)
        precondition(memory.bookmarks["all"]?.assetID == before.assetID)
        print("PASS: leaving and recreating a deeply paginated gallery restores the photo, row offset and loaded pages")

        host.rootView = content("motion", Array(items.prefix(100)))
        await settle(); await settle()
        grid = find(host)!
        precondition(grid.enclosingScrollView!.contentView.bounds.minY < 1)
        grid.enclosingScrollView!.contentView.scroll(to: NSPoint(x: 0, y: 250))
        grid.enclosingScrollView!.reflectScrolledClipView(grid.enclosingScrollView!.contentView)
        await settle()
        let motionOrigin = grid.enclosingScrollView!.contentView.bounds.minY
        host.rootView = content(); await settle(); await settle()
        precondition(abs(find(host)!.enclosingScrollView!.contentView.bounds.minY - origin) < 2)
        host.rootView = content("motion", Array(items.prefix(100))); await settle(); await settle()
        precondition(abs(find(host)!.enclosingScrollView!.contentView.bounds.minY - motionOrigin) < 2)
        print("PASS: media filters retain independent scroll positions")

        host.rootView = AnyView(Text("Tasks").frame(width: 1000, height: 700)); await settle()
        let inserted = (0..<35).map { LibraryItem(id: "new-\($0)", name: "new", date: Date(), kind: "photo") }
        host.rootView = content("all", inserted + items, revision: 2)
        await settle(); await settle()
        precondition(memory.bookmarks["all"]?.assetID == before.assetID)
        precondition(abs((memory.bookmarks["all"]?.offset ?? -100) - before.offset) < 2)
        precondition(find(host)!.visibleItems().count < 100)
        print("PASS: newly inserted photos preserve the visible photo anchor without expanding the live cell count")
    }
}
