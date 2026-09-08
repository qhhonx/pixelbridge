import AppKit
import SwiftUI

@main struct PhotoGridTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let items = (0..<55_000).map { LibraryItem(id: "test-\($0)", name: "photo", date: .distantPast, kind: "photo") }
        var reported = 0
        let root = PhotoGrid(items: items, revision: 1, filter: "all", tileSize: 180, language: "en", phases: [:], retryIDs: [], activeID: nil, onLoaded: { reported = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func wait() async { try? await Task.sleep(nanoseconds: 200_000_000) }
        func collection(in view: NSView) -> NSCollectionView? {
            if let found = view as? NSCollectionView { return found }
            return view.subviews.compactMap { collection(in: $0) }.first
        }
        await wait()
        let grid = collection(in: window.contentView!)!
        let scroll = grid.enclosingScrollView!
        precondition(grid.numberOfItems(inSection: 0) == 200 && reported == 200)
        for _ in 0..<5 {
            let end = max(0, grid.collectionViewLayout!.collectionViewContentSize.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: end)); scroll.reflectScrolledClipView(scroll.contentView)
            await wait()
        }
        for _ in 0..<20 { if reported == grid.numberOfItems(inSection: 0) { break }; await wait() }
        precondition(reported >= 1200 && reported < items.count)
        precondition(grid.numberOfItems(inSection: 0) == reported)
        precondition(grid.visibleItems().count < 100, "View count must stay bounded independently of library size")
        scroll.contentView.scroll(to: .zero); await wait()
        precondition(grid.indexPathsForVisibleItems().contains(IndexPath(item: 0, section: 0)))
        let host = window.contentView as! NSHostingView<PhotoGrid>
        host.rootView = PhotoGrid(items: items, revision: 1, filter: "all", tileSize: 180, language: "zh-Hans", phases: ["test-0": "transferred"], retryIDs: [], activeID: nil, onLoaded: { reported = $0 })
        await wait()
        let first = grid.item(at: IndexPath(item: 0, section: 0))!
        precondition(first.view.toolTip?.contains(tr(.metric_delivered)) == true)
        let oldCount = grid.numberOfItems(inSection: 0)
        host.rootView = PhotoGrid(items: Array(items.prefix(100)), revision: 1, filter: "motion", tileSize: 280, language: "zh-Hans", phases: [:], retryIDs: [], activeID: nil, onLoaded: { reported = $0 })
        await wait()
        precondition(grid.numberOfItems(inSection: 0) == 100 && reported == 100)
        print("PASS: 55,000 metadata items, paginated 200 → \(oldCount), fewer than 100 visible cells, back-scroll, live status/language update and filter reset")
    }
}
