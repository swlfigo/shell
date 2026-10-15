import Foundation
import Darwin

enum ForwardTestSocket {
  struct Failure: Error { let message: String }

  static func write(_ fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { send(fd, $0.baseAddress! + offset, data.count - offset, 0) }
      guard count > 0 else { throw Failure(message: "send: \(String(cString: strerror(errno)))") }
      offset += count
    }
  }

  static func read(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let received = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + offset, count - offset, 0) }
      guard received > 0 else { throw Failure(message: "read: \(received), \(String(cString: strerror(errno)))") }
      offset += received
    }
    return data
  }

  static func readToEOF(_ fd: Int32) throws -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count == 0 { return data }
      guard count > 0 else { throw Failure(message: "read: \(String(cString: strerror(errno)))") }
      data.append(contentsOf: buffer.prefix(count))
    }
  }

  static func socksRequest(host: String, port: Int) -> Data {
    var ipv4 = in_addr(), ipv6 = in6_addr()
    let suffix = Data([UInt8(port >> 8), UInt8(port & 255)])
    if inet_pton(AF_INET, host, &ipv4) == 1 {
      return Data([5, 1, 0, 1]) + withUnsafeBytes(of: ipv4) { Data($0) } + suffix
    }
    if inet_pton(AF_INET6, host, &ipv6) == 1 {
      return Data([5, 1, 0, 4]) + withUnsafeBytes(of: ipv6) { Data($0) } + suffix
    }
    let name = Array(host.utf8)
    return Data([5, 1, 0, 3, UInt8(name.count)] + name) + suffix
  }

  static func socksExchange(port: Int, host: String, targetPort: Int, data: Data = Data()) async throws -> Data {
    try await Task.detached {
      let fd = try open(port: port)
      defer { Darwin.close(fd) }
      // Coalesce greeting, request and application bytes; the proxy must preserve framing.
      try write(fd, data: Data([5, 1, 0]) + socksRequest(host: host, port: targetPort) + data)
      guard try read(fd, count: 2) == Data([5, 0]), try read(fd, count: 10)[1] == 0 else {
        throw Failure(message: "SOCKS negotiation failed")
      }
      shutdown(fd, SHUT_WR)
      return try readToEOF(fd)
    }.value
  }

  static func open(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(message: "socket") }
    var timeout = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { Darwin.close(fd); throw Failure(message: "connect: \(String(cString: strerror(errno)))") }
    return fd
  }

  static func exchange(port: Int, data: Data) async throws -> Data {
    try await Task.detached {
      let fd = try open(port: port)
      defer { Darwin.close(fd) }
      var offset = 0
      while offset < data.count {
        let count = data.withUnsafeBytes { send(fd, $0.baseAddress! + offset, data.count - offset, 0) }
        guard count > 0 else { throw Failure(message: "send: \(String(cString: strerror(errno)))") }
        offset += count
      }
      shutdown(fd, SHUT_WR)
      var output = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count == 0 { return output }
        guard count > 0 else { throw Failure(message: "read: \(String(cString: strerror(errno)))") }
        output.append(contentsOf: buffer.prefix(count))
      }
    }.value
  }

  static func boundPort(_ fd: Int32) throws -> (host: UInt32, port: Int) {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { throw Failure(message: "getsockname") }
    return (address.sin_addr.s_addr, Int(UInt16(bigEndian: address.sin_port)))
  }

  /// Reserves an IPv4 loopback port for conflict and release tests.
  static func listener(port: Int = 0) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(message: "socket") }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw Failure(message: "bind/listen") }
    return fd
  }
}
