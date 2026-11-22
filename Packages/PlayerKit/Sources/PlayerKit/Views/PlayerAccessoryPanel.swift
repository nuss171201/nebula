import SwiftUI

/// The side panel the app supplies, in the same frame as the player's own panels.
struct PlayerAccessoryPanel: View {
    let accessory: PlayerAccessory
    let chrome: PlayerChromeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(accessory.title)
                    .font(.headline)
                Spacer()
                Button {
                    chrome.isAccessoryVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close \(accessory.title)")
            }
            .padding(12)

            Divider()

            accessory.content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: PlayerSettingsPanel.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .controlSize(.small)
    }
}

/// The control bar's button for the app's panel, with a count on it when there is something new.
struct AccessoryButton: View {
    let accessory: PlayerAccessory
    let chrome: PlayerChromeModel

    var body: some View {
        Button {
            chrome.isAccessoryVisible.toggle()
        } label: {
            Image(systemName: accessory.systemImage)
                .overlay(alignment: .topTrailing) {
                    if chrome.accessoryBadge > 0, !chrome.isAccessoryVisible {
                        Text(chrome.accessoryBadge > 99 ? "99+" : "\(chrome.accessoryBadge)")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 9, y: -7)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(accessory.title)
        .accessibilityValue(chrome.accessoryBadge > 0 ? "\(chrome.accessoryBadge) new" : "")
        .help(accessory.title)
    }
}
