import Foundation

/// One parameter of an operation, as reported by `GET /v1/ops` so scripts and agents can discover the API.
nonisolated struct AutomationParamDoc {
    let name: String
    let type: String
    let required: Bool
    let summary: String

    init(_ name: String, _ type: String, required: Bool = false, _ summary: String = "") {
        self.name = name; self.type = type; self.required = required; self.summary = summary
    }

    var json: [String: Any] { ["name": name, "type": type, "required": required, "summary": summary] }
}

/// Everything a command needs: the editing session it targets and the workspace it lives in.
struct AutomationContext {
    let workspace: ProjectWorkspace
    let tab: ProjectTab
    var session: EditorSession { tab.session }
    var controller: ProjectController { tab.controller }

    /// The document, or a clear error when the tab has none yet.
    func document() throws -> CanvasDocument {
        guard let document = session.document else { throw AutomationError.conflict("no document is open in this project; run project.new or project.open first") }
        return document
    }

    /// A layer by id or, with `nameFallback`, by exact name; `"active"` and a missing key mean the active layer.
    func layer(_ params: AutomationParams, key: String = "layer", allowActive: Bool = true) throws -> ImageLayer {
        let document = try document()
        if let reference = try params.optionalString(key), reference != "active" {
            if let id = UUID(uuidString: reference), let layer = document.layers.first(where: { $0.id == id }) { return layer }
            let named = document.layers.filter { $0.name == reference }
            if named.count == 1 { return named[0] }
            if named.count > 1 { throw AutomationError.conflict("several layers are named \"\(reference)\"; use the id") }
            throw AutomationError.notFound("no layer \"\(reference)\"")
        }
        guard allowActive else { throw AutomationError.badRequest("\"\(key)\" is required") }
        guard let layer = session.activeLayer else { throw AutomationError.conflict("no active layer; pass \"\(key)\"") }
        return layer
    }

    func layerID(_ params: AutomationParams, key: String = "layer", allowActive: Bool = true) throws -> UUID {
        try layer(params, key: key, allowActive: allowActive).id
    }

    /// Several layers from a `layers` array of ids or names.
    func layers(_ params: AutomationParams, key: String = "layers") throws -> [ImageLayer] {
        let names = try params.strings(key)
        guard !names.isEmpty else { throw AutomationError.badRequest("\"\(key)\" must list at least one layer") }
        return try names.map { try layer(AutomationParams([key: $0]), key: key, allowActive: false) }
    }

    /// Makes `id` the active layer (pixels target) unless it already is, keeping the mask target when asked.
    func activate(_ id: UUID, mask: Bool = false) throws {
        if session.activeLayerID != id || session.selectedLayerIDs != [id] {
            session.selectLayer(id)
            guard session.activeLayerID == id else { throw AutomationError.conflict("the layer could not be selected; finish the edit in progress first") }
        }
        session.isMaskSelected = mask
    }

    /// Refuses the command with the session's reason when editing is blocked, so scripts see why instead of a silent no-op.
    func requireEditable() throws {
        let session = session
        guard session.document != nil else { throw AutomationError.conflict("no document is open") }
        guard session.canEditLayers else { throw AutomationError.conflict(blockedReason()) }
        // As every session edit does: an opacity drag in progress becomes its own undo step, not part of this one.
        session.finishOpacityEdit()
    }

    func blockedReason() -> String {
        let s = session
        if s.isProjectBusy { return "the project is busy (a save, import or render is running)" }
        if s.isImporting { return "an import is running" }
        if s.transformEdit != nil { return "a transform is in progress; commit or cancel it" }
        if s.cropRect != nil { return "a crop is in progress; apply or cancel it" }
        if s.gradientEdit != nil { return "a gradient is pending" }
        if s.pixelMove != nil { return "a pixel move is in progress" }
        if s.levels != nil { return "a Levels edit is open" }
        if s.hueSaturation != nil { return "a Hue/Saturation edit is open" }
        if s.filterEdit != nil { return "a filter edit is open" }
        if s.adjustmentEditingID != nil { return "an adjustment layer editor is open" }
        if s.textDraft != nil { return "a text edit is open" }
        if s.colorRange != nil { return "a Color Range edit is open" }
        if s.selectionAmountOperation != nil { return "a selection amount prompt is open" }
        if s.renamingLayerID != nil { return "a layer is being renamed" }
        if s.brushStroke != nil || s.warpStroke != nil { return "a brush stroke is in progress" }
        if s.showsNewDocument || s.showsImporter { return "a dialog is open" }
        return "editing is not possible right now"
    }

    /// Runs `body` and turns a `brushError` it left behind into a thrown error.
    func checkingBrushError<T>(_ body: () throws -> T) throws -> T {
        session.brushError = nil
        let result = try body()
        if let error = session.brushError {
            session.brushError = nil
            throw AutomationError.unprocessable(error)
        }
        return result
    }

    func checkingBrushErrorAsync<T>(_ body: () async throws -> T) async throws -> T {
        session.brushError = nil
        let result = try await body()
        if let error = session.brushError {
            session.brushError = nil
            throw AutomationError.unprocessable(error)
        }
        return result
    }
}

/// One operation the API understands.
struct AutomationOp {
    let name: String
    let group: String
    let summary: String
    let params: [AutomationParamDoc]
    /// Main-actor explicitly: with approachable concurrency a plain async function type would run on the caller's actor.
    let run: @MainActor (AutomationContext, AutomationParams) async throws -> Any

    var doc: [String: Any] { ["op": name, "summary": summary, "params": params.map(\.json)] }
}

/// The catalog of operations, filled by the `AutomationCommands+*.swift` files.
final class AutomationRegistry {
    private(set) var ops: [String: AutomationOp] = [:]
    private(set) var order: [String] = []
    private(set) var groups: [(name: String, summary: String)] = []

    init() {
        registerProjectCommands()
        registerLayerCommands()
        registerMaskCommands()
        registerTransformCommands()
        registerEffectCommands()
        registerAdjustmentCommands()
        registerFilterCommands()
        registerSelectionCommands()
        registerPaintCommands()
        registerCanvasCommands()
        registerSessionCommands()
    }

    func group(_ name: String, _ summary: String) {
        if !groups.contains(where: { $0.name == name }) { groups.append((name, summary)) }
    }

    func add(_ name: String, group: String, _ summary: String, params: [AutomationParamDoc] = [],
             run: @escaping @MainActor (AutomationContext, AutomationParams) async throws -> Any) {
        precondition(ops[name] == nil, "duplicate automation op \(name)")
        ops[name] = AutomationOp(name: name, group: group, summary: summary, params: params, run: run)
        order.append(name)
    }

    /// Looks an operation up by name, tolerating case and separator differences (`layer.setOpacity` = `layer.set_opacity`).
    func op(named name: String) -> AutomationOp? {
        if let exact = ops[name] { return exact }
        let wanted = AutomationParams.normalize(name)
        return ops.values.first { AutomationParams.normalize($0.name) == wanted }
    }

    var catalog: [String: Any] {
        let grouped = Dictionary(grouping: order.compactMap { ops[$0] }, by: \.group)
        return [
            "version": AutomationRouter.apiVersion,
            "count": order.count,
            "groups": groups.map { group in
                ["name": group.name, "summary": group.summary, "ops": (grouped[group.name] ?? []).map(\.doc)]
            },
        ]
    }
}

/// Shared parameter documentation, so every command describes the same things the same way.
nonisolated enum AutomationDocs {
    static let layer = AutomationParamDoc("layer", "string", "Layer id or unique name; \"active\" or omitted means the active layer.")
    static let layers = AutomationParamDoc("layers", "[string]", required: true, "Layer ids or names.")
    static let mode = AutomationParamDoc("mode", "string", "Selection mode: replace (default), add, subtract or intersect.")
    static let point = AutomationParamDoc("point", "point", required: true, "Document pixel position as [x, y] or {x, y}.")
    static let color = AutomationParamDoc("color", "color", "\"#RRGGBB\", [r, g, b] in 0–1 or 0–255, or {red, green, blue}.")
    static let name = AutomationParamDoc("name", "string", "Undo step name shown in Edit > Undo.")
}
