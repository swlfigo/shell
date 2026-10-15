import Foundation
import Darwin

/// RFC 1928 framing, with NO AUTHENTICATION and CONNECT only. The loopback listener
/// delegates destination resolution to SSH direct-tcpip; it never resolves a domain locally.
enum SOCKS5Handshake {
  struct Endpoint: Equatable, Sendable { let host: String; let port: Int }

  static func negotiate(socket: ForwardSocket, timeout: TimeInterval = 10) async throws -> Endpoint {
    try await perform(socket: socket) {
      let io = try SocketIO(socket: socket, timeout: timeout)
      let greeting = try io.read(2)
      guard greeting[0] == 5, greeting[1] > 0 else {
        throw LocalForwardError.socks("无效的版本或认证方法列表。")
      }
      let methods = try io.read(Int(greeting[1]))
      guard methods.contains(0) else {
        try io.write([5, 255])
        throw LocalForwardError.socks("仅支持无需认证的本机代理。")
      }
      try io.write([5, 0])
      do {
        let request = try io.read(4)
        guard request[0] == 5, request[2] == 0 else {
          throw RequestFailure(code: 1, message: "无效的请求头。")
        }
        guard request[1] == 1 else {
          throw RequestFailure(code: 7, message: "仅支持 TCP CONNECT，不支持 BIND 或 UDP。")
        }
        let host: String
        switch request[3] {
        case 1: host = try io.read(4).map(String.init).joined(separator: ".")
        case 4:
          var address = try io.read(16)
          var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
          guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else {
            throw RequestFailure(code: 8, message: "无效的 IPv6 地址。")
          }
          host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        case 3:
          let length = Int(try io.read(1)[0])
          guard length > 0 else { throw RequestFailure(code: 8, message: "目标域名为空。") }
          let name = try io.read(length)
          guard name.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
              || byte == 45 || byte == 46 || byte == 95
          }) else { throw RequestFailure(code: 8, message: "域名需为 ASCII（国际域名使用 Punycode）。") }
          host = String(decoding: name, as: UTF8.self)
        default: throw RequestFailure(code: 8, message: "不支持的目标地址类型。")
        }
        let bytes = try io.read(2)
        let port = Int(bytes[0]) * 256 + Int(bytes[1])
        guard port > 0 else { throw RequestFailure(code: 1, message: "目标端口不能为 0。") }
        return Endpoint(host: host, port: port)
      } catch let failure as RequestFailure {
        try? io.write(response(code: failure.code))
        throw LocalForwardError.socks(failure.message)
      } catch {
        try? io.write(response(code: 1))
        throw error
      }
    }
  }

  static func reply(socket: ForwardSocket, code: UInt8) async throws {
    try await perform(socket: socket) { try SocketIO(socket: socket, timeout: 10).write(response(code: code)) }
  }

  private struct RequestFailure: Error { let code: UInt8; let message: String }
  private static func response(code: UInt8) -> [UInt8] {
    // SSH does not expose the server's outgoing bind endpoint. CONNECT clients do
    // not use BND.ADDR/BND.PORT; return the unspecified IPv4 endpoint, as ssh -D does.
    [5, code, 0, 1, 0, 0, 0, 0, 0, 0]
  }

  private static func perform<T: Sendable>(socket: ForwardSocket,
                                          _ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // A fragmented or silent client must not block the listener/session queue
        // or occupy a Swift cooperative executor thread while waiting for a socket.
        DispatchQueue(label: "termes.socks.handshake").async {
          do { continuation.resume(returning: try operation()) }
          catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { socket.close() }
  }

  private final class SocketIO {
    let socket: ForwardSocket
    let deadline: TimeInterval
    private let pollingFD: Int32
    init(socket: ForwardSocket, timeout: TimeInterval) throws {
      self.socket = socket; deadline = ProcessInfo.processInfo.systemUptime + timeout
      pollingFD = try socket.withFD { fd in
        guard fd >= 0 else { throw CancellationError() }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw LocalForwardError.socks(String(cString: strerror(errno))) }
        return duplicate
      }
    }
    deinit { Darwin.close(pollingFD) }

    func read(_ size: Int) throws -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: size)
      var offset = 0
      while offset < size {
        try wait(events: Int16(POLLIN))
        let count = try socket.withFD { fd in
          guard fd >= 0 else { throw CancellationError() }
          return bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + offset, size - offset, 0) }
        }
        if count > 0 { offset += count }
        else if count == 0 { throw LocalForwardError.socks("客户端在握手完成前关闭连接。") }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          throw LocalForwardError.socks(String(cString: strerror(errno)))
        }
      }
      // Read exactly the frame length; pipelined application bytes stay for the bridge.
      return bytes
    }

    func write(_ bytes: [UInt8]) throws {
      var offset = 0
      while offset < bytes.count {
        try wait(events: Int16(POLLOUT))
        let count = try socket.withFD { fd in
          guard fd >= 0 else { throw CancellationError() }
          return bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, bytes.count - offset, 0) }
        }
        if count > 0 { offset += count }
        else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
          throw LocalForwardError.socks("客户端无法接收握手响应。")
        }
      }
    }

    private func wait(events: Int16) throws {
      while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw LocalForwardError.socks("握手超时（10 秒）。") }
        guard socket.withFD({ $0 >= 0 }) else { throw CancellationError() }
        // Poll a separately owned descriptor without holding the socket lock. shutdown
        // on the original wakes this descriptor, while dup prevents descriptor reuse
        // from making poll observe an unrelated socket during a concurrent stop.
        var descriptor = pollfd(fd: pollingFD, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(min(100, max(1, remaining * 1000))))
        if result < 0 && errno != EINTR { throw LocalForwardError.socks(String(cString: strerror(errno))) }
        if result > 0 { return }
      }
    }
  }
}
