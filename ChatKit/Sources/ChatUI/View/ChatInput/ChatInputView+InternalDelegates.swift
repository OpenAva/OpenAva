//
//  ChatInputView+InternalDelegates.swift
//  ChatUI
//

import Foundation
import PDFKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - InputEditor.Delegate

extension ChatInputView: InputEditor.Delegate {
    func onInputEditorCaptureButtonTapped() {
        openCamera()
    }

    func onInputEditorPickAttachmentTapped() {
        openFilePicker()
    }

    func onInputEditorContextButtonTapped() {
        // Trigger the context usage command usually from QuickSettingBar
        delegate?.chatInputDidTriggerCommand(self, command: "/context")
    }

    func onInputEditorMicButtonTapped() {
        presentSpeechRecognition()
    }

    func onInputEditorStopVoiceRecordingTapped() {
        stopInlineSpeechRecognition(applyTranscript: true)
    }

    func onInputEditorCancelVoiceRecordingTapped() {
        stopInlineSpeechRecognition(applyTranscript: false)
    }

    func onInputEditorToggleMoreButtonTapped() {
        endEditing(true)
        controlPanel.toggle()
    }

    func onInputEditorPasteAsAttachmentTapped() {
        guard importPasteboardContentAsAttachment() else {
            delegate?.chatInputDidReportError(self, error: String.localized("Unsupported format."))
            return
        }
    }

    func onInputEditorSubmitButtonTapped() {
        let object = collectObject()
        if object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, object.attachments.isEmpty {
            return
        }
        submitValues()
    }

    func onInputEditorStopButtonTapped() {
        delegate?.chatInputDidRequestStop(self)
    }

    func onInputEditorBeginEditing() {
        controlPanel.close()
    }

    func onInputEditorEndEditing() {
        publishNewEditorStatus()
    }

    func onInputEditorPastingLargeTextAsDocument(content: String) {
        insertTextAttachment(content: content, preferredName: nil)
    }

    func onInputEditorPastingImage(image: UIImage) {
        process(image: image)
    }

    func onInputEditorTextChanged(text: String) {
        dropColorView.alpha = 0
        publishNewEditorStatus()
        guard text.isEmpty else { return }
        controlPanel.close()
    }
}

// MARK: - AttachmentsBar.Delegate

extension ChatInputView: AttachmentsBar.Delegate {
    func attachmentBarDidUpdateAttachments(_: [AttachmentsBar.Item]) {
        publishNewEditorStatus()
    }
}

// MARK: - QuickSettingBar.Delegate

extension ChatInputView: QuickSettingBar.Delegate {
    func quickSettingBarOnValueChanged() {
        publishNewEditorStatus()
    }

    func quickSettingBarDidTriggerCommand(_ command: String) {
        delegate?.chatInputDidTriggerCommand(self, command: command)
    }

    func quickSettingBarDidTriggerSkill(prompt: String, autoSubmit: Bool) {
        delegate?.chatInputDidTriggerSkill(self, prompt: prompt, autoSubmit: autoSubmit)
        guard autoSubmit else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        refill(withText: trimmed, attachments: [])
        submitValues()
    }
}

// MARK: - ControlPanel.Delegate

extension ChatInputView: ControlPanel.Delegate {
    func onControlPanelOpen() {
        quickSettingBar.hide()
        inputEditor.isControlPanelOpened = true
    }

    func onControlPanelClose() {
        quickSettingBar.show()
        inputEditor.isControlPanelOpened = false
    }

    func onControlPanelCameraButtonTapped() {
        openCamera()
    }

    func onControlPanelPickPhotoButtonTapped() {
        openPhotoPicker()
    }

    func onControlPanelPickFileButtonTapped() {
        openFilePicker()
    }

    func onControlPanelRequestWebScrubber() {}
}

// MARK: - Speech Recognition

extension ChatInputView {
    func presentSpeechRecognition() {
        guard voiceRecognitionSession == nil else { return }

        inputEditor.beginVoiceRecording()
        let session = SpeechRecognitionSession()
        voiceRecognitionSession = session
        session.onTranscriptUpdate = { [weak self] transcript in
            self?.inputEditor.updateVoiceTranscript(transcript)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await session.start()
            } catch {
                self.stopInlineSpeechRecognition(applyTranscript: false)
                self.delegate?.chatInputDidReportError(self, error: error.localizedDescription)
            }
        }
    }

    func stopInlineSpeechRecognition(applyTranscript: Bool) {
        voiceRecognitionSession?.stop()
        voiceRecognitionSession = nil

        let transcript = inputEditor.finishVoiceRecording(applyTranscript: applyTranscript)

        // Since InputEditor now handles merging the text, we don't need to append the transcript again here.
        // We just need to trigger a UI update and refocus if applyTranscript is true.
        if applyTranscript {
            // We ensure we read the finalized merged text from InputEditor
            let finalMergedText = inputEditor.textView.text ?? ""
            inputEditor.set(text: finalMergedText)
            inputEditor.textView.becomeFirstResponder()
        }
    }
}

// MARK: - Camera / Photo / File Pickers

extension ChatInputView {
    func openCamera() {
        guard let parent = parentViewController else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            delegate?.chatInputDidReportError(self, error: String.localized("Camera is not available, please grant camera permission"))
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        picker.allowsEditing = false
        picker.mediaTypes = ["public.image"]
        parent.present(picker, animated: true)
    }

    func openPhotoPicker() {
        guard let parent = parentViewController else { return }
        var config = PHPickerConfiguration()
        config.selectionLimit = 4
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        parent.present(picker, animated: true)
    }

    func openFilePicker() {
        guard let parent = parentViewController else { return }
        let supportedTypes: [UTType] = [.data, .image, .text, .plainText, .pdf, .audio]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        parent.present(picker, animated: true)
    }
}

// MARK: - File Processing

extension ChatInputView {
    func process(image: UIImage) {
        guard let compressed = image.prepareAttachment(compressImage: configuration.compressImage) else {
            delegate?.chatInputDidReportError(self, error: String.localized("Failed to process image."))
            return
        }
        let storageFilename = storage.makeUniqueFilenameStem() + ".jpeg"
        let destinationURL = storage.fileURL(for: storageFilename)
        do {
            try? FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destinationURL)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            try compressed.write(to: destinationURL)
        } catch {
            delegate?.chatInputDidReportError(self, error: String.localized("Failed to process image."))
            return
        }
        let attachment = ChatInputAttachment(
            type: .image,
            name: String.localized("Image"),
            previewImageData: image.jpeg(.medium) ?? Data(),
            fileData: compressed,
            storageFilename: storageFilename
        )
        attachmentsBar.insert(item: attachment)
    }

    func process(file: URL) {
        if let fileType = UTType(filenameExtension: file.pathExtension),
           fileType.conforms(to: .audio)
        {
            processAudioFile(file)
            return
        }

        if let image = UIImage(contentsOfFile: file.path) {
            process(image: image)
            return
        }

        if file.pathExtension.lowercased() == "pdf" {
            processPDF(file: file)
            return
        }

        guard let attachment = makeTextAttachment(file: file) else {
            delegate?.chatInputDidReportError(self, error: String.localized("Unsupported format."))
            return
        }
        if attachment.textContent.count > 1_000_000 {
            delegate?.chatInputDidReportError(self, error: String.localized("Text too long."))
            return
        }
        attachmentsBar.insert(item: attachment)
    }

    private func processAudioFile(_ url: URL) {
        guard let storedAudioURL = storage.copyFileIntoStorageIfNeeded(url) else {
            delegate?.chatInputDidReportError(self, error: String.localized("Failed to process audio file."))
            return
        }
        let storageFilename = storedAudioURL.lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = url.lastPathComponent.isEmpty ? "Audio.\(fileExtension)" : url.lastPathComponent

        let attachment = ChatInputAttachment(
            type: .audio,
            name: name,
            fileData: (try? Data(contentsOf: storedAudioURL)) ?? Data(),
            textContent: name,
            storageFilename: storageFilename
        )
        attachmentsBar.insert(item: attachment)
    }

    func processPDF(file: URL) {
        guard let pdfDocument = PDFDocument(url: file) else {
            delegate?.chatInputDidReportError(self, error: String.localized("Failed to load PDF file."))
            return
        }

        let pageCount = pdfDocument.pageCount
        guard pageCount > 0 else {
            delegate?.chatInputDidReportError(self, error: String.localized("PDF file is empty."))
            return
        }

        let alert = UIAlertController(
            title: String.localized("Import PDF"),
            message: String.localized("This PDF has \(pageCount) page(s). Import as text or convert to images?"),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: String.localized("Import Text"), style: .default) { [weak self] _ in
            guard let self else { return }
            let attachment = ChatInputAttachment(
                type: .document,
                name: file.lastPathComponent,
                textContent: pdfDocument.string ?? "",
                storageFilename: file.lastPathComponent
            )
            if attachment.textContent.count > 1_000_000 {
                delegate?.chatInputDidReportError(self, error: String.localized("Text too long."))
                return
            }
            attachmentsBar.insert(item: attachment)
        })
        alert.addAction(UIAlertAction(title: String.localized("Convert to Images"), style: .default) { [weak self] _ in
            self?.convertPDFToImages(pdfDocument: pdfDocument)
        })
        alert.addAction(UIAlertAction(title: String.localized("Cancel"), style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = bounds
        }
        parentViewController?.present(alert, animated: true)
    }

    func convertPDFToImages(pdfDocument: PDFDocument) {
        let pageCount = pdfDocument.pageCount
        Task(priority: .userInitiated) { [weak self] in
            var images: [UIImage] = []
            for i in 0 ..< pageCount {
                guard let page = pdfDocument.page(at: i) else { continue }
                let rect = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: rect.size)
                let image = renderer.image { context in
                    UIColor.white.set()
                    context.fill(CGRect(origin: .zero, size: rect.size))
                    context.cgContext.translateBy(x: 0, y: rect.size.height)
                    context.cgContext.scaleBy(x: 1, y: -1)
                    context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                    page.draw(with: .mediaBox, to: context.cgContext)
                }
                images.append(image)
            }
            for image in images {
                self?.process(image: image)
            }
        }
    }

    private func makeTextAttachment(file: URL) -> ChatInputAttachment? {
        guard let storedFileURL = storage.copyFileIntoStorageIfNeeded(file) else { return nil }
        guard let content = try? String(contentsOf: file) else { return nil }
        return ChatInputAttachment(
            type: .document,
            name: file.lastPathComponent,
            textContent: content,
            storageFilename: storedFileURL.lastPathComponent
        )
    }
}

// MARK: - Pasteboard

private extension ChatInputView {
    func importPasteboardContentAsAttachment() -> Bool {
        let pasteboard = UIPasteboard.general

        if pasteboard.hasImages, let image = pasteboard.image {
            process(image: image)
            return true
        }

        if let fileURL = extractFileURL(from: pasteboard) {
            process(file: fileURL)
            return true
        }

        if let remoteURL = extractRemoteURL(from: pasteboard) {
            let preferredName = suggestedName(for: remoteURL)
            insertTextAttachment(content: remoteURL.absoluteString, preferredName: preferredName)
            return true
        }

        if let text = extractText(from: pasteboard) {
            insertTextAttachment(content: text, preferredName: nil)
            return true
        }

        return false
    }

    func extractFileURL(from pasteboard: UIPasteboard) -> URL? {
        if let url = pasteboard.url, url.isFileURL { return url }
        if let urls = pasteboard.urls, let fileURL = urls.first(where: { $0.isFileURL }) { return fileURL }
        for item in pasteboard.items {
            if let url = item[UTType.fileURL.identifier] as? URL { return url }
            if let data = item[UTType.fileURL.identifier] as? Data,
               let urlString = String(data: data, encoding: .utf8),
               let url = URL(string: urlString), url.isFileURL { return url }
        }
        return nil
    }

    func extractRemoteURL(from pasteboard: UIPasteboard) -> URL? {
        if let url = pasteboard.url, !url.isFileURL { return url }
        if let urls = pasteboard.urls, let remote = urls.first(where: { !$0.isFileURL }) { return remote }
        for item in pasteboard.items {
            if let url = item[UTType.url.identifier] as? URL, !url.isFileURL { return url }
            if let data = item[UTType.url.identifier] as? Data,
               let urlString = String(data: data, encoding: .utf8),
               let url = URL(string: urlString), !url.isFileURL { return url }
        }
        return nil
    }

    func extractText(from pasteboard: UIPasteboard) -> String? {
        if let string = pasteboard.string, !string.isEmpty { return string }
        for item in pasteboard.items {
            for (typeIdentifier, value) in item {
                guard let type = UTType(typeIdentifier), type.conforms(to: .plainText) else { continue }
                if let string = value as? String, !string.isEmpty { return string }
                if let data = value as? Data, let string = String(data: data, encoding: .utf8), !string.isEmpty { return string }
            }
        }
        return nil
    }

    func insertTextAttachment(content: String, preferredName: String?) {
        guard !content.isEmpty else { return }
        let sanitizedName = sanitizedFileName(from: preferredName)
        let destinationURL = storage.fileURL(for: storage.makeUniqueFilenameStem())
            .deletingLastPathComponent()
            .appendingPathComponent(sanitizedName)
            .appendingPathExtension("txt")
        do {
            try content.write(to: destinationURL, atomically: true, encoding: .utf8)
            process(file: destinationURL)
        } catch {
            delegate?.chatInputDidReportError(self, error: String.localized("Failed to save text."))
        }
    }

    func sanitizedFileName(from preferredName: String?) -> String {
        let fallback = String.localized("Pasteboard") + "-\(UUID().uuidString)"
        guard var name = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return fallback
        }
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let components = name.components(separatedBy: invalidCharacters).filter { !$0.isEmpty }
        name = components.isEmpty ? fallback : components.joined(separator: "-")
        return name
    }

    func suggestedName(for url: URL) -> String? {
        let lastComponent = url.lastPathComponent
        if !lastComponent.isEmpty { return lastComponent }
        if let host = url.host, !host.isEmpty { return host }
        return nil
    }
}
