import Foundation
import Network

/// Local HTTP fixture; /stall accepts the request but never supplies video bytes.
final class PreviewHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "macmpv.test-preview-http")
    private let video: Data
    // Accessed only on queue, including the connection and receive callbacks.
    private var connections: [NWConnection] = []

    init(video: Data) throws {
        self.video = video
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection, request: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            let request = request + (data ?? Data())
            let text = String(decoding: request, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if !complete, error == nil { receive(connection, request: request) }
                return
            }
            guard !text.hasPrefix("GET /stall ") else { return }
            let supportsSeeking = !text.hasPrefix("GET /unseekable ")
            let range = text.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("range: bytes=") }
                .flatMap { supportsSeeking ? $0 : nil }
                .map { $0.dropFirst("Range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false) }
            let start = range.flatMap { Int($0[0]) } ?? 0
            let end = min(range.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? video.count - 1, video.count - 1)
            guard start >= 0, start <= end else { connection.cancel(); return }
            let body = video.subdata(in: start..<(end + 1))
            let status = range == nil ? "200 OK" : "206 Partial Content"
            let contentRange = range == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(video.count)\r\n"
            let acceptRanges = supportsSeeking ? "Accept-Ranges: bytes\r\n" : ""
            let header = "HTTP/1.1 \(status)\r\n\(acceptRanges)Content-Type: video/mp4\r\n\(contentRange)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func stop() {
        listener.cancel()
        listener.newConnectionHandler = nil
        queue.async { [self] in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
