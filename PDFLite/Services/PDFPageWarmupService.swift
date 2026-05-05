import AppKit
import Foundation
import PDFKit

enum PDFPageWarmupDirection: Sendable {
    case backward
    case forward
    case both
}

/// Best-effort PDF page renderer warmup.
///
/// Calls `page.thumbnail(of:for:)` on neighbouring pages from a background queue using the same
/// PDFDocument instance the PDFView is rendering — that way the work primes PDFKit's per-document
/// caches (font subsets, image decodes, vector resolution, raster results) so when PDFView reaches
/// those pages during scrolling the bitmap is already prepared.
///
/// Each DocumentSession owns its own service so multi-window usage doesn't cross-cancel pendings.
final class PDFPageWarmupService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pdflite.pdf-page-warmup", qos: .background)
    private weak var document: PDFDocument?
    private var pending: DispatchWorkItem?

    func attach(document: PDFDocument) {
        cancelPending()
        self.document = document
    }

    func reset() {
        cancelPending()
        document = nil
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func schedule(currentPageIndex: Int,
                  pageCount: Int,
                  displayMode: PDFDisplayMode,
                  thumbnailSize: CGSize,
                  direction: PDFPageWarmupDirection,
                  delayMilliseconds: Int) {
        guard pageCount > 1, document != nil else { return }
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
            guard let self, let item, let document = self.document else { return }
            self.warm(document: document, indices: indices, size: thumbnailSize, workItem: item)
        }
        item = workItem
        pending = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds), execute: workItem)
    }

    private func warm(document: PDFDocument,
                      indices: [Int],
                      size: CGSize,
                      workItem: DispatchWorkItem) {
        for index in indices {
            if workItem.isCancelled { return }
            autoreleasepool {
                guard index >= 0,
                      index < document.pageCount,
                      let page = document.page(at: index) else { return }
                _ = page.thumbnail(of: size, for: .cropBox)
            }
        }
    }

    private func warmupRadius(displayMode: PDFDisplayMode,
                              direction: PDFPageWarmupDirection) -> Int {
        let isTwoUp = displayMode == .twoUp || displayMode == .twoUpContinuous
        switch (isTwoUp, direction) {
        case (true, .both): return 2
        case (true, _): return 4
        case (false, .both): return 2
        case (false, _): return 3
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
