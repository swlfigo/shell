public enum SSHError: Error, Equatable {
  case connectionFailed(String)
  case authenticationFailed
  case hostKeyRejected
  case hostKeyMismatch(stored: String, got: String)
  case channelFailure(String)
  case disconnected
}
