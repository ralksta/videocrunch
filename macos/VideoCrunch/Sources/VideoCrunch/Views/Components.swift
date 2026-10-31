import AppKit
import SwiftUI

func videoCount(_ n: Int) -> String {
    n == 1 ? "1 Video" : "\(n) Videos"
}

// MARK: - Option building blocks

/// Grouped card surface, the way System Settings draws its sections.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}

/// A titled group of options.
struct OptionSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content
        }
    }
}

/// Icon tile, title and explanation on the left, a control on the right.
struct SettingRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// macOS Visual Effect View for native blur
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Shared building blocks

/// Big round icon, title and explanation — for waiting, empty, error and done states.
struct StatusHero<Accessory: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String?
    var compact: Bool = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: compact ? 60 : 76, height: compact ? 60 : 76)
                Image(systemName: icon)
                    .font(.system(size: compact ? 26 : 32, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.title2.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }
            accessory
                .padding(.top, 4)
        }
        .padding(compact ? 8 : 32)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
    }
}

/// Small rounded label for codec, resolution, counts.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.75) : tint)
    }
}

/// Share of a file the encode is expected to save.
struct SavingsBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.green.gradient)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

/// A labelled number in the summary row.
struct StatTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }
}

func codecName(_ codec: String) -> String {
    codec == "av1" ? "AV1" : "HEVC"
}
