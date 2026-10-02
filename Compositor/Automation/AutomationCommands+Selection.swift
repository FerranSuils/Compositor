import Foundation
import CoreGraphics

extension AutomationRegistry {
    func registerSelectionCommands() {
        group("selection", "Selections: marquee shapes, polygons, magic wand, object, subject, color range, from layers and masks, expand/contract/feather, move, and the pixel edits they scope: fill, clear, copy/cut/paste, move pixels, transform selection.")

        add("selection.get", group: "selection", "The current selection as subpaths of document points (null = none).") { context, _ in
            AutomationState.selection(try context.document().selection)
        }

        add("selection.rect", group: "selection", "Rectangular marquee from a document rect.", params: [
            AutomationParamDoc("rect", "rect", required: true, "[x, y, width, height]"), AutomationDocs.mode,
        ]) { context, params in
            let rect = try params.rect("rect")
            try AutomationSelections.apply(context, CGPath(rect: rect, transform: nil), mode: try AutomationSelections.mode(params), name: "Rectangular Marquee")
            return AutomationState.selection(context.session.selection)
        }

        add("selection.ellipse", group: "selection", "Elliptical marquee inscribed in a document rect.", params: [
            AutomationParamDoc("rect", "rect", required: true), AutomationDocs.mode,
        ]) { context, params in
            let rect = try params.rect("rect")
            try AutomationSelections.apply(context, CGPath(ellipseIn: rect, transform: nil), mode: try AutomationSelections.mode(params), name: "Elliptical Marquee")
            return AutomationState.selection(context.session.selection)
        }

        add("selection.polygon", group: "selection", "Lasso outline through document points (closed automatically); several outlines with `polygons`.", params: [
            AutomationParamDoc("points", "[point]", "At least three points."), AutomationParamDoc("polygons", "[[point]]", "Several outlines at once (holes by winding)."), AutomationDocs.mode,
        ]) { context, params in
            let path = CGMutablePath()
            var outlines: [[CGPoint]] = []
            if params.has("points") { outlines.append(try params.points("points")) }
            if params.has("polygons") {
                for (index, element) in try params.array("polygons").enumerated() {
                    guard let list = element as? [Any] else { throw AutomationError.badRequest("\"polygons[\(index)]\" must be a list of points") }
                    outlines.append(try list.enumerated().map { try AutomationParams.point($1, named: "polygons[\(index)][\($0)]") })
                }
            }
            guard !outlines.isEmpty else { throw AutomationError.badRequest("give \"points\" or \"polygons\"") }
            for outline in outlines {
                guard outline.count >= 3 else { throw AutomationError.badRequest("an outline needs at least three points") }
                path.addLines(between: outline)
                path.closeSubpath()
            }
            try AutomationSelections.apply(context, path, mode: try AutomationSelections.mode(params), name: "Polygonal Lasso")
            return AutomationState.selection(context.session.selection)
        }

        add("selection.wand", group: "selection", "Magic Wand at a point.", params: [
            AutomationDocs.point, AutomationParamDoc("tolerance", "int", "0–255, default 32."), AutomationParamDoc("contiguous", "bool", "Default true."),
            AutomationParamDoc("sampleAllLayers", "bool"), AutomationParamDoc("sampleSize", "string", "point, 3x3 or 5x5."), AutomationDocs.mode,
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            var settings = session.wandSettings
            if let tolerance = try params.optionalInt("tolerance") { settings.tolerance = min(255, max(0, tolerance)) }
            if let contiguous = try params.optionalBool("contiguous") { settings.contiguous = contiguous }
            if let all = try params.optionalBool("sampleAllLayers") { settings.sampleAllLayers = all }
            if let size = try params.optionalString("sampleSize") {
                switch AutomationParams.normalize(size) {
                case "point", "1", "1x1": settings.sampleSize = .point
                case "3x3", "3", "threebythree": settings.sampleSize = .threeByThree
                case "5x5", "5", "fivebyfive": settings.sampleSize = .fiveByFive
                default: throw AutomationError.badRequest("\"sampleSize\" must be point, 3x3 or 5x5")
                }
            }
            session.wandSettings = settings
            let point = try params.point("point")
            let mode = try AutomationSelections.mode(params)
            try await AutomationSelections.combine(context, mode: mode) { mode in
                await session.magicWand(at: point, mode: mode)
            }
            return AutomationState.selection(session.selection)
        }

        add("selection.object", group: "selection", "Object Selection: the foreground object under a point (Vision).", params: [
            AutomationDocs.point, AutomationParamDoc("sampleAllLayers", "bool", "Default true."), AutomationParamDoc("edgeOffset", "int", "−10…10; positive erodes, negative expands."), AutomationDocs.mode,
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            if let all = try params.optionalBool("sampleAllLayers") { session.objectSelectionSettings.sampleAllLayers = all }
            if let offset = try params.optionalInt("edgeOffset") { session.objectSelectionSettings.edgeOffset = min(10, max(-10, offset)) }
            let point = try params.point("point")
            try await AutomationSelections.combine(context, mode: try AutomationSelections.mode(params)) { mode in
                await session.selectObject(at: point, mode: mode)
            }
            return AutomationState.selection(session.selection)
        }

        add("selection.subject", group: "selection", "Select Subject: the foreground of the whole canvas (Vision).", params: [AutomationDocs.mode]) { context, params in
            try context.requireEditable()
            let session = context.session
            guard session.canSelectSubject else { throw AutomationError.conflict("Select Subject cannot run right now") }
            try await AutomationSelections.combine(context, mode: try AutomationSelections.mode(params)) { mode in
                await session.selectSubject(mode: mode)
            }
            return AutomationState.selection(session.selection)
        }

        add("selection.colorRange", group: "selection", "Color Range: pixels near the given colors anywhere in the composite.", params: [
            AutomationParamDoc("colors", "[color]", "Colors to include (or `points` to sample)."), AutomationParamDoc("points", "[point]", "Document points whose colors to include."),
            AutomationParamDoc("exclude", "[color]", "Colors to take away."), AutomationParamDoc("fuzziness", "number", "0–200, default 40."),
            AutomationParamDoc("invert", "bool"), AutomationDocs.mode,
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            guard session.canSelectColorRange else { throw AutomationError.conflict("Color Range cannot start right now") }
            // Everything is read before Color Range opens, so a bad parameter can't leave it open.
            let mode = try AutomationSelections.mode(params)
            let previous = session.selection
            func bytes(_ colors: [AutomationColor]) -> [UInt8] {
                colors.flatMap { [UInt8((($0.red) * 255).rounded()), UInt8((($0.green) * 255).rounded()), UInt8((($0.blue) * 255).rounded())] }
            }
            var include: [AutomationColor] = []
            if params.has("colors") {
                for (index, element) in try params.array("colors").enumerated() {
                    guard let color = AutomationColor(any: element) else { throw AutomationError.badRequest("\"colors[\(index)]\" is not a color") }
                    include.append(color)
                }
            }
            if params.has("points") {
                for point in try params.points("points") {
                    guard let color = session.sampleCompositeColor(at: point) else { continue }
                    include.append(AutomationState.color(color))
                }
            }
            guard !include.isEmpty else { throw AutomationError.badRequest("give at least one color or point") }
            var exclude: [AutomationColor] = []
            if params.has("exclude") {
                for (index, element) in try params.array("exclude").enumerated() {
                    guard let color = AutomationColor(any: element) else { throw AutomationError.badRequest("\"exclude[\(index)]\" is not a color") }
                    exclude.append(color)
                }
            }
            let fuzziness = try params.double("fuzziness", in: ColorRangeEdit.fuzzinessRange, default: 40)
            let invert = try params.bool("invert", default: false)
            let canvas = try context.document().size
            session.beginColorRange()
            guard let edit = session.colorRange else { throw AutomationError.conflict("Color Range could not start") }
            edit.include = bytes(include)
            edit.exclude = bytes(exclude)
            edit.fuzziness = fuzziness
            edit.invert = invert
            session.updateColorRange()
            do {
                let deadline = ContinuousClock.now + .seconds(60)
                while edit.preview == nil, edit.error == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
                if let error = edit.error { throw AutomationError.unprocessable(error) }
                guard edit.preview != nil else { throw AutomationError.failed("Color Range timed out") }
            } catch {
                session.cancelColorRange()
                throw error
            }
            if mode == .replace {
                session.commitColorRange()
            } else {
                // The panel always replaces. For the other modes take its preview, close it without an undo step,
                // and record the combined selection as the one step.
                let found = session.selection
                session.cancelColorRange()
                let combined: DocumentSelection?
                if let found { combined = try AutomationSelections.combined(previous, with: found.path, mode: mode, canvas: canvas, antialiased: session.selectionAntialiased) }
                else { combined = mode == .intersect ? nil : previous }
                session.setSelection(combined, name: "Color Range")
            }
            return AutomationState.selection(session.selection)
        }

        add("selection.fromLayer", group: "selection", "Loads a layer's opaque pixels as the selection.", params: [AutomationDocs.layer, AutomationDocs.mode]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard !layer.isGroup else { throw AutomationError.unprocessable("folders have no pixels to load") }
            let mode = try AutomationSelections.mode(params)
            try await AutomationSelections.combine(context, mode: mode) { mode in context.session.loadLayerSelection(layerID: layer.id, mode: mode) }
            return AutomationState.selection(context.session.selection)
        }

        add("selection.fromMask", group: "selection", "Loads a mask as the selection: its white (shown) area by default, or the black area with `hidden`.", params: [
            AutomationDocs.layer, AutomationParamDoc("hidden", "bool", "Select the mask's black (hidden) pixels instead."), AutomationDocs.mode,
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard let mask = layer.mask else { throw AutomationError.notFound("the layer has no mask") }
            let mode = try AutomationSelections.mode(params)
            if try params.bool("hidden", default: false) {
                try await AutomationSelections.combine(context, mode: mode) { mode in context.session.loadMaskSelection(layerID: layer.id, mode: mode) }
            } else {
                let image = mask.asset.image
                var path = MaskTracing.whitePixels(in: image) ?? CGMutablePath()
                if image.width == 1, image.height == 1 {
                    // A uniform mask has no traced edge; a white one covers the layer, a black one nothing.
                    path = MaskTracing.whitePixels(in: image) == nil ? CGMutablePath() : CGPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1), transform: nil)
                }
                var mapping = BrushRaster.pixelToDocument(layer.maskTransform, width: image.width, height: image.height)
                guard let mapped = path.copy(using: &mapping) else { throw AutomationError.failed("could not map the mask") }
                try AutomationSelections.apply(context, mapped, mode: mode, name: "Load Mask Selection")
            }
            return AutomationState.selection(context.session.selection)
        }

        add("selection.fromMaskImage", group: "selection", "Loads a selection from a grayscale image the size of the canvas (white = selected).", params: [
            AutomationParamDoc("path", "string"), AutomationParamDoc("imageData", "base64"), AutomationDocs.mode,
        ]) { context, params in
            try context.requireEditable()
            let document = try context.document()
            let image: CGImage
            if let url = try params.optionalFileURL("path") { image = try AutomationImages.gray(try AutomationImages.decode(fileAt: url)) }
            else { image = try AutomationImages.gray(try AutomationImages.decode(try params.data("imageData"))) }
            guard image.width == document.width, image.height == document.height else {
                throw AutomationError.unprocessable("the mask image must be \(document.width)×\(document.height), the canvas size")
            }
            let path = MaskTracing.whitePixels(in: image) ?? CGMutablePath()
            try AutomationSelections.apply(context, path, mode: try AutomationSelections.mode(params), name: "Load Selection")
            return AutomationState.selection(context.session.selection)
        }

        add("selection.all", group: "selection", "Selects the whole canvas.") { context, _ in
            try context.requireEditable()
            context.session.selectAll()
            return AutomationState.selection(context.session.selection)
        }

        add("selection.none", group: "selection", "Deselects.") { context, _ in
            try context.requireEditable()
            context.session.deselect()
            return NSNull()
        }

        add("selection.invert", group: "selection", "Inverts the selection (Select Inverse).") { context, _ in
            try context.requireEditable()
            guard context.session.selection != nil else { throw AutomationError.conflict("there is no selection to invert") }
            context.session.invertSelection()
            return AutomationState.selection(context.session.selection)
        }

        add("selection.expand", group: "selection", "Grows the selection by `amount` pixels (1–500).", params: [AutomationParamDoc("amount", "int", required: true)]) { context, params in
            try context.requireEditable()
            guard context.session.canModifySelection else { throw AutomationError.conflict("there is no selection to expand") }
            context.session.expandSelection(by: try params.int("amount", in: 1...500))
            return AutomationState.selection(context.session.selection)
        }

        add("selection.contract", group: "selection", "Shrinks the selection by `amount` pixels (1–500).", params: [AutomationParamDoc("amount", "int", required: true)]) { context, params in
            try context.requireEditable()
            guard context.session.canModifySelection else { throw AutomationError.conflict("there is no selection to contract") }
            context.session.contractSelection(by: try params.int("amount", in: 1...500))
            return AutomationState.selection(context.session.selection)
        }

        add("selection.feather", group: "selection", "Softens the edge by `amount` pixels (1–250, cumulative), or sets the feather exactly with `absolute`.", params: [
            AutomationParamDoc("amount", "number"), AutomationParamDoc("absolute", "number", "Exact feather in pixels, 0–250."),
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            guard let current = session.selection, !current.isEmpty else { throw AutomationError.conflict("there is no selection to feather") }
            if let absolute = try params.optionalDouble("absolute") {
                guard (0...250).contains(absolute) else { throw AutomationError.badRequest("\"absolute\" must be 0–250") }
                session.setSelection(DocumentSelection(path: current.path, antialiased: current.antialiased, feather: CGFloat(absolute)), name: "Feather Selection")
            } else {
                session.featherSelection(by: try params.int("amount", in: 1...250))
            }
            return AutomationState.selection(session.selection)
        }

        add("selection.setAntialiased", group: "selection", "Whether new selections have smooth edges (default true).", params: [AutomationParamDoc("antialiased", "bool", required: true)]) { context, params in
            context.session.selectionAntialiased = try params.bool("antialiased")
            return ["antialiased": context.session.selectionAntialiased]
        }

        add("selection.move", group: "selection", "Moves the selection outline (not the pixels) by dx/dy.", params: [AutomationParamDoc("dx", "number"), AutomationParamDoc("dy", "number")]) { context, params in
            try context.requireEditable()
            guard context.session.selection?.isEmpty == false else { throw AutomationError.conflict("there is no selection to move") }
            context.session.nudgeSelection(dx: CGFloat(try params.double("dx", default: 0)), dy: CGFloat(try params.double("dy", default: 0)))
            return AutomationState.selection(context.session.selection)
        }

        add("selection.movePixels", group: "selection", "Moves (or duplicates) the selected pixels of the active layer by dx/dy; the selection follows.", params: [
            AutomationDocs.layer, AutomationParamDoc("dx", "number"), AutomationParamDoc("dy", "number"), AutomationParamDoc("duplicate", "bool", "Leave the original in place."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            try context.activate(layer.id)
            let session = context.session
            // Read before the move opens, so a bad parameter can't leave it open.
            let offset = CGSize(width: try params.double("dx", default: 0), height: try params.double("dy", default: 0))
            guard session.beginPixelMove(duplicate: try params.bool("duplicate", default: false)) else {
                throw AutomationError.conflict("nothing to move: needs a selection over the layer's pixels")
            }
            session.movePixels(by: offset)
            try await context.checkingBrushErrorAsync { await session.finishPixelMove() }
            return AutomationState.selection(session.selection)
        }

        add("selection.fill", group: "selection", "Fills the selection (or the whole layer) with a color on the active layer.", params: [
            AutomationDocs.layer, AutomationParamDoc("color", "color", "Defaults to the foreground color; \"background\" uses the background color."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            try context.activate(layer.id)
            let session = context.session
            var source = EditorSession.FillSource.foreground
            if let text = params.raw["color"] as? String, AutomationParams.normalize(text) == "background" {
                source = .background
            } else if let color = try params.optionalColor("color") {
                session.foregroundColor = AutomationSettings.palette(color)
            }
            guard session.canEditPixels else { throw AutomationError.conflict("the layer cannot be filled right now (folders, adjustment layers and empty selections fill nothing)") }
            try await context.checkingBrushErrorAsync { await session.fillSelection(with: source) }
            return ["layer": layer.id.uuidString]
        }

        add("selection.clear", group: "selection", "Deletes the selected pixels of the active layer (they become transparent).", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            try context.activate(layer.id)
            let session = context.session
            guard session.selection != nil else { throw AutomationError.conflict("there is no selection") }
            guard session.canEditPixels, layer.asset != nil else { throw AutomationError.conflict("the layer has no pixels to clear") }
            try await context.checkingBrushErrorAsync { await session.clearSelectedPixels() }
            return ["layer": layer.id.uuidString]
        }

        add("selection.copy", group: "selection", "Copies the selected pixels (or the whole layer without a selection) to the clipboard, as the app's Copy does.", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            try context.activate(try context.layerID(params))
            let session = context.session
            guard session.canCopyPixels || session.canCopyLayer else { throw AutomationError.conflict("nothing to copy") }
            session.copySelection()
            return ["copied": true]
        }

        add("selection.copyMerged", group: "selection", "Copies the selection across every visible layer, composited, to the clipboard.") { context, _ in
            try context.requireEditable()
            guard context.session.canCopyMerged else { throw AutomationError.conflict("nothing to copy") }
            context.session.copyMergedSelection()
            return ["copied": true]
        }

        add("selection.cut", group: "selection", "Copies then clears the selected pixels.", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            try context.activate(try context.layerID(params))
            let session = context.session
            guard session.selection != nil, session.canCopyPixels else { throw AutomationError.conflict("nothing to cut") }
            try await context.checkingBrushErrorAsync { await session.cutSelection() }
            return ["cut": true]
        }

        add("selection.paste", group: "selection", "Pastes the clipboard as a new layer above the active one: copied pixels go back where they came from, and a whole copied layer comes back complete, as Cmd-V does.") { context, _ in
            try context.requireEditable()
            let before = Set(try context.document().layers.map(\.id))
            // A whole layer copied without a selection is pasted by the workspace, as Cmd-V does; it only targets the
            // tab in front, and a layer from another tab arrives a moment later.
            if context.session === context.workspace.current.session, context.workspace.pasteCopiedLayer() {
                let deadline = ContinuousClock.now + .seconds(30)
                while try context.document().layers.allSatisfy({ before.contains($0.id) }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
            } else {
                guard context.session.canPaste else { throw AutomationError.conflict("the clipboard has no image") }
                context.session.paste()
            }
            guard let layer = try context.document().layers.last(where: { !before.contains($0.id) }) else { throw AutomationError.failed("nothing was pasted") }
            return AutomationState.layer(layer, in: try context.document(), session: context.session)
        }

        add("selection.layerViaCopy", group: "selection", "The selection's pixels become a new layer in place (Layer via Copy); without a selection, duplicates the layer.", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            try context.activate(try context.layerID(params))
            let before = Set(try context.document().layers.map(\.id))
            context.session.layerViaCopy()
            let document = try context.document()
            return document.layers.filter { !before.contains($0.id) }.map { AutomationState.layer($0, in: document, session: context.session) }
        }

        add("selection.pixels", group: "selection", "The selected pixels of a layer (or the merged composite) as base64 PNG with their document rect.", params: [
            AutomationDocs.layer, AutomationParamDoc("merged", "bool", "Composite of every visible layer instead of one layer."), AutomationParamDoc("mask", "bool", "The layer's mask instead of its pixels."),
        ]) { context, params in
            let session = context.session
            let rendered: (image: CGImage, region: CGRect)?
            if try params.bool("merged", default: false) {
                rendered = try session.renderMergedPixels()
            } else {
                let layer = try context.layer(params)
                rendered = try session.renderSelectedPixels(from: layer, mask: try params.bool("mask", default: false))
            }
            guard let rendered else { throw AutomationError.notFound("nothing under the selection") }
            let data = try AutomationImages.encode(rendered.image, format: .png)
            return ["rect": AutomationJSON.rect(rendered.region), "png": data.base64EncodedString()]
        }

        add("selection.transform", group: "selection", "Transforms the selected pixels of the active layer as a floating selection: move by dx/dy, scale by factor, rotate by degrees; then merges them back.", params: [
            AutomationDocs.layer, AutomationParamDoc("dx", "number"), AutomationParamDoc("dy", "number"), AutomationParamDoc("factor", "number"),
            AutomationParamDoc("factorY", "number"), AutomationParamDoc("degrees", "number"), AutomationParamDoc("flipX", "bool"), AutomationParamDoc("flipY", "bool"),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            try context.activate(layer.id)
            let session = context.session
            guard session.canTransformSelection else { throw AutomationError.conflict("needs a selection over the layer's pixels") }
            // Read before the selection floats: a bad parameter afterwards would leave the floating layer and its edit open.
            let fx = try params.optionalDouble("factor") ?? 1, fy = try params.optionalDouble("factorY") ?? fx
            let dx = try params.double("dx", default: 0), dy = try params.double("dy", default: 0)
            let degrees = try params.double("degrees", default: 0)
            let flipX = try params.optionalBool("flipX"), flipY = try params.optionalBool("flipY")
            await session.beginSelectionTransform()
            guard var draft = session.transformEdit?.draft else { throw AutomationError.conflict("the floating selection could not start") }
            let center = draft.center
            draft.size = CGSize(width: draft.size.width * CGFloat(fx), height: draft.size.height * CGFloat(fy))
            draft.origin = CGPoint(x: center.x - draft.size.width / 2 + CGFloat(dx), y: center.y - draft.size.height / 2 + CGFloat(dy))
            draft.rotation += CGFloat(degrees)
            if let flipX { draft.flipX = flipX }
            if let flipY { draft.flipY = flipY }
            guard draft.isValid else { session.cancelTransform(); throw AutomationError.badRequest("the resulting box is invalid") }
            session.previewTransform(draft)
            session.commitTransform()
            return AutomationState.selection(session.selection)
        }
    }
}

enum AutomationSelections {
    enum Mode: String { case replace, add, subtract, intersect }

    static func mode(_ params: AutomationParams) throws -> Mode {
        guard let text = try params.optionalString("mode") else { return .replace }
        switch AutomationParams.normalize(text) {
        case "replace", "new": return .replace
        case "add", "union": return .add
        case "subtract", "remove": return .subtract
        case "intersect", "intersection": return .intersect
        default: throw AutomationError.badRequest("\"mode\" must be replace, add, subtract or intersect")
        }
    }

    static func selectionMode(_ mode: Mode) -> SelectionMode {
        switch mode {
        case .replace, .intersect: return .replace
        case .add: return .add
        case .subtract: return .subtract
        }
    }

    /// Combines `shape` with the current selection in the requested mode, including intersect, which the app has no menu for.
    static func apply(_ context: AutomationContext, _ shape: CGPath, mode: Mode, name: String) throws {
        try context.requireEditable()
        let session = context.session
        guard session.canEditSelection else { throw AutomationError.conflict(context.blockedReason()) }
        if mode == .intersect {
            let combined = try combined(session.selection, with: shape, mode: .intersect, canvas: try context.document().size, antialiased: session.selectionAntialiased)
            session.setSelection(combined, name: name)
        } else {
            session.applySelection(shape, mode: selectionMode(mode), name: name)
        }
    }

    static func combined(_ current: DocumentSelection?, with shape: CGPath, mode: Mode, canvas: CGSize, antialiased: Bool) throws -> DocumentSelection? {
        let canvasPath = CGPath(rect: CGRect(origin: .zero, size: canvas), transform: nil)
        let clipped = shape.intersection(canvasPath, using: .winding)
        switch mode {
        case .replace: return DocumentSelection(path: clipped, antialiased: antialiased)
        case .add: return DocumentSelection(path: current.map { $0.path.union(clipped, using: .winding) } ?? clipped, antialiased: current?.antialiased ?? antialiased, feather: current?.feather ?? 0)
        case .subtract:
            guard let current else { return nil }
            return DocumentSelection(path: current.path.subtracting(clipped, using: .winding), antialiased: current.antialiased, feather: current.feather)
        case .intersect:
            guard let current else { return DocumentSelection(path: clipped, antialiased: antialiased) }
            return DocumentSelection(path: current.path.intersection(clipped, using: .winding), antialiased: current.antialiased, feather: current.feather)
        }
    }

    /// Runs a tool that only knows replace/add/subtract, then folds its result into the previous selection for intersect.
    static func combine(_ context: AutomationContext, mode: Mode, _ run: (SelectionMode) async -> Void) async throws {
        let session = context.session
        let previous = session.selection
        session.brushError = nil
        // For intersect, the tool's own step and the intersection that follows are recorded as one undo step.
        if mode == .intersect { session.beginEdit("Intersect Selection") }
        defer { if mode == .intersect { session.endEdit() } }
        await run(selectionMode(mode))
        if let error = session.brushError { session.brushError = nil; throw AutomationError.unprocessable(error) }
        if mode == .intersect {
            let found = session.selection
            guard let found else { session.setSelection(nil, name: "Intersect"); return }
            let combined = try combined(previous, with: found.path, mode: .intersect, canvas: try context.document().size, antialiased: session.selectionAntialiased)
            session.setSelection(combined, name: "Intersect")
        }
    }
}
