import Foundation
import CoreGraphics
import AppKit

extension AutomationRegistry {
    func registerSessionCommands() {
        group("session", "History, tools, colors and app-level control.")

        add("history.undo", group: "session", "Undoes the last edit (several with `steps`).", params: [AutomationParamDoc("steps", "int")]) { context, params in
            let session = context.session
            var done = 0
            for _ in 0..<max(1, try params.int("steps", default: 1)) {
                guard session.canUndo else { break }
                session.undo(); done += 1
            }
            return ["undone": done, "canUndo": session.canUndo, "undoName": session.history.undoName]
        }

        add("history.redo", group: "session", "Redoes the last undone edit (several with `steps`).", params: [AutomationParamDoc("steps", "int")]) { context, params in
            let session = context.session
            var done = 0
            for _ in 0..<max(1, try params.int("steps", default: 1)) {
                guard session.canRedo else { break }
                session.redo(); done += 1
            }
            return ["redone": done, "canRedo": session.canRedo, "redoName": session.history.redoName]
        }

        add("history.get", group: "session", "Undo/redo availability and names.") { context, _ in
            let session = context.session
            return ["canUndo": session.canUndo, "canRedo": session.canRedo, "undoName": session.history.undoName, "redoName": session.history.redoName,
                    "isModified": session.isModified, "undoCount": session.history.undoCount]
        }

        add("history.markSaved", group: "session", "Treats the current state as saved (clears the modified flag) without writing.") { context, _ in
            context.session.history.markSaved()
            return ["isModified": context.session.isModified]
        }

        add("tool.select", group: "session", "Selects a tool: " + NavigationTool.allCases.filter { $0 != .idle }.map(\.rawValue).joined(separator: ", ") + ".", params: [
            AutomationParamDoc("tool", "string", required: true),
        ]) { context, params in
            let tool: NavigationTool = try params.enumeration("tool", cases: NavigationTool.allCases.filter { $0 != .idle })
            context.session.selectTool(tool)
            guard context.session.tool == tool else { throw AutomationError.conflict(context.blockedReason()) }
            return ["tool": tool.rawValue]
        }

        add("tool.set", group: "session", "Sets tool options: brush (diameter, hardness, opacity, smoothing, blurRadius, mode, blurMode, healingMode), clone (aligned, sampleAllLayers), wand (tolerance, contiguous, sampleAllLayers, sampleSize), objectSelection (sampleAllLayers, edgeOffset), gradient (shape, style, reversed, opacity), shape (kind, cornerRadius, lineWidth), selection (antialiased, featherAmount, expandAmount, contractAmount).", params: [
            AutomationParamDoc("brush", "object"), AutomationParamDoc("clone", "object"), AutomationParamDoc("wand", "object"), AutomationParamDoc("objectSelection", "object"),
            AutomationParamDoc("gradient", "object"), AutomationParamDoc("shape", "object"), AutomationParamDoc("selection", "object"),
        ]) { context, params in
            let session = context.session
            if let brush = try params.optionalObject("brush") {
                try AutomationPainting.applyBrushSettings(brush, session)
                if let radius = try brush.optionalDouble("blurRadius") { session.brushSettings.blurRadius = CGFloat(radius) }
                try AutomationSettings.set(brush, "mode", &session.brushMode)
                try AutomationSettings.set(brush, "blurMode", &session.blurMode)
                try AutomationSettings.set(brush, "healingMode", &session.spotHealingMode)
            }
            if let clone = try params.optionalObject("clone") {
                try AutomationSettings.set(clone, "aligned", &session.cloneSettings.aligned)
                try AutomationSettings.set(clone, "sampleAllLayers", &session.cloneSettings.sampleAllLayers)
                if let source = try clone.optionalPoint("source") { session.setCloneSource(source) }
            }
            if let wand = try params.optionalObject("wand") {
                if let tolerance = try wand.optionalInt("tolerance") { session.wandSettings.tolerance = min(255, max(0, tolerance)) }
                try AutomationSettings.set(wand, "contiguous", &session.wandSettings.contiguous)
                try AutomationSettings.set(wand, "sampleAllLayers", &session.wandSettings.sampleAllLayers)
                if let size = try wand.optionalInt("sampleSize"), let value = WandSampleSize(rawValue: size) { session.wandSettings.sampleSize = value }
            }
            if let object = try params.optionalObject("objectSelection") {
                try AutomationSettings.set(object, "sampleAllLayers", &session.objectSelectionSettings.sampleAllLayers)
                if let offset = try object.optionalInt("edgeOffset") { session.objectSelectionSettings.edgeOffset = min(10, max(-10, offset)) }
            }
            if let gradient = try params.optionalObject("gradient") {
                var settings = session.gradientSettings
                try AutomationSettings.set(gradient, "shape", &settings.shape)
                try AutomationSettings.set(gradient, "style", &settings.style)
                try AutomationSettings.set(gradient, "reversed", &settings.reversed)
                if let opacity = try gradient.optionalDouble("opacity") { settings.opacity = CGFloat(min(1, max(0, opacity))) }
                session.gradientSettings = settings
            }
            if let shape = try params.optionalObject("shape") {
                try AutomationSettings.set(shape, "kind", &session.shapeKind)
                try AutomationSettings.set(shape, "cornerRadius", &session.shapeCornerRadius)
                try AutomationSettings.set(shape, "lineWidth", &session.shapeLineWidth)
            }
            if let selection = try params.optionalObject("selection") {
                try AutomationSettings.set(selection, "antialiased", &session.selectionAntialiased)
                try AutomationSettings.set(selection, "featherAmount", &session.selectionFeatherAmount)
                try AutomationSettings.set(selection, "expandAmount", &session.selectionExpandAmount)
                try AutomationSettings.set(selection, "contractAmount", &session.selectionContractAmount)
            }
            return AutomationState.tools(session)
        }

        add("color.set", group: "session", "Sets the foreground and/or background color.", params: [
            AutomationParamDoc("foreground", "color"), AutomationParamDoc("background", "color"), AutomationParamDoc("swap", "bool"), AutomationParamDoc("reset", "bool", "Black over white."),
        ]) { context, params in
            let session = context.session
            if try params.bool("reset", default: false) { session.resetPaletteColors() }
            if try params.bool("swap", default: false) { session.swapPaletteColors() }
            if let color = try params.optionalColor("foreground") { session.foregroundColor = AutomationSettings.palette(color) }
            if let color = try params.optionalColor("background") { session.backgroundColor = AutomationSettings.palette(color) }
            return ["foreground": AutomationState.color(session.foregroundColor).json, "background": AutomationState.color(session.backgroundColor).json]
        }

        add("color.sample", group: "session", "The composited color at a document point (the Eyedropper).", params: [AutomationDocs.point, AutomationParamDoc("setForeground", "bool")]) { context, params in
            let point = try params.point("point")
            guard let color = context.session.sampleCompositeColor(at: point) else { throw AutomationError.notFound("no opaque pixel at that point") }
            if try params.bool("setForeground", default: false) { context.session.foregroundColor = color }
            return AutomationState.color(color).json
        }

        add("session.cancel", group: "session", "Cancels whatever edit is in progress (transform, crop, filter, levels, text…), freeing the session.") { context, _ in
            let session = context.session
            var cancelled: [String] = []
            if session.brushStroke != nil || session.warpStroke != nil { session.cancelBrush(); cancelled.append("stroke") }
            if session.gradientEdit != nil { session.cancelGradient(); cancelled.append("gradient") }
            if session.pixelMove != nil { session.cancelPixelMove(); cancelled.append("pixelMove") }
            if session.textDraft != nil { session.cancelText(); cancelled.append("text") }
            if session.shapeDraft != nil { session.cancelShape(); cancelled.append("shape") }
            if session.lassoDraft != nil { session.cancelLasso(); cancelled.append("lasso") }
            if session.filterEdit != nil { session.cancelFilter(); cancelled.append("filter") }
            if session.levels != nil { session.cancelLevels(); cancelled.append("levels") }
            if session.hueSaturation != nil { session.cancelHueSaturation(); cancelled.append("hueSaturation") }
            if session.adjustmentEditingID != nil { _ = session.finishAdjustmentEditing(commit: false); session.adjustmentEditingID = nil; cancelled.append("adjustment") }
            if session.colorRange != nil { session.cancelColorRange(); cancelled.append("colorRange") }
            if session.selectionAmountOperation != nil { session.selectionAmountOperation = nil; cancelled.append("selectionAmount") }
            if session.transformEdit != nil { session.cancelTransform(); cancelled.append("transform") }
            if session.cropRect != nil { session.cancelCrop(); cancelled.append("crop") }
            if session.renamingLayerID != nil { session.renamingLayerID = nil; cancelled.append("rename") }
            if session.importError != nil { session.importError = nil; cancelled.append("importError") }
            if session.brushError != nil { session.brushError = nil }
            if session.cropError != nil { session.cropError = nil }
            return ["cancelled": cancelled, "editable": session.canEditLayers]
        }

        add("session.wait", group: "session", "Waits until the project is idle (no save, import or render running), up to `timeout` seconds.", params: [AutomationParamDoc("timeout", "number", "0–3600, default 60.")]) { context, params in
            let timeout = try params.double("timeout", in: 0...3600, default: 60)
            let deadline = ContinuousClock.now + .seconds(max(0, timeout))
            while context.session.isProjectBusy || context.session.isImporting, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            return ["idle": !context.session.isProjectBusy && !context.session.isImporting]
        }

        add("app.info", group: "session", "App and API versions, limits, and the enumerations the API accepts.") { _, _ in
            let bundle = Bundle.main
            return [
                "app": bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "build": bundle.infoDictionary?["CFBundleVersion"] as? String ?? "",
                "api": AutomationRouter.apiVersion,
                "limits": ["maxSide": DocumentLimits.maxSide, "maxSurfacePixels": DocumentLimits.maxSurfacePixels, "documentPixelBudget": DocumentLimits.documentPixelBudget],
                "enums": [
                    "blendModes": LayerBlendMode.allCases.map(\.rawValue), "adjustmentKinds": AdjustmentKind.allCases.map(\.rawValue),
                    "filterKinds": FilterKind.allCases.map(\.rawValue), "effectKinds": LayerEffectKind.allCases.map(\.rawValue),
                    "sampling": LayerSampling.allCases.map(\.rawValue), "tools": NavigationTool.allCases.filter { $0 != .idle }.map(\.rawValue),
                    "colorRanges": ColorRange.allCases.map(\.rawValue), "ditherStyles": DitherStyle.allCases.map(\.rawValue),
                    "shapeKinds": ShapeKind.allCases.map(\.rawValue), "textAlignments": TextAlignment.allCases.map(\.rawValue),
                    "healingModes": SpotHealingMode.allCases.map(\.rawValue), "trimModes": TrimBasedOn.allCases.map(\.rawValue),
                    "gradientShapes": GradientShape.allCases.map(\.rawValue), "gradientStyles": GradientStyle.allCases.map(\.rawValue),
                    "cameraRaw": ["glowStyles": CameraRawGlowStyle.allCases.map(\.rawValue), "vignetteStyles": CameraRawVignetteStyle.allCases.map(\.rawValue),
                                  "upright": CameraRawUprightMode.allCases.map(\.rawValue), "projections": CameraRawProjection.allCases.map(\.rawValue),
                                  "processVersions": CameraRawProcessVersion.allCases.map(\.rawValue), "mixerColors": CameraRawMixerSettings.names],
                ],
            ]
        }

        add("app.quit", group: "session", "Quits Compositor. Refused while any project has unsaved changes unless `discard` is true.", params: [AutomationParamDoc("discard", "bool")]) { context, params in
            let dirty = context.workspace.tabs.filter { $0.session.isModified && $0.session.document != nil }
            if !dirty.isEmpty, try !params.bool("discard", default: false) {
                throw AutomationError.conflict("unsaved changes in: " + dirty.map(\.title).joined(separator: ", "))
            }
            // Marking tabs saved is only safe when the quit will go ahead, so refuse now what would cancel it later.
            guard !context.workspace.isManaging, context.workspace.canSwitch else {
                throw AutomationError.conflict("the app is busy (a save, import or dialog is still open); try again, or call session.cancel")
            }
            for tab in dirty { tab.session.history.markSaved() }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.terminate(nil)
            }
            return ["quitting": true]
        }
    }
}
