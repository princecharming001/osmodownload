import SwiftUI
import OsmoCore
import OsmoBrain

/// "You" — the Wispr-Flow-style texting persona: a written narrative, the raw
/// numbers, how you differ by platform, and the phrases that are distinctly
/// yours. Same layout grammar as Today (scrolling stack of cards, an eyebrow
/// per section) — this is a mirror pointed at the user instead of at them.
struct YouView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                if model.voiceStats.isEmpty {
                    EmptyStateView(icon: "person.crop.circle",
                                   title: "Not enough sent messages yet",
                                   message: "Once you've sent a few messages across your connected platforms, Osmo reads your own texting voice here.")
                } else {
                    personaCard
                    statGrid
                    if model.voiceStats.perPlatform.count > 1 { platformComparison }
                    soundChips
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { model.ensureVoiceStats(); model.ensureVoicePersona() }
        .onChange(of: model.dataVersion) { _, _ in model.ensureVoiceStats() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow("Your voice")
            Text("You").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
            Text("How you actually text — read from your own sent messages, not a generic style guide.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
        }
    }

    // MARK: Persona

    private var personaCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack {
                    Eyebrow("Your persona")
                    Spacer()
                    Button {
                        model.ensureVoicePersona(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                    .accessibilityLabel("Refresh your persona")
                }
                ForEach(Array(personaParagraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Live/cached AI narrative when available (Pro + live key); otherwise the
    /// deterministic, always-honest fallback — never blank.
    private var personaParagraphs: [String] {
        model.voicePersona?.paragraphs ?? VoicePersona.fallback(model.voiceStats).paragraphs
    }

    // MARK: Stats

    private var statGrid: some View {
        let stats = model.voiceStats
        let items: [(String, String, String)] = [
            ("bubble.left.fill", "Sent", "\(stats.overall.msgCount)"),
            ("text.alignleft", "Avg length", "\(stats.overall.avgWords) words"),
            ("bolt.fill", "Reply speed", stats.medianReplySeconds.map(PartnerProfile.humanGap) ?? "—"),
            ("clock.fill", "Most active", stats.activeBlock ?? "—"),
            ("face.smiling.fill", "Emoji rate", "\(Int(stats.overall.emojiRate * 100))%"),
            ("textformat", "Lowercase", "\(Int(stats.overall.lowercaseShare * 100))%"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.m), count: 3),
                         spacing: DS.Space.m) {
            ForEach(items, id: \.1) { icon, label, value in
                statCard(icon: icon, label: label, value: value)
            }
        }
    }

    private func statCard(icon: String, label: String, value: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(DS.Colors.accent)
                Text(value).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                Text(label).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Per-platform

    /// Formal on LinkedIn, lowercase on iMessage — made visible, not just felt.
    private var platformComparison: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Eyebrow("How you adapt by platform")
            Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                GridRow {
                    Text("").frame(width: 90, alignment: .leading)
                    Text("Avg words").font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                    Text("Lowercase").font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                    Text("Emoji").font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                }
                ForEach(sortedPlatforms, id: \.self) { platform in
                    if let sub = model.voiceStats.perPlatform[platform] {
                        GridRow {
                            HStack(spacing: 4) {
                                Image(systemName: platform.symbolName).font(.system(size: 9))
                                    .foregroundStyle(platform.tint)
                                Text(platform.displayName).font(DS.Typography.caption)
                                    .foregroundStyle(DS.Colors.ink)
                            }
                            Text("\(sub.avgWords)").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                            Text("\(Int(sub.lowercaseShare * 100))%").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                            Text("\(Int(sub.emojiRate * 100))%").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                        }
                    }
                }
            }
            .padding(DS.Space.l)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        }
    }

    private var sortedPlatforms: [Platform] {
        model.voiceStats.perPlatform.keys.sorted { $0.displayName < $1.displayName }
    }

    // MARK: Chips

    @ViewBuilder private var soundChips: some View {
        if !model.voiceChips.isEmpty || !model.voiceStats.topPhrases.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !model.voiceChips.isEmpty {
                    Eyebrow("How you sound to others")
                    FlowLayout(spacing: 6) {
                        ForEach(model.voiceChips, id: \.self) { chip in
                            Chip(chip)
                        }
                    }
                }
                if !model.voiceStats.topPhrases.isEmpty {
                    Eyebrow("Signature phrases").padding(.top, model.voiceChips.isEmpty ? 0 : DS.Space.s)
                    FlowLayout(spacing: 6) {
                        ForEach(model.voiceStats.topPhrases, id: \.self) { phrase in
                            Text("\u{201c}\(phrase)\u{201d}")
                                .font(DS.Typography.eyebrow)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(DS.Colors.ink)
                                .background(DS.Colors.chip, in: Capsule())
                        }
                    }
                }
            }
        }
    }
}
