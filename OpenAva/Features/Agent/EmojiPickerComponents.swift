import ChatUI
import SwiftUI

enum EmojiPickerCatalog {
    static let candidates = [
        "🤖", "🦊", "🐼", "🦉", "🐙", "🐬", "🦄", "🐝", "🐧", "🦁",
        "🐯", "🐸", "🐵", "🦋", "🐲", "🦖", "🦕", "🐢", "🐳", "🐺",
        "😄", "😎", "🙂", "🤩", "🥳", "🧠", "💡", "✨", "🔥", "⚡️",
        "🌈", "☀️", "🌙", "⭐️", "🌊", "🍀", "🍎", "🍉", "🍵", "☕️",
        "🎯", "🎨", "🎧", "🎬", "🎮", "🧩", "🛠️", "📚", "📝", "📎",
        "🧭", "🛰️", "🔭", "🧪", "🔬", "📡", "🖥️", "💻", "⌨️", "🖱️",
        "📱", "🕹️", "🛸", "🚀", "🗺️", "🏔️", "🌋", "🌲", "🌸", "🌻",
        "🦀", "🐋", "🐅", "🦓", "🦒", "🦥", "🦦", "🦔", "🐿️", "🦜",
    ]

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EmojiSelectionControl: View {
    let emoji: String
    let onPick: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPick) {
                Text(emoji)
                    .font(.system(size: 20))
                    .frame(width: 34, height: 34)
                    .background(Color(uiColor: ChatUIDesign.Color.warmCream), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))
                    .frame(width: 34, height: 34)
                    .background(Color(uiColor: ChatUIDesign.Color.warmCream), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

struct EmojiPickerGrid: View {
    let emojis: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("agent.creation.emojiPicker.choose", emoji))
                }
            }
            .padding()
        }
    }
}
