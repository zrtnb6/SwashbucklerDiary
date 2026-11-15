import SwiftUI

/// 应用锁界面：数字密码 / 图案密码 / 生物识别。
struct LockScreenView: View {
    @ObservedObject private var lockService = AppLockService.shared
    @ObservedObject private var settingsStore = SettingsStore.shared

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var shake = false
    @State private var usePattern = false
    @State private var didTryBiometrics = false

    private var hasNumberPassword: Bool {
        !settingsStore.settings.appLockNumberPassword.isEmpty
    }

    private var hasPatternPassword: Bool {
        !settingsStore.settings.appLockPatternPassword.isEmpty
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.accentSoft))
                    Text("侠客日记已锁定")
                        .font(.title3.weight(.semibold))
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text(usePattern ? "绘制解锁图案" : "输入解锁密码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if usePattern {
                    PatternLockView { sequence in
                        verify(sequence)
                    }
                    .frame(width: 260, height: 260)
                } else {
                    passcodeDots
                    numberPad
                }

                Spacer(minLength: 12)

                HStack(spacing: 18) {
                    if lockService.biometricEnabled {
                        Button {
                            Task { await tryBiometrics() }
                        } label: {
                            Label(lockService.biometricName, systemImage: biometricSymbol)
                                .font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    if hasNumberPassword && hasPatternPassword {
                        Button(usePattern ? "使用数字密码" : "使用图案密码") {
                            usePattern.toggle()
                            input = ""
                            errorMessage = nil
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 24)
            }
            .offset(x: shake ? -8 : 0)
        }
        .task {
            guard !didTryBiometrics, lockService.biometricEnabled else { return }
            didTryBiometrics = true
            await tryBiometrics()
        }
        .onAppear {
            usePattern = !hasNumberPassword && hasPatternPassword
        }
    }

    private var biometricSymbol: String {
        switch lockService.biometricKind {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.open"
        }
    }

    // MARK: 数字密码

    private var passcodeDots: some View {
        HStack(spacing: 16) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.4)
                    .background(
                        Circle().fill(index < input.count ? Theme.accent : Color.clear)
                    )
                    .frame(width: 14, height: 14)
            }
        }
    }

    private var numberPad: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(1..<4, id: \.self) { column in
                        numberButton("\(row * 3 + column)")
                    }
                }
            }
            HStack(spacing: 20) {
                Color.clear.frame(width: 68, height: 68)
                numberButton("0")
                Button {
                    guard !input.isEmpty else { return }
                    input.removeLast()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 20))
                        .frame(width: 68, height: 68)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func numberButton(_ digit: String) -> some View {
        Button {
            guard input.count < 12 else { return }
            input.append(digit)
            Haptics.light()
            if input.count >= 4 {
                // 4 位及以上时自动尝试校验；密码长度未知，所以每加一位都试一次
                verify(input)
            }
        } label: {
            Text(digit)
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .frame(width: 68, height: 68)
                .background(Circle().fill(Theme.subtleFill))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 校验

    private func verify(_ value: String) {
        let kind: AppLockService.Kind = usePattern ? .pattern : .number
        if lockService.verify(password: value, kind: kind) {
            Haptics.success()
            withAnimation(.snappy) { lockService.unlock() }
            input = ""
        } else {
            Haptics.error()
            errorMessage = "密码错误，请重试"
            withAnimation(.default) { shake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.default) { shake = false }
            }
            input = ""
        }
    }

    private func tryBiometrics() async {
        let success = await lockService.authenticateWithBiometrics()
        if success {
            Haptics.success()
            await MainActor.run {
                withAnimation(.snappy) { lockService.unlock() }
            }
        }
    }
}

/// 3×3 图案锁。支持连续拖动，松手即校验。
struct PatternLockView: View {
    var onComplete: (String) -> Void

    @State private var selected: [Int] = []
    @State private var currentPoint: CGPoint = .zero
    @State private var isDragging = false

    private let columns = 3
    private let gridSize: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let spacing = size / CGFloat(gridSize + 1)
            let radius: CGFloat = 10

            ZStack {
                // 连线
                Path { path in
                    guard !selected.isEmpty else { return }
                    for (index, item) in selected.enumerated() {
                        let point = center(for: item, spacing: spacing, origin: .zero)
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                    if isDragging, !selected.isEmpty {
                        path.addLine(to: currentPoint)
                    }
                }
                .stroke(Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

                ForEach(0..<9, id: \.self) { index in
                    let point = center(for: index, spacing: spacing, origin: .zero)
                    Circle()
                        .fill(selected.contains(index) ? Theme.accent : Theme.subtleFill)
                        .frame(width: radius * 2.6, height: radius * 2.6)
                        .overlay(
                            Circle().strokeBorder(Theme.accent.opacity(selected.contains(index) ? 1 : 0.35), lineWidth: 1.2)
                        )
                        .position(point)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        currentPoint = value.location
                        if let hit = hitTest(value.location, spacing: spacing), !selected.contains(hit) {
                            selected.append(hit)
                            Haptics.light()
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        defer {
                            selected = []
                            currentPoint = .zero
                        }
                        guard selected.count >= 4 else {
                            if !selected.isEmpty { Haptics.error() }
                            return
                        }
                        onComplete(selected.map(String.init).joined(separator: "-"))
                    }
            )
        }
    }

    private func center(for index: Int, spacing: CGFloat, origin: CGPoint) -> CGPoint {
        let row = index / columns
        let column = index % columns
        return CGPoint(
            x: spacing * CGFloat(column + 1) + origin.x,
            y: spacing * CGFloat(row + 1) + origin.y
        )
    }

    private func hitTest(_ location: CGPoint, spacing: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<9 {
            let point = center(for: index, spacing: spacing, origin: .zero)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance <= spacing * 0.42 {
                if best == nil || distance < best!.distance {
                    best = (index, distance)
                }
            }
        }
        return best?.index
    }
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
