import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns the session's model into JSON and back. Every value a script can set is reported here in the same shape it
/// is accepted in, so `GET /v1/state` doubles as a reference for the payloads.
enum AutomationState {
    static func session(_ context: AutomationContext, include: Set<String>) -> [String: Any] {
        let session = context.session
        var out: [String: Any] = [
            "project": project(context),
            "tool": session.tool.rawValue,
            "history": [
                "canUndo": session.canUndo, "canRedo": session.canRedo,
                "undoName": session.history.undoName, "redoName": session.history.redoName,
                "isModified": session.isModified, "undoCount": session.history.undoCount,
            ],
            "editable": session.canEditLayers,
            "blockedBy": AutomationJSON.nullable(session.canEditLayers ? nil : context.blockedReason()),
            "colors": ["foreground": color(session.foregroundColor).json, "background": color(session.backgroundColor).json],
            "activeLayer": AutomationJSON.nullable(session.activeLayerID?.uuidString),
            "selectedLayers": session.selectedLayerIDs.map(\.uuidString).sorted(),
            "maskSelected": session.isMaskSelected,
        ]
        guard let document = session.document else {
            out["document"] = NSNull()
            return out
        }
        var doc: [String: Any] = [
            "id": document.id.uuidString,
            "width": document.width, "height": document.height, "resolution": document.resolution,
            "layerCount": document.layers.count,
        ]
        if include.contains("layers") || include.contains("all") {
            doc["layers"] = document.layers.map { layer($0, in: document, session: session) }
        }
        if include.contains("guides") || include.contains("all") {
            doc["guides"] = document.guides.map { ["id": $0.id.uuidString, "axis": $0.axis.rawValue, "position": $0.position] }
        }
        if include.contains("selection") || include.contains("all") {
            doc["selection"] = selection(document.selection)
        }
        out["document"] = doc
        if include.contains("tools") || include.contains("all") { out["tools"] = tools(session) }
        return out
    }

    static func project(_ context: AutomationContext) -> [String: Any] {
        let session = context.session
        return [
            "id": context.tab.id.uuidString,
            "title": context.tab.title,
            "path": AutomationJSON.nullable(session.projectURL?.path),
            "hasDocument": session.document != nil,
            "isModified": session.isModified,
            "isBusy": session.isProjectBusy,
        ]
    }

    // MARK: Layers

    static func layer(_ layer: ImageLayer, in document: CanvasDocument, session: EditorSession) -> [String: Any] {
        var out: [String: Any] = [
            "id": layer.id.uuidString,
            "name": layer.name,
            "kind": layer.isGroup ? "group" : layer.adjustment != nil ? "adjustment" : layer.liveText != nil ? "text" : layer.liveShape != nil ? "shape" : "pixels",
            "index": document.layers.firstIndex { $0.id == layer.id } ?? -1,
            "parent": AutomationJSON.nullable(layer.parentID?.uuidString),
            "isGroup": layer.isGroup,
            "isVisible": layer.isVisible,
            "opacity": layer.opacity,
            "blendMode": layer.blendMode.rawValue,
            "transform": transform(layer.transform),
            "hasPixels": layer.asset != nil,
            "clippedTo": AutomationJSON.nullable(layer.maskSourceID?.uuidString),
            "collapsed": session.collapsedGroupIDs.contains(layer.id),
        ]
        if let asset = layer.asset {
            out["pixelSize"] = ["width": asset.image.width, "height": asset.image.height]
        }
        if let mask = layer.mask {
            out["mask"] = [
                "enabled": mask.isEnabled, "linked": mask.isLinked,
                "pixelSize": ["width": mask.asset.image.width, "height": mask.asset.image.height],
                "placement": AutomationJSON.nullable(mask.placement.map(transform)),
            ]
        }
        if let adjustment = layer.adjustment { out["adjustment"] = AutomationSettings.adjustment(adjustment) }
        if let effects = layer.effects { out["effects"] = AutomationSettings.effects(effects) }
        if let text = layer.liveText { out["text"] = AutomationSettings.textStyle(text.style) }
        if let shape = layer.liveShape { out["shape"] = AutomationSettings.shapeStyle(shape.style) }
        return out
    }

    static func transform(_ transform: LayerTransform) -> [String: Any] {
        [
            "x": Double(transform.origin.x), "y": Double(transform.origin.y),
            "width": Double(transform.size.width), "height": Double(transform.size.height),
            "rotation": Double(transform.rotation), "flipX": transform.flipX, "flipY": transform.flipY,
            "sampling": transform.sampling.rawValue,
        ]
    }

    static func color(_ color: PaletteColor) -> AutomationColor {
        AutomationColor(red: Double(color.red), green: Double(color.green), blue: Double(color.blue))
    }

    // MARK: Selection

    /// The selection as subpaths of document points, plus its box and edge settings. `nil` means no selection,
    /// `isEmpty` an explicit empty one.
    static func selection(_ selection: DocumentSelection?) -> Any {
        guard let selection else { return NSNull() }
        let box = selection.path.boundingBoxOfPath
        var subpaths: [[[Double]]] = []
        var current: [[Double]] = []
        var curved = false
        selection.path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                if !current.isEmpty { subpaths.append(current) }
                current = [[Double(points[0].x), Double(points[0].y)]]
            case .addLineToPoint:
                current.append([Double(points[0].x), Double(points[0].y)])
            case .addQuadCurveToPoint:
                curved = true
                current.append([Double(points[1].x), Double(points[1].y)])
            case .addCurveToPoint:
                curved = true
                current.append([Double(points[2].x), Double(points[2].y)])
            case .closeSubpath:
                if !current.isEmpty { subpaths.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if !current.isEmpty { subpaths.append(current) }
        return [
            "isEmpty": selection.isEmpty,
            "bounds": AutomationJSON.nullable(box.isNull ? nil : AutomationJSON.rect(box)),
            "feather": Double(selection.feather),
            "antialiased": selection.antialiased,
            "approximate": curved,
            "subpaths": subpaths,
        ]
    }

    // MARK: Tools

    static func tools(_ session: EditorSession) -> [String: Any] {
        let brush = session.brushSettings
        return [
            "brush": [
                "diameter": Double(brush.diameter), "hardness": Double(brush.hardness), "opacity": Double(brush.opacity),
                "smoothing": Double(brush.smoothing), "blurRadius": Double(brush.blurRadius),
                "mode": session.brushMode.rawValue, "blurMode": session.blurMode.rawValue,
                "healingMode": session.spotHealingMode.rawValue,
            ],
            "clone": ["aligned": session.cloneSettings.aligned, "sampleAllLayers": session.cloneSettings.sampleAllLayers,
                      "source": AutomationJSON.nullable(session.cloneSource.map(AutomationJSON.point))],
            "wand": ["tolerance": session.wandSettings.tolerance, "sampleSize": session.wandSettings.sampleSize.rawValue,
                     "contiguous": session.wandSettings.contiguous, "sampleAllLayers": session.wandSettings.sampleAllLayers],
            "objectSelection": ["sampleAllLayers": session.objectSelectionSettings.sampleAllLayers,
                                "edgeOffset": session.objectSelectionSettings.edgeOffset],
            "gradient": ["shape": session.gradientSettings.shape.rawValue, "style": session.gradientSettings.style.rawValue,
                         "reversed": session.gradientSettings.reversed, "opacity": Double(session.gradientSettings.opacity)],
            "shape": ["kind": session.shapeKind.rawValue, "cornerRadius": session.shapeCornerRadius, "lineWidth": session.shapeLineWidth],
            "text": AutomationSettings.textStyle(session.textDefaults),
            "selection": ["antialiased": session.selectionAntialiased, "featherAmount": session.selectionFeatherAmount,
                          "expandAmount": session.selectionExpandAmount, "contractAmount": session.selectionContractAmount],
            "view": ["showsGrid": session.showsGrid, "showsGuides": session.showsGuides, "showsRulers": session.showsRulers,
                     "showsPixelGrid": session.showsPixelGrid, "snap": session.snapEnabled, "snapToGuides": session.snapToGuides,
                     "snapToGrid": session.snapToGrid, "snapToLayers": session.snapToLayers,
                     "snapToDocumentBounds": session.snapToDocumentBounds, "locksGuides": session.locksGuides,
                     "grid": ["spacing": session.layoutGrid.spacing, "subdivisions": session.layoutGrid.subdivisions,
                              "style": session.gridAppearance.style.rawValue, "preset": session.gridAppearance.preset.rawValue,
                              "opacity": session.gridAppearance.opacity,
                              "customColor": color(session.gridAppearance.customColor).json],
                     "zoom": Double(session.viewport.zoom)],
        ]
    }
}

/// Image bytes in and out of the API, through ImageIO so nothing here depends on the exporter's file panels.
nonisolated enum AutomationImages {
    enum Format: String { case png, jpeg, tiff, heic }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AutomationError.unprocessable("the image data could not be decoded")
        }
        return image
    }

    static func decode(fileAt url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AutomationError.notFound("no file at \(url.path)") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AutomationError.unprocessable("\(url.lastPathComponent) could not be decoded as an image")
        }
        return image
    }

    static func encode(_ image: CGImage, format: Format, quality: Double = 0.9, resolution: Double? = nil) throws -> Data {
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .tiff: type = .tiff
        case .heic: type = .heic
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw AutomationError.failed("could not create a \(format.rawValue) encoder")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg || format == .heic { properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
        if let resolution {
            properties[kCGImagePropertyDPIWidth] = resolution
            properties[kCGImagePropertyDPIHeight] = resolution
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AutomationError.failed("encoding the \(format.rawValue) failed") }
        return data as Data
    }

    static func contentType(_ format: Format) -> String {
        switch format {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .tiff: return "image/tiff"
        case .heic: return "image/heic"
        }
    }

    /// Draws `image` filling a `BrushRaster` context the right way up. Those contexts are flipped to a top-left
    /// origin, so a plain `draw` would land the image upside down.
    static func drawUpright(_ image: CGImage, width: Int, height: Int, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    /// Converts any decoded image into the 8-bit RGBA layout layers use.
    static func rgba(_ image: CGImage) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        drawUpright(image, width: image.width, height: image.height, in: context)
        guard let result = context.makeImage() else { throw AutomationError.failed("could not convert the image") }
        return result
    }

    /// Converts any decoded image into the 8-bit gray layout masks use (luminance of the source).
    static func gray(_ image: CGImage) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        drawUpright(image, width: image.width, height: image.height, in: context)
        guard let result = context.makeImage() else { throw AutomationError.failed("could not convert the mask") }
        return result
    }

    /// A solid RGBA image.
    static func solid(size: CGSize, color: AutomationColor) throws -> CGImage {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw AutomationError.failed("could not create the image") }
        return result
    }

    /// The image resampled by `scale`.
    static func scaled(_ image: CGImage, by scale: Double) throws -> CGImage {
        guard scale > 0, scale != 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.interpolationQuality = .high
        drawUpright(image, width: width, height: height, in: context)
        guard let result = context.makeImage() else { throw AutomationError.failed("could not scale the image") }
        return result
    }

    static func importedImage(_ image: CGImage, name: String) throws -> ImportedImage {
        let rgba = try rgba(image)
        return ImportedImage(image: rgba, thumbnail: try PixelAdjust.thumbnail(of: rgba), name: name)
    }
}
