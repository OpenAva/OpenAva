import SwiftUI
import UIKit

@MainActor
class SkillListPopoverController: UIViewController {
    let items: [QuickSettingItem]
    let onSelect: (QuickSettingItem) -> Void
    let onDismiss: () -> Void

    init(items: [QuickSettingItem], onSelect: @escaping (QuickSettingItem) -> Void, onDismiss: @escaping () -> Void) {
        self.items = items
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .popover
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let hostingController = UIHostingController(rootView: SkillListPopoverView(
            items: items,
            onSelect: { [weak self] item in
                self?.dismiss(animated: true) {
                    self?.onSelect(item)
                }
            }
        ))

        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss()
    }
}

private struct SkillListPopoverView: View {
    let items: [QuickSettingItem]
    let onSelect: (QuickSettingItem) -> Void
    @State private var searchText = ""
    @State private var hoveredItemID: String?
    @State private var selectedItemID: String?
    @FocusState private var isSearchFocused: Bool

    var filteredItems: [QuickSettingItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty { return items }
        return items.filter { item in
            switch item {
            case let .skill(_, title, _, _, _), let .command(_, title, _, _):
                return title.localizedCaseInsensitiveContains(keyword)
            default:
                return false
            }
        }
    }

    private var activeItemID: String? {
        hoveredItemID ?? selectedItemID ?? filteredItems.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchBar(searchText: $searchText, isFocused: $isSearchFocused) {
                submitCurrentSelection()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)

            if filteredItems.isEmpty {
                SkillListEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredItems, id: \.id) { item in
                            Button {
                                selectedItemID = item.id
                                onSelect(item)
                            } label: {
                                SkillCommandRow(
                                    item: item,
                                    isActive: activeItemID == item.id,
                                    onHoverChanged: { isHovering in
                                        if isHovering {
                                            hoveredItemID = item.id
                                            selectedItemID = item.id
                                        } else if hoveredItemID == item.id {
                                            hoveredItemID = nil
                                        }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .onAppear {
            syncSelection()
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _ in
            syncSelection()
        }
    }

    private func syncSelection() {
        if filteredItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = filteredItems.first?.id
    }

    private func submitCurrentSelection() {
        guard let currentID = activeItemID,
              let item = filteredItems.first(where: { $0.id == currentID }) ?? filteredItems.first
        else { return }
        onSelect(item)
    }
}

private struct SearchBar: View {
    @Binding var searchText: String
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Color(uiColor: .secondaryLabel))

            TextField(String.localized("搜索技能"), text: $searchText)
                .focused($isFocused)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(uiColor: .label))
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit(onSubmit)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(uiColor: .tertiaryLabel))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
    }
}

private struct SkillCommandRow: View {
    let item: QuickSettingItem
    let isActive: Bool
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            SkillCommandIcon(item: item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }

            Spacer()

            if isActive {
                Text("↵")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.62))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.black.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Color.black.opacity(0.05) : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: isActive)
        .onHover(perform: onHoverChanged)
    }
}

private struct SkillCommandIcon: View {
    let item: QuickSettingItem

    var body: some View {
        Group {
            if let emoji = item.emojiIcon {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))

                    Text(emoji)
                        .font(.system(size: 17))
                        .lineLimit(1)
                }
            } else if let iconName = item.nonEmojiIconName,
                      let uiImage = UIImage.chatInputIcon(named: iconName)
            {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))

                    Image(uiImage: uiImage)
                        .renderingMode(uiImage.renderingMode == .alwaysOriginal ? .original : .template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundColor(Color(uiColor: .label))
                }
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                    }
            }
        }
        .frame(width: 28, height: 28)
    }
}

private struct SkillListEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Color(uiColor: .secondaryLabel))

            Text(String.localized("未找到匹配的技能"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(uiColor: .secondaryLabel))

            Text(String.localized("试试其他关键词"))
                .font(.system(size: 12))
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension QuickSettingItem {
    var title: String {
        switch self {
        case let .skill(_, title, _, _, _), let .command(_, title, _, _): return title
        default: return ""
        }
    }

    var iconName: String? {
        switch self {
        case let .skill(_, _, icon, _, _), let .command(_, _, icon, _): return icon
        default: return nil
        }
    }

    var emojiIcon: String? {
        guard let iconName, iconName.containsEmoji else { return nil }
        return iconName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmojiIconName: String? {
        guard let iconName else { return nil }
        return iconName.containsEmoji ? nil : iconName
    }

    var subtitle: String {
        switch self {
        case let .skill(id, _, _, _, autoSubmit):
            let slug = id.replacingOccurrences(of: "skill-", with: "")
            return autoSubmit ? "/\(slug) · 自动执行" : "/\(slug)"
        case let .command(_, _, _, command):
            return command
        default:
            return String.localized("可立即使用")
        }
    }
}

private extension String {
    var containsEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
        }
    }
}
