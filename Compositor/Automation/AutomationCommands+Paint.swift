import Foundation
import CoreGraphics

extension AutomationRegistry {
    func registerPaintCommands() {
        group("paint", "Painting and retouching: brush and eraser strokes, spot healing, clone stamp, blur, smudge, liquify, gradients, shapes and text.")

        add("paint.stroke", group: "paint", "Paints (or erases) a brush stroke through document points on a layer's pixels or mask. Several strokes with `strokes`.", params: [
            AutomationDocs.layer, AutomationParamDoc("points", "[point]", "The stroke path; one point is a dab."),
            AutomationParamDoc("strokes", "[[point]]", "Several strokes with the same settings."),
            AutomationParamDoc("mode", "string", "paint (default) or erase."), AutomationParamDoc("mask", "bool", "Paint the layer's mask (white reveals, black hides)."),
            AutomationDocs.color, AutomationParamDoc("diameter", "number", "1–2000 px."), AutomationParamDoc("hardness", "number", "0–1."),
            AutomationParamDoc("opacity", "number", "0.01–1."), AutomationParamDoc("smoothing", "number", "0–100."),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            let mask = try params.bool("mask", default: false)
            try AutomationPainting.prepare(context, layer: layer, mask: mask, tool: .brush)
            let mode = try params.optionalString("mode").map(AutomationParams.normalize) ?? "paint"
            switch mode {
            case "paint", "brush": session.brushMode = .paint
            case "erase", "eraser": session.brushMode = .erase
            default: throw AutomationError.badRequest("\"mode\" must be paint or erase")
            }
            try AutomationPainting.applyBrushSettings(params, session)
            if let color = try params.optionalColor("color") {
                if mask { session.maskPaintWhite = color.red + color.green + color.blue >= 1.5 } else { session.foregroundColor = AutomationSettings.palette(color) }
            }
            let strokes = try AutomationPainting.strokes(params)
            var count = 0
            for stroke in strokes { try AutomationPainting.stroke(context, stroke); count += 1 }
            return ["layer": layer.id.uuidString, "strokes": count, "mode": session.brushMode.rawValue, "mask": mask]
        }

        add("paint.heal", group: "paint", "Spot Healing Brush along document points (content-aware).", params: [
            AutomationDocs.layer, AutomationParamDoc("points", "[point]"), AutomationParamDoc("strokes", "[[point]]"),
            AutomationParamDoc("healingMode", "string", "Content-Aware (default), Create Texture or Proximity Match."),
            AutomationParamDoc("diameter", "number"), AutomationParamDoc("hardness", "number"), AutomationParamDoc("opacity", "number"),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            try AutomationPainting.prepare(context, layer: layer, mask: false, tool: .spotHealing)
            if params.has("healingMode") { session.spotHealingMode = try params.enumeration("healingMode", cases: SpotHealingMode.allCases) }
            try AutomationPainting.applyBrushSettings(params, session)
            let strokes = try AutomationPainting.strokes(params)
            for stroke in strokes { try AutomationPainting.stroke(context, stroke) }
            return ["layer": layer.id.uuidString, "strokes": strokes.count, "healingMode": session.spotHealingMode.rawValue]
        }

        add("paint.clone", group: "paint", "Clone Stamp: copies from `source` (document point) along the stroke.", params: [
            AutomationDocs.layer, AutomationParamDoc("source", "point", required: true, "Where to copy from, for the first point of the stroke."),
            AutomationParamDoc("points", "[point]"), AutomationParamDoc("strokes", "[[point]]"),
            AutomationParamDoc("aligned", "bool", "Keep the offset between strokes (default true)."), AutomationParamDoc("sampleAllLayers", "bool"),
            AutomationParamDoc("diameter", "number"), AutomationParamDoc("hardness", "number"), AutomationParamDoc("opacity", "number"),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            try AutomationPainting.prepare(context, layer: layer, mask: false, tool: .cloneStamp)
            if let aligned = try params.optionalBool("aligned") { session.cloneSettings.aligned = aligned }
            if let all = try params.optionalBool("sampleAllLayers") { session.cloneSettings.sampleAllLayers = all }
            try AutomationPainting.applyBrushSettings(params, session)
            session.setCloneSource(try params.point("source"))
            let strokes = try AutomationPainting.strokes(params)
            for stroke in strokes { try AutomationPainting.stroke(context, stroke) }
            return ["layer": layer.id.uuidString, "strokes": strokes.count]
        }

        add("paint.blur", group: "paint", "Blur brush along document points, on pixels or a mask.", params: [
            AutomationDocs.layer, AutomationParamDoc("points", "[point]"), AutomationParamDoc("strokes", "[[point]]"), AutomationParamDoc("mask", "bool"),
            AutomationParamDoc("radius", "number", "Blur radius 0.5–50."), AutomationParamDoc("diameter", "number"), AutomationParamDoc("hardness", "number"), AutomationParamDoc("opacity", "number"),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            let mask = try params.bool("mask", default: false)
            try AutomationPainting.prepare(context, layer: layer, mask: mask, tool: .blur)
            session.blurMode = .blur
            try AutomationPainting.applyBrushSettings(params, session)
            if params.has("radius") { session.brushSettings.blurRadius = CGFloat(try params.double("radius", in: 0.5...50)) }
            let strokes = try AutomationPainting.strokes(params)
            for stroke in strokes { try AutomationPainting.stroke(context, stroke) }
            return ["layer": layer.id.uuidString, "strokes": strokes.count]
        }

        add("paint.smudge", group: "paint", "Smudge (drag pixels) along document points; `strength` is the brush opacity.", params: [
            AutomationDocs.layer, AutomationParamDoc("points", "[point]"), AutomationParamDoc("strokes", "[[point]]"),
            AutomationParamDoc("strength", "number", "0.01–1."), AutomationParamDoc("diameter", "number"), AutomationParamDoc("hardness", "number"),
        ]) { context, params in
            try await AutomationPainting.warp(context, params, mode: .smudge)
        }

        add("paint.liquify", group: "paint", "Liquify (push pixels) along document points; `strength` is the brush opacity.", params: [
            AutomationDocs.layer, AutomationParamDoc("points", "[point]"), AutomationParamDoc("strokes", "[[point]]"),
            AutomationParamDoc("strength", "number", "0.01–1."), AutomationParamDoc("diameter", "number"), AutomationParamDoc("hardness", "number"),
        ]) { context, params in
            try await AutomationPainting.warp(context, params, mode: .liquify)
        }

        add("paint.gradient", group: "paint", "Fills the layer (or selection, or mask) with a linear or radial gradient from `from` to `to`.", params: [
            AutomationDocs.layer, AutomationParamDoc("from", "point", required: true), AutomationParamDoc("to", "point", required: true),
            AutomationParamDoc("shape", "string", "Linear (default) or Radial."), AutomationParamDoc("style", "string", "Foreground to Transparent (default) or Foreground to Background."),
            AutomationParamDoc("reversed", "bool"), AutomationParamDoc("opacity", "number", "0–1."), AutomationParamDoc("mask", "bool", "Draw on the layer's mask."),
            AutomationParamDoc("color", "color", "Foreground color."), AutomationParamDoc("backgroundColor", "color"),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            let mask = try params.bool("mask", default: false)
            try AutomationPainting.prepare(context, layer: layer, mask: mask, tool: .gradient)
            var settings = session.gradientSettings
            try AutomationSettings.set(params, "shape", &settings.shape)
            try AutomationSettings.set(params, "style", &settings.style)
            try AutomationSettings.set(params, "reversed", &settings.reversed)
            if let opacity = try params.optionalDouble("opacity") { settings.opacity = CGFloat(min(1, max(0, opacity))) }
            session.gradientSettings = settings
            if let color = try params.optionalColor("color") {
                if mask { session.maskPaintWhite = color.red + color.green + color.blue >= 1.5 } else { session.foregroundColor = AutomationSettings.palette(color) }
            }
            if let color = try params.optionalColor("backgroundColor") { session.backgroundColor = AutomationSettings.palette(color) }
            let from = try params.point("from"), to = try params.point("to")
            guard hypot(to.x - from.x, to.y - from.y) >= 0.5 else { throw AutomationError.badRequest("\"from\" and \"to\" must differ") }
            session.brushError = nil
            session.beginGradient(at: from)
            guard session.gradientEdit != nil else { throw AutomationError.conflict("the gradient could not start: " + (session.brushError ?? session.paintRefusal ?? "unknown reason")) }
            session.moveGradient(end: to)
            try await context.checkingBrushErrorAsync { await session.commitGradient() }
            guard session.gradientEdit == nil else { session.cancelGradient(); throw AutomationError.failed("the gradient did not commit") }
            return ["layer": layer.id.uuidString, "gradient": ["shape": settings.shape.rawValue, "style": settings.style.rawValue, "reversed": settings.reversed, "opacity": Double(settings.opacity)]]
        }

        add("shape.add", group: "paint", "Adds a shape layer: rectangle, ellipse or line, filled with a color, above the active layer.", params: [
            AutomationParamDoc("kind", "string", required: true, "Rectangle, Ellipse or Line."), AutomationParamDoc("rect", "rect", "Box in document pixels (rectangle/ellipse, or the line's box)."),
            AutomationParamDoc("from", "point", "Line start."), AutomationParamDoc("to", "point", "Line end."),
            AutomationDocs.color, AutomationParamDoc("cornerRadius", "number", "Rectangles only."), AutomationParamDoc("lineWidth", "number", "Lines only, default 4."),
            AutomationParamDoc("name", "string"),
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            let kind: ShapeKind = try params.enumeration("kind", cases: ShapeKind.allCases)
            let color = try params.optionalColor("color").map(AutomationSettings.palette) ?? session.foregroundColor
            var rect: CGRect
            var start: CGPoint?, end: CGPoint?
            var lineWidth: CGFloat = 0
            if kind == .line {
                let from = try params.point("from"), to = try params.point("to")
                lineWidth = CGFloat(try params.double("lineWidth", in: 1...2000, default: session.shapeLineWidth))
                let pad = lineWidth / 2 + 1
                rect = CGRect(x: min(from.x, to.x) - pad, y: min(from.y, to.y) - pad, width: abs(to.x - from.x) + 2 * pad, height: abs(to.y - from.y) + 2 * pad).integral
                start = CGPoint(x: (from.x - rect.minX) / rect.width, y: (from.y - rect.minY) / rect.height)
                end = CGPoint(x: (to.x - rect.minX) / rect.width, y: (to.y - rect.minY) / rect.height)
            } else {
                rect = CropGeometry.snapped(try params.rect("rect"))
            }
            guard rect.width >= 1, rect.height >= 1, rect.width * rect.height <= CGFloat(EditorSession.maxShapePixels) else { throw AutomationError.badRequest("the shape box must be at least 1×1 and at most \(EditorSession.maxShapePixels) pixels") }
            let radius = CGFloat(try params.double("cornerRadius", default: 0))
            let image = try EditorSession.shapeImage(kind, size: rect.size, color: color, cornerRadius: radius, lineWidth: lineWidth, start: start, end: end)
            let style = LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue, cornerRadius: radius,
                                        lineWidth: kind == .line ? lineWidth : nil, start: start, end: end)
            let before = Set(try context.document().layers.map(\.id))
            let name = try params.optionalString("name") ?? session.nextShapeName(kind)
            session.addPixelLayer(image, at: rect.origin, name: name, editName: kind.rawValue, dropsSelection: false, shape: LayerShape(style: style, image: image))
            guard let layer = try context.document().layers.first(where: { !before.contains($0.id) }) else { throw AutomationError.conflict("the shape could not be added (\(context.blockedReason()))") }
            return AutomationState.layer(layer, in: try context.document(), session: session)
        }

        add("text.add", group: "paint", "Adds an editable text layer with its top-left at `origin` (or a paragraph box with `boxSize`).", params: [
            AutomationParamDoc("content", "string", required: true), AutomationParamDoc("origin", "point", required: true),
            AutomationParamDoc("fontName", "string", "PostScript name, default Helvetica."), AutomationParamDoc("fontSize", "number", "1–2000 px, default 72."),
            AutomationDocs.color, AutomationParamDoc("alignment", "string", "Left, Center or Right."), AutomationParamDoc("tracking", "number", "−100…1000."),
            AutomationParamDoc("leading", "number", "0 = auto; 0–5000."), AutomationParamDoc("boxSize", "size", "Paragraph box; text wraps inside."),
            AutomationParamDoc("colorRuns", "[object]", "[{location, length, color}] in UTF-16 units."), AutomationParamDoc("fontRuns", "[object]", "[{location, length, fontName}]."),
            AutomationParamDoc("name", "string"),
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            let document = try context.document()
            var style = session.textDefaults
            style.colorRuns = nil; style.fontRuns = nil
            style.content = ""
            let fg = session.foregroundColor
            style.red = fg.red; style.green = fg.green; style.blue = fg.blue
            try AutomationSettings.textStyle(params, into: &style)
            guard !style.content.isEmpty else { throw AutomationError.badRequest("\"content\" must not be empty") }
            let draft = TextDraft(documentID: document.id, layerID: nil, origin: try params.point("origin"), style: style)
            let before = Set(document.layers.map(\.id))
            guard session.applyText(draft) else { throw AutomationError.conflict("the text could not be added (\(context.blockedReason()))") }
            guard let layer = try context.document().layers.first(where: { !before.contains($0.id) }) else { throw AutomationError.failed("no text layer appeared") }
            if let name = try params.optionalString("name") { session.renameLayer(layer.id, to: name) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("text.set", group: "paint", "Changes an editable text layer's content or style (partial; unmentioned values stay).", params: [
            AutomationDocs.layer, AutomationParamDoc("content", "string"), AutomationParamDoc("fontName", "string"), AutomationParamDoc("fontSize", "number"),
            AutomationDocs.color, AutomationParamDoc("alignment", "string"), AutomationParamDoc("tracking", "number"), AutomationParamDoc("leading", "number"),
            AutomationParamDoc("boxSize", "size", "null for point text."), AutomationParamDoc("colorRuns", "[object]"), AutomationParamDoc("fontRuns", "[object]"),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard let text = layer.liveText else { throw AutomationError.unprocessable("\"\(layer.name)\" is not editable text any more (painting on a text layer rasterizes it)") }
            let session = context.session
            try context.activate(layer.id)
            var style = text.style
            try AutomationSettings.textStyle(params, into: &style)
            let document = try context.document()
            let draft = TextDraft(documentID: document.id, layerID: layer.id, origin: layer.transform.origin, transform: layer.transform, style: style)
            guard session.applyText(draft) else { throw AutomationError.conflict("the text could not be changed (\(context.blockedReason()))") }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("text.defaults", group: "paint", "Reads or sets the style new text starts from.", params: [
            AutomationParamDoc("fontName", "string"), AutomationParamDoc("fontSize", "number"), AutomationDocs.color, AutomationParamDoc("alignment", "string"),
            AutomationParamDoc("tracking", "number"), AutomationParamDoc("leading", "number"),
        ]) { context, params in
            var style = context.session.textDefaults
            try AutomationSettings.textStyle(params, into: &style)
            context.session.textDefaults = style
            return AutomationSettings.textStyle(style)
        }
    }
}

enum AutomationPainting {
    static func prepare(_ context: AutomationContext, layer: ImageLayer, mask: Bool, tool: NavigationTool) throws {
        try context.requireEditable()
        let session = context.session
        if mask { guard layer.mask?.isEnabled == true else { throw AutomationError.unprocessable("\"\(layer.name)\" needs an enabled mask to paint on") } }
        else {
            guard !layer.isGroup else { throw AutomationError.unprocessable("\"\(layer.name)\" is a folder; paint its mask or a layer inside") }
            guard layer.adjustment == nil else { throw AutomationError.unprocessable("adjustment layers have no pixels; paint their mask instead") }
        }
        try context.activate(layer.id, mask: mask)
        session.selectTool(tool)
        guard session.tool == tool else { throw AutomationError.conflict("the tool could not be selected (\(context.blockedReason()))") }
        if tool.isBrushTool, !session.canPaint { throw AutomationError.unprocessable(session.paintRefusal ?? "the layer cannot be painted right now") }
    }

    static func applyBrushSettings(_ params: AutomationParams, _ session: EditorSession) throws {
        var settings = session.brushSettings
        if let diameter = try params.optionalDouble("diameter") {
            guard (1...2000).contains(diameter) else { throw AutomationError.badRequest("\"diameter\" must be 1–2000") }
            settings.diameter = CGFloat(diameter)
        }
        if let hardness = try params.optionalDouble("hardness") {
            guard (0...1).contains(hardness) else { throw AutomationError.badRequest("\"hardness\" must be 0–1") }
            settings.hardness = CGFloat(hardness)
        }
        if let opacity = try params.optionalDouble("opacity") ?? params.optionalDouble("strength") {
            guard (0.01...1).contains(opacity) else { throw AutomationError.badRequest("\"opacity\" must be 0.01–1") }
            settings.opacity = CGFloat(opacity)
        }
        if let smoothing = try params.optionalDouble("smoothing") {
            guard (0...100).contains(smoothing) else { throw AutomationError.badRequest("\"smoothing\" must be 0–100") }
            settings.smoothing = CGFloat(smoothing)
        }
        session.brushSettings = settings
    }

    static func strokes(_ params: AutomationParams) throws -> [[CGPoint]] {
        var strokes: [[CGPoint]] = []
        if params.has("points") { strokes.append(try params.points("points")) }
        if params.has("strokes") {
            for (index, element) in try params.array("strokes").enumerated() {
                guard let list = element as? [Any] else { throw AutomationError.badRequest("\"strokes[\(index)]\" must be a list of points") }
                strokes.append(try list.enumerated().map { try AutomationParams.point($1, named: "strokes[\(index)][\($0)]") })
            }
        }
        guard !strokes.isEmpty, strokes.allSatisfy({ !$0.isEmpty }) else { throw AutomationError.badRequest("give \"points\" or \"strokes\" with at least one point") }
        return strokes
    }

    /// One stroke through `points`, committed as one undo step.
    static func stroke(_ context: AutomationContext, _ points: [CGPoint]) throws {
        let session = context.session
        session.brushError = nil
        session.beginBrush(at: points[0])
        guard session.brushStroke != nil || session.warpStroke != nil else {
            throw AutomationError.unprocessable(session.brushError ?? session.paintRefusal ?? "the stroke could not start")
        }
        for point in points.dropFirst() {
            session.continueBrush(at: point)
            if let error = session.brushError { session.cancelBrush(); session.brushError = nil; throw AutomationError.unprocessable(error) }
        }
        guard session.finishBrushImmediately() else { session.cancelBrush(); throw AutomationError.conflict("the project is busy") }
        if let error = session.brushError { session.brushError = nil; throw AutomationError.unprocessable(error) }
    }

    static func warp(_ context: AutomationContext, _ params: AutomationParams, mode: BlurToolMode) async throws -> Any {
        let layer = try context.layer(params)
        let session = context.session
        try prepare(context, layer: layer, mask: false, tool: .blur)
        guard layer.asset != nil else { throw AutomationError.unprocessable("\"\(layer.name)\" has no pixels yet") }
        session.blurMode = mode
        try applyBrushSettings(params, session)
        let strokes = try strokes(params)
        for stroke in strokes { try self.stroke(context, stroke) }
        return ["layer": layer.id.uuidString, "strokes": strokes.count, "mode": mode.rawValue]
    }
}
