import Foundation
import XCTest
import SSHCore
import TermesKit

@MainActor
final class ConnectionProgressTests: XCTestCase {
  private func config(jumps: Int = 0) -> ConnectionConfig {
    .init(hostname: "target", username: "user", auth: .privateKey(data: Data("PRIVATE_KEY_SECRET".utf8), passphrase: "PASSPHRASE_SECRET"),
      jumpHosts: (0..<jumps).map { .init(hostname: "jump\($0)", username: "user", auth: .password("PASSWORD_SECRET")) })
  }
  private func send(_ model: ConnectionProgressModel, token: UUID, node: Int = 0, sequence: UInt64,
                    stage: SSHProgressStage, status: SSHProgressStatus) {
    model.receive(.init(sequence: sequence, endpoint: model.nodes[node].endpoint, stage: stage, status: status), token: token)
  }

  func test_ready_requires_authentication_and_shell_not_just_channel_or_pty() {
    let model = ConnectionProgressModel(), token = model.begin(config: config())
    send(model, token: token, sequence: 1, stage: .connection, status: .succeeded)
    send(model, token: token, sequence: 2, stage: .hostKey, status: .waitingForTrust(fingerprint: "SHA256:example"))
    XCTAssertEqual(model.state, .waitingForTrust); XCTAssertEqual(model.currentNode?.steps[1], .waitingForTrust)
    send(model, token: token, sequence: 3, stage: .hostKey, status: .succeeded)
    send(model, token: token, sequence: 4, stage: .authentication, status: .succeeded)
    XCTAssertFalse(model.ready(token: token)); XCTAssertEqual(model.currentNode?.steps[3], .waiting)
    send(model, token: token, sequence: 5, stage: .channel, status: .succeeded)
    XCTAssertFalse(model.ready(token: token)); XCTAssertEqual(model.currentNode?.steps[3], .running)
    send(model, token: token, sequence: 6, stage: .pty, status: .succeeded)
    XCTAssertFalse(model.ready(token: token))
    send(model, token: token, sequence: 7, stage: .shell, status: .succeeded)
    XCTAssertTrue(model.ready(token: token)); XCTAssertEqual(model.state, .ready)
    XCTAssertEqual(model.currentNode?.steps, Array(repeating: .succeeded, count: 5)); XCTAssertFalse(model.canCancel)
  }

  func test_jump_route_readiness_is_separate_from_target_terminal_readiness() {
    let model = ConnectionProgressModel(), token = model.begin(config: config(jumps: 2))
    send(model, token: token, node: 0, sequence: 1, stage: .route, status: .succeeded)
    XCTAssertEqual(model.nodes[0].steps[4], .succeeded); XCTAssertEqual(model.state, .running)
    send(model, token: token, node: 1, sequence: 2, stage: .connection, status: .started)
    XCTAssertEqual(model.currentNode?.endpoint.hostname, "jump1")
    send(model, token: token, node: 1, sequence: 3, stage: .authentication, status: .failed(.authentication))
    XCTAssertEqual(model.currentNodeIndex, 1); XCTAssertEqual(model.state, .failed(SSHProgressFailure.authentication.message))
    XCTAssertTrue(model.nodes[2].steps.allSatisfy { $0 == .waiting })
    XCTAssertFalse(model.ready(token: token))
    XCTAssertTrue(model.logs.last?.text.contains("跳板 2/2") == true)
  }

  func test_cancel_and_new_attempt_ignore_late_tokens_unknown_endpoints_and_old_sequences() {
    let model = ConnectionProgressModel(), old = model.begin(config: config())
    send(model, token: old, sequence: 1, stage: .connection, status: .started)
    model.endConnection(); XCTAssertEqual(model.state, .cancelled)
    let before = model.logs
    send(model, token: old, sequence: 2, stage: .authentication, status: .succeeded)
    XCTAssertEqual(model.logs, before); XCTAssertFalse(model.ready(token: old))
    let fresh = model.begin(config: config(), attempt: 2)
    send(model, token: old, sequence: 500, stage: .shell, status: .succeeded)
    model.receive(.init(sequence: 500, endpoint: .init(hostname: "other", port: 22, username: "u", index: 0, jumpCount: 0),
      stage: .connection, status: .succeeded), token: fresh)
    XCTAssertTrue(model.nodes[0].steps.allSatisfy { $0 == .waiting })
    send(model, token: fresh, sequence: 2, stage: .connection, status: .started)
    send(model, token: fresh, sequence: 1, stage: .connection, status: .succeeded)
    XCTAssertEqual(model.nodes[0].steps[0], .running); XCTAssertEqual(model.attempt, 2)
  }

  func test_failure_and_retry_keep_reason_reset_stages_and_bound_logs_without_credentials() {
    let model = ConnectionProgressModel(), config = config(jumps: 1), first = model.begin(config: config)
    for sequence in 1...500 { send(model, token: first, sequence: UInt64(sequence), stage: .authentication, status: .started) }
    XCTAssertEqual(model.logs.count, ConnectionProgressModel.maximumLogCount)
    send(model, token: first, sequence: 501, stage: .authentication, status: .failed(.authentication))
    model.waitingRetry(seconds: 4, token: first)
    XCTAssertEqual(model.state, .waitingRetry(seconds: 4)); XCTAssertTrue(model.canCancel)
    XCTAssertEqual(model.nodes[0].steps[2], .failed(SSHProgressFailure.authentication.message))
    let second = model.begin(config: config, attempt: 2)
    XCTAssertEqual(model.logs.count, ConnectionProgressModel.maximumLogCount)
    XCTAssertTrue(model.nodes.allSatisfy { $0.steps.allSatisfy { $0 == .waiting } })
    XCTAssertTrue(model.logs.contains { $0.text.contains("4 秒后") })
    let text = String(describing: model.logs) + String(describing: model.nodes)
    for secret in ["PRIVATE_KEY_SECRET", "PASSPHRASE_SECRET", "PASSWORD_SECRET"] { XCTAssertFalse(text.contains(secret)) }
    model.endConnection(); model.waitingRetry(seconds: 8, token: second)
    XCTAssertEqual(model.state, .cancelled)
  }

  func test_display_metadata_and_log_lines_are_bounded_and_target_change_drops_old_history() {
    let model = ConnectionProgressModel()
    let long = String(repeating: "中", count: 5000) + "\n\u{1b}"
    let token = model.begin(config: .init(hostname: long, username: long, auth: .password("secret")))
    XCTAssertLessThanOrEqual(model.nodes[0].endpoint.hostname.unicodeScalars.count, 256)
    XCTAssertLessThanOrEqual(model.nodes[0].endpoint.username.unicodeScalars.count, 128)
    send(model, token: token, sequence: 1, stage: .hostKey, status: .waitingForTrust(fingerprint: long))
    XCTAssertTrue(model.logs.allSatisfy { $0.text.unicodeScalars.count <= 512 && !$0.text.contains("\n") && !$0.text.contains("\u{1b}") })
    model.begin(config: config())
    XCTAssertEqual(model.logs.count, 1); XCTAssertEqual(model.currentNode?.endpoint.hostname, "target")
  }
}
