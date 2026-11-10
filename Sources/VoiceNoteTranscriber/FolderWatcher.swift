import Foundation

/// Calls back when files are added, removed or renamed in a folder (e.g. in Finder), so the library stays current.
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private(set) var folder: URL?

    var isWatching: Bool { source != nil }

    func watch(_ folder: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // The folder itself was renamed or deleted: stop, and let the next refresh re-attach.
                if let self, let event = self.source?.data, !event.isDisjoint(with: [.rename, .delete]) {
                    self.stop()
                }
                onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        self.folder = folder
    }

    func stop() {
        source?.cancel()
        source = nil
        folder = nil
    }
}
