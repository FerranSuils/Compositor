import Foundation
import CoreGraphics

/// JSON in and out for every settings struct the editor has. Readers report the full value; writers take a partial
/// object and change only the keys present, so a script can say `{"exposure": 0.5}` without restating the rest.
enum AutomationSettings {
    // MARK: Colors

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> [String: Any] {
        AutomationColor(red: Double(red), green: Double(green), blue: Double(blue)).json
    }

    static func color(_ color: AdjustmentColor) -> [String: Any] {
        AutomationColor(red: color.red, green: color.green, blue: color.blue).json
    }

    static func adjustmentColor(_ params: AutomationParams, _ key: String, into value: inout AdjustmentColor) throws {
        if let color = try params.optionalColor(key) { value = AdjustmentColor(red: color.red, green: color.green, blue: color.blue) }
    }

    static func palette(_ color: AutomationColor) -> PaletteColor {
        PaletteColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue))
    }

    // MARK: Small helpers

    static func set(_ params: AutomationParams, _ key: String, _ value: inout Double) throws {
        if let number = try params.optionalDouble(key) { value = number }
    }

    static func set(_ params: AutomationParams, _ key: String, _ value: inout CGFloat) throws {
        if let number = try params.optionalDouble(key) { value = CGFloat(number) }
    }

    static func set(_ params: AutomationParams, _ key: String, _ value: inout Float) throws {
        if let number = try params.optionalDouble(key) { value = Float(number) }
    }

    static func set(_ params: AutomationParams, _ key: String, _ value: inout Bool) throws {
        if let flag = try params.optionalBool(key) { value = flag }
    }

    static func set(_ params: AutomationParams, _ key: String, _ value: inout Int) throws {
        if let number = try params.optionalInt(key) { value = number }
    }

    static func set<T: RawRepresentable & CaseIterable>(_ params: AutomationParams, _ key: String, _ value: inout T) throws where T.RawValue == String {
        if params.has(key) { value = try params.enumeration(key, cases: Array(T.allCases)) }
    }

    static func curvePoints(_ points: [CurvePoint]) -> [[Double]] { points.map { [$0.x, $0.y] } }

    static func curvePoints(_ params: AutomationParams, _ key: String) throws -> [CurvePoint]? {
        guard params.has(key) else { return nil }
        return try params.array(key).enumerated().map { index, element in
            let point = try AutomationParams.point(element, named: "\(key)[\(index)]")
            return CurvePoint(x: Double(point.x), y: Double(point.y))
        }
    }

    // MARK: Levels

    static func levels(_ settings: LevelsSettings) -> [String: Any] {
        [
            "channel": settings.channel.rawValue,
            "ranges": settings.ranges.map { ["black": $0.black, "gamma": $0.gamma, "white": $0.white, "outputBlack": $0.outputBlack, "outputWhite": $0.outputWhite] },
        ]
    }

    /// Accepts either the shorthand (`black`, `gamma`, `white`, `outputBlack`, `outputWhite` on the chosen `channel`) or a full
    /// `ranges` array of four such objects (RGB, red, green, blue).
    static func levels(_ params: AutomationParams, into settings: inout LevelsSettings) throws {
        try set(params, "channel", &settings.channel)
        if params.has("ranges") {
            let ranges = try params.objects("ranges")
            guard ranges.count == 4 else { throw AutomationError.badRequest("\"ranges\" must have four entries: RGB, red, green, blue") }
            for (index, object) in ranges.enumerated() {
                var range = settings.ranges[index]
                try levelRange(object, into: &range)
                settings.ranges[index] = range.normalized
            }
        }
        var current = settings.current
        try levelRange(params, into: &current)
        settings.current = current
    }

    private static func levelRange(_ params: AutomationParams, into range: inout LevelRange) throws {
        try set(params, "black", &range.black)
        try set(params, "gamma", &range.gamma)
        try set(params, "white", &range.white)
        try set(params, "outputBlack", &range.outputBlack)
        try set(params, "outputWhite", &range.outputWhite)
    }

    // MARK: Curves (Image > Curves, 0–255)

    static func curves(_ settings: CurvesSettings) -> [String: Any] {
        ["channel": settings.channel.rawValue, "rgb": curvePoints(settings.channels[0]), "red": curvePoints(settings.channels[1]),
         "green": curvePoints(settings.channels[2]), "blue": curvePoints(settings.channels[3])]
    }

    static func curves(_ params: AutomationParams, into settings: inout CurvesSettings) throws {
        try set(params, "channel", &settings.channel)
        for (index, key) in ["rgb", "red", "green", "blue"].enumerated() {
            if let points = try curvePoints(params, key) { settings.channels[index] = points }
        }
        if let points = try curvePoints(params, "points") { settings.channels[settings.channel.index] = points }
        guard settings.isValid else {
            throw AutomationError.badRequest("curves must have 2–32 points per channel, from x 0 to x 255, with increasing x and values in 0–255")
        }
    }

    // MARK: Hue/Saturation

    static func hueSaturation(_ settings: HueSaturationSettings) -> [String: Any] {
        var adjustments: [String: Any] = [:]
        for (range, adjustment) in settings.adjustments {
            adjustments[range.rawValue] = ["hue": adjustment.hue, "saturation": adjustment.saturation, "lightness": adjustment.lightness]
        }
        var bands: [String: Any] = [:]
        for (range, band) in settings.bands { bands[range.rawValue] = band.handles }
        return ["range": settings.range.rawValue, "colorize": settings.colorize, "invertRange": settings.invertRange,
                "hue": settings.hue, "saturation": settings.saturation, "lightness": settings.lightness,
                "adjustments": adjustments, "bands": bands]
    }

    /// `hue`/`saturation`/`lightness` apply to `range` (Master by default); `adjustments` and `bands` set several ranges at once.
    static func hueSaturation(_ params: AutomationParams, into settings: inout HueSaturationSettings) throws {
        if let colorize = try params.optionalBool("colorize"), colorize != settings.colorize {
            settings = colorize ? HueSaturationSettings.colorizeStart : HueSaturationSettings()
        }
        try set(params, "range", &settings.range)
        try set(params, "invertRange", &settings.invertRange)
        try set(params, "hue", &settings.hue)
        try set(params, "saturation", &settings.saturation)
        try set(params, "lightness", &settings.lightness)
        if let adjustments = try params.optionalObject("adjustments") {
            for key in adjustments.keys {
                guard let range = AutomationParams.match(key, in: ColorRange.allCases) else {
                    throw AutomationError.badRequest("\"adjustments\" keys must be one of: \(ColorRange.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                let object = try adjustments.object(key)
                var adjustment = settings.adjustments[range] ?? RangeAdjustment()
                try set(object, "hue", &adjustment.hue)
                try set(object, "saturation", &adjustment.saturation)
                try set(object, "lightness", &adjustment.lightness)
                settings.adjustments[range] = adjustment
            }
        }
        if let bands = try params.optionalObject("bands") {
            for key in bands.keys {
                guard let range = AutomationParams.match(key, in: ColorRange.allCases) else {
                    throw AutomationError.badRequest("\"bands\" keys must be color range names")
                }
                let handles = try bands.doubles(key)
                guard handles.count == 4 else { throw AutomationError.badRequest("a band is [falloffStart, rangeStart, rangeEnd, falloffEnd] in degrees") }
                settings.bands[range] = HueBand(falloffStart: handles[0], rangeStart: handles[1], rangeEnd: handles[2], falloffEnd: handles[3])
            }
        }
        let limit: Double = settings.colorize ? 360 : 180
        for adjustment in settings.adjustments.values {
            guard adjustment.hue.isFinite, abs(adjustment.hue) <= limit, abs(adjustment.saturation) <= 100, abs(adjustment.lightness) <= 100 else {
                throw AutomationError.badRequest("hue must be within ±\(Int(limit)), saturation and lightness within ±100")
            }
        }
    }

    // MARK: Simple adjustment settings

    static func exposure(_ settings: ExposureSettings) -> [String: Any] {
        ["exposure": settings.exposure, "offset": settings.offset, "gamma": settings.gamma]
    }

    static func exposure(_ params: AutomationParams, into settings: inout ExposureSettings) throws {
        try set(params, "exposure", &settings.exposure)
        try set(params, "offset", &settings.offset)
        try set(params, "gamma", &settings.gamma)
        guard settings.isValid else { throw AutomationError.badRequest("exposure must be within ±20, offset within ±0.5, gamma 0.01–9.99") }
    }

    static func gradientMap(_ settings: GradientMapSettings) -> [String: Any] {
        ["shadows": color(settings.shadows), "highlights": color(settings.highlights), "reversed": settings.reversed]
    }

    static func gradientMap(_ params: AutomationParams, into settings: inout GradientMapSettings) throws {
        try adjustmentColor(params, "shadows", into: &settings.shadows)
        try adjustmentColor(params, "highlights", into: &settings.highlights)
        try set(params, "reversed", &settings.reversed)
    }

    static func grain(_ settings: GrainSettings) -> [String: Any] {
        ["amount": settings.amount, "size": settings.size, "roughness": settings.roughness, "seed": Int(settings.seed)]
    }

    static func grain(_ params: AutomationParams, into settings: inout GrainSettings) throws {
        try set(params, "amount", &settings.amount)
        try set(params, "size", &settings.size)
        try set(params, "roughness", &settings.roughness)
        if let seed = try params.optionalInt("seed") { settings.seed = UInt32(truncatingIfNeeded: seed) }
        guard settings.isValid else { throw AutomationError.badRequest("grain amount 0–100, size 0.5–20, roughness 0–100") }
    }

    static func blackWhite(_ settings: BlackWhiteSettings) -> [String: Any] {
        ["reds": settings.reds, "yellows": settings.yellows, "greens": settings.greens, "cyans": settings.cyans, "blues": settings.blues,
         "magentas": settings.magentas, "tint": settings.tint, "tintHue": settings.tintHue, "tintSaturation": settings.tintSaturation]
    }

    static func blackWhite(_ params: AutomationParams, into settings: inout BlackWhiteSettings) throws {
        try set(params, "reds", &settings.reds); try set(params, "yellows", &settings.yellows); try set(params, "greens", &settings.greens)
        try set(params, "cyans", &settings.cyans); try set(params, "blues", &settings.blues); try set(params, "magentas", &settings.magentas)
        try set(params, "tint", &settings.tint); try set(params, "tintHue", &settings.tintHue); try set(params, "tintSaturation", &settings.tintSaturation)
        guard settings.isValid else { throw AutomationError.badRequest("black & white channels are −200–300, tint hue 0–360, tint saturation 0–100") }
    }

    static func colorBalance(_ settings: ColorBalanceSettings) -> [String: Any] {
        ["shadows": [settings.shadowCyanRed, settings.shadowMagentaGreen, settings.shadowYellowBlue],
         "midtones": [settings.midCyanRed, settings.midMagentaGreen, settings.midYellowBlue],
         "highlights": [settings.highlightCyanRed, settings.highlightMagentaGreen, settings.highlightYellowBlue],
         "preserveLuminosity": settings.preserveLuminosity,
         "shadowCyanRed": settings.shadowCyanRed, "shadowMagentaGreen": settings.shadowMagentaGreen, "shadowYellowBlue": settings.shadowYellowBlue,
         "midCyanRed": settings.midCyanRed, "midMagentaGreen": settings.midMagentaGreen, "midYellowBlue": settings.midYellowBlue,
         "highlightCyanRed": settings.highlightCyanRed, "highlightMagentaGreen": settings.highlightMagentaGreen, "highlightYellowBlue": settings.highlightYellowBlue]
    }

    /// Takes the nine named sliders, or `shadows`/`midtones`/`highlights` as `[cyanRed, magentaGreen, yellowBlue]` triples.
    static func colorBalance(_ params: AutomationParams, into settings: inout ColorBalanceSettings) throws {
        func triple(_ key: String, _ a: inout Double, _ b: inout Double, _ c: inout Double) throws {
            guard params.has(key) else { return }
            let values = try params.doubles(key)
            guard values.count == 3 else { throw AutomationError.badRequest("\"\(key)\" is [cyanRed, magentaGreen, yellowBlue]") }
            a = values[0]; b = values[1]; c = values[2]
        }
        try triple("shadows", &settings.shadowCyanRed, &settings.shadowMagentaGreen, &settings.shadowYellowBlue)
        try triple("midtones", &settings.midCyanRed, &settings.midMagentaGreen, &settings.midYellowBlue)
        try triple("highlights", &settings.highlightCyanRed, &settings.highlightMagentaGreen, &settings.highlightYellowBlue)
        try set(params, "shadowCyanRed", &settings.shadowCyanRed); try set(params, "shadowMagentaGreen", &settings.shadowMagentaGreen)
        try set(params, "shadowYellowBlue", &settings.shadowYellowBlue); try set(params, "midCyanRed", &settings.midCyanRed)
        try set(params, "midMagentaGreen", &settings.midMagentaGreen); try set(params, "midYellowBlue", &settings.midYellowBlue)
        try set(params, "highlightCyanRed", &settings.highlightCyanRed); try set(params, "highlightMagentaGreen", &settings.highlightMagentaGreen)
        try set(params, "highlightYellowBlue", &settings.highlightYellowBlue); try set(params, "preserveLuminosity", &settings.preserveLuminosity)
        guard settings.isValid else { throw AutomationError.badRequest("color balance values are −100–100") }
    }

    // MARK: Adjustment layers

    static func adjustment(_ adjustment: LayerAdjustment) -> [String: Any] {
        var out: [String: Any] = ["kind": adjustment.kind.rawValue]
        switch adjustment.kind {
        case .hsv: out["hueSaturation"] = hueSaturation(adjustment.resolvedHSV)
        case .levels: out["levels"] = levels(adjustment.levels)
        case .curves: out["curves"] = curves(adjustment.curves)
        case .exposure: out["exposure"] = exposure(adjustment.exposure)
        case .gradientMap: out["gradientMap"] = gradientMap(adjustment.gradientMap)
        case .grain: out["grain"] = grain(adjustment.grain)
        case .blackWhite: out["blackWhite"] = blackWhite(adjustment.blackWhite)
        case .colorBalance: out["colorBalance"] = colorBalance(adjustment.colorBalance)
        case .gaussianBlur: out["radius"] = adjustment.gaussianRadius
        case .motionBlur: out["angle"] = adjustment.resolvedMotionAngle; out["distance"] = adjustment.resolvedMotionDistance
        case .addNoise:
            out["amount"] = adjustment.resolvedNoiseAmount; out["gaussian"] = adjustment.resolvedNoiseGaussian
            out["monochromatic"] = adjustment.resolvedNoiseMonochromatic; out["seed"] = Int(adjustment.resolvedNoiseSeed)
        case .invert: break
        }
        return out
    }

    /// Applies the kind's settings. The kind-specific object (`levels`, `curves`, …) may be given, or its keys may sit at
    /// the top level for the simple kinds (`radius`, `amount`, `exposure`, …).
    static func adjustment(_ params: AutomationParams, into adjustment: inout LayerAdjustment) throws {
        func section(_ key: String) throws -> AutomationParams { try params.optionalObject(key) ?? params }
        switch adjustment.kind {
        case .hsv:
            var settings = adjustment.resolvedHSV
            try hueSaturation(try section("hueSaturation"), into: &settings)
            adjustment.hsvSettings = settings
            adjustment.hue = settings.hue; adjustment.saturation = settings.saturation
            adjustment.lightness = settings.lightness; adjustment.colorize = settings.colorize
        case .levels:
            try levels(try section("levels"), into: &adjustment.levels)
        case .curves:
            try curves(try section("curves"), into: &adjustment.curves)
        case .exposure:
            var settings = adjustment.exposure; try exposure(try section("exposure"), into: &settings); adjustment.exposure = settings
        case .gradientMap:
            var settings = adjustment.gradientMap; try gradientMap(try section("gradientMap"), into: &settings); adjustment.gradientMap = settings
        case .grain:
            var settings = adjustment.grain; try grain(try section("grain"), into: &settings); adjustment.grain = settings
        case .blackWhite:
            var settings = adjustment.blackWhite; try blackWhite(try section("blackWhite"), into: &settings); adjustment.blackWhite = settings
        case .colorBalance:
            var settings = adjustment.colorBalance; try colorBalance(try section("colorBalance"), into: &settings); adjustment.colorBalance = settings
        case .gaussianBlur:
            var radius = adjustment.gaussianRadius; try set(params, "radius", &radius); adjustment.gaussianRadius = radius
        case .motionBlur:
            var angle = adjustment.resolvedMotionAngle; try set(params, "angle", &angle); adjustment.resolvedMotionAngle = angle
            var distance = adjustment.resolvedMotionDistance; try set(params, "distance", &distance); adjustment.resolvedMotionDistance = distance
        case .addNoise:
            var amount = adjustment.resolvedNoiseAmount; try set(params, "amount", &amount); adjustment.resolvedNoiseAmount = amount
            var gaussian = adjustment.resolvedNoiseGaussian; try set(params, "gaussian", &gaussian); adjustment.resolvedNoiseGaussian = gaussian
            var mono = adjustment.resolvedNoiseMonochromatic; try set(params, "monochromatic", &mono); adjustment.resolvedNoiseMonochromatic = mono
            if let seed = try params.optionalInt("seed") { adjustment.resolvedNoiseSeed = UInt32(truncatingIfNeeded: seed) }
        case .invert:
            break
        }
        guard adjustment.isValid else {
            throw AutomationError.badRequest("the adjustment settings are out of range (blur radius 0.1–250, motion angle ±90 and distance 1–2000, noise 0.1–400, hue ±360, saturation and lightness ±100)")
        }
    }

    // MARK: Dither

    static func dither(_ settings: DitherSettings) -> [String: Any] {
        ["style": settings.style.rawValue, "pixelSize": settings.pixelSize, "pixelShape": settings.pixelShape.rawValue, "cellSize": settings.cellSize,
         "textSize": settings.textSize, "lineSpacing": settings.lineSpacing, "glow": settings.glow, "dots": settings.dots, "wobble": settings.wobble,
         "angle": settings.angle, "levels": settings.levels, "diffusion": settings.diffusion, "density": settings.density, "contrast": settings.contrast,
         "colors": settings.colors.rawValue, "dark": color(settings.dark), "light": color(settings.light), "lightOnDark": settings.lightOnDark,
         "characters": settings.characters]
    }

    static func dither(_ params: AutomationParams, into settings: inout DitherSettings) throws {
        try set(params, "style", &settings.style); try set(params, "pixelSize", &settings.pixelSize); try set(params, "pixelShape", &settings.pixelShape)
        try set(params, "cellSize", &settings.cellSize); try set(params, "textSize", &settings.textSize); try set(params, "lineSpacing", &settings.lineSpacing)
        try set(params, "glow", &settings.glow); try set(params, "dots", &settings.dots); try set(params, "wobble", &settings.wobble)
        try set(params, "angle", &settings.angle); try set(params, "levels", &settings.levels); try set(params, "diffusion", &settings.diffusion)
        try set(params, "density", &settings.density); try set(params, "contrast", &settings.contrast); try set(params, "colors", &settings.colors)
        try adjustmentColor(params, "dark", into: &settings.dark); try adjustmentColor(params, "light", into: &settings.light)
        try set(params, "lightOnDark", &settings.lightOnDark)
        if let characters = try params.optionalString("characters") { settings.characters = characters }
        settings = settings.normalized
    }

    // MARK: Filters

    /// The settings of one filter kind, as the filter sheet shows them.
    static func filter(_ kind: FilterKind, _ settings: FilterSettings) -> [String: Any] {
        switch kind {
        case .gaussianBlur: return ["radius": settings.radius]
        case .motionBlur: return ["angle": settings.angle, "distance": settings.distance]
        case .addNoise: return ["amount": settings.amount, "gaussian": settings.gaussian, "monochromatic": settings.monochromatic]
        case .vignette:
            return ["amount": settings.vignetteAmount, "color": color(settings.vignetteColor), "midpoint": settings.vignetteMidpoint,
                    "roundness": settings.vignetteRoundness, "feather": settings.vignetteFeather, "highlights": settings.vignetteHighlights]
        case .bloomGlow: return ["amount": settings.bloomAmount, "radius": settings.bloomRadius]
        case .dither: return dither(settings.dither)
        case .tonalContrast:
            return ["amount": settings.tonalAmount, "radius": settings.tonalRadius, "shadows": settings.tonalShadows,
                    "midtones": settings.tonalMidtones, "highlights": settings.tonalHighlights]
        case .lensCorrection: return ["distortion": settings.distortion]
        case .cameraRaw: return cameraRaw(settings.cameraRaw)
        case .removeBackground:
            return ["quality": settings.backgroundQuality.rawValue, "refineEdges": settings.refineEdges,
                    "matteContrast": settings.matteContrast, "shiftEdge": settings.shiftEdge]
        case .contentAwareFill: return [:]
        case .curves: return curves(settings.curves)
        case .exposure: return exposure(settings.exposure)
        case .gradientMap: return gradientMap(settings.gradientMap)
        case .grain: return grain(settings.grain)
        case .blackWhite: return blackWhite(settings.blackWhite)
        case .colorBalance: return colorBalance(settings.colorBalance)
        }
    }

    static func filter(_ kind: FilterKind, _ params: AutomationParams, into settings: inout FilterSettings) throws {
        switch kind {
        case .gaussianBlur:
            try set(params, "radius", &settings.radius)
        case .motionBlur:
            try set(params, "angle", &settings.angle); try set(params, "distance", &settings.distance)
        case .addNoise:
            try set(params, "amount", &settings.amount); try set(params, "gaussian", &settings.gaussian); try set(params, "monochromatic", &settings.monochromatic)
        case .vignette:
            try set(params, "amount", &settings.vignetteAmount); try adjustmentColor(params, "color", into: &settings.vignetteColor)
            try set(params, "midpoint", &settings.vignetteMidpoint); try set(params, "roundness", &settings.vignetteRoundness)
            try set(params, "feather", &settings.vignetteFeather); try set(params, "highlights", &settings.vignetteHighlights)
        case .bloomGlow:
            try set(params, "amount", &settings.bloomAmount); try set(params, "radius", &settings.bloomRadius)
        case .dither:
            try dither(params, into: &settings.dither)
        case .tonalContrast:
            try set(params, "amount", &settings.tonalAmount); try set(params, "radius", &settings.tonalRadius); try set(params, "shadows", &settings.tonalShadows)
            try set(params, "midtones", &settings.tonalMidtones); try set(params, "highlights", &settings.tonalHighlights)
        case .lensCorrection:
            try set(params, "distortion", &settings.distortion)
        case .cameraRaw:
            try cameraRaw(params, into: &settings.cameraRaw)
        case .removeBackground:
            try set(params, "quality", &settings.backgroundQuality); try set(params, "refineEdges", &settings.refineEdges)
            try set(params, "matteContrast", &settings.matteContrast); try set(params, "shiftEdge", &settings.shiftEdge)
        case .contentAwareFill:
            break
        case .curves: try curves(params, into: &settings.curves)
        case .exposure: try exposure(params, into: &settings.exposure)
        case .gradientMap: try gradientMap(params, into: &settings.gradientMap)
        case .grain: try grain(params, into: &settings.grain)
        case .blackWhite: try blackWhite(params, into: &settings.blackWhite)
        case .colorBalance: try colorBalance(params, into: &settings.colorBalance)
        }
        settings = settings.normalized
    }

    // MARK: Camera Raw

    static func cameraRaw(_ s: CameraRawSettings) -> [String: Any] {
        [
            "whiteBalance": s.whiteBalance.rawValue, "temperature": s.temperature, "tint": s.tint,
            "light": ["exposure": s.exposure, "contrast": s.contrast, "highlights": s.highlights, "shadows": s.shadows, "whites": s.whites, "blacks": s.blacks],
            "color": ["temperature": s.temperature, "tint": s.tint, "vibrance": s.vibrance, "saturation": s.saturation],
            "effects": ["texture": s.texture, "clarity": s.clarity, "dehaze": s.dehaze,
                        "glow": ["amount": s.glow, "style": s.glowStyle.rawValue, "range": s.glowRange, "spread": s.glowSpread, "warmth": s.glowWarmth],
                        "vignette": ["amount": s.vignetteAmount, "style": s.vignetteStyle.rawValue, "midpoint": s.vignetteMidpoint,
                                     "roundness": s.vignetteRoundness, "feather": s.vignetteFeather, "highlights": s.vignetteHighlights],
                        "grain": ["amount": s.grainAmount, "size": s.grainSize, "roughness": s.grainRoughness]],
            "curve": ["shadows": s.curve.shadows, "darks": s.curve.darks, "lights": s.curve.lights, "highlights": s.curve.highlights,
                      "shadowSplit": s.curve.shadowSplit, "darkSplit": s.curve.darkSplit, "lightSplit": s.curve.lightSplit,
                      "rgb": curvePoints(s.curve.rgb), "red": curvePoints(s.curve.red), "green": curvePoints(s.curve.green), "blue": curvePoints(s.curve.blue),
                      "refineSaturation": s.curve.refineSaturation],
            "mixer": ["names": CameraRawMixerSettings.names, "hue": s.mixer.hue, "saturation": s.mixer.saturation, "luminance": s.mixer.luminance,
                      "points": s.mixer.points.map { ["hue": $0.hue, "saturation": $0.saturation, "luminance": $0.luminance,
                                                       "hueShift": $0.hueShift, "saturationShift": $0.saturationShift, "luminanceShift": $0.luminanceShift,
                                                       "hueRange": $0.hueRange, "saturationRange": $0.saturationRange, "luminanceRange": $0.luminanceRange] }],
            "grading": ["shadows": wheel(s.grading.shadows), "midtones": wheel(s.grading.midtones), "highlights": wheel(s.grading.highlights),
                        "global": wheel(s.grading.global), "blending": s.grading.blending, "balance": s.grading.balance],
            "detail": ["sharpenAmount": s.detail.sharpenAmount, "sharpenRadius": s.detail.sharpenRadius, "sharpenDetail": s.detail.sharpenDetail,
                       "sharpenMasking": s.detail.sharpenMasking, "noiseLuminance": s.detail.noiseLuminance, "noiseLuminanceDetail": s.detail.noiseLuminanceDetail,
                       "noiseLuminanceContrast": s.detail.noiseLuminanceContrast, "noiseColor": s.detail.noiseColor,
                       "noiseColorDetail": s.detail.noiseColorDetail, "noiseColorSmoothness": s.detail.noiseColorSmoothness],
            "optics": ["removeChromaticAberration": s.optics.removeChromaticAberration, "enableLensProfile": s.optics.enableLensProfile,
                       "profileDistortion": s.optics.profileDistortion, "profileVignetting": s.optics.profileVignetting, "distortion": s.optics.distortion,
                       "purpleAmount": s.optics.purpleAmount, "purpleHueLow": s.optics.purpleHueLow, "purpleHueHigh": s.optics.purpleHueHigh,
                       "greenAmount": s.optics.greenAmount, "greenHueLow": s.optics.greenHueLow, "greenHueHigh": s.optics.greenHueHigh,
                       "vignetteAmount": s.optics.vignetteAmount, "vignetteMidpoint": s.optics.vignetteMidpoint],
            "geometry": ["upright": s.geometry.upright.rawValue, "projection": s.geometry.projection.rawValue, "vertical": s.geometry.vertical,
                         "horizontal": s.geometry.horizontal, "rotate": s.geometry.rotate, "aspect": s.geometry.aspect, "scale": s.geometry.scale,
                         "offsetX": s.geometry.offsetX, "offsetY": s.geometry.offsetY, "constrainCrop": s.geometry.constrainCrop,
                         "guides": s.geometry.guides.map { ["start": [$0.startX, $0.startY], "end": [$0.endX, $0.endY]] }],
            "calibration": ["process": s.calibration.process.rawValue, "shadowTint": s.calibration.shadowTint, "redHue": s.calibration.redHue,
                            "redSaturation": s.calibration.redSaturation, "greenHue": s.calibration.greenHue, "greenSaturation": s.calibration.greenSaturation,
                            "blueHue": s.calibration.blueHue, "blueSaturation": s.calibration.blueSaturation],
            "isIdentity": s.isIdentity,
        ]
    }

    private static func wheel(_ wheel: CameraRawGradeWheel) -> [String: Any] {
        ["hue": wheel.hue, "saturation": wheel.saturation, "luminance": wheel.luminance]
    }

    private static func wheel(_ params: AutomationParams, _ key: String, into wheel: inout CameraRawGradeWheel) throws {
        guard let object = try params.optionalObject(key) else { return }
        try set(object, "hue", &wheel.hue); try set(object, "saturation", &wheel.saturation); try set(object, "luminance", &wheel.luminance)
    }

    /// Camera Raw takes the same nested shape it reports; every group is optional, and the Light, Color and Effects
    /// sliders may also be given flat at the top level (`{"exposure": 0.5, "vibrance": 20}`).
    static func cameraRaw(_ params: AutomationParams, into s: inout CameraRawSettings) throws {
        if try params.optionalBool("reset") == true { s = CameraRawSettings() }
        let light = try params.optionalObject("light") ?? params
        try set(light, "exposure", &s.exposure); try set(light, "contrast", &s.contrast); try set(light, "highlights", &s.highlights)
        try set(light, "shadows", &s.shadows); try set(light, "whites", &s.whites); try set(light, "blacks", &s.blacks)
        let color = try params.optionalObject("color") ?? params
        try set(color, "whiteBalance", &s.whiteBalance)
        if color.has("temperature") || color.has("tint") {
            try set(color, "temperature", &s.temperature); try set(color, "tint", &s.tint)
            s.whiteBalance = .custom
        }
        try set(color, "vibrance", &s.vibrance); try set(color, "saturation", &s.saturation)
        let effects = try params.optionalObject("effects") ?? params
        try set(effects, "texture", &s.texture); try set(effects, "clarity", &s.clarity); try set(effects, "dehaze", &s.dehaze)
        if let glow = try effects.optionalObject("glow") {
            try set(glow, "amount", &s.glow); try set(glow, "style", &s.glowStyle); try set(glow, "range", &s.glowRange)
            try set(glow, "spread", &s.glowSpread); try set(glow, "warmth", &s.glowWarmth)
        } else {
            try set(effects, "glow", &s.glow)
        }
        if let vignette = try effects.optionalObject("vignette") {
            try set(vignette, "amount", &s.vignetteAmount); try set(vignette, "style", &s.vignetteStyle); try set(vignette, "midpoint", &s.vignetteMidpoint)
            try set(vignette, "roundness", &s.vignetteRoundness); try set(vignette, "feather", &s.vignetteFeather); try set(vignette, "highlights", &s.vignetteHighlights)
        }
        if let grain = try effects.optionalObject("grain") {
            try set(grain, "amount", &s.grainAmount); try set(grain, "size", &s.grainSize); try set(grain, "roughness", &s.grainRoughness)
        }
        if let curve = try params.optionalObject("curve") {
            try set(curve, "shadows", &s.curve.shadows); try set(curve, "darks", &s.curve.darks); try set(curve, "lights", &s.curve.lights)
            try set(curve, "highlights", &s.curve.highlights); try set(curve, "shadowSplit", &s.curve.shadowSplit)
            try set(curve, "darkSplit", &s.curve.darkSplit); try set(curve, "lightSplit", &s.curve.lightSplit)
            if let points = try curvePoints(curve, "rgb") { s.curve.rgb = points }
            if let points = try curvePoints(curve, "red") { s.curve.red = points }
            if let points = try curvePoints(curve, "green") { s.curve.green = points }
            if let points = try curvePoints(curve, "blue") { s.curve.blue = points }
            if let preset = try curve.optionalString("preset") {
                switch AutomationParams.normalize(preset) {
                case "linear": s.curve.rgb = CameraRawCurveSettings.linear
                case "mediumcontrast", "medium": s.curve.rgb = CameraRawCurveSettings.mediumContrast
                case "strongcontrast", "strong": s.curve.rgb = CameraRawCurveSettings.strongContrast
                default: throw AutomationError.badRequest("curve preset must be linear, mediumContrast or strongContrast")
                }
            }
            try set(curve, "refineSaturation", &s.curve.refineSaturation)
        }
        if let mixer = try params.optionalObject("mixer") {
            let paths: [(String, WritableKeyPath<CameraRawMixerSettings, [Double]>)] = [("hue", \.hue), ("saturation", \.saturation), ("luminance", \.luminance)]
            for (key, path) in paths {
                guard mixer.has(key) else { continue }
                if mixer.raw[key] is [String: Any] {
                    let object = try mixer.object(key)
                    var values = s.mixer[keyPath: path]
                    for name in object.keys {
                        guard let index = CameraRawMixerSettings.names.firstIndex(where: { AutomationParams.normalize($0) == AutomationParams.normalize(name) }) else {
                            throw AutomationError.badRequest("mixer colors are \(CameraRawMixerSettings.names.joined(separator: ", "))")
                        }
                        values[index] = try object.double(name)
                    }
                    s.mixer[keyPath: path] = values
                } else {
                    let values = try mixer.doubles(key)
                    guard values.count == 8 else { throw AutomationError.badRequest("mixer \"\(key)\" needs eight values (\(CameraRawMixerSettings.names.joined(separator: ", "))) or an object keyed by color name") }
                    s.mixer[keyPath: path] = values
                }
            }
            if mixer.has("points") {
                s.mixer.points = try mixer.objects("points").map { object in
                    var point = CameraRawPointColor()
                    try set(object, "hue", &point.hue); try set(object, "saturation", &point.saturation); try set(object, "luminance", &point.luminance)
                    try set(object, "hueShift", &point.hueShift); try set(object, "saturationShift", &point.saturationShift)
                    try set(object, "luminanceShift", &point.luminanceShift); try set(object, "hueRange", &point.hueRange)
                    try set(object, "saturationRange", &point.saturationRange); try set(object, "luminanceRange", &point.luminanceRange)
                    return point
                }
            }
        }
        if let grading = try params.optionalObject("grading") {
            try wheel(grading, "shadows", into: &s.grading.shadows); try wheel(grading, "midtones", into: &s.grading.midtones)
            try wheel(grading, "highlights", into: &s.grading.highlights); try wheel(grading, "global", into: &s.grading.global)
            try set(grading, "blending", &s.grading.blending); try set(grading, "balance", &s.grading.balance)
        }
        if let detail = try params.optionalObject("detail") {
            try set(detail, "sharpenAmount", &s.detail.sharpenAmount); try set(detail, "sharpenRadius", &s.detail.sharpenRadius)
            try set(detail, "sharpenDetail", &s.detail.sharpenDetail); try set(detail, "sharpenMasking", &s.detail.sharpenMasking)
            try set(detail, "noiseLuminance", &s.detail.noiseLuminance); try set(detail, "noiseLuminanceDetail", &s.detail.noiseLuminanceDetail)
            try set(detail, "noiseLuminanceContrast", &s.detail.noiseLuminanceContrast); try set(detail, "noiseColor", &s.detail.noiseColor)
            try set(detail, "noiseColorDetail", &s.detail.noiseColorDetail); try set(detail, "noiseColorSmoothness", &s.detail.noiseColorSmoothness)
        }
        if let optics = try params.optionalObject("optics") {
            try set(optics, "removeChromaticAberration", &s.optics.removeChromaticAberration); try set(optics, "enableLensProfile", &s.optics.enableLensProfile)
            try set(optics, "profileDistortion", &s.optics.profileDistortion); try set(optics, "profileVignetting", &s.optics.profileVignetting)
            try set(optics, "distortion", &s.optics.distortion); try set(optics, "purpleAmount", &s.optics.purpleAmount)
            try set(optics, "purpleHueLow", &s.optics.purpleHueLow); try set(optics, "purpleHueHigh", &s.optics.purpleHueHigh)
            try set(optics, "greenAmount", &s.optics.greenAmount); try set(optics, "greenHueLow", &s.optics.greenHueLow)
            try set(optics, "greenHueHigh", &s.optics.greenHueHigh); try set(optics, "vignetteAmount", &s.optics.vignetteAmount)
            try set(optics, "vignetteMidpoint", &s.optics.vignetteMidpoint)
        }
        if let geometry = try params.optionalObject("geometry") {
            try set(geometry, "upright", &s.geometry.upright); try set(geometry, "projection", &s.geometry.projection)
            try set(geometry, "vertical", &s.geometry.vertical); try set(geometry, "horizontal", &s.geometry.horizontal)
            try set(geometry, "rotate", &s.geometry.rotate); try set(geometry, "aspect", &s.geometry.aspect); try set(geometry, "scale", &s.geometry.scale)
            try set(geometry, "offsetX", &s.geometry.offsetX); try set(geometry, "offsetY", &s.geometry.offsetY)
            try set(geometry, "constrainCrop", &s.geometry.constrainCrop)
            if geometry.has("guides") {
                s.geometry.guides = try geometry.objects("guides").map { object in
                    let start = try object.point("start"), end = try object.point("end")
                    return CameraRawGeometryGuide(startX: Double(start.x), startY: Double(start.y), endX: Double(end.x), endY: Double(end.y))
                }
                if !s.geometry.guides.isEmpty { s.geometry.upright = .guided }
            }
        }
        if let calibration = try params.optionalObject("calibration") {
            try set(calibration, "process", &s.calibration.process); try set(calibration, "shadowTint", &s.calibration.shadowTint)
            try set(calibration, "redHue", &s.calibration.redHue); try set(calibration, "redSaturation", &s.calibration.redSaturation)
            try set(calibration, "greenHue", &s.calibration.greenHue); try set(calibration, "greenSaturation", &s.calibration.greenSaturation)
            try set(calibration, "blueHue", &s.calibration.blueHue); try set(calibration, "blueSaturation", &s.calibration.blueSaturation)
        }
        s = s.normalized
    }

    // MARK: Layer effects

    static func effects(_ effects: LayerEffects) -> [String: Any] {
        var out: [String: Any] = [:]
        if let e = effects.stroke {
            out["stroke"] = ["enabled": e.isEnabled, "size": Double(e.size), "color": color(e.red, e.green, e.blue), "opacity": e.opacity, "inside": e.inside]
        }
        if let e = effects.shadow {
            out["shadow"] = ["enabled": e.isEnabled, "angle": Double(e.angle), "distance": Double(e.distance), "blur": Double(e.blur),
                             "color": color(e.red, e.green, e.blue), "opacity": e.opacity]
        }
        if let e = effects.colorOverlay {
            out["colorOverlay"] = ["enabled": e.isEnabled, "color": color(e.red, e.green, e.blue), "opacity": e.opacity]
        }
        if let e = effects.innerShadow {
            out["innerShadow"] = ["enabled": e.isEnabled, "angle": Double(e.angle), "distance": Double(e.distance), "blur": Double(e.blur),
                                  "color": color(e.red, e.green, e.blue), "opacity": e.opacity]
        }
        if let e = effects.outerGlow {
            out["outerGlow"] = ["enabled": e.isEnabled, "size": Double(e.size), "color": color(e.red, e.green, e.blue), "opacity": e.opacity]
        }
        if let e = effects.innerGlow {
            out["innerGlow"] = ["enabled": e.isEnabled, "size": Double(e.size), "color": color(e.red, e.green, e.blue), "opacity": e.opacity]
        }
        return out
    }

    /// Keys are effect names (`stroke`, `shadow`, `colorOverlay`, `innerShadow`, `outerGlow`, `innerGlow`); `null` removes one.
    static func effects(_ params: AutomationParams, into effects: inout LayerEffects) throws {
        func rgb(_ object: AutomationParams, _ red: inout CGFloat, _ green: inout CGFloat, _ blue: inout CGFloat) throws {
            if let c = try object.optionalColor("color") { red = CGFloat(c.red); green = CGFloat(c.green); blue = CGFloat(c.blue) }
        }
        func enabled(_ object: AutomationParams, _ value: inout Bool?) throws {
            if let flag = try object.optionalBool("enabled") { value = flag ? nil : false }
        }
        for key in params.keys {
            let kind: LayerEffectKind
            switch AutomationParams.normalize(key) {
            case "stroke": kind = .stroke
            case "shadow", "dropshadow": kind = .shadow
            case "coloroverlay": kind = .colorOverlay
            case "innershadow": kind = .innerShadow
            case "outerglow": kind = .outerGlow
            case "innerglow": kind = .innerGlow
            default: throw AutomationError.badRequest("unknown effect \"\(key)\"; use stroke, shadow, colorOverlay, innerShadow, outerGlow or innerGlow")
            }
            guard params.has(key) else { effects.remove(kind); continue }
            let object = try params.object(key)
            switch kind {
            case .stroke:
                var e = effects.stroke ?? StrokeEffect()
                try enabled(object, &e.enabled); try set(object, "size", &e.size); try rgb(object, &e.red, &e.green, &e.blue)
                try set(object, "opacity", &e.opacity); try set(object, "inside", &e.inside)
                effects.stroke = e
            case .shadow:
                var e = effects.shadow ?? ShadowEffect()
                try enabled(object, &e.enabled); try set(object, "angle", &e.angle); try set(object, "distance", &e.distance)
                try set(object, "blur", &e.blur); try rgb(object, &e.red, &e.green, &e.blue); try set(object, "opacity", &e.opacity)
                effects.shadow = e
            case .colorOverlay:
                var e = effects.colorOverlay ?? ColorOverlayEffect()
                try enabled(object, &e.enabled); try rgb(object, &e.red, &e.green, &e.blue); try set(object, "opacity", &e.opacity)
                effects.colorOverlay = e
            case .innerShadow:
                var e = effects.innerShadow ?? InnerShadowEffect()
                try enabled(object, &e.enabled); try set(object, "angle", &e.angle); try set(object, "distance", &e.distance)
                try set(object, "blur", &e.blur); try rgb(object, &e.red, &e.green, &e.blue); try set(object, "opacity", &e.opacity)
                effects.innerShadow = e
            case .outerGlow:
                var e = effects.outerGlow ?? OuterGlowEffect()
                try enabled(object, &e.enabled); try set(object, "size", &e.size); try rgb(object, &e.red, &e.green, &e.blue); try set(object, "opacity", &e.opacity)
                effects.outerGlow = e
            case .innerGlow:
                var e = effects.innerGlow ?? InnerGlowEffect()
                try enabled(object, &e.enabled); try set(object, "size", &e.size); try rgb(object, &e.red, &e.green, &e.blue); try set(object, "opacity", &e.opacity)
                effects.innerGlow = e
            }
        }
        guard effects.isValid else {
            throw AutomationError.badRequest("effect values out of range: sizes 0–500, blur 0–500, distance 0–5000, angle ±360, opacity and colors 0–1")
        }
    }

    // MARK: Text and shapes

    static func textStyle(_ style: LayerTextStyle) -> [String: Any] {
        var out: [String: Any] = [
            "content": style.content, "fontName": style.fontName, "fontSize": Double(style.fontSize),
            "color": color(style.red, style.green, style.blue), "alignment": style.alignment.rawValue,
            "tracking": Double(style.tracking), "leading": Double(style.leading),
            "boxSize": AutomationJSON.nullable(style.boxSize.map(AutomationJSON.size)),
        ]
        if let runs = style.colorRuns {
            out["colorRuns"] = runs.map { ["location": $0.location, "length": $0.length, "color": color($0.red, $0.green, $0.blue)] }
        }
        if let runs = style.fontRuns { out["fontRuns"] = runs.map { ["location": $0.location, "length": $0.length, "fontName": $0.fontName] } }
        return out
    }

    static func textStyle(_ params: AutomationParams, into style: inout LayerTextStyle) throws {
        if let content = try params.optionalString("content") {
            style.replaceCharacters(in: NSRange(location: 0, length: style.content.utf16.count), withLength: content.utf16.count)
            style.content = content
        }
        if let font = try params.optionalString("fontName") { style.fontName = font }
        try set(params, "fontSize", &style.fontSize)
        if let c = try params.optionalColor("color") { style.red = CGFloat(c.red); style.green = CGFloat(c.green); style.blue = CGFloat(c.blue) }
        try set(params, "alignment", &style.alignment)
        try set(params, "tracking", &style.tracking)
        try set(params, "leading", &style.leading)
        if params.has("boxSize") {
            if params.raw["boxSize"] is NSNull { style.boxSize = nil } else { style.boxSize = try params.size("boxSize") }
        }
        if params.has("colorRuns") {
            style.colorRuns = try params.objects("colorRuns").map { run in
                let c = try run.color("color")
                return LayerTextColorRun(location: try run.int("location"), length: try run.int("length"),
                                         red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue))
            }
            if style.colorRuns?.isEmpty == true { style.colorRuns = nil }
        }
        if params.has("fontRuns") {
            style.fontRuns = try params.objects("fontRuns").map { run in
                LayerTextFontRun(location: try run.int("location"), length: try run.int("length"), fontName: try run.string("fontName"))
            }
            if style.fontRuns?.isEmpty == true { style.fontRuns = nil }
        }
        guard style.isValid else {
            throw AutomationError.badRequest("text style out of range: font size 1–2000, tracking −100–1000, leading 0–5000, box sides 16–30000, runs sorted and inside the content")
        }
    }

    static func shapeStyle(_ style: LayerShapeStyle) -> [String: Any] {
        var out: [String: Any] = ["kind": style.kind.rawValue, "color": color(style.red, style.green, style.blue), "cornerRadius": Double(style.cornerRadius)]
        if let width = style.lineWidth { out["lineWidth"] = Double(width) }
        if let start = style.start { out["start"] = AutomationJSON.point(start) }
        if let end = style.end { out["end"] = AutomationJSON.point(end) }
        return out
    }
}
