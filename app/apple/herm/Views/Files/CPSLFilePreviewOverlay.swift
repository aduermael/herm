import Foundation
import SwiftUI
#if canImport(PDFKit)
import PDFKit
#endif

struct CPSLFilePreviewContentView: View {
    let preview: CPSLFilePreview

    var body: some View {
        switch preview.kind {
        case .text(let text):
            CPSLTextFilePreview(text: text)
        case .pdf(let url):
            CPSLPDFFilePreview(url: url)
        }
    }
}

private struct CPSLTextFilePreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(CPSLTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CPSLTheme.medium)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLPDFFilePreview: View {
    let url: URL

    var body: some View {
#if os(macOS) && canImport(PDFKit)
        CPSLPDFKitView(url: url)
#elseif canImport(UIKit) && canImport(PDFKit)
        CPSLPDFKitView(url: url)
#else
        CPSLUnsupportedPDFPreview()
#endif
    }
}

private struct CPSLUnsupportedPDFPreview: View {
    var body: some View {
        VStack(spacing: CPSLTheme.small) {
            Image(systemName: "doc.richtext")
                .font(CPSLTheme.iconLargeFont)
                .foregroundStyle(CPSLTheme.secondaryText)
            Text("PDF preview is not available on this platform.")
                .font(CPSLTheme.supportingFont)
                .foregroundStyle(CPSLTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS) && canImport(PDFKit)
private struct CPSLPDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView)
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
    }
}
#elseif canImport(UIKit) && canImport(PDFKit)
private struct CPSLPDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        configure(pdfView)
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
    }
}
#endif
