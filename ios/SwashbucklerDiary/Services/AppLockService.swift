import Foundation
import CommonCrypto
import LocalAuthentication

/// 密码哈希。
///
/// 算法与原项目 `PasswordHasher` 完全一致：PBKDF2-HMAC-SHA256，10000 次迭代，
/// 32 字节随机盐，32 字节输出，Base64 存储。这样即便将来做跨端密码迁移，
/// 旧哈希也能直接校验，不需要用户重设。
enum PasswordHasher {
    static let iterations = 10_000
    static let saltLength = 32
    static let hashLength = 32

    static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        return Data(bytes)
    }

    static func hash(password: String, salt: Data) -> Data? {
        var derived = [UInt8](repeating: 0, count: hashLength)
        let passwordBytes = Array(password.utf8)
        let result = salt.withUnsafeBytes { saltBuffer -> Int32 in
            guard let saltPointer = saltBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes, passwordBytes.count,
                saltPointer, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived, derived.count
            )
        }
        guard result == kCCSuccess else { return nil }
        return Data(derived)
    }

    /// 生成 (hashBase64, saltBase64)
    static func makePassword(_ password: String) -> (hash: String, salt: String) {
        let salt = makeSalt()
        guard let hashed = hash(password: password, salt: salt) else { return ("", "") }
        return (hashed.base64EncodedString(), salt.base64EncodedString())
    }

    static func verify(password: String, hashBase64: String, saltBase64: String) -> Bool {
        guard !hashBase64.isEmpty, !saltBase64.isEmpty,
              let salt = Data(base64Encoded: saltBase64),
              let expected = Data(base64Encoded: hashBase64),
              let computed = hash(password: password, salt: salt) else {
            return false
        }
        return constantTimeEquals(computed, expected)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

/// 应用锁：数字密码 / 图案密码 + 生物识别。
///
/// 密码只以 PBKDF2 哈希形式保存在本机 UserDefaults（与原项目一致），
/// 明文不会落盘，也不会进备份。
final class AppLockService: ObservableObject {
    static let shared = AppLockService()

    enum Kind {
        case number
        case pattern
    }

    @Published private(set) var isLocked = false

    private let store = SettingsStore.shared

    private init() {}

    var hasPassword: Bool {
        !store.settings.appLockNumberPassword.isEmpty || !store.settings.appLockPatternPassword.isEmpty
    }

    var biometricEnabled: Bool {
        store.settings.appLockBiometric
    }

    var lockWhenLeave: Bool {
        store.settings.lockAppWhenLeave
    }

    var biometricKind: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var biometricName: String {
        switch biometricKind {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "虹膜 ID"
        default: return "生物识别"
        }
    }

    // MARK: - 密码校验

    func verify(password: String, kind: Kind) -> Bool {
        let settings = store.settings
        switch kind {
        case .number:
            return PasswordHasher.verify(
                password: password,
                hashBase64: settings.appLockNumberPassword,
                saltBase64: settings.appLockNumberPasswordSalt
            )
        case .pattern:
            return PasswordHasher.verify(
                password: password,
                hashBase64: settings.appLockPatternPassword,
                saltBase64: settings.appLockPatternPasswordSalt
            )
        }
    }

    func setPassword(_ password: String, kind: Kind) {
        let result = PasswordHasher.makePassword(password)
        store.update { settings in
            switch kind {
            case .number:
                settings.appLockNumberPassword = result.hash
                settings.appLockNumberPasswordSalt = result.salt
            case .pattern:
                settings.appLockPatternPassword = result.hash
                settings.appLockPatternPasswordSalt = result.salt
            }
        }
        Log.info("应用锁密码已更新（\(kind == .number ? "数字" : "图案")）", .app)
    }

    func clearPassword(kind: Kind) {
        store.update { settings in
            switch kind {
            case .number:
                settings.appLockNumberPassword = ""
                settings.appLockNumberPasswordSalt = ""
            case .pattern:
                settings.appLockPatternPassword = ""
                settings.appLockPatternPasswordSalt = ""
            }
        }
    }

    // MARK: - 生物识别

    func authenticateWithBiometrics() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "使用密码"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            Log.warning("生物识别不可用：\(error?.localizedDescription ?? "unknown")", .app)
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁侠客日记"
            )
            if success { unlock() }
            return success
        } catch {
            Log.warning("生物识别失败：\(error.localizedDescription)", .app)
            return false
        }
    }

    // MARK: - 锁定状态

    func lockIfNeeded() {
        guard hasPassword else { return }
        isLocked = true
    }

    func lock() {
        isLocked = true
    }

    func unlock() {
        isLocked = false
    }
}

/// 隐私模式控制器。
///
/// 职责边界很明确：只负责「进入/退出隐私空间」与密码校验，
/// 真正的数据隔离由 `DiaryDatabase.isPrivacyMode` 在连接层完成，
/// UI 层不需要（也无法）自己拼接隐私库路径。
final class PrivacyModeController: ObservableObject {
    static let shared = PrivacyModeController()

    @Published private(set) var isActive = false
    @Published var lastError: String?

    private let store = SettingsStore.shared

    private init() {
        isActive = DiaryDatabase.shared.isPrivacyMode
    }

    var hasPassword: Bool {
        !store.settings.privacyModeEntrancePassword.isEmpty
    }

    var entranceHidden: Bool {
        store.settings.hidePrivacyModeEntrance
    }

    func setPassword(_ password: String) {
        let result = PasswordHasher.makePassword(password)
        store.update { settings in
            settings.privacyModeEntrancePassword = result.hash
            settings.privacyModeEntrancePasswordSalt = result.salt
        }
    }

    func clearPassword() {
        store.update { settings in
            settings.privacyModeEntrancePassword = ""
            settings.privacyModeEntrancePasswordSalt = ""
        }
        exit()
    }

    func verify(password: String) -> Bool {
        PasswordHasher.verify(
            password: password,
            hashBase64: store.settings.privacyModeEntrancePassword,
            saltBase64: store.settings.privacyModeEntrancePasswordSalt
        )
    }

    @discardableResult
    func enter(password: String) -> Bool {
        guard verify(password: password) else {
            lastError = "密码错误"
            return false
        }
        DiaryDatabase.shared.setPrivacyMode(true)
        isActive = true
        lastError = nil
        NotificationCenter.default.post(name: .privacyModeChanged, object: nil)
        return true
    }

    func exit() {
        DiaryDatabase.shared.setPrivacyMode(false)
        isActive = false
        NotificationCenter.default.post(name: .privacyModeChanged, object: nil)
    }
}

extension Notification.Name {
    static let privacyModeChanged = Notification.Name("diary.privacyModeChanged")
}
