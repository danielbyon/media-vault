//
//  BrowserSurfaceRenderer.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Renders one already-mounted Browser surface into an in-memory image.
///
/// All callers share the same hierarchy-rendering and validation rules. A layer fallback is
/// allowed for app-owned UIKit surfaces, but never for WebKit: a WebKit layer can be non-empty
/// while omitting the committed page pixels that a transition is required to preserve.
@MainActor
enum BrowserSurfaceRenderer {
    /// Declares which surface types are allowed to use a Core Animation layer fallback.
    ///
    /// WebKit layers can contain compositor bookkeeping without the committed page pixels. They
    /// therefore remain hierarchy-only even when the fallback would produce a nonempty image.
    enum RenderingPolicy {
        /// Captures an app-owned surface for disposable preview data using hierarchy rendering.
        case nativePreview
        /// Captures an app-owned UIKit surface for a transition representation.
        case appOwnedTransition
        /// Captures a WebKit surface for readiness or transition evidence.
        case webKit

        var allowsLayerFallback: Bool {
            switch self {
            case .nativePreview,
                 .webKit:
                false
            case .appOwnedTransition:
                true
            }
        }
    }

    static func image(
        from view: UIView,
        afterScreenUpdates: Bool,
        opaque: Bool,
        renderingPolicy: RenderingPolicy,
        outputSize: CGSize? = nil,
        drawHierarchy: @escaping @MainActor (UIView, CGRect, Bool) -> Bool = { view, bounds, afterScreenUpdates in
            view.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        },
    ) -> UIImage? {
        guard view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.windowScene?.screen.scale
            ?? view.window?.screen.scale
            ?? view.traitCollection.displayScale
        format.opaque = opaque
        var didDrawHierarchy = false
        let renderSize = outputSize ?? view.bounds.size
        guard renderSize.width > 0, renderSize.height > 0 else {
            return nil
        }

        let image = UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            context.cgContext.saveGState()
            context.cgContext.scaleBy(
                x: renderSize.width / view.bounds.width,
                y: renderSize.height / view.bounds.height,
            )
            didDrawHierarchy = drawHierarchy(view, view.bounds, afterScreenUpdates)
            if !didDrawHierarchy, renderingPolicy.allowsLayerFallback {
                view.layer.render(in: context.cgContext)
            }
            context.cgContext.restoreGState()
        }

        guard didDrawHierarchy || renderingPolicy.allowsLayerFallback,
              image.size.width > 0,
              image.size.height > 0
        else {
            return nil
        }

        return image
    }

    /// Creates the fixed-bounds image view used by transition clones.
    static func imageView(
        from view: UIView,
        afterScreenUpdates: Bool,
        opaque: Bool,
        renderingPolicy: RenderingPolicy,
    ) -> UIImageView? {
        guard let image = image(
            from: view,
            afterScreenUpdates: afterScreenUpdates,
            opaque: opaque,
            renderingPolicy: renderingPolicy,
        ) else {
            return nil
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        return imageView
    }
}
