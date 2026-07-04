import SwiftUI
import KeyboardShortcuts
import OsmoShell

/// Full-window onboarding takeover on first launch. Steps live in
/// OsmoShell.OnboardingModel (pure); this renders them on the cream ground.
struct OnboardingFlow: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var step: OnboardingModel.Step = .welcome
    @State private var permissionTimer: Timer?

    private let flow = OnboardingModel()

    var body: some View {
        ZStack {
            DS.Colors.cream.ignoresSafeArea()
            VStack(spacing: DS.Space.xl) {
                Spacer()
                content
                    .frame(maxWidth: 480)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                Spacer()
                footer
            }
            .padding(DS.Space.xxl)
        }
        .onDisappear { permissionTimer?.invalidate() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .hotkey: hotkey
        case .permission: permission
        case .practice: practice
        case .connect: connect
        case .finish: finish
        }
    }

    // MARK: - Screens

    private var welcome: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(DS.Colors.accent)
            Text("Every conversation, remembered.")
                .font(DS.Typography.display).multilineTextAlignment(.center)
                .foregroundStyle(DS.Colors.ink)
            Text("Osmo reads your messages across every platform, remembers each person, and drafts what to say — in your voice, toward what you want.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var hotkey: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("keyboard")
            Text("Your summon key").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Press this anywhere to bring up Osmo. ⌥Space is a good default — you can change it.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            KeyboardShortcuts.Recorder(for: .togglePill)
                .padding(.top, DS.Space.s)
        }
    }

    private var permission: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("lock.shield")
            Text("One permission").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("No screen recording. No keylogging. One permission.")
                .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                bullet("Accessibility lets the pill appear when you're writing a message")
                bullet("It reads only the field you're typing in — nothing else")
                bullet("Everything stays on your Mac")
            }
            if AXPermission.isTrusted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.green)
            } else {
                PillButton("Open System Settings") {
                    AXPermission.promptIfNeeded()
                    startPermissionPoll()
                }
            }
        }
        .onAppear { startPermissionPoll() }
    }

    private var practice: some View {
        PracticeScreen()
            .environmentObject(model)
    }

    private var connect: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("link")
            Text("Bring your conversations").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Connect a platform and Osmo pulls your history + keeps it live. iMessage stays on your Mac; the rest connect in one click.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            HStack(spacing: DS.Space.m) {
                PillButton("Connect a platform", kind: .quiet) {
                    hasOnboarded = true; model.section = .connections
                }
            }
        }
    }

    private var finish: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("checkmark.circle")
            Text("You're set").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Osmo lives in your menu bar. Press ⌥Space anywhere, or it'll appear on its own when you start writing a message.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { withAnimation(DS.Motion.expoOut) { flow.back(); step = flow.step } }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
            Spacer()
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                Circle().fill(s == step ? DS.Colors.accent : DS.Colors.hairline)
                    .frame(width: 6, height: 6)
            }
            Spacer()
            HStack(spacing: DS.Space.m) {
                if step != .finish {
                    Button("Skip") { advance(skip: true) }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                }
                PillButton(step == .finish ? "Start using Osmo" : "Continue") {
                    if step == .finish { hasOnboarded = true } else { advance(skip: false) }
                }
            }
        }
    }

    // MARK: - Helpers

    private func advance(skip: Bool) {
        withAnimation(DS.Motion.expoOut) {
            if skip { flow.skip() } else { flow.advance() }
            step = flow.step
            if flow.completed { hasOnboarded = true }
        }
    }

    private func startPermissionPoll() {
        permissionTimer?.invalidate()
        permissionTimer = AXPermission.poll {
            // Auto-advance shortly after the green check shows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if step == .permission { advance(skip: false) }
            }
        }
    }

    private func stepIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 32)).foregroundStyle(DS.Colors.accent)
    }
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.accent)
                .padding(.top, 3)
            Text(text).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
        }
    }
}

/// The aha: a fake compose box that summons the REAL pill with a canned thread.
struct PracticeScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var typed = ""

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Text("Try it right now").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack { AvatarView(name: "Sam", size: 28); Text("Sam").font(DS.Typography.bodyEm); Spacer() }
                    Text("hey — are we still on for friday?")
                        .font(DS.Typography.body)
                        .padding(DS.Space.s)
                        .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                    TextField("Type a reply and press ⌥Space…", text: $typed)
                        .textFieldStyle(.plain).font(DS.Typography.body)
                        .padding(DS.Space.s)
                        .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).stroke(DS.Colors.hairline, lineWidth: 1))
                        .onChange(of: typed) { _, value in
                            if !value.isEmpty { PillController.shared.showPractice(partnerName: "Sam") }
                        }
                }
            }
            Text("Osmo appears with three ways to reply — send, tweak, or ignore. It works in every app.")
                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
        }
    }
}
