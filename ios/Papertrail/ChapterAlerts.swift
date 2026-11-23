import BackgroundTasks
import Observation
import OSLog
import UIKit
import UserNotifications

struct ChapterAlertCheckpoint: Codable {
    private let oldestNumber: Decimal?
    private var seen: Set<String>
    var checkedAt: Date

    static func checked(_ list: ChapterList, previous: Self?, at date: Date) -> (Self, [Chapter]) {
        let entries = list.items.map { chapter in
            let label = Chapter.normalizedNumber(chapter.number)
            let number = label.flatMap { value in
                value.split(separator: ".").count <= 2
                    ? Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
                    : nil
            }
            return (chapter: chapter, key: label.map { "number:\($0)" } ?? "id:\(chapter.localKey)", number: number)
        }
        var checkpoint = previous ?? Self(
            oldestNumber: list.nextOffset == nil ? nil : entries.compactMap(\.number).min(),
            seen: [], checkedAt: date
        )
        var releases: [Chapter] = []
        for entry in entries where checkpoint.seen.insert(entry.key).inserted {
            // If an older release moves onto the first page, it is outside the initial tracking window.
            if let oldest = checkpoint.oldestNumber, let number = entry.number, number < oldest { continue }
            if previous != nil { releases.append(entry.chapter) }
        }
        checkpoint.checkedAt = date
        return (checkpoint, releases)
    }
}

@MainActor
@Observable
final class ChapterAlerts {
    static let shared = ChapterAlerts()
    private static let appIdentifier = Bundle.main.bundleIdentifier ?? "dev.infinitmanga.reader"
    static let refreshID = "\(appIdentifier).bookmarked-chapters"
    nonisolated static let chapterURLKey = "bookmarkedChapterURL"
    private static let preferenceKey = "bookmarked-chapter-alerts"
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: ChapterAlerts.appIdentifier, category: "ChapterAlerts")
    private var inFlight: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var revision = 0

    private(set) var enabled = UserDefaults.standard.bool(forKey: preferenceKey)
    private(set) var permissionDenied = false
    private(set) var pendingChapter: Chapter?

    func setEnabled(_ enabled: Bool, library: ReadingStore) async {
        if enabled {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                permissionDenied = !granted
                guard granted else { return }
            } catch {
                permissionDenied = true
                return
            }
        } else {
            revision += 1
            retryAfter.removeAll()
            library.resetChapterAlerts()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        }
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
    }

    func openChapter(from link: String) {
        guard let url = SourceHTTP.url(link), let source = ReadingSource.match(url),
              let chapter = source.chapterLink(url) else { return }
        pendingChapter = chapter
    }

    func takePendingChapter() -> Chapter? {
        defer { pendingChapter = nil }
        return pendingChapter
    }

    func refresh(_ library: ReadingStore) async {
        guard enabled else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard enabled, !Task.isCancelled else { return }
        permissionDenied = status == .denied
        let eligible = library.bookmarks.filter { library.enabledSources.contains($0.provider) }
        guard status == .authorized || status == .provisional, !eligible.isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
            return
        }
        await scheduleRefreshIfNeeded()
        guard enabled, !Task.isCancelled else { return }

        let now = Date()
        let due = eligible.filter { manga in
            let checkedAt = library.chapterAlertCheckpoint(manga)?.checkedAt ?? .distantPast
            return now.timeIntervalSince(checkedAt) >= 10 * 60 && (retryAfter[manga.id] ?? .distantPast) <= now
        }.sorted {
            (library.chapterAlertCheckpoint($0)?.checkedAt ?? .distantPast) <
            (library.chapterAlertCheckpoint($1)?.checkedAt ?? .distantPast)
        }
        let batch = Array(due.lazy.filter { !self.inFlight.contains($0.id) }.prefix(12))
        inFlight.formUnion(batch.map(\.id))
        defer { inFlight.subtract(batch.map(\.id)) }
        let checkRevision = revision

        for start in stride(from: 0, to: batch.count, by: 3) {
            guard enabled, revision == checkRevision, !Task.isCancelled else { return }
            await withTaskGroup(of: (Manga, ChapterList?).self) { group in
                for manga in batch[start..<min(start + 3, batch.count)] {
                    group.addTask { (manga, try? await manga.provider.chaptersForAlerts(manga)) }
                }
                for await (manga, chapters) in group {
                    guard enabled, revision == checkRevision, !Task.isCancelled,
                          library.bookmarked(manga), library.enabledSources.contains(manga.provider) else { continue }
                    if let chapters {
                        await record(chapters, for: manga, in: library, revision: checkRevision)
                    } else {
                        retryAfter[manga.id] = .now.addingTimeInterval(10 * 60)
                    }
                }
            }
            if start + 3 < batch.count { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    private func scheduleRefreshIfNeeded() async {
        let pending = await BGTaskScheduler.shared.pendingTaskRequests()
        guard enabled, !Task.isCancelled, !pending.contains(where: { $0.identifier == Self.refreshID }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        request.earliestBeginDate = .now.addingTimeInterval(30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.debug("Chapter refresh could not be scheduled: \(error.localizedDescription)")
        }
    }

    private func record(_ list: ChapterList, for manga: Manga, in library: ReadingStore, revision: Int) async {
        let matching = ChapterList(items: list.items.filter { $0.slug == manga.slug }, nextOffset: list.nextOffset)
        guard list.items.isEmpty || !matching.items.isEmpty else {
            retryAfter[manga.id] = .now.addingTimeInterval(10 * 60)
            return
        }
        let (checkpoint, releases) = ChapterAlertCheckpoint.checked(
            matching, previous: library.chapterAlertCheckpoint(manga), at: .now
        )
        let unread = releases.filter { !library.progress($0).read }
        if let chapter = unread.first {
            let content = UNMutableNotificationContent()
            content.title = manga.title
            content.body = unread.count == 1
                ? "\(chapter.displayTitle) is available on \(manga.provider.name)."
                : "\(unread.count) new chapters are available on \(manga.provider.name)."
            content.sound = .default
            content.threadIdentifier = "bookmarked-chapters"
            content.userInfo[Self.chapterURLKey] = chapter.source.absoluteString
            let identifier = "new-chapter:\(chapter.localKey)"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            } catch {
                retryAfter[manga.id] = .now.addingTimeInterval(10 * 60)
                return
            }
        }
        guard self.revision == revision, library.bookmarked(manga), library.enabledSources.contains(manga.provider) else { return }
        retryAfter[manga.id] = nil
        library.setChapterAlertCheckpoint(checkpoint, for: manga)
    }
}

final class ChapterNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = response.notification.request.content.userInfo[ChapterAlerts.chapterURLKey] as? String else { return }
        await ChapterAlerts.shared.openChapter(from: link)
    }
}
