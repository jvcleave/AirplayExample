import Dispatch
import Foundation

final class AirplayHttpServer {
    private let server = HttpServer()

    subscript(path: String) -> ((HttpRequest) -> HttpResponse)? {
        get { server[path] }
        set { server[path] = newValue }
    }

    func start(_ port: in_port_t = 8080, forceIPv4: Bool = false, priority: DispatchQoS.QoSClass = .background) throws {
        try server.start(port, forceIPv4: forceIPv4, priority: priority)
    }

    func stop() {
        server.stop()
    }
}

enum Errno {
    static func description() -> String {
        String(cString: strerror(errno))
    }
}

public final class HttpRequest {
    public var path: String = ""
    public var method: String = ""
    public var headers: [String: String] = [:]

    public init() {}
}

public protocol HttpResponseBodyWriter {
    func write(_ data: [UInt8]) throws
    func write(_ data: ArraySlice<UInt8>) throws
    func write(_ data: Data) throws
}

public enum HttpResponseBody {
    case htmlBody(String)
    case data(Data, contentType: String? = nil)

    func content() -> (Int, ((HttpResponseBodyWriter) throws -> Void)?) {
        switch self {
        case .htmlBody(let body):
            let serialized = "<html><meta charset=\"UTF-8\"><body>\(body)</body></html>"
            let data = [UInt8](serialized.utf8)
            return (data.count, { try $0.write(data) })
        case .data(let data, _):
            return (data.count, { try $0.write(data) })
        }
    }
}

public enum HttpResponse {
    case ok(HttpResponseBody, [String: String] = [:])
    case notFound(HttpResponseBody? = nil)

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
        var headers = ["Server": "AirplayHttpServer \(HttpServer.VERSION)"]
        switch self {
        case .ok(let body, let customHeaders):
            for (key, value) in customHeaders {
                headers[key] = value
            }
            switch body {
            case .htmlBody:
                headers["Content-Type"] = "text/html"
            case .data(_, let contentType):
                headers["Content-Type"] = contentType
            }
        case .notFound:
            break
        }
        return headers
    }

    func content() -> (length: Int, write: ((HttpResponseBodyWriter) throws -> Void)?) {
        switch self {
        case .ok(let body, _):
            return body.content()
        case .notFound(let body):
            return body?.content() ?? (-1, nil)
        }
    }
}

public final class HttpParser {
    public init() {}

    func readHttpRequest(_ socket: Socket) throws -> HttpRequest {
        let statusLine = try socket.readLine()
        let statusLineTokens = statusLine.components(separatedBy: " ")
        guard statusLineTokens.count >= 3 else {
            throw NSError(domain: "AirplayHttpServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid request line: \(statusLine)"])
        }

        let request = HttpRequest()
        request.method = statusLineTokens[0]
        let encodedPath = statusLineTokens[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? statusLineTokens[1]
        let urlComponents = URLComponents(string: encodedPath)
        request.path = urlComponents?.path ?? ""
        request.headers = try readHeaders(socket)
        return request
    }

    private func readHeaders(_ socket: Socket) throws -> [String: String] {
        var headers = [String: String]()
        while case let headerLine = try socket.readLine(), !headerLine.isEmpty {
            let headerTokens = headerLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            if let name = headerTokens.first, let value = headerTokens.last {
                headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    func supportsKeepAlive(_ headers: [String: String]) -> Bool {
        if let value = headers["connection"] {
            return value.trimmingCharacters(in: .whitespaces).lowercased() == "keep-alive"
        }
        return false
    }
}

final class HttpRouter {
    init() {}

    private final class Node {
        var nodes = [String: Node]()
        var isEndOfRoute = false
        var handler: ((HttpRequest) -> HttpResponse)?
    }

    private var rootNode = Node()
    private let queue = DispatchQueue(label: "airplay.http.router")

    func register(_ method: String?, path: String, handler: ((HttpRequest) -> HttpResponse)?) {
        var pathSegments = pathSegments(for: stripQuery(path))
        pathSegments.insert(method ?? "*", at: 0)
        var iterator = pathSegments.makeIterator()
        inflate(&rootNode, generator: &iterator).handler = handler
    }

    func route(_ method: String?, path: String) -> ((HttpRequest) -> HttpResponse)? {
        queue.sync {
            if let method {
                let pathSegments = pathSegments(for: method + "/" + stripQuery(path))
                var iterator = pathSegments.makeIterator()
                if let handler = findHandler(&rootNode, generator: &iterator) {
                    return handler
                }
            }

            let pathSegments = pathSegments(for: "*/" + stripQuery(path))
            var iterator = pathSegments.makeIterator()
            if let handler = findHandler(&rootNode, generator: &iterator) {
                return handler
            }

            return nil
        }
    }

    private func inflate(_ node: inout Node, generator: inout IndexingIterator<[String]>) -> Node {
        var currentNode = node
        while let pathSegment = generator.next() {
            if let nextNode = currentNode.nodes[pathSegment] {
                currentNode = nextNode
            } else {
                currentNode.nodes[pathSegment] = Node()
                currentNode = currentNode.nodes[pathSegment]!
            }
        }
        currentNode.isEndOfRoute = true
        return currentNode
    }

    private func findHandler(_ node: inout Node, generator: inout IndexingIterator<[String]>) -> ((HttpRequest) -> HttpResponse)? {
        var matchedRoutes = [Node]()
        let pattern = generator.map { $0 }
        findHandler(&node, pattern: pattern, matchedNodes: &matchedRoutes, index: 0, count: pattern.count)
        return matchedRoutes.first?.handler
    }

    private func findHandler(_ node: inout Node, pattern: [String], matchedNodes: inout [Node], index: Int, count: Int) {
        if index < count, let pathToken = pattern[index].removingPercentEncoding {
            let nextIndex = index + 1

            let variableNodes = node.nodes.filter { $0.key.first == ":" }
            if let variableNode = variableNodes.first {
                _ = pathToken // matched path token; params are not needed by this app
                findHandler(&node.nodes[variableNode.key]!, pattern: pattern, matchedNodes: &matchedNodes, index: nextIndex, count: count)
            }

            if var exactNode = node.nodes[pathToken] {
                findHandler(&exactNode, pattern: pattern, matchedNodes: &matchedNodes, index: nextIndex, count: count)
            }

            if var wildcardNode = node.nodes["*"] {
                findHandler(&wildcardNode, pattern: pattern, matchedNodes: &matchedNodes, index: nextIndex, count: count)
            }
        }

        if node.isEndOfRoute, index == count {
            matchedNodes.append(node)
        }
    }

    private func stripQuery(_ path: String) -> String {
        path.components(separatedBy: "?").first ?? path
    }

    private func pathSegments(for path: String) -> [String] {
        path.split { $0 == "/" }.map(String.init)
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

    private let router = HttpRouter()
    private var socket = Socket(socketFileDescriptor: -1)
    private var sockets: [Int32: Socket] = [:]
    private var stateValue: Int32 = State.stopped.rawValue
    private let queue = DispatchQueue(label: "airplay.httpserver.clientsockets")

    subscript(path: String) -> ((HttpRequest) -> HttpResponse)? {
        get { nil }
        set { router.register(nil, path: path, handler: newValue) }
    }

    private(set) var state: State {
        get { State(rawValue: stateValue) ?? .stopped }
        set { stateValue = newValue.rawValue }
    }

    var operating: Bool {
        state == .running
    }

    var listenAddressIPv4: String?
    var listenAddressIPv6: String?

    deinit {
        stop()
    }

    func start(_ port: in_port_t = 8080, forceIPv4: Bool = false, priority: DispatchQoS.QoSClass = .background) throws {
        guard !operating else { return }
        stop()
        state = .starting
        let address = forceIPv4 ? listenAddressIPv4 : listenAddressIPv6
        socket = try Socket.tcpSocketForListen(port, forceIPv4, SOMAXCONN, address)
        state = .running

        DispatchQueue.global(qos: priority).async { [weak self] in
            guard let self, self.operating else { return }
            while let clientSocket = try? self.socket.acceptClientSocket() {
                DispatchQueue.global(qos: priority).async { [weak self] in
                    guard let self, self.operating else { return }
                    self.queue.async { self.sockets[clientSocket.socketFileDescriptor] = clientSocket }
                    self.handleConnection(clientSocket)
                    self.queue.async { self.sockets.removeValue(forKey: clientSocket.socketFileDescriptor) }
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
        queue.sync {
            sockets.removeAll(keepingCapacity: true)
        }
        socket.close()
        state = .stopped
    }

    private func dispatch(_ request: HttpRequest) -> (HttpRequest) -> HttpResponse {
        if let handler = router.route(request.method, path: request.path) {
            return handler
        }
        return { _ in .notFound() }
    }

    private func handleConnection(_ socket: Socket) {
        let parser = HttpParser()
        while operating, let request = try? parser.readHttpRequest(socket) {
            let handler = dispatch(request)
            let response = handler(request)
            var keepConnection = parser.supportsKeepAlive(request.headers)
            do {
                if operating {
                    keepConnection = try respond(socket, response: response, keepAlive: keepConnection)
                }
            } catch {
                print("Failed to send response: \(error)")
            }
            if !keepConnection { break }
        }
        socket.close()
    }

    private struct InnerWriteContext: HttpResponseBodyWriter {
        let socket: Socket

        func write(_ data: [UInt8]) throws {
            try write(ArraySlice(data))
        }

        func write(_ data: ArraySlice<UInt8>) throws {
            try socket.writeUInt8(data)
        }

        func write(_ data: Data) throws {
            try socket.writeData(data)
        }
    }

    private func respond(_ socket: Socket, response: HttpResponse, keepAlive: Bool) throws -> Bool {
        guard operating else { return false }

        var responseHeader = ""
        responseHeader.append("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n")

        let content = response.content()
        if content.length >= 0 {
            responseHeader.append("Content-Length: \(content.length)\r\n")
        }

        if keepAlive && content.length != -1 {
            responseHeader.append("Connection: keep-alive\r\n")
        }

        for (name, value) in response.headers() {
            responseHeader.append("\(name): \(value)\r\n")
        }
        responseHeader.append("\r\n")

        try socket.writeUTF8(responseHeader)

        if let writer = content.write {
            try writer(InnerWriteContext(socket: socket))
        }

        return keepAlive && content.length != -1
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

    func writeUInt8(_ data: [UInt8]) throws {
        try writeUInt8(ArraySlice(data))
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

    class func setNoSigPipe(_ socket: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    class func close(_ socket: Int32) {
        _ = Darwin.close(socket)
    }

    class func tcpSocketForListen(_ port: in_port_t, _ forceIPv4: Bool = false, _ maxPendingConnection: Int32 = SOMAXCONN, _ listenAddress: String? = nil) throws -> Socket {
        let socketFileDescriptor = socket(forceIPv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)

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

        var bindResult: Int32 = -1
        if forceIPv4 {
            var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.stride), sin_family: UInt8(AF_INET), sin_port: port.bigEndian, sin_addr: in_addr(s_addr: in_addr_t(0)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            if let address = listenAddress {
                _ = address.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
            }
            bindResult = withUnsafePointer(to: &addr) {
                bind(socketFileDescriptor, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } else {
            var addr = sockaddr_in6(sin6_len: UInt8(MemoryLayout<sockaddr_in6>.stride), sin6_family: UInt8(AF_INET6), sin6_port: port.bigEndian, sin6_flowinfo: 0, sin6_addr: in6addr_any, sin6_scope_id: 0)
            if let address = listenAddress {
                _ = address.withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }
            }
            bindResult = withUnsafePointer(to: &addr) {
                bind(socketFileDescriptor, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
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
