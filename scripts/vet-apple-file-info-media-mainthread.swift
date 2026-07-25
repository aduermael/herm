import Foundation

/// Structural gates for:
/// - file info as Files stack route (not popover)
/// - media playback audio session (.playback for silent switch)
/// - location/calendar open paths that keep heavy work off the main thread
@main
private struct CPSLFileInfoMediaMainThreadChecks {
    static func main() throws {
        let browser = try source("app/apple/herm/Views/Files/CPSLFileBrowserView.swift")
        let chatModel = try source("app/apple/herm/Models/CPSLChatModel.swift")
        let preview = try source("app/apple/herm/Views/Files/CPSLFilePreviewOverlay.swift")
        let locationService = try source("app/apple/herm/Services/CPSLLocationService.swift")
        let locationMap = try source("app/apple/herm/Views/Location/CPSLLocationMapView.swift")
        let calendar = try source("app/apple/herm/Services/CPSLCalendarService.swift")

        try assertFileInfoIsStackRoute(browser: browser, chatModel: chatModel)
        try assertMediaPlaysInSilentMode(preview: preview)
        try assertMainThreadFriendlyWidgets(
            chatModel: chatModel,
            locationService: locationService,
            locationMap: locationMap,
            calendar: calendar
        )
        print("vet-apple-file-info-media-mainthread: all checks passed")
    }

    private static func assertFileInfoIsStackRoute(browser: String, chatModel: String) throws {
        try require(
            browser.contains("case fileInfo(CPSLFilePreview)"),
            "Files route stack must include a fileInfo case"
        )
        try require(
            browser.contains("case .fileInfo(let preview):\n            CPSLFileInfoPageView(preview: preview)"),
            "fileInfo route must render the in-pane info page"
        )
        try require(
            browser.contains("struct CPSLFileInfoPageView"),
            "file info content must be a full page view"
        )
        try require(
            !browser.contains(".popover(isPresented: $isShowingInfo)"),
            "file info must not present as a popover drawer"
        )
        try require(
            !browser.contains("CPSLFilePreviewInfoPopover"),
            "popover-based file info type must be removed"
        )
        try require(
            chatModel.contains("private(set) var isFileInfoOpen = false"),
            "chat model must own isFileInfoOpen for stack depth"
        )
        try require(
            chatModel.contains("func openFileInfo()") && chatModel.contains("func closeFileInfo()"),
            "chat model must open/close file info like folder navigation"
        )
        try require(
            browser.contains("model.closeFileInfo()") && browser.contains("model.openFileInfo()"),
            "header back/info must drive model file-info navigation"
        )
        try require(
            browser.contains("(.preview, .fileInfo)") && browser.contains("(.fileInfo, .preview)"),
            "route direction must treat info as one level deeper than preview"
        )
    }

    private static func assertMediaPlaysInSilentMode(preview: String) throws {
        try require(
            preview.contains("activatePlaybackAudioSession()"),
            "media play must configure the playback audio session"
        )
        try require(
            preview.contains("setCategory(.playback"),
            "audio session category must be .playback (ignores silent switch like Music)"
        )
        try require(
            preview.contains("player.play()") &&
                preview.range(of: "activatePlaybackAudioSession()") != nil,
            "session activation must happen on the play path"
        )
    }

    private static func assertMainThreadFriendlyWidgets(
        chatModel: String,
        locationService: String,
        locationMap: String,
        calendar: String
    ) throws {
        try require(
            chatModel.contains("isLocationOpen = true") &&
                chatModel.contains("Task(priority: .userInitiated)") &&
                chatModel.contains("await location.loadCurrentLocation()"),
            "location overlay must open before awaiting location load"
        )
        try require(
            locationService.contains("await Self.locationServicesEnabled()") &&
                locationService.contains("Task.detached(priority: .utility)"),
            "locationServicesEnabled must stay off the main thread"
        )
        try require(
            locationService.contains("await Task.yield()"),
            "location load must yield so overlay chrome can paint first"
        )
        try require(
            locationMap.contains("@State private var isMapReady = false") &&
                locationMap.contains("isMapReady = true"),
            "MKMapView construction must be deferred until after first frames"
        )
        try require(
            calendar.contains("Task.detached(priority: .userInitiated)") &&
                calendar.contains("fetchUpcomingEvents(from:"),
            "calendar event matching must run off the MainActor"
        )
        try require(
            chatModel.contains("await service.listDirectory(path)") ||
                chatModel.contains("await service.listDirectory"),
            "directory listing must be awaited on the service actor (not sync on UI)"
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CheckFailure("could not read \(relativePath): \(error.localizedDescription)")
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw CheckFailure(message)
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
