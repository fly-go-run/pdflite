import AppKit
import Foundation
import PDFKit

enum PDFPageWarmupDirection: Sendable {
    case backward
    case forward
    case both
}

/// Best-effort renderer warmup for nearby pages.
///
/// PDFView lazily rasterizes pages as they become visible. Heavy figure pages can briefly show a
/// blank area during fast scrolling. This service does not replace PDFView's renderer; it only
/// pre-draws nearby pages on a background queue with a separate PDFDocument instance so CoreGraphics
/// has already decoded fonts, images, and vector resources when PDFView reaches those pages.
final class PDFPageWarmupService: @unchecked Sendable {
    static let shared = PDFPageWarmupService()

    private let queue = DispatchQueue(label: "com.pdflite.pdf-page-warmup", qos: .background)
    private var pending: DispatchWorkItem?
    private var cachedURL: URL?
    private var cachedDocument: PDFDocument?

    private init() {}

    func schedule(url: URL,
                  currentPageIndex: Int,
                  pageCount: Int,
                  displayMode: PDFDisplayMode,
                  scaleFactor: CGFloat,
                  direction: PDFPageWarmupDirection,
                  delayMilliseconds: Int) {
        guard pageCount > 1 else { return }

        pending?.cancel()

        let radius = warmupRadius(displayMode: displayMode, direction: direction)
        let indices = warmupIndices(
            around: currentPageIndex,
            pageCount: pageCount,
            radius: radius,
            direction: direction
        )
        guard !indices.isEmpty else { return }

        var item: DispatchWorkItem?
        let workItem = DispatchWorkItem { [weak self] in
            guard let item else { return }
            self?.warm(url: url, indices: indices, scaleFactor: scaleFactor, workItem: item)
        }
        item = workItem
        pending = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds), execute: workItem)
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func reset() {
        cancelPending()
        queue.async { [weak self] in
            self?.cachedURL = nil
            self?.cachedDocument = nil
        }
    }

    private func warm(url: URL, indices: [Int], scaleFactor: CGFloat, workItem: DispatchWorkItem) {
        autoreleasepool {
            guard let document = cachedDocument(for: url) else { return }

            for index in indices {
                if workItem.isCancelled { return }
                guard index >= 0,
                      index < document.pageCount,
                      let page = document.page(at: index) else { continue }

                let bounds = page.bounds(for: .cropBox)
                guard bounds.width > 0, bounds.height > 0 else { continue }

                let drawScale = min(max(scaleFactor, 0.5), 1.25)
                let width = min(max(bounds.width * drawScale, 480), 1100)
                let height = max(width * bounds.height / bounds.width, 1)
                _ = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
            }
        }
    }

    private func cachedDocument(for url: URL) -> PDFDocument? {
        if cachedURL != url {
            cachedURL = url
            cachedDocument = PDFDocument(url: url)
        }
        return cachedDocument
    }

    private func warmupRadius(displayMode: PDFDisplayMode, direction: PDFPageWarmupDirection) -> Int {
        let isTwoUp = displayMode == .twoUp || displayMode == .twoUpContinuous
        switch (isTwoUp, direction) {
        case (true, .both): return 2
        case (true, _): return 3
        case (false, .both): return 1
        case (false, _): return 2
        }
    }

    private func warmupIndices(around index: Int,
                               pageCount: Int,
                               radius: Int,
                               direction: PDFPageWarmupDirection) -> [Int] {
        var result: [Int] = []
        for distance in 1...radius {
            switch direction {
            case .forward:
                let next = index + distance
                if next < pageCount { result.append(next) }
            case .backward:
                let previous = index - distance
                if previous >= 0 { result.append(previous) }
            case .both:
                let next = index + distance
                if next < pageCount { result.append(next) }

                let previous = index - distance
                if previous >= 0 { result.append(previous) }
            }
        }
        return result
    }
}
