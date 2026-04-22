import ChatUI
import SwiftUI

enum EmojiPickerCatalog {
    static let candidates: [String] = {
        // Put likely Agent avatars first, then append a broader Unicode-derived catalog.
        var result: [String] = preferredCandidates
        var seen = Set<String>()

        for emoji in result {
            seen.insert(normalized(emoji))
        }

        func appendEmojiScalars(in range: ClosedRange<UInt32>) {
            for value in range {
                guard let scalar = UnicodeScalar(value) else { continue }

                // Skip scalars that are only useful inside emoji sequences.
                if value == 0x200D { continue } // ZWJ
                if (0xFE00 ... 0xFE0F).contains(value) { continue } // variation selectors

                let props = scalar.properties

                // Prefer characters that default to emoji presentation to avoid pulling in lots of
                // "text-looking" symbols that require VS16. Still include some key emoji blocks below.
                guard props.isEmojiPresentation || props.isEmoji else { continue }

                // Exclude skin tone modifiers; keep bases and standalone emoji.
                if props.isEmojiModifier { continue }

                let emoji = String(scalar)
                let key = normalized(emoji)
                if seen.insert(key).inserted {
                    result.append(emoji)
                }
            }
        }

        // Main emoji blocks (rough but effective coverage).
        appendEmojiScalars(in: 0x2300 ... 0x23FF) // Misc technical symbols
        appendEmojiScalars(in: 0x2600 ... 0x26FF) // Misc symbols
        appendEmojiScalars(in: 0x2700 ... 0x27BF) // Dingbats
        appendEmojiScalars(in: 0x1F300 ... 0x1F5FF) // Misc symbols & pictographs
        appendEmojiScalars(in: 0x1F600 ... 0x1F64F) // Emoticons
        appendEmojiScalars(in: 0x1F680 ... 0x1F6FF) // Transport & map
        appendEmojiScalars(in: 0x1F700 ... 0x1F77F) // Alchemical symbols (some appear as emoji)
        appendEmojiScalars(in: 0x1F780 ... 0x1F7FF) // Geometric shapes extended
        appendEmojiScalars(in: 0x1F800 ... 0x1F8FF) // Supplemental arrows-C
        appendEmojiScalars(in: 0x1F900 ... 0x1F9FF) // Supplemental symbols & pictographs
        appendEmojiScalars(in: 0x1FA00 ... 0x1FAFF) // Symbols & pictographs extended-A

        // A small set of common flags (ASCII escapes, so no source encoding risk).
        let commonFlags: [String] = [
            "\u{1F1FA}\u{1F1F8}", // US
            "\u{1F1E8}\u{1F1F3}", // CN
            "\u{1F1EF}\u{1F1F5}", // JP
            "\u{1F1F0}\u{1F1F7}", // KR
            "\u{1F1EC}\u{1F1E7}", // GB
            "\u{1F1EB}\u{1F1F7}", // FR
            "\u{1F1E9}\u{1F1EA}", // DE
            "\u{1F1EE}\u{1F1F9}", // IT
            "\u{1F1EA}\u{1F1F8}", // ES
            "\u{1F1E8}\u{1F1E6}", // CA
            "\u{1F1E6}\u{1F1FA}", // AU
            "\u{1F1E7}\u{1F1F7}", // BR
            "\u{1F1EE}\u{1F1F3}", // IN
            "\u{1F1F2}\u{1F1FD}", // MX
            "\u{1F1F8}\u{1F1EC}", // SG
            "\u{1F1ED}\u{1F1F0}", // HK
            "\u{1F1F9}\u{1F1FC}", // TW
        ]
        for flag in commonFlags {
            let key = normalized(flag)
            if seen.insert(key).inserted {
                result.append(flag)
            }
        }

        return result
    }()

    static let preferredCandidates: [String] = [
        "\u{1F916}", // robot
        "\u{1F4BB}", // laptop
        "\u{1F9E0}", // brain
        "\u{2728}", // sparkles
        "\u{1F6E0}\u{FE0F}", // hammer and wrench
        "\u{1F4DA}", // books
        "\u{1F50D}", // magnifying glass
        "\u{1F9EA}", // test tube
        "\u{1F4DD}", // memo
        "\u{1F3AF}", // bullseye
        "\u{2699}\u{FE0F}", // gear
        "\u{1F4CE}", // paperclip
        "\u{1F9ED}", // compass
        "\u{1F52C}", // microscope
        "\u{1F4E1}", // satellite antenna
        "\u{1F680}", // rocket
        "\u{1F4A1}", // light bulb
        "\u{1F3A8}", // palette
        "\u{1F3A7}", // headphones
        "\u{1F3AC}", // clapper board
        "\u{1F9E9}", // puzzle piece
        "\u{1F4F1}", // mobile phone
        "\u{1F5A5}\u{FE0F}", // desktop computer
        "\u{1F4F0}", // newspaper
        "\u{1F30D}", // globe
        "\u{1F50C}", // electric plug
        "\u{1F525}", // fire
        "\u{26A1}\u{FE0F}", // high voltage
        "\u{1F436}", // dog
        "\u{1F98A}", // fox
        "\u{1F43C}", // panda
        "\u{1F989}", // owl
        "\u{1F419}", // octopus
        "\u{1F42C}", // dolphin
        "\u{1F984}", // unicorn
        "\u{1F41D}", // bee
        "\u{1F427}", // penguin
        "\u{1F981}", // lion
        "\u{1F42F}", // tiger face
        "\u{1F438}", // frog
        "\u{1F435}", // monkey face
        "\u{1F60E}", // smiling face with sunglasses
        "\u{1F929}", // star-struck
        "\u{1F973}", // partying face
        "\u{1F31F}", // glowing star
    ]

    static func normalized(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
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
