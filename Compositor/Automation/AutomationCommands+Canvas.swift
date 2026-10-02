import Foundation
import CoreGraphics

extension AutomationRegistry {
    func registerCanvasCommands() {
        group("canvas", "The canvas: size, image size, trim, crop, flip, resolution, guides, grid and view settings.")

        add("canvas.size", group: "canvas", "Canvas Size: changes the canvas without scaling layers, anchored at one of nine positions; `fill` colors the new area.", params: [
            AutomationParamDoc("width", "int", "New width; unchanged when omitted."), AutomationParamDoc("height", "int"),
            AutomationParamDoc("relative", "bool", "Treat width/height as amounts to add."),
            AutomationParamDoc("anchor", "string", "topLeft, top, topRight, left, center (default), right, bottomLeft, bottom, bottomRight, or 0–8."),
            AutomationParamDoc("fill", "color", "Color for the added area (a new bottom layer); transparent when omitted. \"foreground\"/\"background\" use the palette."),
        ]) { context, params in
            let document = try context.document()
            var width = try params.optionalInt("width") ?? document.width
            var height = try params.optionalInt("height") ?? document.height
            if try params.bool("relative", default: false) {
                width = document.width + (try params.optionalInt("width") ?? 0)
                height = document.height + (try params.optionalInt("height") ?? 0)
            }
            guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
                throw AutomationError.badRequest("the canvas must be 1–\(DocumentLimits.maxSide) pixels on a side")
            }
            var options = CanvasSizeOptions(width: width, height: height)
            options.anchor = try AutomationCanvas.anchor(params)
            if let text = params.raw["fill"] as? String, ["foreground", "background"].contains(AutomationParams.normalize(text)) {
                let palette = AutomationParams.normalize(text) == "foreground" ? context.session.foregroundColor : context.session.backgroundColor
                options.fill = CanvasExtensionColor(red: palette.red, green: palette.green, blue: palette.blue)
            } else if let color = try params.optionalColor("fill") {
                options.fill = CanvasExtensionColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue))
            }
            try await AutomationCanvas.resize(context, actionName: "Canvas Size") { snapshot in
                try await CanvasResizer.shared.resize(snapshot, to: options)
            }
            return AutomationCanvas.report(context)
        }

        add("canvas.imageSize", group: "canvas", "Image Size: resamples every layer to a new pixel size, or changes only the resolution.", params: [
            AutomationParamDoc("width", "int"), AutomationParamDoc("height", "int"), AutomationParamDoc("percent", "number", "Scale both sides by a percentage."),
            AutomationParamDoc("keepRatio", "bool", "With one of width/height, keep the other in proportion (default true)."),
            AutomationParamDoc("resolution", "number", "Pixels per inch, 1–9600."), AutomationParamDoc("sampling", "string", "Nearest, Smooth or High quality (default)."),
        ]) { context, params in
            let document = try context.document()
            var width = document.width, height = document.height
            if let percent = try params.optionalDouble("percent") {
                guard percent > 0 else { throw AutomationError.badRequest("\"percent\" must be positive") }
                width = max(1, Int((Double(document.width) * percent / 100).rounded()))
                height = max(1, Int((Double(document.height) * percent / 100).rounded()))
            } else {
                let keep = try params.bool("keepRatio", default: true)
                if let w = try params.optionalInt("width") {
                    width = w
                    if keep, !params.has("height") { height = max(1, Int((Double(w) * Double(document.height) / Double(document.width)).rounded())) }
                }
                if let h = try params.optionalInt("height") {
                    height = h
                    if keep, !params.has("width") { width = max(1, Int((Double(h) * Double(document.width) / Double(document.height)).rounded())) }
                }
            }
            guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
                throw AutomationError.badRequest("the image must be 1–\(DocumentLimits.maxSide) pixels on a side")
            }
            let resolution = try params.double("resolution", in: 1...9600, default: document.resolution)
            let sampling: LayerSampling = params.has("sampling") ? try params.enumeration("sampling", cases: LayerSampling.allCases) : .high
            let options = ImageSizeOptions(width: width, height: height, resolution: resolution, sampling: sampling)
            try await AutomationCanvas.resize(context, actionName: "Image Size") { snapshot in
                try await ImageResizer.shared.resize(snapshot, to: options)
            }
            return AutomationCanvas.report(context)
        }

        add("canvas.trim", group: "canvas", "Trims the canvas to its content: transparent pixels, or the top-left / bottom-right pixel color.", params: [
            AutomationParamDoc("basedOn", "string", "Transparent Pixels (default), Top Left Pixel Color or Bottom Right Pixel Color."),
            AutomationParamDoc("top", "bool"), AutomationParamDoc("bottom", "bool"), AutomationParamDoc("left", "bool"), AutomationParamDoc("right", "bool"),
            AutomationParamDoc("tolerance", "int", "0–255 color tolerance."),
        ]) { context, params in
            var options = TrimOptions()
            if params.has("basedOn") { options.basedOn = try params.enumeration("basedOn", cases: TrimBasedOn.allCases) }
            try AutomationSettings.set(params, "top", &options.top); try AutomationSettings.set(params, "bottom", &options.bottom)
            try AutomationSettings.set(params, "left", &options.left); try AutomationSettings.set(params, "right", &options.right)
            if let tolerance = try params.optionalInt("tolerance") { options.tolerance = UInt8(min(255, max(0, tolerance))) }
            guard options.trimsAny else { throw AutomationError.badRequest("at least one side must be trimmed") }
            let session = context.session
            guard session.canStartProjectOperation else { throw AutomationError.conflict(context.blockedReason()) }
            session.commitTransform(); session.cancelCrop()
            let trimmed: Bool
            do { trimmed = try await session.trim(options: options) } catch { throw AutomationError.unprocessable(error.localizedDescription) }
            var report = AutomationCanvas.report(context)
            report["trimmed"] = trimmed
            return report
        }

        add("canvas.crop", group: "canvas", "Crops the canvas to a document rect (it may extend past the canvas; layers keep their pixels outside).", params: [
            AutomationParamDoc("rect", "rect", "The crop box; the selection's bounds when omitted."),
        ]) { context, params in
            let session = context.session
            let rect: CGRect
            if let given = try params.optionalRect("rect") { rect = CropGeometry.snapped(given) }
            else if let selection = session.selection, !selection.isEmpty { rect = CropGeometry.snapped(selection.path.boundingBoxOfPath) }
            else { throw AutomationError.badRequest("give \"rect\" or make a selection first") }
            guard CropGeometry.valid(rect) else { throw AutomationError.badRequest("the crop must be 1–\(DocumentLimits.maxSide) pixels on a side") }
            guard session.canStartProjectOperation else { throw AutomationError.conflict(context.blockedReason()) }
            session.commitTransform()
            session.cropRect = rect
            session.cropError = nil
            await session.commitCrop()
            if let error = session.cropError { session.cropError = nil; session.cancelCrop(); throw AutomationError.unprocessable(error) }
            session.cancelCrop()
            return AutomationCanvas.report(context)
        }

        add("canvas.flip", group: "canvas", "Flips the whole canvas (every layer, mask, guide and the selection).", params: [
            AutomationParamDoc("horizontal", "bool", "true (default) flips left-right; false top-bottom."),
        ]) { context, params in
            try context.requireEditable()
            context.session.flipCanvas(horizontally: try params.bool("horizontal", default: true))
            return AutomationCanvas.report(context)
        }

        add("canvas.setResolution", group: "canvas", "Sets the document resolution in pixels per inch without resampling.", params: [AutomationParamDoc("resolution", "number", required: true, "1–9600")]) { context, params in
            let document = try context.document()
            let resolution = try params.double("resolution", in: 1...9600)
            let options = ImageSizeOptions(width: document.width, height: document.height, resolution: resolution, sampling: .high)
            try await AutomationCanvas.resize(context, actionName: "Image Size") { snapshot in try await ImageResizer.shared.resize(snapshot, to: options) }
            return AutomationCanvas.report(context)
        }

        // MARK: Guides and grid

        add("guides.list", group: "canvas", "The alignment guides.") { context, _ in
            try context.document().guides.map { ["id": $0.id.uuidString, "axis": $0.axis.rawValue, "position": $0.position] }
        }

        add("guides.add", group: "canvas", "Adds a horizontal or vertical guide at `position` (document pixels).", params: [
            AutomationParamDoc("axis", "string", required: true, "horizontal or vertical"), AutomationParamDoc("position", "number", required: true),
        ]) { context, params in
            try context.requireEditable()
            let axis: CanvasGuide.Axis = try params.enumeration("axis", cases: [.horizontal, .vertical])
            let position = try params.double("position", in: -1_000_000...1_000_000)
            guard context.session.canEditGuides else { throw AutomationError.conflict("guides are locked or cannot be edited right now") }
            let guide = CanvasGuide(id: UUID(), axis: axis, position: position)
            context.session.addGuide(guide)
            return ["id": guide.id.uuidString, "axis": axis.rawValue, "position": position]
        }

        add("guides.set", group: "canvas", "Replaces every guide with the given list of {axis, position}.", params: [AutomationParamDoc("guides", "[object]", required: true)]) { context, params in
            try context.requireEditable()
            let guides = try params.objects("guides").map { object in
                let axis: CanvasGuide.Axis = try object.enumeration("axis", cases: [.horizontal, .vertical])
                return CanvasGuide(id: UUID(), axis: axis, position: try object.double("position", in: -1_000_000...1_000_000))
            }
            guard guides.count <= 1000 else { throw AutomationError.badRequest("at most 1000 guides") }
            let session = context.session
            guard session.canEditGuides else { throw AutomationError.conflict("guides are locked or cannot be edited right now") }
            session.beginEdit("Set Guides")
            session.document?.guides = guides
            session.endEdit()
            if !guides.isEmpty { session.showsGuides = true }
            return guides.map { ["id": $0.id.uuidString, "axis": $0.axis.rawValue, "position": $0.position] }
        }

        add("guides.remove", group: "canvas", "Removes one guide by id, or all of them.", params: [AutomationParamDoc("id", "string")]) { context, params in
            try context.requireEditable()
            let session = context.session
            guard session.canEditGuides else { throw AutomationError.conflict("guides are locked or cannot be edited right now") }
            if let text = try params.optionalString("id") {
                guard let id = UUID(uuidString: text), session.document?.guides.contains(where: { $0.id == id }) == true else { throw AutomationError.notFound("no guide \(text)") }
                session.beginEdit("Delete Guide")
                session.document?.guides.removeAll { $0.id == id }
                session.endEdit()
            } else {
                session.clearGuides()
            }
            return ["count": session.document?.guides.count ?? 0]
        }

        add("view.set", group: "canvas", "View settings (not saved in the project): grid, guides, rulers, snapping, pixel grid, transform controls, zoom.", params: [
            AutomationParamDoc("showsGrid", "bool"), AutomationParamDoc("gridSpacing", "int", "2–4096"), AutomationParamDoc("gridSubdivisions", "int", "1–64"),
            AutomationParamDoc("gridStyle", "string", "Lines, Dashed Lines or Dots"), AutomationParamDoc("gridPreset", "string", "Light Gray … Custom"),
            AutomationParamDoc("gridColor", "color", "Custom grid color"), AutomationParamDoc("gridOpacity", "int", "1–100"),
            AutomationParamDoc("showsGuides", "bool"), AutomationParamDoc("showsRulers", "bool"), AutomationParamDoc("showsPixelGrid", "bool"),
            AutomationParamDoc("snap", "bool"), AutomationParamDoc("snapToGuides", "bool"), AutomationParamDoc("snapToGrid", "bool"),
            AutomationParamDoc("snapToLayers", "bool"), AutomationParamDoc("snapToDocumentBounds", "bool"), AutomationParamDoc("locksGuides", "bool"),
            AutomationParamDoc("showsTransformControls", "bool"), AutomationParamDoc("autoSelect", "bool"),
            AutomationParamDoc("zoom", "number", "Zoom factor (1 = actual pixels); \"fit\" fits the canvas."),
        ]) { context, params in
            let session = context.session
            try AutomationSettings.set(params, "showsGrid", &session.showsGrid)
            if params.has("gridSpacing") || params.has("gridSubdivisions") {
                session.layoutGrid = LayoutGrid(spacing: try params.optionalInt("gridSpacing") ?? session.layoutGrid.spacing,
                                                subdivisions: try params.optionalInt("gridSubdivisions") ?? session.layoutGrid.subdivisions)
            }
            var appearance = session.gridAppearance
            if params.has("gridStyle") { appearance.style = try params.enumeration("gridStyle", cases: GridAppearance.Style.allCases) }
            if params.has("gridPreset") { appearance.preset = try params.enumeration("gridPreset", cases: GridAppearance.Preset.allCases) }
            if let color = try params.optionalColor("gridColor") { appearance.customColor = AutomationSettings.palette(color); appearance.preset = .custom }
            if let opacity = try params.optionalInt("gridOpacity") { appearance.opacity = min(100, max(1, opacity)) }
            session.gridAppearance = appearance
            try AutomationSettings.set(params, "showsGuides", &session.showsGuides)
            try AutomationSettings.set(params, "showsRulers", &session.showsRulers)
            try AutomationSettings.set(params, "showsPixelGrid", &session.showsPixelGrid)
            if let snap = try params.optionalBool("snap") { session.snapEnabled = snap; session.snappingEnabled = snap }
            try AutomationSettings.set(params, "snapToGuides", &session.snapToGuides)
            try AutomationSettings.set(params, "snapToGrid", &session.snapToGrid)
            try AutomationSettings.set(params, "snapToLayers", &session.snapToLayers)
            try AutomationSettings.set(params, "snapToDocumentBounds", &session.snapToDocumentBounds)
            try AutomationSettings.set(params, "locksGuides", &session.locksGuides)
            try AutomationSettings.set(params, "showsTransformControls", &session.showsTransformControls)
            try AutomationSettings.set(params, "autoSelect", &session.transformAutoSelect)
            if let text = params.raw["zoom"] as? String, AutomationParams.normalize(text) == "fit" { session.fit() }
            else if let zoom = try params.optionalDouble("zoom") { session.zoom(to: CGFloat(zoom)) }
            return AutomationJSON.nullable(AutomationState.tools(session)["view"])
        }
    }
}

enum AutomationCanvas {
    static func anchor(_ params: AutomationParams) throws -> Int {
        guard params.has("anchor") else { return 4 }
        if let number = try? params.optionalInt("anchor") {
            guard (0...8).contains(number) else { throw AutomationError.badRequest("\"anchor\" must be 0–8") }
            return number
        }
        let names = ["topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright"]
        let aliases = ["topcenter": 1, "middleleft": 3, "middle": 4, "middlecenter": 4, "middleright": 5, "bottomcenter": 7]
        let text = AutomationParams.normalize(try params.string("anchor"))
        if let index = names.firstIndex(of: text) { return index }
        if let index = aliases[text] { return index }
        throw AutomationError.badRequest("\"anchor\" must be one of topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight")
    }

    /// Snapshot, resize off the main actor, install, as the Canvas Size / Image Size sheets do.
    static func resize(_ context: AutomationContext, actionName: String, _ work: (ProjectSnapshot) async throws -> ProjectSnapshot) async throws {
        let session = context.session
        guard session.canStartProjectOperation else { throw AutomationError.conflict(context.blockedReason()) }
        session.commitTransform()
        session.cancelCrop()
        guard let snapshot = session.projectSnapshot() else { throw AutomationError.conflict("no document is open") }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        let resized: ProjectSnapshot
        do { resized = try await work(snapshot) } catch { throw AutomationError.unprocessable(error.localizedDescription) }
        session.applyDocumentSize(resized, actionName: actionName)
    }

    static func report(_ context: AutomationContext) -> [String: Any] {
        guard let document = context.session.document else { return [:] }
        return ["width": document.width, "height": document.height, "resolution": document.resolution, "layerCount": document.layers.count]
    }
}
