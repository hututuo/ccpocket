import Flutter
import LocalAuthentication
import Security

/// Secure-Enclave-backed proof that a file mutation was approved by Face ID.
///
/// The private key is non-exportable and invalidates when the enrolled
/// biometric set changes. Dart receives only the public key and a DER ECDSA
/// signature over the exact Bridge challenge payload.
final class FileMutationAuthPlugin: NSObject, FlutterPlugin {
  static let channelName = "ccpocket/file_mutation_auth"
  static let nativeAPIVersion = 1

  private static let keyTag = Data(
    "com.k9i.ccpocket.file-mutation-auth.p256.v1".utf8
  )
  private static let keychainService = "com.k9i.ccpocket.file-mutation-auth"
  private static let deviceIdAccount = "device-id-v1"
  private static let publicKeyAccount = "public-key-v1"
  private static let maximumChallengeBytes = 4_096

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(FileMutationAuthPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      switch call.method {
      case "getSnapshot":
        result(Self.snapshot())
      case "prepareKey":
        self.prepareKey(result: result)
      case "signChallenge":
        self.signChallenge(arguments: call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func snapshot(context: LAContext = LAContext()) -> [String: Any] {
    var error: NSError?
    let canEvaluate = context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      error: &error
    )
    return [
      "supported": true,
      "nativeApiVersion": nativeAPIVersion,
      "canEvaluateBiometrics": canEvaluate,
      "biometryType": biometryName(context.biometryType),
      "deviceId": loadOrCreateDeviceId(),
      "keyPrepared": loadKeychainData(account: publicKeyAccount) != nil,
      "reason": canEvaluate ? NSNull() : boundedReason(error),
    ]
  }

  private func prepareKey(result: @escaping FlutterResult) {
    let context = LAContext()
    var evaluationError: NSError?
    guard context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      error: &evaluationError
    ) else {
      result(
        FlutterError(
          code: "biometrics_unavailable",
          message: Self.boundedReason(evaluationError),
          details: nil
        )
      )
      return
    }

    do {
      let publicKey = try Self.loadOrCreatePublicKey()
      result([
        "deviceId": Self.loadOrCreateDeviceId(),
        "publicKey": Self.base64Url(publicKey),
        "biometryType": Self.biometryName(context.biometryType),
      ])
    } catch let error as FileMutationNativeError {
      result(
        FlutterError(code: error.code, message: error.message, details: nil)
      )
    } catch {
      result(
        FlutterError(
          code: "biometric_key_unavailable",
          message: "The Secure Enclave key could not be prepared",
          details: nil
        )
      )
    }
  }

  private func signChallenge(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let arguments = arguments as? [String: Any],
      let payload = arguments["payload"] as? String,
      Self.isValidChallengePayload(payload)
    else {
      result(
        FlutterError(
          code: "invalid_challenge",
          message: "The Bridge approval challenge is invalid",
          details: nil
        )
      )
      return
    }
    let reason =
      (arguments["reason"] as? String)?.prefix(160).description
      ?? "Approve this file change on your Mac"
    let context = LAContext()
    context.localizedCancelTitle = "Cancel"
    context.localizedReason = reason

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let privateKey = try Self.loadPrivateKey(context: context)
        var signatureError: Unmanaged<CFError>?
        guard
          let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(payload.utf8) as CFData,
            &signatureError
          ) as Data?
        else {
          throw FileMutationNativeError(
            code: "biometric_sign_failed",
            message: Self.securityErrorMessage(signatureError?.takeRetainedValue())
          )
        }
        let response: [String: Any] = [
          "deviceId": Self.loadOrCreateDeviceId(),
          "signature": Self.base64Url(signature),
        ]
        DispatchQueue.main.async { result(response) }
      } catch let error as FileMutationNativeError {
        if error.code == "biometric_key_invalidated" {
          Self.deleteKeychainData(account: Self.publicKeyAccount)
        }
        DispatchQueue.main.async {
          result(
            FlutterError(code: error.code, message: error.message, details: nil)
          )
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "biometric_sign_failed",
              message: "Face ID could not approve this file change",
              details: nil
            )
          )
        }
      }
    }
  }

  static func isValidChallengePayload(_ payload: String) -> Bool {
    let count = payload.lengthOfBytes(using: .utf8)
    return count > 0 && count <= maximumChallengeBytes
  }

  private static func loadOrCreatePublicKey() throws -> Data {
    if let cached = loadKeychainData(account: publicKeyAccount) {
      return cached
    }
    var accessError: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .biometryCurrentSet],
        &accessError
      )
    else {
      throw FileMutationNativeError(
        code: "biometric_key_unavailable",
        message: securityErrorMessage(accessError?.takeRetainedValue())
      )
    }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: keyTag,
        kSecAttrAccessControl as String: access,
      ],
    ]
    var creationError: Unmanaged<CFError>?
    guard
      let privateKey = SecKeyCreateRandomKey(
        attributes as CFDictionary,
        &creationError
      ),
      let publicKey = SecKeyCopyPublicKey(privateKey)
    else {
      throw FileMutationNativeError(
        code: "secure_enclave_unavailable",
        message: securityErrorMessage(creationError?.takeRetainedValue())
      )
    }
    var exportError: Unmanaged<CFError>?
    guard
      let external = SecKeyCopyExternalRepresentation(
        publicKey,
        &exportError
      ) as Data?
    else {
      throw FileMutationNativeError(
        code: "public_key_unavailable",
        message: securityErrorMessage(exportError?.takeRetainedValue())
      )
    }
    guard external.count == 65, external.first == 0x04 else {
      throw FileMutationNativeError(
        code: "public_key_invalid",
        message: "The Secure Enclave public key has an unexpected format"
      )
    }
    try saveKeychainData(external, account: publicKeyAccount)
    return external
  }

  private static func loadPrivateKey(
    context: LAContext
  ) throws -> SecKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: keyTag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
      kSecUseAuthenticationContext as String: context,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let item else {
      let code =
        status == errSecItemNotFound || status == errSecAuthFailed
        ? "biometric_key_invalidated"
        : status == errSecUserCanceled
          ? "biometric_cancelled"
          : "biometric_key_unavailable"
      throw FileMutationNativeError(
        code: code,
        message: boundedSecurityStatus(status)
      )
    }
    guard CFGetTypeID(item) == SecKeyGetTypeID() else {
      throw FileMutationNativeError(
        code: "biometric_key_unavailable",
        message: "The Secure Enclave key has an unexpected type"
      )
    }
    let privateKey = item as! SecKey
    return privateKey
  }

  private static func loadOrCreateDeviceId() -> String {
    if
      let data = loadKeychainData(account: deviceIdAccount),
      let value = String(data: data, encoding: .utf8),
      !value.isEmpty
    {
      return value
    }
    let value = "ios:\(UUID().uuidString.lowercased())"
    try? saveKeychainData(Data(value.utf8), account: deviceIdAccount)
    return value
  }

  private static func loadKeychainData(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    else {
      return nil
    }
    return item as? Data
  }

  private static func saveKeychainData(_ data: Data, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(
      query as CFDictionary,
      attributes as CFDictionary
    )
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw FileMutationNativeError(
        code: "keychain_write_failed",
        message: boundedSecurityStatus(update)
      )
    }
    let add = SecItemAdd(
      query.merging(attributes) { _, new in new } as CFDictionary,
      nil
    )
    guard add == errSecSuccess else {
      throw FileMutationNativeError(
        code: "keychain_write_failed",
        message: boundedSecurityStatus(add)
      )
    }
  }

  private static func deleteKeychainData(account: String) {
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ] as CFDictionary)
  }

  private static func base64Url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func biometryName(_ type: LABiometryType) -> String {
    if type == .faceID { return "faceId" }
    if type == .touchID { return "touchId" }
    if #available(iOS 17.0, *), type == .opticID { return "opticId" }
    if type == .none { return "none" }
    return "unknown"
  }

  private static func boundedReason(_ error: NSError?) -> String {
    guard let error else { return "Biometric authentication is unavailable" }
    return String(error.localizedDescription.prefix(240))
  }

  private static func securityErrorMessage(_ error: CFError?) -> String {
    guard let error else { return "The secure key operation failed" }
    let description = CFErrorCopyDescription(error) as String
    return String(description.prefix(240))
  }

  private static func boundedSecurityStatus(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
      return String(message.prefix(240))
    }
    return "Security operation failed (\(status))"
  }
}

private struct FileMutationNativeError: Error {
  let code: String
  let message: String
}
