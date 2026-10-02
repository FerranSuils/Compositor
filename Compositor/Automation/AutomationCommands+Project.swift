import Foundation
import CoreGraphics
import AppKit

extension AutomationRegistry {
    func registerProjectCommands() {
        group("project", "Projects: new, open, save, export, render, import, tabs.")

        add("project.list", group: "project", "Every open project (tab), with the active one flagged.") { context, _ in
            let workspace = context.workspace
            return workspace.tabs.map { tab -> [String: Any] in
                var info = AutomationState.project(AutomationContext(workspace: workspace, tab: tab))
                info["isActive"] = tab.id == workspace.selectedID
                return info
            }
        }

        add("project.activate", group: "project", "Makes a project the active tab (the one commands target when `project` is omitted).", params: [
            AutomationParamDoc("project", "string", required: true, "Tab id, title or path."),
        ]) { context, params in
            let tab = try AutomationProjects.tab(context.workspace, try params.string("project"))
            guard context.workspace.canSwitch else { throw AutomationError.conflict("the active project is in the middle of an edit") }
            context.workspace.select(tab.id)
            return AutomationState.project(AutomationContext(workspace: context.workspace, tab: tab))
        }

        add("project.new", group: "project", "Creates a new canvas (in the current tab when it is empty, else a new tab).", params: [
            AutomationParamDoc("width", "int", required: true, "1–30000"), AutomationParamDoc("height", "int", required: true),
            AutomationParamDoc("resolution", "number", "Pixels per inch, default 72."), AutomationParamDoc("newTab", "bool", "Always open a new tab."),
            AutomationParamDoc("emptyLayer", "bool", "Start with one blank layer (default true)."),
            AutomationParamDoc("background", "color", "Fill a first layer with this color."),
        ]) { context, params in
            let width = try params.int("width", in: 1...DocumentLimits.maxSide), height = try params.int("height", in: 1...DocumentLimits.maxSide)
            let workspace = context.workspace
            var tab = context.tab
            if try params.bool("newTab", default: false) || tab.session.document != nil {
                guard workspace.canSwitch else { throw AutomationError.conflict("the active project is in the middle of an edit") }
                tab = workspace.addTab(reuseEmpty: !(try params.bool("newTab", default: false)))
            }
            let session = tab.session
            guard !session.isProjectBusy, !session.isImporting else { throw AutomationError.conflict("the project is busy") }
            session.createDocument(width: width, height: height, emptyLayer: try params.bool("emptyLayer", default: true))
            guard session.document != nil else { throw AutomationError.failed("the canvas was not created") }
            if let resolution = try params.optionalDouble("resolution") {
                guard (1...9600).contains(resolution) else { throw AutomationError.badRequest("\"resolution\" must be 1–9600") }
                session.document?.resolution = resolution
            }
            if let color = try params.optionalColor("background") {
                let image = try AutomationImages.solid(size: CGSize(width: width, height: height), color: color)
                if let layer = session.document?.layers.first, layer.asset == nil, let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) {
                    session.document?.layers[index].asset = try AutomationImages.importedImage(image, name: "Background")
                    session.document?.layers[index].name = "Background"
                } else {
                    session.addPixelLayer(image, at: .zero, name: "Background", editName: "Background", dropsSelection: false)
                }
            }
            session.history.reset()
            return AutomationState.session(AutomationContext(workspace: workspace, tab: tab), include: ["layers"])
        }

        add("project.open", group: "project", "Opens a .comp project in a new tab (or selects its tab when already open).", params: [
            AutomationParamDoc("path", "string", required: true),
        ]) { context, params in
            let url = try params.fileURL("path")
            guard FileManager.default.fileExists(atPath: url.path) else { throw AutomationError.notFound("no project at \(url.path)") }
            let workspace = context.workspace
            if let existing = workspace.tabs.first(where: { $0.session.projectURL?.standardizedFileURL == url.standardizedFileURL }) {
                if workspace.canSwitch { workspace.select(existing.id) }
                return AutomationState.session(AutomationContext(workspace: workspace, tab: existing), include: ["layers"])
            }
            // Validate first so a bad file becomes an HTTP error rather than an alert.
            let snapshot: ProjectSnapshot
            do { snapshot = try await ProjectStore.shared.load(from: url) } catch { throw AutomationError.unprocessable("\(url.lastPathComponent): \(error.localizedDescription)") }
            guard workspace.canSwitch else { throw AutomationError.conflict("the active project is in the middle of an edit") }
            let tab = workspace.addTab(reuseEmpty: true)
            tab.session.installProject(snapshot, from: url)
            RecentProjects.shared.note(url)
            await tab.controller.rememberProjectDigest(for: url)
            tab.controller.watchProject(at: url)
            return AutomationState.session(AutomationContext(workspace: workspace, tab: tab), include: ["layers"])
        }

        add("project.save", group: "project", "Saves the project to its path, or to `path` (Save As). Waits until the files are written.", params: [
            AutomationParamDoc("path", "string", "Destination .comp; required for a project never saved."),
        ]) { context, params in
            let session = context.session, controller = context.controller
            guard session.document != nil else { throw AutomationError.conflict("no document is open") }
            guard let destination = try params.optionalFileURL("path") ?? session.projectURL else {
                throw AutomationError.badRequest("this project has no path yet; give \"path\"")
            }
            let url = destination.pathExtension.lowercased() == "comp" ? destination : destination.appendingPathExtension("comp")
            guard session.canStartProjectOperation else { throw AutomationError.conflict(context.blockedReason()) }
            await controller.finishWriting()
            session.cancelCrop()
            session.commitTransform()
            guard let snapshot = session.projectSnapshot() else { throw AutomationError.conflict("no document is open") }
            let revision = session.history.currentRevision
            session.isProjectBusy = true
            controller.externalChanges.saving = true
            defer { session.isProjectBusy = false; controller.externalChanges.saving = false }
            do {
                let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
                try await ProjectStore.shared.save(snapshot, to: url, quickLook: quickLook)
            } catch { throw AutomationError.unprocessable("save failed: \(error.localizedDescription)") }
            if session.projectURL != url { controller.stopWatchingProject() }
            session.projectURL = url
            session.history.markSaved(revision)
            RecentProjects.shared.note(url)
            await controller.rememberProjectDigest(for: url)
            controller.watchProject(at: url)
            return ["path": url.path, "isModified": session.isModified]
        }

        add("project.close", group: "project", "Closes a project tab. Unsaved changes are refused unless `discard` is true.", params: [
            AutomationParamDoc("project", "string", "Tab id, title or path; the active one when omitted."), AutomationParamDoc("discard", "bool"),
        ]) { context, params in
            let workspace = context.workspace
            let tab = params.has("project") ? try AutomationProjects.tab(workspace, try params.string("project")) : context.tab
            if tab.session.isModified, tab.session.document != nil, try !params.bool("discard", default: false) {
                throw AutomationError.conflict("the project has unsaved changes; save it or pass \"discard\": true")
            }
            guard tab.session.canStartProjectOperation else { throw AutomationError.conflict("the project is busy") }
            await tab.controller.finishWriting()
            tab.controller.stopWatchingProject()
            tab.session.clearProject()
            workspace.removeTab(tab.id)
            return ["closed": tab.id.uuidString, "remaining": workspace.tabs.count]
        }

        add("project.export", group: "project", "Exports the flattened composite to a PNG, JPEG, TIFF or HEIC file.", params: [
            AutomationParamDoc("path", "string", required: true), AutomationParamDoc("format", "string", "png (default), jpeg, tiff or heic; inferred from the path's extension."),
            AutomationParamDoc("quality", "number", "JPEG/HEIC quality 0–1, default 0.85."), AutomationParamDoc("matte", "color", "JPEG background behind transparent pixels; white by default."),
            AutomationParamDoc("scale", "number", "Resample the output by this factor (0.1–4)."), AutomationParamDoc("layer", "string", "Export only this layer (with its effects and mask), on transparency."),
            AutomationParamDoc("layers", "[string]", "Export only these layers."), AutomationParamDoc("crop", "rect", "Export only this document rect; \"selection\" uses the selection bounds."),
        ]) { context, params in
            let url = try params.fileURL("path")
            let (data, format) = try await AutomationProjects.render(context, params, defaultFormat: AutomationImages.Format(rawValue: url.pathExtension.lowercased() == "jpg" ? "jpeg" : url.pathExtension.lowercased()) ?? .png)
            do { try await ImageExporter.shared.write(data, to: url) } catch { throw AutomationError.unprocessable("writing \(url.lastPathComponent) failed: \(error.localizedDescription)") }
            return ["path": url.path, "format": format.rawValue, "bytes": data.count]
        }

        add("project.render", group: "project", "The flattened composite (or some layers, or a region) as base64 image data.", params: [
            AutomationParamDoc("format", "string", "png (default), jpeg, tiff, heic"), AutomationParamDoc("quality", "number"), AutomationParamDoc("scale", "number"),
            AutomationParamDoc("layer", "string"), AutomationParamDoc("layers", "[string]"), AutomationParamDoc("crop", "rect"), AutomationParamDoc("matte", "color"),
        ]) { context, params in
            let (data, format) = try await AutomationProjects.render(context, params, defaultFormat: .png)
            return ["format": format.rawValue, "contentType": AutomationImages.contentType(format), "bytes": data.count, "data": data.base64EncodedString()]
        }

        add("project.import", group: "project", "Imports image files as layers (PNG, JPEG, HEIC, TIFF, SVG, PSD/PSB with all their layers, camera RAW). Creates the document from the first image when none is open.", params: [
            AutomationParamDoc("paths", "[string]", required: true), AutomationParamDoc("center", "point", "Where to center the imported layers."),
            AutomationParamDoc("raw", "object", "RAW development: exposure (±3 EV), temperature (2000–12000 K), tint (±150), boost (0–1); as shot when omitted."),
        ]) { context, params in
            let session = context.session
            let urls = try params.strings("paths").map(AutomationParams.fileURL)
            for url in urls where !FileManager.default.fileExists(atPath: url.path) { throw AutomationError.notFound("no file at \(url.path)") }
            if session.document != nil { try context.requireEditable() }
            let raw = try params.optionalObject("raw"), center = try params.optionalPoint("center")
            // Answer the PSD and RAW sheets headlessly for this import only, so the person's own imports still ask.
            let (savedConversions, savedRawDevelop) = (session.confirmConversions, session.confirmRawDevelop)
            defer { session.confirmConversions = savedConversions; session.confirmRawDevelop = savedRawDevelop }
            session.confirmConversions = { _ in true }
            session.confirmRawDevelop = { _, asShot in
                var settings = asShot
                guard let raw else { return settings }
                if let exposure = try? raw.optionalDouble("exposure") { settings.exposure = Float(min(3, max(-3, exposure))) }
                if let temperature = try? raw.optionalDouble("temperature") { settings.temperature = Float(min(12000, max(2000, temperature))) }
                if let tint = try? raw.optionalDouble("tint") { settings.tint = Float(min(150, max(-150, tint))) }
                if let boost = try? raw.optionalDouble("boost") { settings.boost = Float(min(1, max(0, boost))) }
                return settings
            }
            let before = Set(session.document?.layers.map(\.id) ?? [])
            session.importError = nil
            await session.importImages(urls, at: center)
            if let error = session.importError { session.importError = nil; throw AutomationError.unprocessable(error) }
            guard let document = session.document else { throw AutomationError.unprocessable("nothing was imported") }
            return document.layers.filter { !before.contains($0.id) }.map { AutomationState.layer($0, in: document, session: session) }
        }

        add("project.state", group: "project", "The project's full state: canvas, layers, selection, guides, history and tool settings.", params: [
            AutomationParamDoc("include", "[string]", "Sections: layers, selection, guides, tools, all (default all)."),
        ]) { context, params in
            let include = Set((try params.optionalStrings("include") ?? ["all"]).map(AutomationParams.normalize))
            return AutomationState.session(context, include: include)
        }

        add("project.snapshotToFolder", group: "project", "Writes the project as a .comp package to `path` without changing which file the tab points at (a copy).", params: [
            AutomationParamDoc("path", "string", required: true),
        ]) { context, params in
            let session = context.session
            guard session.canStartProjectOperation, let snapshot = session.projectSnapshot() else { throw AutomationError.conflict("no document is open or the project is busy") }
            let destination = try params.fileURL("path")
            let url = destination.pathExtension.lowercased() == "comp" ? destination : destination.appendingPathExtension("comp")
            do { try await ProjectStore.shared.save(snapshot, to: url, quickLook: await ImageExporter.shared.quickLookImages(snapshot)) }
            catch { throw AutomationError.unprocessable("save failed: \(error.localizedDescription)") }
            return ["path": url.path]
        }
    }
}

enum AutomationProjects {
    static func tab(_ workspace: ProjectWorkspace, _ reference: String) throws -> ProjectTab {
        if reference == "active" || reference == "current" { return workspace.current }
        if let id = UUID(uuidString: reference), let tab = workspace.tabs.first(where: { $0.id == id }) { return tab }
        let url = AutomationParams.fileURL(reference).standardizedFileURL
        if let tab = workspace.tabs.first(where: { $0.session.projectURL?.standardizedFileURL == url }) { return tab }
        let titled = workspace.tabs.filter { $0.title == reference }
        if titled.count == 1 { return titled[0] }
        if titled.count > 1 { throw AutomationError.conflict("several projects are titled \"\(reference)\"; use the id") }
        throw AutomationError.notFound("no open project \"\(reference)\"")
    }

    /// Renders the composite the way Export does, optionally restricted to some layers or a region.
    static func render(_ context: AutomationContext, _ params: AutomationParams, defaultFormat: AutomationImages.Format) async throws -> (Data, AutomationImages.Format) {
        let session = context.session
        guard session.canStartProjectOperation else { throw AutomationError.conflict(context.blockedReason()) }
        session.commitTransform()
        guard var snapshot = session.projectSnapshot() else { throw AutomationError.conflict("no document is open") }
        let format: AutomationImages.Format
        if let text = try params.optionalString("format") {
            guard let parsed = AutomationImages.Format(rawValue: AutomationParams.normalize(text) == "jpg" ? "jpeg" : AutomationParams.normalize(text)) else {
                throw AutomationError.badRequest("\"format\" must be png, jpeg, tiff or heic")
            }
            format = parsed
        } else {
            format = defaultFormat
        }
        var wanted: Set<UUID>?
        if params.has("layers") { wanted = Set(try context.layers(params).map(\.id)) }
        else if params.has("layer") { wanted = [try context.layerID(params, key: "layer", allowActive: false)] }
        if let wanted {
            // Keep the wanted layers, their ancestors (so folder masks and opacity still apply) and their contents.
            var keep = wanted, ancestors = Set<UUID>()
            let byID = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
            for id in wanted {
                var parent = byID[id]?.parentID
                while let current = parent { ancestors.insert(current); parent = byID[current]?.parentID }
                keep.formUnion(session.descendantIDs(of: id))
            }
            keep.formUnion(ancestors)
            var layers = snapshot.manifest.layers
            for index in layers.indices where !keep.contains(layers[index].id) { layers[index].isVisible = false }
            // A hidden folder would hide the layer asked for, so its folders show too.
            for index in layers.indices where wanted.contains(layers[index].id) || ancestors.contains(layers[index].id) { layers[index].isVisible = true }
            let manifest = ProjectManifest(resolution: snapshot.manifest.resolution, documentID: snapshot.manifest.documentID, width: snapshot.manifest.width,
                                           height: snapshot.manifest.height, activeLayerID: snapshot.manifest.activeLayerID, layers: layers, guides: snapshot.manifest.guides)
            snapshot = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        let raster: ExportRaster
        do { raster = try await ImageExporter.shared.render(snapshot) } catch { throw AutomationError.unprocessable("render failed: \(error.localizedDescription)") }
        var image = raster.image
        if let text = try params.optionalString("crop"), AutomationParams.normalize(text) == "selection" {
            guard let selection = session.selection, !selection.isEmpty else { throw AutomationError.conflict("there is no selection to crop to") }
            let rect = selection.path.boundingBoxOfPath.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: rect) else { throw AutomationError.failed("crop failed") }
            image = cropped
        } else if let rect = try params.optionalRect("crop") {
            let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1, let cropped = image.cropping(to: clipped) else { throw AutomationError.badRequest("\"crop\" is outside the canvas") }
            image = cropped
        }
        if let scale = try params.optionalDouble("scale") {
            guard (0.1...4).contains(scale) else { throw AutomationError.badRequest("\"scale\" must be 0.1–4") }
            image = try AutomationImages.scaled(image, by: scale)
        }
        let quality = try params.double("quality", in: 0...1, default: 0.85)
        if format == .jpeg {
            // JPEG has no transparency: flatten onto the matte, as the export sheet does.
            let matte = try params.optionalColor("matte") ?? AutomationColor(red: 1, green: 1, blue: 1)
            let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            context.setFillColor(CGColor(srgbRed: matte.red, green: matte.green, blue: matte.blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            AutomationImages.drawUpright(image, width: image.width, height: image.height, in: context)
            guard let flattened = context.makeImage() else { throw AutomationError.failed("flattening failed") }
            image = flattened
        }
        let data = try AutomationImages.encode(image, format: format, quality: quality, resolution: raster.resolution)
        return (data, format)
    }
}
