import SwiftUI
import UniformTypeIdentifiers

struct GetComicsDetail: View {
    let series: ComicSeries
    let downloads: ComicDownloadStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShelfMasthead(title: series.title)
                CoverView(url: series.cover, mangaID: series.id)
                    .frame(width: 120, height: 170)
                    .clipShape(.rect(cornerRadius: 10))
                GetComicsNotice()
                if downloads.active == series.id {
                    LoadingSkeleton(label: "Downloading comic") {
                        SkeletonBlock(radius: 7).frame(height: 38)
                    }
                }
                if let failure = downloads.failure {
                    Text(failure).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("GetComics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                if let saved = downloads.saved(series) {
                    NavigationLink(value: saved.route) {
                        Label("Read download", systemImage: "book")
                    }
                    .accessibilityIdentifier("getcomics-read-download")
                } else {
                    Button {
                        Task { await downloads.download(series) }
                    } label: {
                        Label(downloads.active == series.id ? "Downloading…" : "Download comic",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(downloads.active != nil)
                    .accessibilityIdentifier("getcomics-download")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Link(destination: series.website) {
                    Label("GetComics download page", systemImage: "arrow.up.right")
                }
                .accessibilityIdentifier("getcomics-open-website")
            }
        }
    }
}

struct GetComicsNotice: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Download only").font(.subheadline.weight(.semibold))
                Text("Download the comic, then read it offline in Comics → Library → Downloads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "arrow.down.circle").foregroundStyle(Color.papertrailAccent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ShelfSurface())
        .accessibilityIdentifier("getcomics-download-notice")
    }
}

struct ComicDownloadsSection: View {
    let downloads: ComicDownloadStore

    @State private var importing = false
    @State private var importError: String?
    @State private var removal: ComicDownload?

    private static let allowed = ["cbz", "cbr", "zip", "rar", "pdf"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                importing = true
            } label: {
                Label("Import comic from Files", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(downloads.active != nil)
            .accessibilityIdentifier("comic-import-file")

            if downloads.active != nil {
                LoadingSkeleton(label: "Preparing download") { SkeletonBlock(radius: 7).frame(height: 38) }
            }
            if let error = importError ?? downloads.failure {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            if downloads.items.isEmpty {
                ShelfStateView("No downloaded comics", message: "Download a comic from GetComics or import a CBZ, CBR, ZIP, RAR, or PDF from Files.",
                               style: .compact)
            } else {
                ForEach(downloads.items) { entry in
                    NavigationLink(value: entry.route) {
                        HStack(spacing: 12) {
                            CoverView(url: entry.cover, mangaID: entry.id.uuidString)
                                .frame(width: 56, height: 78)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.subheadline.weight(.semibold))
                                Text("\(entry.files.count) pages · Available offline")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPressStyle())
                    .contextMenu {
                        Button("Remove download", systemImage: "trash", role: .destructive) { removal = entry }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.allowed) { result in
            importError = nil
            switch result {
            case .success(let file): Task { await downloads.importFile(file) }
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Remove this download?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove", role: .destructive) {
                if let entry = removal { downloads.remove(entry) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("This removes the comic’s offline pages from this device.")
        }
    }
}
