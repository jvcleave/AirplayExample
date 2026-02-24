import Dispatch
import Foundation

enum Errno {
    static func description() -> String {
        String(cString: strerror(errno))
    }
}

public enum HttpResponse {
    case ok(data: Data, contentType: String? = nil)
    case notFound

    public var statusCode: Int {
        switch self {
        case .ok: return 200
        case .notFound: return 404
        }
    }

    public var reasonPhrase: String {
        switch self {
        case .ok: return "OK"
        case .notFound: return "Not Found"
        }
    }

    public func headers() -> [String: String] {
        var headers = ["Server": "HttpServer \(HttpServer.VERSION)"]
        switch self {
        case .ok(_, let contentType):
            headers["Content-Type"] = contentType
        case .notFound:
            break
        }
        return headers
    }

    func content() -> (length: Int, data: Data?) {
        switch self {
        case .ok(let data, _):
            return (data.count, data)
        case .notFound:
            return (-1, nil)
        }
    }
}

final class HttpServer {
    static let VERSION = "0.1"

    enum State: Int32 {
        case starting
        case running
        case stopping
        case stopped
    }

    private struct Route {
        let path: String
        let segments: [String]
        let handler: (String) -> HttpResponse
    }

    private var socket = Socket(socketFileDescriptor: -1)
    private var sockets: [Int32: Socket] = [:]
    private var exactRoutes: [String: (String) -> HttpResponse] = [:]
    private var parameterRoutes: [Route] = []
    private var stateValue: Int32 = State.stopped.rawValue
    private let clientsQueue = DispatchQueue(label: "airplay.httpserver.clientsockets")
    private let routesQueue = DispatchQueue(label: "airplay.httpserver.routes")

    subscript(path: String) -> ((String) -> HttpResponse)? {
        get { nil }
        set { registerRoute(path: path, handler: newValue) }
    }

    private(set) var state: State {
        get { State(rawValue: stateValue) ?? .stopped }
        set { stateValue = newValue.rawValue }
    }

    var operating: Bool {
        state == .running
    }

    deinit {
        stop()
    }

    func start(_ port: in_port_t = 8080, priority: DispatchQoS.QoSClass = .background) throws {
        guard !operating else { return }
        stop()
        state = .starting
        socket = try Socket.tcpSocketForListen(port, SOMAXCONN)
        state = .running

        DispatchQueue.global(qos: priority).async { [weak self] in
            guard let self, self.operating else { return }
            while let clientSocket = try? self.socket.acceptClientSocket() {
                DispatchQueue.global(qos: priority).async { [weak self] in
                    guard let self, self.operating else { return }
                    self.clientsQueue.async { self.sockets[clientSocket.socketFileDescriptor] = clientSocket }
                    self.handleConnection(clientSocket)
                    self.clientsQueue.async { self.sockets.removeValue(forKey: clientSocket.socketFileDescriptor) }
                }
            }
            self.stop()
        }
    }

    func stop() {
        guard operating else { return }
        state = .stopping
        for socket in sockets.values {
            socket.close()
        }
        clientsQueue.sync {
            sockets.removeAll(keepingCapacity: true)
        }
        socket.close()
        state = .stopped
    }

    private func dispatch(path: String) -> (String) -> HttpResponse {
        if let handler = routeHandler(path: path) {
            return handler
        }
        return { _ in .notFound }
    }

    private func handleConnection(_ socket: Socket) {
        guard operating, let requestPath = try? readHttpRequestPath(socket) else {
            socket.close()
            return
        }

        let handler = dispatch(path: requestPath)
        let response = handler(requestPath)

        do {
            if operating {
                try respond(socket, response: response)
            }
        } catch {
            print("Failed to send response: \(error)")
        }

        socket.close()
    }

    private func respond(_ socket: Socket, response: HttpResponse) throws {
        guard operating else { return }

        var responseHeader = ""
        responseHeader.append("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n")

        let content = response.content()
        if content.length >= 0 {
            responseHeader.append("Content-Length: \(content.length)\r\n")
        }

        for (name, value) in response.headers() {
            responseHeader.append("\(name): \(value)\r\n")
        }
        responseHeader.append("\r\n")

        try socket.writeUTF8(responseHeader)

        if let data = content.data {
            try socket.writeData(data)
        }
    }

    private func readHttpRequestPath(_ socket: Socket) throws -> String {
        let requestLine = try socket.readLine()
        guard requestLine.hasPrefix("GET ") else {
            throw NSError(domain: "HttpServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported request line: \(requestLine)"])
        }

        let tokens = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard tokens.count >= 3 else {
            throw NSError(domain: "HttpServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid request line: \(requestLine)"])
        }

        let rawPath = String(tokens[1])
        try discardHeaders(socket)
        return stripQuery(rawPath)
    }

    private func discardHeaders(_ socket: Socket) throws {
        while !(try socket.discardLine()) {
        }
    }

    private func registerRoute(path: String, handler: ((String) -> HttpResponse)?) {
        let normalizedPath = stripQuery(path)
        let segments = pathSegments(for: normalizedPath)
        let hasParameters = segments.contains { $0.first == ":" }

        routesQueue.sync {
            exactRoutes.removeValue(forKey: normalizedPath)
            parameterRoutes.removeAll { $0.path == normalizedPath }

            guard let handler else { return }

            if hasParameters {
                parameterRoutes.append(Route(path: normalizedPath, segments: segments, handler: handler))
            } else {
                exactRoutes[normalizedPath] = handler
            }
        }
    }

    private func routeHandler(path: String) -> ((String) -> HttpResponse)? {
        routesQueue.sync {
            let normalizedPath = stripQuery(path)
            if let handler = exactRoutes[normalizedPath] {
                return handler
            }

            let requestSegments = pathSegments(for: normalizedPath)
            for route in parameterRoutes where route.segments.count == requestSegments.count {
                if matches(route.segments, requestSegments) {
                    return route.handler
                }
            }
            return nil
        }
    }

    private func matches(_ routeSegments: [String], _ requestSegments: [String]) -> Bool {
        for (routeSegment, requestSegment) in zip(routeSegments, requestSegments) {
            if routeSegment.first == ":" {
                continue
            }
            guard routeSegment.removingPercentEncoding == requestSegment.removingPercentEncoding else {
                return false
            }
        }
        return true
    }

    private func stripQuery(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private func pathSegments(for path: String) -> [String] {
        path.split { $0 == "/" }.map(String.init)
    }
}

public enum SocketError: Error {
    case socketCreationFailed(String)
    case socketSettingReUseAddrFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case writeFailed(String)
    case acceptFailed(String)
    case recvFailed(String)
}

final class Socket {
    let socketFileDescriptor: Int32
    private var shutdown = false

    init(socketFileDescriptor: Int32) {
        self.socketFileDescriptor = socketFileDescriptor
    }

    deinit {
        close()
    }

    func close() {
        guard !shutdown else { return }
        shutdown = true
        Socket.close(socketFileDescriptor)
    }

    func writeUTF8(_ string: String) throws {
        try writeUInt8(ArraySlice(string.utf8))
    }

    func writeUInt8(_ data: ArraySlice<UInt8>) throws {
        try data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, !data.isEmpty else { return }
            try writeBuffer(baseAddress, length: data.count)
        }
    }

    func writeData(_ data: Data) throws {
        try data.withUnsafeBytes { (body: UnsafeRawBufferPointer) in
            if let baseAddress = body.baseAddress, body.count > 0 {
                try self.writeBuffer(baseAddress, length: body.count)
            }
        }
    }

    private func writeBuffer(_ pointer: UnsafeRawPointer, length: Int) throws {
        var sent = 0
        while sent < length {
            let result = Darwin.write(socketFileDescriptor, pointer + sent, Int(length - sent))
            if result <= 0 {
                throw SocketError.writeFailed(Errno.description())
            }
            sent += result
        }
    }

    func read() throws -> UInt8 {
        var byte: UInt8 = 0
        let count = Darwin.read(socketFileDescriptor, &byte, 1)
        guard count > 0 else {
            throw SocketError.recvFailed(Errno.description())
        }
        return byte
    }

    private static let CR: UInt8 = 13
    private static let NL: UInt8 = 10

    func readLine() throws -> String {
        var characters = ""
        var index: UInt8 = 0
        repeat {
            index = try read()
            if index > Socket.CR, let scalar = UnicodeScalar(Int(index)) {
                characters.append(Character(scalar))
            }
        } while index != Socket.NL
        return characters
    }

    // Returns true when the discarded line was empty (CRLF only).
    func discardLine() throws -> Bool {
        var sawContent = false
        var byte: UInt8 = 0
        repeat {
            byte = try read()
            if byte > Socket.CR {
                sawContent = true
            }
        } while byte != Socket.NL
        return !sawContent
    }

    class func setNoSigPipe(_ socket: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    class func close(_ socket: Int32) {
        _ = Darwin.close(socket)
    }

    class func tcpSocketForListen(_ port: in_port_t, _ maxPendingConnection: Int32 = SOMAXCONN) throws -> Socket {
        let socketFileDescriptor = socket(AF_INET, SOCK_STREAM, 0)

        if socketFileDescriptor == -1 {
            throw SocketError.socketCreationFailed(Errno.description())
        }

        var value: Int32 = 1
        if setsockopt(socketFileDescriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size)) == -1 {
            let details = Errno.description()
            Socket.close(socketFileDescriptor)
            throw SocketError.socketSettingReUseAddrFailed(details)
        }
        Socket.setNoSigPipe(socketFileDescriptor)

        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.stride), sin_family: UInt8(AF_INET), sin_port: port.bigEndian, sin_addr: in_addr(s_addr: in_addr_t(0)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bindResult = withUnsafePointer(to: &addr) {
            bind(socketFileDescriptor, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        if bindResult == -1 {
            let details = Errno.description()
            Socket.close(socketFileDescriptor)
            throw SocketError.bindFailed(details)
        }

        if listen(socketFileDescriptor, maxPendingConnection) == -1 {
            let details = Errno.description()
            Socket.close(socketFileDescriptor)
            throw SocketError.listenFailed(details)
        }

        return Socket(socketFileDescriptor: socketFileDescriptor)
    }

    func acceptClientSocket() throws -> Socket {
        var addr = sockaddr()
        var len: socklen_t = 0
        let clientSocket = accept(socketFileDescriptor, &addr, &len)
        if clientSocket == -1 {
            throw SocketError.acceptFailed(Errno.description())
        }
        Socket.setNoSigPipe(clientSocket)
        return Socket(socketFileDescriptor: clientSocket)
    }
}
