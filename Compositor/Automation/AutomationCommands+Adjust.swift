import Foundation
import CoreGraphics

extension AutomationRegistry {
    // MARK: - Adjustment layers and destructive adjustments

    func registerAdjustmentCommands() {
        group("adjustment", "Adjustment layers (non-destructive) and Image-menu adjustments applied to a layer's pixels: Levels, Curves, Hue/Saturation, Exposure, Gradient Map, Grain, Black & White, Color Balance, Invert.")

        add("adjustmentLayer.add", group: "adjustment", "Adds an adjustment layer above the active layer. Kinds: " + AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", ") + ".", params: [
            AutomationParamDoc("kind", "string", required: true),
            AutomationParamDoc("settings", "object", "The kind's settings (same shape adjustmentLayer.get reports); defaults to identity."),
            AutomationParamDoc("name", "string", "Layer name; the kind's name when omitted."),
            AutomationParamDoc("above", "string", "Layer to insert above; the active layer when omitted."),
        ]) { context, params in
            try context.requireEditable()
            let kind: AdjustmentKind = try params.enumeration("kind", cases: AdjustmentKind.allCases)
            let session = context.session
            if params.has("above") { try context.activate(try context.layerID(params, key: "above", allowActive: false)) }
            let before = Set(try context.document().layers.map(\.id))
            session.addAdjustment(kind)
            // The panel would open the kind's editor on seeing this; the API sets values directly instead.
            session.adjustmentEditingID = nil
            guard let layer = try context.document().layers.first(where: { !before.contains($0.id) }), var adjustment = layer.adjustment else {
                throw AutomationError.conflict("the adjustment layer could not be added (\(context.blockedReason()))")
            }
            if let settings = try params.optionalObject("settings") {
                try AutomationSettings.adjustment(settings, into: &adjustment)
                session.beginEdit("Edit \(kind.rawValue) Adjustment")
                session.updateAdjustment(layer.id, value: adjustment)
                session.endEdit()
            }
            if let name = try params.optionalString("name") { session.renameLayer(layer.id, to: name) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("adjustmentLayer.get", group: "adjustment", "An adjustment layer's kind and settings.", params: [AutomationDocs.layer]) { context, params in
            let layer = try context.layer(params)
            guard let adjustment = layer.adjustment else { throw AutomationError.unprocessable("\"\(layer.name)\" is not an adjustment layer") }
            return AutomationSettings.adjustment(adjustment)
        }

        add("adjustmentLayer.set", group: "adjustment", "Changes an adjustment layer's settings (partial object; unmentioned values stay).", params: [
            AutomationDocs.layer, AutomationParamDoc("settings", "object", required: true), AutomationParamDoc("reset", "bool", "Start from the identity adjustment."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard var adjustment = layer.adjustment else { throw AutomationError.unprocessable("\"\(layer.name)\" is not an adjustment layer") }
            if try params.bool("reset", default: false) { adjustment = LayerAdjustment(kind: adjustment.kind) }
            try AutomationSettings.adjustment(try params.object("settings"), into: &adjustment)
            let session = context.session
            session.beginEdit("Edit \(adjustment.kind.rawValue) Adjustment")
            session.updateAdjustment(layer.id, value: adjustment)
            session.endEdit()
            return AutomationSettings.adjustment(try context.layer(AutomationParams(["layer": layer.id.uuidString])).adjustment ?? adjustment)
        }

        add("adjust.levels", group: "adjustment", "Levels on the active (or given) layer's pixels, inside the selection if any. Give ranges, or `auto` = contrast, color or neutral.", params: [
            AutomationDocs.layer, AutomationParamDoc("channel", "string", "RGB (default), Red, Green or Blue for the shorthand keys."),
            AutomationParamDoc("black", "number", "Input black 0–254."), AutomationParamDoc("gamma", "number", "0.1–9.99."), AutomationParamDoc("white", "number", "Input white 1–255."),
            AutomationParamDoc("outputBlack", "number"), AutomationParamDoc("outputWhite", "number"),
            AutomationParamDoc("ranges", "[object]", "Four {black, gamma, white, outputBlack, outputWhite} objects: RGB, red, green, blue."),
            AutomationParamDoc("auto", "string", "Auto Levels: contrast, color or neutral (Color + neutral midtones)."),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            // Parameters are read before Levels opens, so a bad one can't leave the edit open.
            var autoMode: LevelsAuto?
            if let auto = try params.optionalString("auto") {
                switch AutomationParams.normalize(auto) {
                case "contrast": autoMode = .contrast
                case "color": autoMode = .color
                case "neutral", "colorneutral", "color+neutralmidtones": autoMode = .neutral
                default: throw AutomationError.badRequest("\"auto\" must be contrast, color or neutral")
                }
            }
            try AutomationAdjustments.prepare(context, layer: layer)
            session.beginLevels()
            guard let edit = session.levels else { throw AutomationError.conflict("Levels could not start: " + (session.brushError ?? "the layer must be a visible pixel layer with no empty selection")) }
            var settings = edit.settings
            if let mode = autoMode {
                await edit.histogramTask?.value
                guard edit.histogramReady else { session.cancelLevels(); throw AutomationError.failed("the histogram was not computed") }
                settings = mode.settings(histogram: edit.histogram)
            }
            do { try AutomationSettings.levels(params, into: &settings) } catch { session.cancelLevels(); throw error }
            session.updateLevels(settings, preview: false)
            try await context.checkingBrushErrorAsync { await session.commitLevels() }
            return ["layer": layer.id.uuidString, "applied": !settings.isIdentity, "levels": AutomationSettings.levels(settings)]
        }

        add("adjust.hueSaturation", group: "adjustment", "Hue/Saturation on a layer's pixels: hue, saturation, lightness for `range` (Master default), per-range `adjustments`, `bands`, `colorize`.", params: [
            AutomationDocs.layer, AutomationParamDoc("hue", "number", "±180 (0–360 when colorize)."), AutomationParamDoc("saturation", "number", "±100."),
            AutomationParamDoc("lightness", "number", "±100."), AutomationParamDoc("range", "string", "Master, Reds, Yellows, Greens, Cyans, Blues, Magentas."),
            AutomationParamDoc("colorize", "bool"), AutomationParamDoc("invertRange", "bool"), AutomationParamDoc("adjustments", "object", "{Reds: {hue, saturation, lightness}, …}"),
            AutomationParamDoc("bands", "object", "{Reds: [falloffStart, rangeStart, rangeEnd, falloffEnd], …} in degrees."),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            try AutomationAdjustments.prepare(context, layer: layer)
            session.beginHueSaturation()
            guard let edit = session.hueSaturation else { throw AutomationError.conflict("Hue/Saturation could not start: " + (session.brushError ?? "the layer must be a visible pixel layer with no empty selection")) }
            var settings = edit.settings
            do { try AutomationSettings.hueSaturation(params, into: &settings) } catch { session.cancelHueSaturation(); throw error }
            session.updateHueSaturation(settings, preview: false)
            try await context.checkingBrushErrorAsync { await session.commitHueSaturation() }
            return ["layer": layer.id.uuidString, "applied": !settings.isIdentity, "hueSaturation": AutomationSettings.hueSaturation(settings)]
        }

        add("adjust.invert", group: "adjustment", "Inverts a layer's colors (inside the selection when there is one).", params: [AutomationDocs.layer]) { context, params in
            let layer = try context.layer(params)
            try AutomationAdjustments.prepare(context, layer: layer)
            guard context.session.canInvert else { throw AutomationError.conflict("the layer cannot be inverted right now") }
            try await context.checkingBrushErrorAsync { await context.session.invertPixels() }
            return ["layer": layer.id.uuidString]
        }

        for kind in [FilterKind.curves, .exposure, .gradientMap, .grain, .blackWhite, .colorBalance] {
            add("adjust." + AutomationAdjustments.name(kind), group: "adjustment", "\(kind.rawValue) applied to a layer's pixels (destructive). Same settings as the adjustment layer of that kind.", params: [
                AutomationDocs.layer, AutomationParamDoc("settings", "object", "Settings object; keys may also be given at the top level."),
            ]) { context, params in
                try await AutomationAdjustments.applyFilter(kind, context, params)
            }
        }
    }

    // MARK: - Filters

    func registerFilterCommands() {
        group("filter", "Filters applied to a layer's pixels, inside the selection if any: blurs, noise, vignette, bloom, dither, tonal contrast, lens correction, Camera Raw, Remove Background and Content-Aware Fill.")

        add("filter.apply", group: "filter", "Applies any filter by `kind` (" + FilterKind.allCases.map(\.rawValue).joined(separator: ", ") + ") with a `settings` object.", params: [
            AutomationDocs.layer, AutomationParamDoc("kind", "string", required: true), AutomationParamDoc("settings", "object"),
            AutomationParamDoc("fromLast", "bool", "Start from the settings last applied instead of the defaults."),
        ]) { context, params in
            let kind: FilterKind = try params.enumeration("kind", cases: FilterKind.allCases)
            return try await AutomationAdjustments.applyFilter(kind, context, params)
        }

        add("filter.defaults", group: "filter", "The default (or last applied, with `fromLast`) settings of a filter kind, as filter.apply takes them.", params: [
            AutomationParamDoc("kind", "string", required: true), AutomationParamDoc("fromLast", "bool"),
        ]) { context, params in
            let kind: FilterKind = try params.enumeration("kind", cases: FilterKind.allCases)
            let settings = try params.bool("fromLast", default: false) ? context.session.filterSettings : FilterSettings()
            return AutomationSettings.filter(kind, settings)
        }

        for kind in [FilterKind.gaussianBlur, .motionBlur, .addNoise, .vignette, .bloomGlow, .dither, .tonalContrast, .lensCorrection, .removeBackground, .contentAwareFill] {
            let summary: String
            switch kind {
            case .gaussianBlur: summary = "Gaussian Blur: radius 0.1–250 px. The layer grows to hold the spread."
            case .motionBlur: summary = "Motion Blur: angle ±90°, distance 1–2000 px."
            case .addNoise: summary = "Add Noise: amount 0.1–400 %, gaussian (else uniform), monochromatic."
            case .vignette: summary = "Vignette: amount 0–100, color, midpoint 0–100, roundness ±100, feather 0–100, highlights 0–100. Works on an empty layer too."
            case .bloomGlow: summary = "Bloom / Glow: amount 0–100, radius 1–150 px."
            case .dither: summary = "Dither: style (Atkinson, Floyd–Steinberg, Bayer 2 × 2/4 × 4/8 × 8, Halftone Dots/Lines/Diamonds, Mac Patterns, ASCII, Scanlines), pixelSize, pixelShape, cellSize, textSize, lineSpacing, glow, dots, wobble, angle, levels, diffusion, density, contrast, colors, dark, light, lightOnDark, characters."
            case .tonalContrast: summary = "Tonal Contrast: amount 0–100, radius 1–100 px, shadows/midtones/highlights ±100."
            case .lensCorrection: summary = "Lens Correction: distortion ±100."
            case .removeBackground: summary = "Remove Background: adds a layer mask hiding the background (Vision). quality Basic/Advanced, refineEdges 0–40, matteContrast 0–100, shiftEdge ±10."
            case .contentAwareFill: summary = "Content-Aware Fill of the selection, extending the layer past its edges when the selection reaches beyond them."
            default: summary = kind.rawValue
            }
            add("filter." + AutomationAdjustments.name(kind), group: "filter", summary, params: [
                AutomationDocs.layer, AutomationParamDoc("settings", "object", "Settings; keys may also be given at the top level."),
                AutomationParamDoc("fromLast", "bool", "Start from the settings last applied."),
            ]) { context, params in
                try await AutomationAdjustments.applyFilter(kind, context, params)
            }
        }

        add("filter.cameraRaw", group: "filter", "Camera Raw on a layer's pixels: light, color/white balance, effects (texture, clarity, dehaze, glow, vignette, grain), curve, mixer, grading, detail, optics, geometry, calibration. Sliders may be flat (`exposure`) or grouped as filter.defaults shows.", params: [
            AutomationDocs.layer, AutomationParamDoc("settings", "object", "Camera Raw settings; keys may also be given at the top level."),
            AutomationParamDoc("fromLast", "bool", "Continue from the grade last applied (the app's own behavior)."),
            AutomationParamDoc("autoWhiteBalance", "bool", "Solve temperature and tint automatically before applying."),
            AutomationParamDoc("whiteBalancePoint", "point", "Sample a neutral at this document point for the white balance."),
            AutomationParamDoc("hide", "[string]", "Groups to leave out of the render, like the panel's eyes: light, color, effects, curve, mixer, grading, detail, optics, geometry, calibration."),
        ]) { context, params in
            try await AutomationAdjustments.applyFilter(.cameraRaw, context, params)
        }
    }
}

enum AutomationAdjustments {
    static func name(_ kind: FilterKind) -> String {
        switch kind {
        case .gaussianBlur: return "gaussianBlur"
        case .motionBlur: return "motionBlur"
        case .addNoise: return "addNoise"
        case .vignette: return "vignette"
        case .bloomGlow: return "bloom"
        case .dither: return "dither"
        case .tonalContrast: return "tonalContrast"
        case .lensCorrection: return "lensCorrection"
        case .cameraRaw: return "cameraRaw"
        case .removeBackground: return "removeBackground"
        case .contentAwareFill: return "contentAwareFill"
        case .curves: return "curves"
        case .exposure: return "exposure"
        case .gradientMap: return "gradientMap"
        case .grain: return "grain"
        case .blackWhite: return "blackWhite"
        case .colorBalance: return "colorBalance"
        }
    }

    /// Makes `layer` the single active pixel target and checks the adjustment gates, naming what is wrong.
    static func prepare(_ context: AutomationContext, layer: ImageLayer, allowingEmpty: Bool = false) throws {
        try context.requireEditable()
        guard !layer.isGroup else { throw AutomationError.unprocessable("\"\(layer.name)\" is a folder; adjustments need a pixel layer") }
        guard layer.adjustment == nil else { throw AutomationError.unprocessable("\"\(layer.name)\" is an adjustment layer; use adjustmentLayer.set") }
        guard layer.asset != nil || allowingEmpty else { throw AutomationError.unprocessable("\"\(layer.name)\" has no pixels yet") }
        try context.activate(layer.id)
        let session = context.session
        guard session.document?.effectiveVisibleIDs.contains(layer.id) == true else { throw AutomationError.unprocessable("\"\(layer.name)\" is hidden") }
        guard session.selection?.isEmpty != true else { throw AutomationError.unprocessable("the selection is empty, so nothing would change; deselect first") }
        guard session.levels == nil, session.hueSaturation == nil, session.filterEdit == nil else { throw AutomationError.conflict("another adjustment is open") }
    }

    static func applyFilter(_ kind: FilterKind, _ context: AutomationContext, _ params: AutomationParams) async throws -> Any {
        let layer = try context.layer(params)
        let session = context.session
        try prepare(context, layer: layer, allowingEmpty: kind == .vignette)
        if kind == .contentAwareFill {
            guard session.selection?.isEmpty == false else { throw AutomationError.unprocessable("Content-Aware Fill needs a selection") }
            guard session.canContentAwareFill else { throw AutomationError.conflict("Content-Aware Fill cannot run right now") }
        }
        var settings = try params.bool("fromLast", default: false) ? session.filterSettings : FilterSettings()
        let source = try params.optionalObject("settings") ?? params
        try AutomationSettings.filter(kind, source, into: &settings)
        if kind == .gradientMap, !source.has("shadows"), !source.has("highlights"), try !params.bool("fromLast", default: false) {
            settings.gradientMap.shadows = AdjustmentColor(session.foregroundColor)
            settings.gradientMap.highlights = AdjustmentColor(session.backgroundColor)
        }
        session.brushError = nil
        session.beginFilter(kind)
        guard let edit = session.filterEdit, edit.kind == kind else {
            throw AutomationError.conflict("\(kind.rawValue) could not start: " + (session.brushError ?? "the layer must be a visible pixel layer with no empty selection"))
        }
        // Anything that fails once the filter is open cancels it, so the session isn't left mid-edit.
        do {
            if kind == .cameraRaw {
                if let hide = try params.optionalStrings("hide") {
                    for group in hide {
                        switch AutomationParams.normalize(group) {
                        case "light": edit.showsCameraRawLight = false
                        case "color": edit.showsCameraRawColor = false
                        case "effects": edit.showsCameraRawEffects = false
                        case "curve": edit.showsCameraRawCurve = false
                        case "mixer": edit.showsCameraRawMixer = false
                        case "grading": edit.showsCameraRawGrading = false
                        case "detail": edit.showsCameraRawDetail = false
                        case "optics": edit.showsCameraRawOptics = false
                        case "geometry": edit.showsCameraRawGeometry = false
                        case "calibration": edit.showsCameraRawCalibration = false
                        default: throw AutomationError.badRequest("unknown Camera Raw group \"\(group)\"")
                        }
                    }
                }
                session.updateFilter(settings, preview: false)
                if try params.bool("autoWhiteBalance", default: false) {
                    await session.applyCameraRawAutoWhiteBalance()
                }
                if let point = try params.optionalPoint("whiteBalancePoint") {
                    edit.samplesWhiteBalance = true
                    session.sampleCameraRawWhiteBalance(at: point)
                    edit.samplesWhiteBalance = false
                }
                settings = edit.settings
            } else {
                session.updateFilter(settings, preview: kind.isAutomatic)
            }
            if kind.isAutomatic {
                // Automatic filters commit the prepared preview, so it has to finish first.
                await edit.previewTask?.value
                if let error = edit.previewError { throw AutomationError.unprocessable(error) }
            }
        } catch {
            if session.filterEdit != nil { session.cancelFilter() }
            throw error
        }
        try await context.checkingBrushErrorAsync { await session.commitFilter() }
        guard session.filterEdit == nil else { session.cancelFilter(); throw AutomationError.failed("the filter did not finish") }
        let after = try context.layer(AutomationParams(["layer": layer.id.uuidString]))
        return ["layer": layer.id.uuidString, "kind": kind.rawValue, "settings": AutomationSettings.filter(kind, settings),
                "transform": AutomationState.transform(after.transform), "hasMask": after.mask != nil]
    }
}
