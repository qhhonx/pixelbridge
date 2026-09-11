import AppKit
import Photos
import SwiftUI

private enum Page: String, CaseIterable, Identifiable {
    case library, overview, tasks, device, settings, experiments
    var title: String { tr(TextKey(rawValue: "nav_" + rawValue)!) }
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .overview: return "square.3.layers.3d"
        case .tasks: return "arrow.triangle.2.circlepath"
        case .device: return "iphone"
        case .settings: return "slider.horizontal.3"
        case .experiments: return "flask"
        }
    }
}
// Matched to site/app/globals.css, .app-window and its children.
// The website's 934 px illustration maps to a ~1245 pt desktop window (4/3).
private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}
private enum Palette {
    static let ink = Color(rgb: 0x303746)
    static let muted = Color(rgb: 0x687184)
    static let sidebar = Color(rgb: 0xf4f5f8)
    static let sidebarText = Color(rgb: 0x5d6575)
    static let caption = Color(rgb: 0x8992a2)
    static let galleryCaption = Color(rgb: 0x838c9e)
    static let line = Color(rgb: 0xe4e8f0)
    static let sidebarLine = Color(rgb: 0xe5e8f0)
    static let toolbarLine = Color(rgb: 0xeff1f5)
    static let selected = Color(rgb: 0xe0e9ff)
    static let selectedInk = Color(rgb: 0x2b57d4)
    static let filter = Color(rgb: 0xf1f3f7)
    static let subtle = Color(rgb: 0xf8faff)
    static let transferLine = Color(rgb: 0xe9eef9)
    static let transferCaption = Color(rgb: 0x8992a0)
    static let transferAccent = Color(rgb: 0x3067c3)
}
private enum Layout {
    static let scale: CGFloat = 4 / 3
    static let sidebarWidth = 180 * scale
    static let contentInset = 22 * scale
    static let toolbarHeight = 45 * scale
    static let gridGap = 7 * scale
    static let photoRadius = 5 * scale
    static let photoAspect: CGFloat = 1.37
    static let headingFont = 18 * scale
    static let captionFont = 12 * scale
    static let navigationFont = 13 * scale
}
private let accent = Color(rgb: 0x2859ed)

private struct ActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 15).frame(height: 36)
            .foregroundStyle(primary ? Color.white : Palette.ink)
            .background(primary ? accent : Palette.sidebar, in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.42)
    }
}
private struct SectionHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: Layout.headingFont, weight: .medium))
            Text(detail).font(.system(size: Layout.captionFont)).foregroundStyle(Palette.galleryCaption).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct Surface<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
    }
}
private struct PreferenceRow<Control: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder let control: Control
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control
        }.padding(.vertical, 3)
    }
}
private struct NumberControl: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    var body: some View {
        Stepper(value: $value, in: range) {
            Text(tr(.preference_value, String(value), unit)).font(.system(size: 14, weight: .medium)).monospacedDigit().frame(width: 72, alignment: .trailing)
        }.fixedSize().accessibilityLabel(title).accessibilityValue(tr(.preference_value, String(value), unit))
    }
}

struct ContentView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var updater: AppUpdater
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var page: Page = .library
    @AppStorage("galleryTileSize") private var tileSize = 280.0
    @AppStorage("galleryShowLabels") private var galleryShowLabels = false
    @State private var kindFilter = "all"
    @State private var loadedPhotos = 0
    @StateObject private var galleryPosition = GalleryPosition()
    @State private var showInstall = false
    @State private var selectedTask: String?
    @State private var taskStatusFilter: TaskStatusFilter = .all
    @State private var taskKindFilter = "all"
    @State private var showLogs = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: Layout.sidebarWidth)
            Rectangle().fill(Palette.sidebarLine).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Palette.toolbarLine).frame(height: 1)
                Group {
                    switch page {
                    case .library: library
                    case .overview: overview
                    case .tasks: tasks
                    case .device: device
                    case .settings: settings
                    case .experiments: experiments
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                transferBar
            }.background(.white)
        }
        .foregroundStyle(Palette.ink).tint(accent).preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: L10n.resolve(preference: appLanguage, preferredLanguages: Locale.preferredLanguages)))
        .frame(minWidth: 1000, minHeight: 680)
        .task { await model.launch() }
        .sheet(isPresented: $showInstall) { installSheet }
    }
    private var displayDevice: String {
        if let device = model.devices.first(where: { $0.id == model.selectedDevice }) { return device.label }
        return model.selectedDevice.isEmpty ? tr(.device_unselected) : tr(.device_disconnected)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: "PixelBridge") ?? NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 35, height: 35)
                Text("PixelBridge").font(.system(size: 14 * Layout.scale, weight: .medium))
            }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 40)
            navigationGroup(tr(.sidebar_photos), items: [.library, .overview, .tasks])
            navigationGroup(tr(.sidebar_management), items: [.device, .settings, .experiments]).padding(.top, 30)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Circle().fill(model.autoRunning ? Color.green : Palette.muted).frame(width: 7, height: 7)
                    Text(model.autoRunning ? tr(.status_automatic) : tr(.automatic_paused)).font(.system(size: 13))
                }
                Text(displayDevice).font(.system(size: 11)).lineLimit(1).padding(.leading, 16)
            }.foregroundStyle(Palette.muted).padding(24)
        }.frame(maxHeight: .infinity).background(Palette.sidebar)
    }
    private func navigationGroup(_ title: String, items: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: Layout.captionFont)).foregroundStyle(Palette.caption)
                .padding(.leading, 15).padding(.bottom, 7)
            ForEach(items) { item in
                Button { page = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).font(.system(size: 16 * Layout.scale, weight: .regular)).frame(width: 23)
                        Text(item.title).font(.system(size: Layout.navigationFont, weight: page == item ? .medium : .regular))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).frame(height: 47)
                        .foregroundStyle(page == item ? Palette.selectedInk : Palette.sidebarText)
                        .background(page == item ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
            }
        }.padding(.horizontal, 16)
    }
    private var topBar: some View {
        HStack(spacing: 16) {
            Text(page.title).font(.system(size: Layout.navigationFont, weight: .medium))
            Spacer()
            if page == .library {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3").foregroundStyle(Palette.muted)
                    Slider(value: $tileSize, in: 180...340).frame(width: 80).accessibilityLabel(tr(.gallery_size))
                }
                Button { Task { await model.scan(force: true) } } label: {
                    Label(model.scanning ? tr(.gallery_refreshing) : tr(.gallery_refresh), systemImage: "arrow.clockwise")
                }.buttonStyle(ActionStyle()).help(tr(.gallery_refresh_help)).disabled(model.scanning)
            }
            Button { model.autoRunning || model.busy ? model.pause() : model.startAutomatic() } label: {
                Label(model.pausing ? tr(.status_pausing) : (model.autoRunning || model.busy ? tr(.backup_pause) : tr(.backup_automatic)), systemImage: model.autoRunning || model.busy ? "pause" : "play.fill")
            }.buttonStyle(ActionStyle(primary: true))
                .disabled((!model.ready && !model.autoRunning && !model.busy) || model.installing || model.pausing || (model.scanning && !model.busy))
        }.padding(.horizontal, Layout.contentInset).frame(height: Layout.toolbarHeight)
    }
    private var transferBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.transferLine).frame(height: 1)
            HStack(spacing: 14) {
                if model.busy, model.cleanupProgress == nil, let item = model.currentItem {
                    Group {
                        Thumbnail(assetID: item.id).frame(width: 40 * Layout.scale, height: 36 * Layout.scale).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Image(systemName: model.scanning ? "photo.on.rectangle" : (model.autoRunning ? "checkmark.shield" : "pause.circle"))
                        .font(.system(size: 23, weight: .light)).foregroundStyle(accent)
                        .frame(width: 52, height: 52).background(Palette.selected.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.busy || model.scanning || model.needsAttention ? model.status.text : (model.autoRunning ? tr(.status_automatic) : tr(.backup_paused)))
                        .font(.system(size: 14, weight: .medium))
                    Text(statusLine).font(.system(size: 14)).foregroundStyle(Palette.transferCaption).lineLimit(1).help(model.detail.text)
                }
                Spacer(minLength: 12)
                if model.busy || model.scanning { ProgressView().controlSize(.small) }
                Button { page = .overview } label: {
                    Label(model.busy ? tr(.backup_progress) : tr(.backup_details), systemImage: "checkmark.shield")
                }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Palette.transferAccent)
            }.padding(.horizontal, Layout.contentInset).frame(height: 80)
        }.background(Palette.subtle)
    }
    private var statusLine: String {
        if model.busy { return model.activityDescription }
        if model.scanning || model.needsAttention { return model.detail.text }
        return tr(.backup_footer_summary, String(describing: model.delivered.formatted()))
    }
    private var visiblePhotos: [LibraryItem] { model.gallery[kindFilter] ?? [] }
    private var library: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                SectionHeading(title: tr(.gallery_heading), detail: model.libraryCounts.text.isEmpty ? tr(.gallery_intro) : model.libraryCounts.text)
                Menu {
                    Picker(tr(.gallery_media_type), selection: $kindFilter) {
                        ForEach(["all", "photo", "motion", "video"], id: \.self) { Text(mediaLabel($0)).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Text(mediaLabel(kindFilter))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Palette.ink)
                    .font(.system(size: Layout.captionFont)).foregroundStyle(Palette.ink).fixedSize()
                    .padding(.horizontal, 15).frame(height: 37)
                    .background(Palette.filter, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(tr(.gallery_filter))
            }.padding(.horizontal, Layout.contentInset).padding(.top, 19 * Layout.scale).padding(.bottom, 15 * Layout.scale)
            if !model.authorized {
                ContentUnavailableView {
                    Label(tr(.photos_connect_title), systemImage: "photo.on.rectangle.angled")
                } description: { Text(tr(.photos_connect_description)) } actions: {
                    Button(tr(.photos_connect_action)) { Task { await model.requestPhotos() } }.buttonStyle(ActionStyle(primary: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 48)
            } else if visiblePhotos.isEmpty {
                ContentUnavailableView(model.scanning ? tr(.gallery_loading) : tr(.gallery_empty), systemImage: model.scanning ? "photo.stack" : "photo", description: Text(model.scanning ? tr(.gallery_loading_description) : tr(.gallery_empty_description)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 48)
            } else {
                PhotoGrid(items: visiblePhotos, revision: model.galleryRevision, filter: kindFilter,
                    tileSize: tileSize, language: L10n.language, phases: model.phases,
                    retryIDs: model.pendingRetryIDs, activeID: model.busy && !model.pausing ? model.currentItem?.id : nil,
                    position: galleryPosition, activeIDs: model.activeIDs, showLabels: galleryShowLabels, onLoaded: { loadedPhotos = $0 })
                    .padding(.horizontal, Layout.contentInset)
                HStack {
                    Text(loadedPhotos >= visiblePhotos.count ? tr(.gallery_loaded_all, String(visiblePhotos.count.formatted())) : tr(.gallery_loaded, String(loadedPhotos.formatted()), String(visiblePhotos.count.formatted())))
                    Spacer()
                    if let date = model.lastLibraryRefresh {
                        Text(tr(.gallery_refreshed, date.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: L10n.language)))))
                    }
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, Layout.contentInset).padding(.vertical, 10)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SectionHeading(title: tr(.overview_heading), detail: tr(.overview_description))
                if !model.authorized || model.adbPath.isEmpty || !model.devices.contains(where: { $0.id == model.selectedDevice && $0.state == "device" }) {
                    connectionNotice
                }
                HStack(spacing: 16) {
                    metric(tr(.nav_library), value: model.authorized ? model.totalAssets.formatted() : "—", unit: tr(.unit_items), icon: "photo.on.rectangle")
                    metric(tr(.metric_delivered), value: model.delivered.formatted(), unit: tr(.unit_items), icon: "checkmark.shield")
                    metric(tr(.metric_cache), value: ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .file), unit: "", icon: "internaldrive")
                }
                currentTransfer
                HStack(alignment: .top, spacing: 20) {
                    Surface {
                        HStack {
                            Text(tr(.recent_title)).font(.system(size: 16, weight: .medium))
                            Spacer()
                            Button(tr(.recent_all)) { page = .tasks }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 12))
                        }
                        if model.rows.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(tr(.recent_empty_title)).font(.system(size: 14, weight: .medium))
                                Text(tr(.recent_empty_description)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }.padding(.vertical, 28)
                        }
                        ForEach(Array(model.rows.prefix(4))) { row in
                            HStack(spacing: 12) {
                                Thumbnail(assetID: row.id).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.filename).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(Date(timeIntervalSince1970: row.timestamp_ms / 1000), format: .dateTime.month().day().hour().minute())
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: row.delivered ? "checkmark.circle.fill" : "clock").foregroundStyle(row.delivered ? Color.green : Color.orange)
                            }
                        }
                    }
                    Surface {
                        HStack {
                            Text(tr(.storage_title)).font(.system(size: 16, weight: .medium))
                            Spacer()
                            Button { page = .device } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel(tr(.device_view))
                        }
                        Label(displayDevice, systemImage: "iphone").font(.system(size: 14, weight: .medium))
                        Text(model.deviceMetrics.text.isEmpty ? model.deviceMessage.text : model.deviceMetrics.text)
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        Divider().overlay(Palette.line)
                        HStack {
                            Text(tr(.cache_budget))
                            Spacer()
                            Text(tr(.cache_budget_value, String(model.cacheGB))).monospacedDigit()
                        }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                        ProgressView(value: min(1, Double(model.cacheBytes) / Double(max(1, model.cacheGB) * 1_000_000_000)))
                        Text(model.autoReclaimCache ? tr(.cache_cleanup_enabled) : tr(.cache_cleanup_disabled))
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }.frame(width: 285)
                }
                Label(tr(.backup_cloud_notice), systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.padding(30)
        }
    }
    private func metric(_ title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 28, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
    private var connectionNotice: some View {
        HStack(spacing: 16) {
            Image(systemName: !model.authorized ? "photo.badge.plus" : "cable.connector").font(.system(size: 26)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(!model.authorized ? tr(.setup_photos_title) : tr(.setup_pixel_title)).font(.system(size: 15, weight: .medium))
                Text(!model.authorized ? tr(.setup_photos_description) : tr(.setup_pixel_description))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button(!model.authorized ? tr(.photos_connect_action) : (model.adbPath.isEmpty ? tr(.adb_install_action) : tr(.device_setup_action))) {
                if !model.authorized { Task { await model.requestPhotos() } }
                else if model.adbPath.isEmpty { showInstall = true }
                else { page = .device }
            }.buttonStyle(ActionStyle(primary: true)).disabled(model.installing)
        }.padding(22).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
    private var currentTransfer: some View {
        Surface {
            HStack(alignment: .center, spacing: 24) {
                if model.busy, model.cleanupProgress == nil, let item = model.currentItem {
                    Group {
                        Thumbnail(assetID: item.id).frame(width: 150, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                } else {
                    Image(systemName: model.autoRunning ? "checkmark.shield" : "photo.stack")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(accent)
                        .frame(width: 92, height: 92).background(Palette.selected.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.busy || model.needsAttention ? model.status.text : (model.autoRunning ? tr(.status_automatic) : tr(.backup_ready)))
                        .font(.system(size: 21, weight: .medium))
                    Text(model.busy ? model.activityDescription : model.detail.text).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
                    if let cleanup = model.cleanupProgress {
                        if let fraction = cleanup.fraction {
                            ProgressView(value: fraction).padding(.top, 5)
                        } else {
                            ProgressView().controlSize(.small).padding(.top, 5)
                        }
                    } else if model.busy {
                        ProgressView(value: Double(model.completed), total: Double(max(1, model.batchTotal))).padding(.top, 5)
                        Text(tr(.backup_batch_progress, String(describing: model.completed), String(describing: model.batchTotal))).font(.system(size: 12)).foregroundStyle(Palette.muted).monospacedDigit()
                    } else if let date = model.nextRun, model.autoRunning {
                        Text(tr(.backup_next_check, String(describing: date.formatted(date: .omitted, time: .shortened)))).font(.system(size: 12)).foregroundStyle(accent)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !model.busy {
                    Button(tr(.backup_once)) { Task { await model.batch() } }.buttonStyle(ActionStyle()).disabled(!model.ready || model.scanning)
                }
            }
        }
    }
    private var tasks: some View {
        let visibleRows = filteredTasks(model.rows, status: taskStatusFilter, kind: taskKindFilter,
            kinds: model.libraryKinds, requested: model.pendingRetryIDs, activeID: model.busy ? model.currentItem?.id : nil, activeIDs: model.activeIDs)
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                SectionHeading(title: tr(.tasks_heading), detail: tr(.tasks_summary, String(describing: model.rows.count.formatted()), String(describing: model.failed)))
                Button(tr(.tasks_retry)) { model.retryNow() }.buttonStyle(ActionStyle()).disabled(model.pausing || model.failed == 0)
            }
            HStack {
                if let selected = visibleRows.first(where: { $0.id == selectedTask }) {
                    if selected.phase == "skipped" {
                        Button(tr(.tasks_restore), systemImage: "arrow.uturn.backward") { Task { await model.restoreTask(selected) } }
                            .disabled(model.taskMutationIDs.contains(selected.id))
                    } else {
                        Button(tr(.tasks_skip), systemImage: "minus.circle") { Task { await model.skipTasks([selected]) } }
                            .disabled(!model.canSkipTask(selected))
                    }
                }
                Spacer()
                Button(tr(.tasks_skip_filtered_failed)) {
                    Task { await model.skipTasks(visibleRows.filter { $0.phase == "failed" }) }
                }.disabled(!visibleRows.contains { $0.phase == "failed" && model.canSkipTask($0) })
            }.buttonStyle(ActionStyle())
            Text(tr(.tasks_skip_notice)).font(.system(size: 12)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Picker(tr(.tasks_column_status), selection: $taskStatusFilter) {
                        ForEach(TaskStatusFilter.allCases, id: \.self) { filter in
                            Text(tr(filter.title)).tag(filter)
                        }
                    }.frame(width: 230)
                    Picker(tr(.gallery_media_type), selection: $taskKindFilter) {
                        ForEach(["all", "photo", "motion", "video", "unknown"], id: \.self) { kind in
                            Text(kind == "unknown" ? tr(.tasks_type_unknown) : mediaLabel(kind)).tag(kind)
                        }
                    }.frame(width: 230)
                    Spacer(minLength: 0)
                }.pickerStyle(.menu)
                HStack {
                    Text(tr(.tasks_filtered_count, visibleRows.count.formatted(), model.rows.count.formatted()))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    if taskStatusFilter != .all || taskKindFilter != "all" {
                        Button(tr(.tasks_clear_filters)) { taskStatusFilter = .all; taskKindFilter = "all" }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if model.rows.isEmpty {
                ContentUnavailableView(tr(.tasks_empty), systemImage: "arrow.triangle.2.circlepath", description: Text(tr(.tasks_empty_description)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 48)
            } else if visibleRows.isEmpty {
                ContentUnavailableView(tr(.tasks_no_matches), systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(tr(.tasks_no_matches_description)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 48)
            } else {
                Table(visibleRows, selection: $selectedTask) {
                    TableColumn(tr(.tasks_column_file)) { row in
                        HStack(spacing: 10) {
                            Thumbnail(assetID: row.id).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(Date(timeIntervalSince1970: row.timestamp_ms / 1000), format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    .help(tr(.tasks_column_updated))
                            }
                        }.padding(.vertical, 5)
                    }.width(min: 150, ideal: 210)
                    TableColumn(tr(.tasks_column_status)) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(model.taskLabel(row), systemImage: model.taskStatus(row).symbol)
                                .font(.system(size: 11)).foregroundStyle(row.delivered ? Color.green : (model.taskStatus(row) == .failed ? Color.orange : Palette.muted))
                            if let progress = model.activeTransfers[row.id], !row.delivered {
                                HStack(spacing: 3) {
                                    ForEach(1...4, id: \.self) { step in
                                        Capsule().fill(step <= progress.stage.step ? accent.opacity(0.7) : Palette.line)
                                            .frame(height: 3)
                                    }
                                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 10)
                                }.frame(maxWidth: 130).help(tr(.tasks_stage_progress_help))
                                    .accessibilityLabel(tr(.tasks_stage_progress_help))
                                    .accessibilityValue(tr(progress.stage.title))
                            }
                        }
                    }.width(160)
                    TableColumn(tr(.tasks_column_size)) { row in
                        Text(row.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? tr(.tasks_size_unknown))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .help(tr(.tasks_size_help))
                    }.width(85)
                    TableColumn(tr(.tasks_column_details)) { row in
                        Text(model.activeTransfers[row.id] != nil && !row.delivered ? tr(.tasks_active_description) : (row.message ?? (row.delivered ? tr(.queue_verified) : tr(.queue_automatic_pending)))).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).help(row.message ?? row.remote ?? "")
                    }
                }.tableStyle(.inset(alternatesRowBackgrounds: false))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
                if let row = visibleRows.first(where: { $0.id == selectedTask }) {
                    Surface {
                        HStack(spacing: 16) {
                            Thumbnail(assetID: row.id).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(row.filename).font(.system(size: 14, weight: .medium))
                                Text(row.message ?? row.label).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            }
                        }
                        DisclosureGroup(tr(.tasks_file_details)) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let remote = row.remote { Text(remote).textSelection(.enabled) }
                                if let hash = row.sha256 { Text("SHA-256  " + hash).textSelection(.enabled) }
                            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 8)
                        }.font(.system(size: 12))
                    }
                }
            }
            Label(tr(.tasks_cloud_notice), systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
            .onChange(of: taskStatusFilter) { _, _ in selectedTask = nil }
            .onChange(of: taskKindFilter) { _, _ in selectedTask = nil }
    }
    private var device: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: tr(.device_heading), detail: tr(.device_description))
                Surface {
                    HStack(spacing: 24) {
                        Image(systemName: "iphone").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(accent)
                            .frame(width: 94, height: 108).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 10) {
                            Text(displayDevice).font(.system(size: 22, weight: .medium))
                            Text(model.deviceMessage.text).font(.system(size: 13)).foregroundStyle(Palette.muted)
                            if !model.deviceMetrics.text.isEmpty { Text(model.deviceMetrics.text).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                        }
                        Spacer()
                        Button(tr(.device_refresh)) { Task { await model.refreshDevice() } }.buttonStyle(ActionStyle()).disabled(model.busy)
                    }
                    Divider()
                    Picker(tr(.device_picker), selection: $model.selectedDevice) {
                        Text(tr(.device_select)).tag("")
                        if !model.selectedDevice.isEmpty && !model.devices.contains(where: { $0.id == model.selectedDevice }) {
                            Text(tr(.device_previous_offline)).tag(model.selectedDevice)
                        }
                        ForEach(model.devices) { device in Text("\(device.label) · \(device.id) · \(device.state)").tag(device.id) }
                    }.disabled(model.busy)
                }
                Surface {
                    Label(tr(.adb_title), systemImage: "shippingbox").font(.system(size: 16, weight: .medium))
                    Text(model.adbPath.isEmpty ? tr(.adb_description) : tr(.adb_ready))
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    HStack(spacing: 12) {
                        if model.adbPath.isEmpty {
                            Button(tr(.adb_download)) { showInstall = true }.buttonStyle(ActionStyle(primary: true)).disabled(model.installing)
                        }
                        Button(tr(.adb_choose)) { model.chooseADB() }.buttonStyle(ActionStyle()).disabled(model.busy || model.installing || model.scanning)
                        if model.installing { ProgressView().controlSize(.small); Text(tr(.adb_installing)).font(.system(size: 12)) }
                        Spacer()
                        Link(tr(.adb_official_download), destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!).font(.system(size: 12))
                    }
                    if !model.adbPath.isEmpty { Text(model.adbPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                }
                Surface {
                    Text(tr(.setup_steps_title)).font(.system(size: 16, weight: .medium))
                    setupStep("1", title: tr(.setup_cable_title), detail: tr(.setup_cable_description))
                    setupStep("2", title: tr(.setup_debug_title), detail: tr(.setup_debug_description))
                    setupStep("3", title: tr(.setup_authorize_title), detail: tr(.setup_authorize_description))
                    setupStep("4", title: tr(.setup_cloud_title), detail: tr(.setup_cloud_description))
                }
            }.padding(30)
        }
    }
    private func setupStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                .frame(width: 28, height: 28).background(Palette.selected.opacity(0.55), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
    }
    private var experiments: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: tr(.experiments_heading), detail: tr(.experiments_description))
                Surface {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 22)).foregroundStyle(accent)
                            .frame(width: 48, height: 48)
                            .background(Palette.selected, in: RoundedRectangle(cornerRadius: 12))
                        Text(tr(.cleanup_title)).font(.system(size: 17, weight: .medium))
                        Spacer()
                        Text(tr(model.pixelCleanupEnabled ? .experiment_enabled : .experiment_disabled))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.pixelCleanupEnabled ? Palette.selectedInk : Palette.muted)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Palette.filter, in: Capsule())
                    }
                    Text(tr(.cleanup_description, String(model.pixelReserveGB))).font(.system(size: 14))
                        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Label(model.cleanupMessage.text, systemImage: "info.circle")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tr(.cleanup_scope_notice)).font(.system(size: 12))
                        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(tr(model.pixelCleanupEnabled ? .cleanup_recheck : .cleanup_enable)) {
                            Task { await model.enablePixelCleanup() }
                        }.buttonStyle(ActionStyle(primary: !model.pixelCleanupEnabled))
                        if model.pixelCleanupEnabled {
                            Button(tr(.cleanup_disable)) { model.disablePixelCleanup() }.buttonStyle(ActionStyle())
                        }
                    }.disabled(model.busy || model.scanning || model.installing || model.pausing)
                    if model.busy {
                        Text(tr(.experiments_pause_notice)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
            }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: tr(.settings_heading), detail: tr(.settings_description))
                Surface {
                    PreferenceRow(title: tr(.language_title), detail: tr(.language_description)) {
                        Picker(tr(.language_title), selection: $appLanguage) {
                            Text(tr(.language_system)).tag("system")
                            Text(tr(.language_chinese)).tag("zh-Hans")
                            Text("English").tag("en")
                        }.labelsHidden().frame(width: 175)
                    }
                    Divider()
                    PreferenceRow(title: tr(.gallery_labels_title), detail: tr(.gallery_labels_description)) {
                        Toggle(tr(.gallery_labels_title), isOn: $galleryShowLabels).labelsHidden().toggleStyle(.switch)
                    }
                }
                Surface {
                    PreferenceRow(title: tr(.updates_title), detail: tr(.updates_description)) {
                        Button(tr(.updates_check)) { updater.check() }.buttonStyle(ActionStyle()).disabled(!updater.canCheck)
                    }
                    Divider()
                    PreferenceRow(title: tr(.updates_automatic), detail: tr(.updates_automatic_description)) {
                        Toggle(tr(.updates_automatic), isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) })).labelsHidden().toggleStyle(.switch)
                    }
                }
                if model.busy {
                    HStack(spacing: 12) {
                        Image(systemName: "lock").foregroundStyle(accent)
                        Text(tr(.settings_locked))
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button(tr(.backup_pause)) { model.pause() }.buttonStyle(ActionStyle())
                    }.padding(18).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 12))
                }
                Surface {
                    Label(tr(.settings_automatic_title), systemImage: "arrow.triangle.2.circlepath").font(.system(size: 16, weight: .medium))
                    PreferenceRow(title: tr(.settings_login), detail: tr(.settings_login_description)) {
                        Toggle(tr(.settings_login), isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_interval), detail: tr(.settings_interval_description)) {
                        NumberControl(title: tr(.settings_interval_control), value: $model.intervalMinutes, range: NumericPreference.intervalMinutes.range, unit: tr(.unit_minutes)).disabled(model.busy)
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_batch), detail: tr(.settings_batch_description)) {
                        NumberControl(title: tr(.settings_batch), value: $model.batchLimit, range: 1...100, unit: tr(.unit_items)).disabled(model.busy)
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_concurrency), detail: tr(.settings_concurrency_description)) {
                        NumberControl(title: tr(.settings_concurrency), value: $model.concurrentTasks, range: NumericPreference.concurrentTasks.range, unit: tr(.unit_items)).disabled(model.busy)
                    }
                    Text(tr(.settings_resume_notice)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Surface {
                    Label(tr(.settings_cache_title), systemImage: "internaldrive").font(.system(size: 16, weight: .medium))
                    PreferenceRow(title: tr(.settings_cache_limit), detail: tr(.cache_used, ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .file))) {
                        NumberControl(title: tr(.settings_cache_limit), value: $model.cacheGB, range: 2...200, unit: "GB").disabled(model.busy)
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_reclaim), detail: tr(.settings_reclaim_description)) {
                        Toggle(tr(.settings_reclaim), isOn: $model.autoReclaimCache).labelsHidden().toggleStyle(.switch).disabled(model.busy)
                    }
                    Text(tr(.settings_reclaim_notice))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button(tr(.settings_data_folder)) { model.showData() }.buttonStyle(ActionStyle())
                }
                Surface {
                    Label(tr(.settings_protection_title), systemImage: "checkmark.shield").font(.system(size: 16, weight: .medium))
                    PreferenceRow(title: tr(.settings_mac_reserve)) {
                        NumberControl(title: tr(.settings_mac_reserve_control), value: $model.macReserveGB, range: NumericPreference.macReserveGB.range, unit: "GB").disabled(model.busy)
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_pixel_reserve), detail: tr(.settings_pixel_reserve_description)) {
                        NumberControl(title: tr(.settings_pixel_reserve_control), value: $model.pixelReserveGB, range: NumericPreference.pixelReserveGB.range, unit: "GB").disabled(model.busy)
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_temperature)) {
                        NumberControl(title: tr(.settings_temperature_control), value: $model.maxTemperatureC, range: NumericPreference.maxTemperatureC.range, unit: "°C").disabled(model.busy)
                    }
                    Text(tr(.settings_protection_notice))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Surface {
                    Label(tr(.settings_privacy_title), systemImage: "photo.badge.checkmark").font(.system(size: 16, weight: .medium))
                    Text(tr(.settings_capabilities))
                        .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
                    Button(tr(.settings_privacy_action)) { model.showSettings() }.buttonStyle(ActionStyle())
                }
                Surface {
                    Label(tr(.logs_title), systemImage: "text.alignleft").font(.system(size: 16, weight: .medium))
                    PreferenceRow(title: tr(.settings_log_days)) {
                        NumberControl(title: tr(.settings_log_days), value: $model.logRetentionDays, range: NumericPreference.logRetentionDays.range, unit: tr(.unit_days))
                    }
                    Divider()
                    PreferenceRow(title: tr(.settings_log_size)) {
                        NumberControl(title: tr(.settings_log_size), value: $model.logStorageMB, range: NumericPreference.logStorageMB.range, unit: "MB")
                    }
                    Text(tr(.logs_retention, String(model.logRetentionDays), String(model.logStorageMB))).font(.caption).foregroundStyle(Palette.muted)
                    HStack(spacing: 12) {
                        Button(tr(.logs_history), systemImage: "folder") { model.showLogHistory() }
                        Button(tr(.logs_export), systemImage: "square.and.arrow.up") { model.exportLogs() }.disabled(model.exportingLogs)
                    }.buttonStyle(ActionStyle())
                    if model.logStorageFailed {
                        Label(tr(.logs_write_failed), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    DisclosureGroup(isExpanded: $showLogs) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tr(.logs_original_language)).font(.caption).foregroundStyle(Palette.muted)
                            if model.logs.isEmpty { Text(tr(.logs_empty)).foregroundStyle(Palette.muted) }
                            ForEach(Array(model.logs.prefix(15).enumerated()), id: \.offset) { _, text in
                                Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                    } label: { Text(tr(.logs_recent)).font(.system(size: 14, weight: .medium)) }
                }
                HStack(spacing: 6) {
                    Text("PixelBridge")
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text(tr(.app_tagline))
                }.font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.bottom, 6)
            }.padding(30)
        }
    }
    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(tr(.adb_sheet_title), systemImage: "shippingbox").font(.system(size: 22, weight: .medium))
            Text(tr(.adb_sheet_description))
                .font(.system(size: 14)).foregroundStyle(Palette.muted).lineSpacing(5)
            Link(tr(.adb_license), destination: URL(string: "https://developer.android.com/studio/terms")!)
            Text(tr(.adb_consent))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Spacer()
                Button(tr(.action_cancel)) { showInstall = false }.buttonStyle(ActionStyle())
                Button(tr(.adb_accept_install)) { showInstall = false; Task { await model.installADB() } }.buttonStyle(ActionStyle(primary: true))
            }
        }.padding(32).frame(width: 490).background(.white)
    }
}

@main
struct PixelBridgeApp: App {
    @StateObject private var model = BridgeModel()
    @StateObject private var updater = AppUpdater()
    @AppStorage("appLanguage") private var appLanguage = "system"
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("PixelBridge", id: "main") { ContentView(model: model, updater: updater).task { updater.start(model: model) } }
            .defaultSize(width: 1240, height: 850).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button(tr(.updates_check)) { updater.check() }.disabled(!updater.canCheck)
                }
            }
        MenuBarExtra("PixelBridge", systemImage: model.busy ? "arrow.triangle.2.circlepath" : "photo.stack") {
            Text(model.status.text).id(appLanguage)
            Text(tr(.menu_delivered, String(describing: model.delivered)))
            Divider()
            Button(tr(.menu_open)) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button(model.autoRunning ? tr(.menu_pause) : tr(.menu_start)) { model.autoRunning ? model.pause() : model.startAutomatic() }
            Divider()
            Button(tr(.updates_check)) { updater.check() }.disabled(!updater.canCheck)
            Button(tr(.menu_quit)) { NSApp.terminate(nil) }
        }
    }
}

struct Thumbnail: View {
    let assetID: String
    @State private var image: NSImage?
    @State private var ticket: ThumbnailTicket?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height) }
                else { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: assetID) {
            ticket?.cancel(); image = nil
            guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { return }
            ticket = ThumbnailStore.load(assetID, pixels: 320) { image = $0 }
        }
        .onDisappear { ticket?.cancel() }
    }
}
