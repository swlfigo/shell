import XCTest
@testable import SSHCore

final class ModelTests: XCTestCase {
  func test_config_defaults_port_22() {
    let c = ConnectionConfig(hostname: "h", username: "u", auth: .password("p"))
    XCTAssertEqual(c.port, 22)
  }

  func test_ssherror_equatable() {
    XCTAssertEqual(SSHError.authenticationFailed, .authenticationFailed)
    XCTAssertNotEqual(SSHError.disconnected, .authenticationFailed)
  }
}
