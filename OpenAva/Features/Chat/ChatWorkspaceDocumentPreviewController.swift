import ChatUI
import Foundation
import MarkdownParser
import MarkdownView
import UIKit

@MainActor
final class ChatWorkspaceDocumentPreviewController: UIViewController {
    var onCloseRequested: (() -> Void)?

    private let fileURL: URL?
    private let fallbackText: String
    private let previewTitle: String
    private let theme: MarkdownTheme
    private let parser = MarkdownParser()

    private lazy var headerView: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        return view
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 1
        label.text = previewTitle
        return label
    }()

    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.text = fileURL?.path
        return label
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        button.tintColor = .secondaryLabel
        button.addAction(UIAction { [weak self] _ in
            self?.handleCloseTapped()
        }, for: .touchUpInside)
        return button
    }()

    private lazy var markdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.backgroundColor = .systemBackground
        view.throttleInterval = 1 / 60
        return view
    }()

    private lazy var emptyStateLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    init(title: String, fileURL: URL?, fallbackText: String, theme: MarkdownTheme) {
        self.fileURL = fileURL
        self.fallbackText = fallbackText
        self.previewTitle = title.isEmpty ? (fileURL?.lastPathComponent ?? String.localized("Document Preview")) : title
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(headerView)
        headerView.addSubview(titleLabel)
        headerView.addSubview(subtitleLabel)
        headerView.addSubview(closeButton)
        view.addSubview(markdownView)
        view.addSubview(emptyStateLabel)

        renderDocument()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let safeBounds = view.bounds.inset(by: view.safeAreaInsets)
        let headerHeight: CGFloat = 56
        headerView.frame = CGRect(x: 0, y: safeBounds.minY, width: view.bounds.width, height: headerHeight)

        let closeSize: CGFloat = 28
        closeButton.frame = CGRect(
            x: headerView.bounds.width - 16 - closeSize,
            y: (headerHeight - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )

        let titleMaxWidth = max(120, closeButton.frame.minX - 28)
        titleLabel.frame = CGRect(x: 16, y: 10, width: titleMaxWidth, height: 20)
        subtitleLabel.frame = CGRect(x: 16, y: 30, width: titleMaxWidth, height: 16)

        let contentY = headerView.frame.maxY + 1
        let contentHeight = max(0, safeBounds.maxY - contentY)
        markdownView.frame = CGRect(x: 0, y: contentY, width: view.bounds.width, height: contentHeight)
        emptyStateLabel.frame = CGRect(x: 24, y: contentY + 24, width: view.bounds.width - 48, height: 88)
    }

    private func renderDocument() {
        let content = loadContent().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            markdownView.isHidden = true
            emptyStateLabel.isHidden = false
            emptyStateLabel.text = String.localized("Unable to preview this document.")
            return
        }

        let parserResult = parser.parse(content)
        let package = MarkdownTextView.PreprocessedContent(parserResult: parserResult, theme: theme)
        markdownView.setMarkdown(package)
        markdownView.isHidden = false
        emptyStateLabel.isHidden = true
    }

    private func loadContent() -> String {
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let content = String(data: data, encoding: .utf8)
        {
            return content
        }
        return fallbackText
    }

    private func handleCloseTapped() {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            dismiss(animated: true)
        }
    }
}
