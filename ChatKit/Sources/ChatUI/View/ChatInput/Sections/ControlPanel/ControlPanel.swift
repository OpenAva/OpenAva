//
//  ControlPanel.swift
//  ChatUI
//

import Combine
import UIKit

final class ControlPanel: EditorSectionView {
    let isPanelOpen: CurrentValueSubject<Bool, Never> = .init(false)

    let buttonHeight: CGFloat = 56
    let buttonSpacing: CGFloat = 10
    let topPadding: CGFloat = 8

    private var buttonViews: [GiantButton] = []
    private var items: [ControlPanelItem] = []

    weak var delegate: Delegate?

    override func initializeViews() {
        super.initializeViews()

        isPanelOpen
            .removeDuplicates()
            .ensureMainThread()
            .sink { [weak self] input in
                guard let self else { return }
                heightPublisher.send(input ? buttonHeight + topPadding : 0)
                if input {
                    delegate?.onControlPanelOpen()
                } else {
                    delegate?.onControlPanelClose()
                }
            }
            .store(in: &cancellables)
    }

    func configure(with items: [ControlPanelItem]) {
        self.items = items

        for view in buttonViews {
            view.removeFromSuperview()
        }
        buttonViews.removeAll()

        for item in items {
            let button = GiantButton(title: item.title, icon: item.icon)
            button.alpha = 0
            button.actionBlock = { [weak self] in
                guard let self else { return }
                switch item.id {
                case "camera":
                    delegate?.onControlPanelCameraButtonTapped()
                case "photo":
                    delegate?.onControlPanelPickPhotoButtonTapped()
                case "file":
                    delegate?.onControlPanelPickFileButtonTapped()
                case "web":
                    delegate?.onControlPanelRequestWebScrubber()
                default:
                    item.action()
                }
                close()
            }
            addSubview(button)
            buttonViews.append(button)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard !buttonViews.isEmpty else { return }

        let horizontalInset: CGFloat = 14
        let availableWidth = bounds.width - horizontalInset * 2
        let buttonWidth = ceil(availableWidth + buttonSpacing) / CGFloat(buttonViews.count) - buttonSpacing

        for (idx, view) in buttonViews.enumerated() {
            view.frame = .init(
                x: horizontalInset + CGFloat(idx) * (buttonWidth + buttonSpacing),
                y: topPadding,
                width: buttonWidth,
                height: buttonHeight
            )
            view.alpha = isPanelOpen.value ? 1 : 0
        }
    }

    func toggle() {
        doEditorLayoutAnimation { [self] in isPanelOpen.send(!isPanelOpen.value) }
    }

    func close() {
        guard isPanelOpen.value else { return }
        toggle()
    }
}
