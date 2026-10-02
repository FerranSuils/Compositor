import Foundation
import CoreGraphics
import CoreImage

extension AutomationRegistry {
    // MARK: - Layers

    func registerLayerCommands() {
        group("layer", "Layers and folders: add, delete, rename, order, visibility, opacity, blend mode, groups, merge, clipping and pixels.")

        add("layer.list", group: "layer", "Every layer, bottom to top, with all its properties.", params: [
            AutomationParamDoc("visibleOnly", "bool", "Only layers that draw (visible, inside visible folders)."),
        ]) { context, params in
            let document = try context.document()
            let visible = document.effectiveVisibleIDs
            let onlyVisible = try params.bool("visibleOnly", default: false)
            return document.layers.filter { !onlyVisible || visible.contains($0.id) }.map { AutomationState.layer($0, in: document, session: context.session) }
        }

        add("layer.get", group: "layer", "One layer's properties.", params: [AutomationDocs.layer]) { context, params in
            let layer = try context.layer(params)
            return AutomationState.layer(layer, in: try context.document(), session: context.session)
        }

        add("layer.select", group: "layer", "Makes layers the selection; the first (or `primary`) becomes the active layer.", params: [
            AutomationDocs.layers, AutomationParamDoc("primary", "string", "Which of them is active; the first when omitted."),
            AutomationParamDoc("mask", "bool", "Target the active layer's mask instead of its pixels."),
        ]) { context, params in
            let layers = try context.layers(params)
            let primary = params.has("primary") ? try context.layerID(params, key: "primary", allowActive: false) : layers[0].id
            if layers.count == 1 {
                try context.activate(primary, mask: try params.bool("mask", default: false))
            } else {
                context.session.selectLayers(Set(layers.map(\.id)), primary: primary)
                guard context.session.activeLayerID == primary else { throw AutomationError.conflict(context.blockedReason()) }
                context.session.isMaskSelected = try params.bool("mask", default: false)
            }
            return ["active": primary.uuidString, "selected": context.session.selectedLayerIDs.map(\.uuidString).sorted()]
        }

        add("layer.add", group: "layer", "Adds an empty canvas-sized layer above the active one and makes it active.", params: [
            AutomationParamDoc("name", "string", "Layer name; \"Layer N\" when omitted."),
        ]) { context, params in
            try context.requireEditable()
            let before = Set(try context.document().layers.map(\.id))
            context.session.addBlankLayer()
            guard let layer = try context.document().layers.first(where: { !before.contains($0.id) }) else {
                throw AutomationError.conflict("the layer could not be added (\(context.blockedReason()))")
            }
            if let name = try params.optionalString("name") { context.session.renameLayer(layer.id, to: name) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: context.session)
        }

        add("layer.addImage", group: "layer", "Adds a pixel layer from a file, inline image data or a solid color. Creates the document when none is open.", params: [
            AutomationParamDoc("path", "string", "Image file (PNG, JPEG, HEIC, TIFF, PSD, SVG, RAW). RAW and PSD go through the importer with default conversion."),
            AutomationParamDoc("imageData", "base64", "Inline PNG/JPEG bytes instead of a path."),
            AutomationParamDoc("color", "color", "Solid fill instead of an image; needs `size`."),
            AutomationParamDoc("size", "size", "Pixel size for a solid layer; defaults to the canvas."),
            AutomationParamDoc("name", "string", "Layer name."),
            AutomationParamDoc("origin", "point", "Top-left corner in document pixels; centered on the canvas when omitted."),
            AutomationParamDoc("center", "point", "Center in document pixels (alternative to origin)."),
        ]) { context, params in
            let session = context.session
            if let url = try params.optionalFileURL("path") {
                // Files the app knows how to convert (RAW, PSD, SVG) go through its importer, headlessly.
                let lower = url.pathExtension.lowercased()
                if RawImporter.matches(url) || PSDReader.matches(url) || lower == "svg" {
                    let center = try params.optionalPoint("center")
                    // Answer the conversion sheets for this import only, so the person's own imports still ask.
                    let (savedConversions, savedRawDevelop) = (session.confirmConversions, session.confirmRawDevelop)
                    defer { session.confirmConversions = savedConversions; session.confirmRawDevelop = savedRawDevelop }
                    if session.confirmConversions == nil { session.confirmConversions = { _ in true } }
                    if session.confirmRawDevelop == nil { session.confirmRawDevelop = { _, settings in settings } }
                    let before = Set(session.document?.layers.map(\.id) ?? [])
                    session.importError = nil
                    await session.importImages([url], at: center)
                    if let error = session.importError { session.importError = nil; throw AutomationError.unprocessable(error) }
                    let added = (session.document?.layers ?? []).filter { !before.contains($0.id) }
                    guard let layer = added.last else { throw AutomationError.unprocessable("nothing was imported from \(url.lastPathComponent)") }
                    if let name = try params.optionalString("name") { session.renameLayer(layer.id, to: name) }
                    return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
                }
            }
            let image: CGImage
            var name = try params.optionalString("name") ?? "Layer"
            if let url = try params.optionalFileURL("path") {
                image = try AutomationImages.decode(fileAt: url)
                if !params.has("name") { name = url.deletingPathExtension().lastPathComponent }
            } else if let data = try params.optionalData("imageData") {
                image = try AutomationImages.decode(data)
            } else if let color = try params.optionalColor("color") {
                let size = try params.optionalSize("size") ?? session.document?.size ?? CGSize(width: 1920, height: 1080)
                image = try AutomationImages.solid(size: size, color: color)
            } else {
                throw AutomationError.badRequest("give \"path\", \"imageData\" or \"color\"")
            }
            guard image.width <= DocumentLimits.maxSide, image.height <= DocumentLimits.maxSide else {
                throw AutomationError.unprocessable("the image exceeds \(DocumentLimits.maxSide) pixels on a side")
            }
            let asset = try AutomationImages.importedImage(image, name: name)
            let before = Set(session.document?.layers.map(\.id) ?? [])
            if session.document == nil || (!params.has("origin") && !params.has("center")) {
                if session.document != nil { try context.requireEditable() }
                session.insert(asset, centeredAt: try params.optionalPoint("center"))
            } else {
                try context.requireEditable()
                let origin: CGPoint
                if let center = try params.optionalPoint("center") {
                    origin = CGPoint(x: (center.x - CGFloat(image.width) / 2).rounded(.down), y: (center.y - CGFloat(image.height) / 2).rounded(.down))
                } else {
                    origin = try params.point("origin")
                }
                session.addPixelLayer(asset.image, at: origin, name: name, editName: "Add Image", dropsSelection: false)
            }
            guard let layer = (session.document?.layers ?? []).first(where: { !before.contains($0.id) }) else {
                throw AutomationError.conflict("the layer could not be added (\(context.blockedReason()))")
            }
            if params.has("name"), layer.name != name { session.renameLayer(layer.id, to: name) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("layer.delete", group: "layer", "Deletes layers (a folder takes its contents). Layers clipped to a deleted one are unclipped, or baked with `bakeClipping`.", params: [
            AutomationParamDoc("layers", "[string]", "Layers to delete; the active layer when omitted."),
            AutomationParamDoc("bakeClipping", "bool", "Bake the deleted layer's clipping into dependent layers' pixels instead of releasing it."),
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            var baked: [UUID: ImportedImage] = [:]
            if try params.bool("bakeClipping", default: false), let snapshot = session.projectSnapshot() {
                let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1).union([$1])) }
                let targets = (session.document?.layers ?? []).filter { !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true }.map(\.id)
                if !targets.isEmpty {
                    baked = try await Task.detached(priority: .userInitiated) {
                        var result: [UUID: ImportedImage] = [:]
                        for target in targets { result[target] = try LiveMaskBaker.bake(snapshot, target: target) }
                        return result
                    }.value
                }
            }
            session.finishDeletingLayers(ids, baked: baked)
            return ["deleted": ids.map(\.uuidString), "layerCount": session.document?.layers.count ?? 0]
        }

        add("layer.rename", group: "layer", "Renames a layer.", params: [AutomationDocs.layer, AutomationParamDoc("name", "string", required: true)]) { context, params in
            let id = try context.layerID(params)
            let name = try params.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw AutomationError.badRequest("\"name\" must not be empty") }
            context.session.renameLayer(id, to: name)
            return ["id": id.uuidString, "name": try context.layer(AutomationParams(["layer": id.uuidString])).name]
        }

        add("layer.setVisible", group: "layer", "Shows or hides layers.", params: [
            AutomationParamDoc("layers", "[string]", "Layers; the active layer when omitted."), AutomationParamDoc("visible", "bool", required: true),
        ]) { context, params in
            try context.requireEditable()
            let visible = try params.bool("visible")
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            let session = context.session
            session.beginEdit(visible ? "Show Layer" : "Hide Layer")
            for id in ids {
                if let index = session.document?.layers.firstIndex(where: { $0.id == id }) { session.document?.layers[index].isVisible = visible }
            }
            session.endEdit()
            return ["layers": ids.map(\.uuidString), "visible": visible]
        }

        add("layer.setOpacity", group: "layer", "Sets opacity, 0–1 (or 0–100 when `percent` is true).", params: [
            AutomationParamDoc("layers", "[string]", "Layers; the active layer when omitted."),
            AutomationParamDoc("opacity", "number", required: true), AutomationParamDoc("percent", "bool"),
        ]) { context, params in
            try context.requireEditable()
            var opacity = try params.double("opacity")
            if try params.bool("percent", default: false) { opacity /= 100 }
            guard (0...1).contains(opacity) else { throw AutomationError.badRequest("\"opacity\" must be 0–1") }
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            let session = context.session
            session.beginEdit("Layer Opacity")
            for id in ids {
                if let index = session.document?.layers.firstIndex(where: { $0.id == id }) { session.document?.layers[index].opacity = opacity }
            }
            session.endEdit()
            return ["layers": ids.map(\.uuidString), "opacity": opacity]
        }

        add("layer.setBlendMode", group: "layer", "Sets the blend mode of a non-folder layer.", params: [
            AutomationDocs.layer, AutomationParamDoc("blendMode", "string", required: true, "One of: " + LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ")),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard !layer.isGroup else { throw AutomationError.unprocessable("folders are pass-through and keep the Normal blend mode") }
            let mode: LayerBlendMode = try params.enumeration("blendMode", cases: LayerBlendMode.allCases)
            try context.activate(layer.id)
            context.session.setLayerBlendMode(mode)
            return ["layer": layer.id.uuidString, "blendMode": mode.rawValue]
        }

        add("layer.move", group: "layer", "Moves a layer in the stack: by `offset` among its siblings, or into `parent` (\"root\" or a folder) above `above` / at the bottom.", params: [
            AutomationDocs.layer,
            AutomationParamDoc("offset", "int", "+1 moves up one sibling, −1 down; larger values repeat."),
            AutomationParamDoc("parent", "string", "Folder id or name, or \"root\"."),
            AutomationParamDoc("above", "string", "Sibling in `parent` to sit above; the top when omitted."),
            AutomationParamDoc("atBottom", "bool", "Place at the bottom of `parent`."),
            AutomationParamDoc("outOfFolder", "bool", "Move out of the enclosing folder, above it."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            let session = context.session
            if try params.bool("outOfFolder", default: false) {
                try context.activate(layer.id)
                session.moveActiveLayerOutOfGroup()
            } else if let offset = try params.optionalInt("offset") {
                try context.activate(layer.id)
                let steps = abs(offset), direction = offset < 0 ? -1 : 1
                for _ in 0..<steps {
                    guard session.canMoveActiveLayer(by: direction) else { break }
                    session.moveActiveLayer(by: direction)
                }
            } else if params.has("parent") || params.has("above") || params.has("atBottom") {
                var parent: UUID?
                if let reference = try params.optionalString("parent"), reference != "root" {
                    let folder = try context.layer(params, key: "parent", allowActive: false)
                    guard folder.isGroup else { throw AutomationError.unprocessable("\"parent\" must be a folder") }
                    parent = folder.id
                } else if !params.has("parent") {
                    parent = layer.parentID
                }
                let above = params.has("above") ? try context.layerID(params, key: "above", allowActive: false) : nil
                guard session.canPlaceLayer(layer.id, in: parent) else { throw AutomationError.unprocessable("the layer cannot be placed there") }
                guard session.placeLayer(layer.id, in: parent, above: above, atBottom: try params.bool("atBottom", default: false)) else {
                    throw AutomationError.unprocessable("the move was refused; check that \"above\" is a sibling inside \"parent\"")
                }
            } else {
                throw AutomationError.badRequest("give \"offset\", \"parent\"/\"above\"/\"atBottom\" or \"outOfFolder\"")
            }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("layer.duplicate", group: "layer", "Duplicates layers (folders with their contents); the copies become selected.", params: [
            AutomationParamDoc("layers", "[string]", "Layers; the active layer when omitted."),
        ]) { context, params in
            try context.requireEditable()
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            let before = Set(try context.document().layers.map(\.id))
            context.session.duplicateLayers(ids)
            let document = try context.document()
            return document.layers.filter { !before.contains($0.id) }.map { AutomationState.layer($0, in: document, session: context.session) }
        }

        add("layer.group", group: "layer", "Wraps layers in a new folder (Group Layers).", params: [
            AutomationParamDoc("layers", "[string]", "Layers to group; the selected layers when omitted."), AutomationParamDoc("name", "string", "Folder name."),
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            if params.has("layers") {
                let layers = try context.layers(params)
                session.selectLayers(Set(layers.map(\.id)), primary: layers[0].id)
            }
            let before = Set(try context.document().layers.map(\.id))
            session.groupSelectedLayers()
            guard let folder = try context.document().layers.first(where: { !before.contains($0.id) && $0.isGroup }) else {
                throw AutomationError.conflict("nothing was grouped")
            }
            if let name = try params.optionalString("name") { session.renameLayer(folder.id, to: name) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": folder.id.uuidString])), in: try context.document(), session: session)
        }

        add("layer.addGroup", group: "layer", "Adds an empty folder above the active layer.", params: [AutomationParamDoc("name", "string")]) { context, params in
            try context.requireEditable()
            let before = Set(try context.document().layers.map(\.id))
            context.session.addGroup()
            guard let folder = try context.document().layers.first(where: { !before.contains($0.id) }) else { throw AutomationError.conflict("the folder could not be added") }
            if let name = try params.optionalString("name") { context.session.renameLayer(folder.id, to: name) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": folder.id.uuidString])), in: try context.document(), session: context.session)
        }

        add("layer.ungroup", group: "layer", "Dissolves a folder; its contents take its place.", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            let folder = try context.layer(params)
            guard folder.isGroup else { throw AutomationError.unprocessable("\"layer\" is not a folder") }
            try context.activate(folder.id)
            guard context.session.canUngroupLayers else { throw AutomationError.conflict(context.blockedReason()) }
            context.session.ungroupLayers()
            return ["ungrouped": folder.id.uuidString]
        }

        add("layer.merge", group: "layer", "Merge Down (one layer), Merge Layers (several) or Merge Group (a folder), into one pixel layer.", params: [
            AutomationParamDoc("layers", "[string]", "Layers to merge; the selection when omitted."),
        ]) { context, params in
            try context.requireEditable()
            let session = context.session
            if params.has("layers") {
                let layers = try context.layers(params)
                if layers.count == 1 { try context.activate(layers[0].id) } else { session.selectLayers(Set(layers.map(\.id)), primary: layers.last!.id) }
            }
            guard session.canMergeLayers else { throw AutomationError.unprocessable("nothing to merge: a pixel layer needs a pixel layer beneath it, or select several layers or a folder") }
            let title = session.mergeTitle
            session.mergeLayers()
            guard let result = session.activeLayer else { throw AutomationError.failed("the merge left no active layer") }
            return ["operation": title, "layer": AutomationState.layer(result, in: try context.document(), session: session)]
        }

        add("layer.flatten", group: "layer", "Merges every layer into one pixel layer.") { context, _ in
            try context.requireEditable()
            let session = context.session
            let roots = try context.document().layers.filter { $0.parentID == nil }
            guard roots.count > 1 || roots.first?.isGroup == true else {
                guard let single = session.activeLayer else { return ["layer": NSNull()] }
                return ["layer": AutomationState.layer(single, in: try context.document(), session: session)]
            }
            session.selectLayers(Set(roots.map(\.id)), primary: roots.last!.id)
            guard session.canMergeLayers else { throw AutomationError.unprocessable("the layers cannot be merged") }
            session.mergeLayers()
            guard let result = session.activeLayer else { throw AutomationError.failed("the merge left no active layer") }
            return ["layer": AutomationState.layer(result, in: try context.document(), session: session)]
        }

        add("layer.clip", group: "layer", "Clips a layer to the pixels of `base` (Create Clipping Mask); without `base`, to the layer below.", params: [
            AutomationDocs.layer, AutomationParamDoc("base", "string", "The layer whose pixels clip this one."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            let session = context.session
            if params.has("base") {
                let base = try context.layerID(params, key: "base", allowActive: false)
                guard session.canLinkMask(source: base, target: layer.id) else { throw AutomationError.unprocessable("that base cannot clip this layer (folders and adjustment layers cannot be bases, and cycles are refused)") }
                guard session.linkMask(source: base, target: layer.id) else { throw AutomationError.unprocessable("the clipping mask was refused") }
            } else {
                guard layer.maskSourceID == nil else { return ["layer": layer.id.uuidString, "clippedTo": layer.maskSourceID!.uuidString] }
                guard session.canToggleClippingMask(layer.id) else { throw AutomationError.unprocessable("no layer below to clip to") }
                session.toggleClippingMask(layer.id)
            }
            return ["layer": layer.id.uuidString, "clippedTo": AutomationJSON.nullable(try context.layer(AutomationParams(["layer": layer.id.uuidString])).maskSourceID?.uuidString)]
        }

        add("layer.unclip", group: "layer", "Releases a clipping mask.", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            context.session.removeLiveMask(from: layer.id)
            return ["layer": layer.id.uuidString, "clippedTo": NSNull()]
        }

        add("layer.setPixels", group: "layer", "Replaces a layer's pixels with an image (file or inline). The layer keeps its position; its size follows the image unless `keepSize`.", params: [
            AutomationDocs.layer, AutomationParamDoc("path", "string"), AutomationParamDoc("imageData", "base64"),
            AutomationParamDoc("keepSize", "bool", "Stretch the new pixels into the current box instead of resizing it."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard !layer.isGroup, layer.adjustment == nil else { throw AutomationError.unprocessable("folders and adjustment layers have no pixels") }
            let image: CGImage
            if let url = try params.optionalFileURL("path") { image = try AutomationImages.decode(fileAt: url) }
            else { image = try AutomationImages.decode(try params.data("imageData")) }
            let asset = try AutomationImages.importedImage(image, name: layer.name)
            let session = context.session
            guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw AutomationError.notFound("layer vanished") }
            session.beginEdit("Replace Pixels")
            session.document?.layers[index].asset = asset
            session.document?.layers[index].text = nil
            session.document?.layers[index].shape = nil
            if try !params.bool("keepSize", default: false) {
                session.document?.layers[index].transform.size = CGSize(width: image.width, height: image.height)
            }
            if let mask = layer.mask, mask.asset.image.width != 1, mask.asset.image.width != image.width || mask.asset.image.height != image.height {
                // A raster mask covers the layer's pixel grid; a grid of another size can no longer be used.
                session.document?.layers[index].mask = nil
            }
            session.endEdit()
            session.brushRevision += 1
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("layer.setCollapsed", group: "layer", "Collapses or expands a folder in the Layers panel (view state only).", params: [
            AutomationDocs.layer, AutomationParamDoc("collapsed", "bool", required: true),
        ]) { context, params in
            let layer = try context.layer(params)
            if try params.bool("collapsed") { context.session.collapsedGroupIDs.insert(layer.id) } else { context.session.collapsedGroupIDs.remove(layer.id) }
            return ["layer": layer.id.uuidString, "collapsed": context.session.collapsedGroupIDs.contains(layer.id)]
        }
    }

    // MARK: - Masks

    func registerMaskCommands() {
        group("mask", "Layer masks: add (reveal all, hide all or from the selection), pixels, enable, link, invert, fill, blur, copy and delete.")

        add("mask.add", group: "mask", "Adds a mask: all white (reveal), all black (hide), or from the selection when there is one.", params: [
            AutomationDocs.layer, AutomationParamDoc("reveal", "bool", "true (default) reveals everything / the selection; false hides it."),
            AutomationParamDoc("fromSelection", "bool", "Use the selection (default when one exists); false ignores it."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard layer.mask == nil else { throw AutomationError.conflict("the layer already has a mask; delete it first or use mask.setPixels") }
            try context.activate(layer.id)
            let session = context.session
            let reveal = try params.bool("reveal", default: true)
            try context.checkingBrushError {
                if try params.bool("fromSelection", default: session.selection != nil) && session.selection != nil {
                    session.addMask(revealing: reveal)
                } else {
                    session.addLayerMask(revealing: reveal)
                }
            }
            guard try context.layer(AutomationParams(["layer": layer.id.uuidString])).mask != nil else { throw AutomationError.conflict("the mask could not be added (\(context.blockedReason()))") }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("mask.setPixels", group: "mask", "Sets a mask from a grayscale image (white reveals) the size of the layer's pixels, or from a solid `value` 0–1. Adds the mask when missing.", params: [
            AutomationDocs.layer, AutomationParamDoc("path", "string"), AutomationParamDoc("imageData", "base64"),
            AutomationParamDoc("value", "number", "Uniform gray 0 (hide) to 1 (reveal)."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            let session = context.session
            let image: CGImage
            if let url = try params.optionalFileURL("path") { image = try AutomationImages.gray(try AutomationImages.decode(fileAt: url)) }
            else if let data = try params.optionalData("imageData") { image = try AutomationImages.gray(try AutomationImages.decode(data)) }
            else if let value = try params.optionalDouble("value") {
                guard (0...1).contains(value) else { throw AutomationError.badRequest("\"value\" must be 0–1") }
                let ctx = try BrushRaster.context(width: 1, height: 1, mask: true)
                ctx.setFillColor(gray: CGFloat(value), alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard let solid = ctx.makeImage() else { throw AutomationError.failed("could not make the mask") }
                image = solid
            } else { throw AutomationError.badRequest("give \"path\", \"imageData\" or \"value\"") }
            if let asset = layer.asset, image.width != 1, image.width != asset.image.width || image.height != asset.image.height {
                throw AutomationError.unprocessable("the mask must be \(asset.image.width)×\(asset.image.height) pixels, the layer's pixel size")
            }
            let maskAsset = try LayerMask.asset(from: image)
            guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw AutomationError.notFound("layer vanished") }
            session.beginEdit(layer.mask == nil ? "Add Layer Mask" : "Replace Layer Mask")
            if let existing = layer.mask {
                session.document?.layers[index].mask = existing.replacing(maskAsset)
            } else {
                session.document?.layers[index].mask = LayerMask(asset: maskAsset)
            }
            session.endEdit()
            session.brushRevision += 1
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("mask.delete", group: "mask", "Removes a layer's mask.", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard layer.mask != nil else { throw AutomationError.notFound("the layer has no mask") }
            try context.activate(layer.id)
            context.session.deleteLayerMask()
            return ["layer": layer.id.uuidString, "mask": NSNull()]
        }

        add("mask.setEnabled", group: "mask", "Enables or disables a mask without removing it.", params: [AutomationDocs.layer, AutomationParamDoc("enabled", "bool", required: true)]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard let mask = layer.mask else { throw AutomationError.notFound("the layer has no mask") }
            let enabled = try params.bool("enabled")
            if mask.isEnabled != enabled {
                try context.activate(layer.id)
                context.session.toggleLayerMask()
            }
            // The toggle is gated (canEditMask), so report what the layer has now rather than what was asked.
            let now = try context.layer(AutomationParams(["layer": layer.id.uuidString])).mask?.isEnabled ?? false
            guard now == enabled else { throw AutomationError.conflict("the mask could not be changed (\(context.blockedReason()))") }
            return ["layer": layer.id.uuidString, "enabled": now]
        }

        add("mask.setLinked", group: "mask", "Links the mask to the layer's transform, or unlinks it so it can be moved on its own.", params: [AutomationDocs.layer, AutomationParamDoc("linked", "bool", required: true)]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard let mask = layer.mask else { throw AutomationError.notFound("the layer has no mask") }
            let linked = try params.bool("linked")
            if mask.isLinked != linked { context.session.toggleMaskLink(layer.id) }
            let now = try context.layer(AutomationParams(["layer": layer.id.uuidString])).mask?.isLinked ?? false
            guard now == linked else { throw AutomationError.conflict("the mask could not be changed (\(context.blockedReason()))") }
            return ["layer": layer.id.uuidString, "linked": now]
        }

        add("mask.copy", group: "mask", "Copies one layer's mask onto another (replacing any it has).", params: [
            AutomationParamDoc("from", "string", required: true), AutomationParamDoc("to", "string", required: true),
        ]) { context, params in
            try context.requireEditable()
            let source = try context.layerID(params, key: "from", allowActive: false), target = try context.layerID(params, key: "to", allowActive: false)
            guard context.session.canCopyMask(from: source, to: target) else { throw AutomationError.unprocessable("the mask cannot be copied there (folders cannot take one)") }
            context.session.copyMask(from: source, to: target)
            return ["from": source.uuidString, "to": target.uuidString]
        }

        add("mask.invert", group: "mask", "Inverts a mask (inside the selection when there is one).", params: [AutomationDocs.layer]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard layer.mask?.isEnabled == true else { throw AutomationError.unprocessable("the layer needs an enabled mask") }
            try context.activate(layer.id, mask: true)
            guard context.session.canInvert else { throw AutomationError.conflict("the mask cannot be inverted right now") }
            try await context.checkingBrushErrorAsync { await context.session.invertPixels() }
            return ["layer": layer.id.uuidString]
        }

        add("mask.fill", group: "mask", "Fills the mask (or the selection on it) with white (reveal) or black (hide).", params: [
            AutomationDocs.layer, AutomationParamDoc("reveal", "bool", required: true),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard layer.mask?.isEnabled == true else { throw AutomationError.unprocessable("the layer needs an enabled mask") }
            try context.activate(layer.id, mask: true)
            let session = context.session
            session.maskPaintWhite = try params.bool("reveal")
            guard session.canEditPixels else { throw AutomationError.conflict("the mask cannot be filled right now (an empty selection fills nothing)") }
            try await context.checkingBrushErrorAsync { await session.fillSelection(with: .foreground) }
            return ["layer": layer.id.uuidString]
        }

        add("mask.blur", group: "mask", "Softens a mask with a Gaussian blur of `radius` pixels.", params: [
            AutomationDocs.layer, AutomationParamDoc("radius", "number", required: true, "0.1–250 mask pixels."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard let mask = layer.mask else { throw AutomationError.notFound("the layer has no mask") }
            let radius = try params.double("radius", in: 0.1...250)
            let source = mask.asset.image
            guard source.width > 1 || source.height > 1 else { return ["layer": layer.id.uuidString, "note": "a uniform mask has nothing to blur"] }
            let blurred: CGImage = try await Task.detached(priority: .userInitiated) {
                let filter = CIFilter(name: "CIGaussianBlur")!
                filter.setValue(CIImage(cgImage: source).clampedToExtent(), forKey: kCIInputImageKey)
                filter.setValue(radius, forKey: kCIInputRadiusKey)
                guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: source.width, height: source.height)) else { throw AutomationError.failed("blur failed") }
                return try PixelAdjust.render(output, width: source.width, height: source.height, isMask: true)
            }.value
            let session = context.session
            // The blur ran off the main actor, so the person may have started an edit meanwhile.
            try context.requireEditable()
            guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw AutomationError.notFound("layer vanished") }
            session.beginEdit("Blur Layer Mask")
            session.document?.layers[index].mask = mask.replacing(try LayerMask.asset(from: blurred))
            session.endEdit()
            session.brushRevision += 1
            return ["layer": layer.id.uuidString, "radius": radius]
        }

        add("mask.setPlacement", group: "mask", "Moves an unlinked mask on its own: a document-space box like a layer transform.", params: [
            AutomationDocs.layer, AutomationParamDoc("x", "number"), AutomationParamDoc("y", "number"), AutomationParamDoc("width", "number"),
            AutomationParamDoc("height", "number"), AutomationParamDoc("rotation", "number"),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard let mask = layer.mask else { throw AutomationError.notFound("the layer has no mask") }
            guard !mask.isLinked else { throw AutomationError.unprocessable("unlink the mask first (mask.setLinked false)") }
            try context.activate(layer.id, mask: true)
            let session = context.session
            session.beginTransform(persistent: true)
            guard var draft = session.transformEdit?.draft, session.transformEdit?.mask == true else {
                session.cancelTransform()
                throw AutomationError.conflict("the mask transform could not start")
            }
            try AutomationTransforms.apply(params, to: &draft)
            session.previewTransform(draft)
            session.commitTransform()
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }
    }

    // MARK: - Transform

    func registerTransformCommands() {
        group("transform", "Non-destructive move, scale, rotate, flip and sampling of layers, folders or several layers together; free distort by corners.")

        add("transform.set", group: "transform", "Sets a layer's box: any of x, y, width, height, rotation (degrees clockwise), flipX, flipY, sampling.", params: [
            AutomationDocs.layer, AutomationParamDoc("x", "number"), AutomationParamDoc("y", "number"), AutomationParamDoc("width", "number"),
            AutomationParamDoc("height", "number"), AutomationParamDoc("rotation", "number"), AutomationParamDoc("flipX", "bool"), AutomationParamDoc("flipY", "bool"),
            AutomationParamDoc("sampling", "string", "Nearest, Smooth or High quality."),
        ]) { context, params in
            let layer = try context.layer(params)
            let session = context.session
            try AutomationTransforms.withEdit(context, layers: [layer.id]) { draft in try AutomationTransforms.apply(params, to: &draft) }
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("transform.move", group: "transform", "Moves layers by `dx`/`dy`, or so their box's top-left lands at `to`.", params: [
            AutomationParamDoc("layers", "[string]", "Layers; the active layer when omitted."), AutomationParamDoc("dx", "number"), AutomationParamDoc("dy", "number"),
            AutomationParamDoc("to", "point", "Absolute top-left of the (group) box."),
        ]) { context, params in
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            try AutomationTransforms.withEdit(context, layers: ids) { draft in
                if let to = try params.optionalPoint("to") { draft.origin = to }
                draft.origin.x += CGFloat(try params.double("dx", default: 0))
                draft.origin.y += CGFloat(try params.double("dy", default: 0))
            }
            return AutomationTransforms.report(context, ids)
        }

        add("transform.scale", group: "transform", "Scales layers about their center: `factor` (1 = same), or `percent` of the layer's pixel size, or `width`/`height`.", params: [
            AutomationParamDoc("layers", "[string]"), AutomationParamDoc("factor", "number"), AutomationParamDoc("factorY", "number", "Vertical factor when different."),
            AutomationParamDoc("percent", "number", "Size as a percentage of the layer's own pixels (single layer)."),
            AutomationParamDoc("width", "number"), AutomationParamDoc("height", "number"), AutomationParamDoc("keepRatio", "bool", "With one of width/height, keep the other in proportion (default true)."),
        ]) { context, params in
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            try AutomationTransforms.withEdit(context, layers: ids) { draft in
                let center = draft.center
                if let percent = try params.optionalDouble("percent") {
                    guard let pixelSize = context.session.transformPixelSize else { throw AutomationError.unprocessable("\"percent\" needs a single pixel layer") }
                    draft = draft.scaled(toPercent: CGFloat(percent), pixelSize: pixelSize)
                } else if let factor = try params.optionalDouble("factor") {
                    let fy = try params.optionalDouble("factorY") ?? factor
                    draft.size = CGSize(width: draft.size.width * CGFloat(factor), height: draft.size.height * CGFloat(fy))
                } else {
                    let keep = try params.bool("keepRatio", default: true)
                    let ratio = draft.size.height / max(1, draft.size.width)
                    if let width = try params.optionalDouble("width") {
                        draft.size.width = CGFloat(width)
                        if keep && !params.has("height") { draft.size.height = CGFloat(width) * ratio }
                    }
                    if let height = try params.optionalDouble("height") {
                        draft.size.height = CGFloat(height)
                        if keep && !params.has("width") { draft.size.width = CGFloat(height) / max(ratio, 0.0001) }
                    }
                }
                draft.origin = CGPoint(x: center.x - draft.size.width / 2, y: center.y - draft.size.height / 2)
            }
            return AutomationTransforms.report(context, ids)
        }

        add("transform.rotate", group: "transform", "Rotates layers about their center by `degrees` (clockwise), or to an absolute `angle`.", params: [
            AutomationParamDoc("layers", "[string]"), AutomationParamDoc("degrees", "number"), AutomationParamDoc("angle", "number"),
        ]) { context, params in
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            try AutomationTransforms.withEdit(context, layers: ids) { draft in
                if let angle = try params.optionalDouble("angle") { draft.rotation = CGFloat(angle) }
                draft.rotation += CGFloat(try params.double("degrees", default: 0))
                draft.rotation = draft.rotation.truncatingRemainder(dividingBy: 360)
            }
            return AutomationTransforms.report(context, ids)
        }

        add("transform.flip", group: "transform", "Flips layers horizontally or vertically about their (group) center.", params: [
            AutomationParamDoc("layers", "[string]"), AutomationParamDoc("horizontal", "bool", "true (default) flips left-right; false top-bottom."),
        ]) { context, params in
            try context.requireEditable()
            let ids = params.has("layers") ? try context.layers(params).map(\.id) : [try context.layerID(params)]
            let session = context.session
            if ids.count == 1 { try context.activate(ids[0]) } else { session.selectLayers(Set(ids), primary: ids[0]) }
            guard session.canTransform else { throw AutomationError.unprocessable("the layer cannot be transformed (hidden, empty or a folder with nothing visible)") }
            session.flipLayers(horizontally: try params.bool("horizontal", default: true))
            return AutomationTransforms.report(context, ids)
        }

        add("transform.distort", group: "transform", "Free distort: maps the layer's box onto four document points (top-left, top-right, bottom-right, bottom-left). Resamples the pixels.", params: [
            AutomationDocs.layer, AutomationParamDoc("corners", "[point]", required: true, "Four points in TL, TR, BR, BL order."),
        ]) { context, params in
            let layer = try context.layer(params)
            let corners = try params.points("corners")
            guard corners.count == 4 else { throw AutomationError.badRequest("\"corners\" needs four points") }
            guard DistortWarp.isUsable(corners) else { throw AutomationError.badRequest("the corners do not form a usable quadrilateral") }
            try context.requireEditable()
            try context.activate(layer.id)
            let session = context.session
            guard session.canTransform else { throw AutomationError.unprocessable("the layer cannot be transformed") }
            session.beginTransform(persistent: true)
            guard session.transformEdit != nil else { throw AutomationError.conflict("the transform could not start") }
            session.beginDistort()
            session.previewCorners(corners)
            session.commitTransform()
            return AutomationState.layer(try context.layer(AutomationParams(["layer": layer.id.uuidString])), in: try context.document(), session: session)
        }

        add("transform.setSampling", group: "transform", "Sets how a layer's pixels are resampled when scaled: Nearest, Smooth or High quality.", params: [
            AutomationDocs.layer, AutomationParamDoc("sampling", "string", required: true),
        ]) { context, params in
            let layer = try context.layer(params)
            let sampling: LayerSampling = try params.enumeration("sampling", cases: LayerSampling.allCases)
            try AutomationTransforms.withEdit(context, layers: [layer.id]) { $0.sampling = sampling }
            return ["layer": layer.id.uuidString, "sampling": sampling.rawValue]
        }
    }

    // MARK: - Effects

    func registerEffectCommands() {
        group("effects", "Layer effects: stroke, drop shadow, color overlay, inner shadow, outer glow, inner glow.")

        add("effects.get", group: "effects", "A layer's effects.", params: [AutomationDocs.layer]) { context, params in
            AutomationSettings.effects(try context.layer(params).effects ?? LayerEffects())
        }

        add("effects.set", group: "effects", "Adds or changes effects. Keys: stroke {size, color, opacity, inside, enabled}, shadow/innerShadow {angle, distance, blur, color, opacity, enabled}, colorOverlay {color, opacity, enabled}, outerGlow/innerGlow {size, color, opacity, enabled}. `null` removes one.", params: [
            AutomationDocs.layer, AutomationParamDoc("effects", "object", required: true), AutomationParamDoc("replace", "bool", "Start from no effects instead of the current ones."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            guard !layer.isGroup, layer.asset != nil else { throw AutomationError.unprocessable("effects need a pixel layer") }
            var effects = try params.bool("replace", default: false) ? LayerEffects() : (layer.effects ?? LayerEffects())
            try AutomationSettings.effects(try params.object("effects"), into: &effects)
            context.session.setEffects(effects, on: layer.id, name: "Layer Effects")
            return AutomationSettings.effects(try context.layer(AutomationParams(["layer": layer.id.uuidString])).effects ?? LayerEffects())
        }

        add("effects.remove", group: "effects", "Removes one effect kind, or all of them.", params: [
            AutomationDocs.layer, AutomationParamDoc("kind", "string", "Stroke, Drop Shadow, Color Overlay, Inner Shadow, Outer Glow or Inner Glow; all when omitted."),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            var effects = layer.effects ?? LayerEffects()
            if params.has("kind") {
                let kind: LayerEffectKind = try params.enumeration("kind", cases: LayerEffectKind.allCases)
                effects.remove(kind)
            } else {
                effects = LayerEffects()
            }
            context.session.setEffects(effects, on: layer.id, name: "Remove Effects")
            return AutomationSettings.effects(try context.layer(AutomationParams(["layer": layer.id.uuidString])).effects ?? LayerEffects())
        }

        add("effects.setEnabled", group: "effects", "Shows or hides one effect without losing its settings.", params: [
            AutomationDocs.layer, AutomationParamDoc("kind", "string", required: true), AutomationParamDoc("enabled", "bool", required: true),
        ]) { context, params in
            try context.requireEditable()
            let layer = try context.layer(params)
            let kind: LayerEffectKind = try params.enumeration("kind", cases: LayerEffectKind.allCases)
            var effects = layer.effects ?? LayerEffects()
            guard effects.contains(kind) else { throw AutomationError.notFound("the layer has no \(kind.rawValue)") }
            effects.setEnabled(try params.bool("enabled"), for: kind)
            context.session.setEffects(effects, on: layer.id, name: (try params.bool("enabled") ? "Show " : "Hide ") + kind.rawValue)
            return AutomationSettings.effects(try context.layer(AutomationParams(["layer": layer.id.uuidString])).effects ?? LayerEffects())
        }

        add("effects.copy", group: "effects", "Copies one effect from a layer to another.", params: [
            AutomationParamDoc("kind", "string", required: true), AutomationParamDoc("from", "string", required: true), AutomationParamDoc("to", "string", required: true),
        ]) { context, params in
            try context.requireEditable()
            let kind: LayerEffectKind = try params.enumeration("kind", cases: LayerEffectKind.allCases)
            let source = try context.layerID(params, key: "from", allowActive: false), target = try context.layerID(params, key: "to", allowActive: false)
            guard context.session.canCopyEffect(kind, from: source, to: target) else { throw AutomationError.unprocessable("the effect cannot be copied there") }
            context.session.copyEffect(kind, from: source, to: target)
            return AutomationSettings.effects(try context.layer(AutomationParams(["layer": target.uuidString])).effects ?? LayerEffects())
        }
    }
}

/// The transform edit as one step: select, begin, change the draft, commit.
enum AutomationTransforms {
    static func apply(_ params: AutomationParams, to draft: inout LayerTransform) throws {
        if let x = try params.optionalDouble("x") { draft.origin.x = CGFloat(x) }
        if let y = try params.optionalDouble("y") { draft.origin.y = CGFloat(y) }
        if let width = try params.optionalDouble("width") { draft.size.width = CGFloat(width) }
        if let height = try params.optionalDouble("height") { draft.size.height = CGFloat(height) }
        if let rotation = try params.optionalDouble("rotation") { draft.rotation = CGFloat(rotation) }
        if let flip = try params.optionalBool("flipX") { draft.flipX = flip }
        if let flip = try params.optionalBool("flipY") { draft.flipY = flip }
        if params.has("sampling") { draft.sampling = try params.enumeration("sampling", cases: LayerSampling.allCases) }
    }

    static func withEdit(_ context: AutomationContext, layers ids: [UUID], change: (inout LayerTransform) throws -> Void) throws {
        try context.requireEditable()
        let session = context.session
        if ids.count == 1 { try context.activate(ids[0]) } else { session.selectLayers(Set(ids), primary: ids[0]) }
        guard session.canTransform else { throw AutomationError.unprocessable("the layer cannot be transformed (hidden, empty, an adjustment layer, or a folder with nothing visible)") }
        session.beginTransform(persistent: true)
        guard var draft = session.transformEdit?.draft else { throw AutomationError.conflict("the transform could not start (\(context.blockedReason()))") }
        do { try change(&draft) } catch { session.cancelTransform(); throw error }
        guard draft.isValid else {
            session.cancelTransform()
            throw AutomationError.badRequest("the resulting box is invalid: sides must be 1–300000 pixels and the origin within ±1000000")
        }
        session.previewTransform(draft)
        session.commitTransform()
    }

    static func report(_ context: AutomationContext, _ ids: [UUID]) -> Any {
        guard let document = context.session.document else { return NSNull() }
        return document.layers.filter { ids.contains($0.id) }.map { ["id": $0.id.uuidString, "transform": AutomationState.transform($0.transform)] }
    }
}
