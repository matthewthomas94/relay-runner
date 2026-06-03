import Foundation

struct RelayInstallProgress {
    let copiedBytes: Int64
    let totalBytes: Int64
    let currentItem: String

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(copiedBytes) / Double(totalBytes))
    }
}

enum RelayBundleInstaller {
    static func install(
        from sourceBundleURL: URL,
        to destinationBundleURL: URL,
        progress: (RelayInstallProgress) -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempURL = destinationBundleURL.deletingLastPathComponent()
            .appendingPathComponent(".\(RelayInstallerContext.bundleName).installing-\(UUID().uuidString)",
                                    isDirectory: true)

        do {
            try copyBundle(from: sourceBundleURL, to: tempURL, progress: progress)

            if fileManager.fileExists(atPath: destinationBundleURL.path) {
                try fileManager.removeItem(at: destinationBundleURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationBundleURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    static func copyBundle(
        from sourceBundleURL: URL,
        to destinationBundleURL: URL,
        progress: (RelayInstallProgress) -> Void
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationBundleURL.path) {
            try fileManager.removeItem(at: destinationBundleURL)
        }

        try fileManager.createDirectory(
            at: destinationBundleURL,
            withIntermediateDirectories: true
        )

        let totalBytes = try byteCount(in: sourceBundleURL)
        var copiedBytes: Int64 = 0

        try copyContents(
            from: sourceBundleURL,
            to: destinationBundleURL,
            totalBytes: totalBytes,
            copiedBytes: &copiedBytes,
            progress: progress
        )
    }

    private static func copyContents(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        totalBytes: Int64,
        copiedBytes: inout Int64,
        progress: (RelayInstallProgress) -> Void
    ) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: keys,
            options: []
        )

        for sourceURL in items {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            let values = try sourceURL.resourceValues(forKeys: Set(keys + [.isDirectoryKey]))

            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
                try copyContents(
                    from: sourceURL,
                    to: destinationURL,
                    totalBytes: totalBytes,
                    copiedBytes: &copiedBytes,
                    progress: progress
                )
            } else {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                if values.isRegularFile == true {
                    copiedBytes += Int64(values.fileSize ?? 0)
                }
                progress(RelayInstallProgress(
                    copiedBytes: copiedBytes,
                    totalBytes: totalBytes,
                    currentItem: sourceURL.lastPathComponent
                ))
            }
        }
    }

    private static func byteCount(in directory: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )
        var total: Int64 = 0
        for url in items {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                total += try byteCount(in: url)
            } else if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
