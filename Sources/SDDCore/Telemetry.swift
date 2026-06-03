import Foundation
import SDDModels

public protocol TelemetrySink {
    func emit(_ event: TelemetryEvent) throws
}

public final class LocalJSONLTelemetrySink: TelemetrySink {
    private let path: URL
    private let fileManager: FileManager

    public init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    public func emit(_ event: TelemetryEvent) throws {
        do {
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var data = try SDDJSON.encoder(prettyPrinted: false).encode(event)
            data.append(0x0A)

            if fileManager.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: path, options: .atomic)
            }
        } catch {
            throw SDDCoreError.telemetryWriteFailed(error.localizedDescription)
        }
    }
}
