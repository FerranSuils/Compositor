import AppKit
import ImageIO
import Testing
@testable import Compositor

/// The automation API drives the same session the window does; these run its operations without a server.
@MainActor struct AutomationTests {
    private func router() -> AutomationRouter { AutomationRouter(workspace: ProjectWorkspace()) }

    private func run(_ router: AutomationRouter, _ op: String, _ params: [String: Any] = [:]) async throws -> Any {
        var raw = params
        raw["op"] = op
        return try await router.execute(AutomationParams(raw), defaultProject: nil).1
    }

    private func post(_ router: AutomationRouter, _ body: [String: Any]) async throws -> (status: Int, json: [String: Any]) {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = await router.route(AutomationHTTPRequest(method: "POST", path: "/v1/run", query: [:], headers: [:], body: data))
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return (response.status, json)
    }

    @Test func catalogListsEveryOperationOnceWithDocumentation() {
        let registry = router().registry
        #expect(registry.order.count == Set(registry.order).count)
        #expect(registry.order.count > 90)
        for name in registry.order {
            let op = try! #require(registry.ops[name])
            #expect(!op.summary.isEmpty)
            #expect(registry.groups.contains { $0.name == op.group })
        }
        #expect(registry.op(named: "layer.set_opacity")?.name == "layer.setOpacity")
        #expect(registry.op(named: "no.such.op") == nil)
    }

    @Test func requestsFromWebPagesAreRefused() {
        func request(_ headers: [String: String]) -> AutomationHTTPRequest {
            AutomationHTTPRequest(method: "POST", path: "/v1/run", query: [:], headers: headers, body: Data())
        }
        // Scripts and curl: no browser headers, the loopback host.
        #expect(AutomationServer.browserRefusal(request([:]), port: 4747) == nil)
        #expect(AutomationServer.browserRefusal(request(["host": "127.0.0.1:4747"]), port: 4747) == nil)
        #expect(AutomationServer.browserRefusal(request(["host": "localhost:4747"]), port: 4747) == nil)
        // The address typed into the browser's own address bar.
        #expect(AutomationServer.browserRefusal(request(["host": "127.0.0.1:4747", "sec-fetch-site": "none"]), port: 4747) == nil)
        // A page posting across sites, a page that sends no Origin, and a DNS name rebound to the loopback address.
        #expect(AutomationServer.browserRefusal(request(["host": "127.0.0.1:4747", "origin": "https://example.com"]), port: 4747) != nil)
        #expect(AutomationServer.browserRefusal(request(["host": "127.0.0.1:4747", "sec-fetch-site": "cross-site"]), port: 4747) != nil)
        #expect(AutomationServer.browserRefusal(request(["host": "attacker.example:4747"]), port: 4747) != nil)
        #expect(AutomationServer.browserRefusal(request(["host": "127.0.0.1:9999"]), port: 4747) != nil)
    }

    @Test func parametersAreTypedAndDescriptive() throws {
        let params = AutomationParams(["n": 3, "flag": true, "one": 1, "color": "#FF8000", "point": [4, 5], "rect": ["x": 1, "y": 2, "width": 3, "height": 4], "mode": "Linear Dodge (add)"])
        #expect(try params.int("n") == 3)
        #expect(try params.bool("flag"))
        #expect(try params.double("one") == 1)
        #expect(try params.color("color").hex == "#FF8000")
        #expect(try params.point("point") == CGPoint(x: 4, y: 5))
        #expect(try params.rect("rect") == CGRect(x: 1, y: 2, width: 3, height: 4))
        let mode: LayerBlendMode = try params.enumeration("mode", cases: LayerBlendMode.allCases)
        #expect(mode == .linearDodge)
        #expect(throws: AutomationError.self) { try params.int("flag") }
        #expect(throws: AutomationError.self) { try params.double("n", in: 0...2) }
        #expect(throws: AutomationError.self) { try params.string("missing") }
        #expect(AutomationColor(any: [255, 128, 0])?.hex == "#FF8000")
        #expect(AutomationColor(any: ["red": 1, "green": 0.5, "blue": 0])?.green == 0.5)
    }

    @Test func buildsALayeredDocumentAndRendersIt() async throws {
        let router = router()
        _ = try await run(router, "project.new", ["width": 64, "height": 32, "emptyLayer": false])
        let square = try #require(try await run(router, "layer.addImage", ["color": "#FF0000", "size": [16, 16], "origin": [8, 8], "name": "Square"]) as? [String: Any])
        let id = try #require(square["id"] as? String)
        #expect(square["kind"] as? String == "pixels")
        _ = try await run(router, "transform.move", ["layer": id, "dx": 10])
        let moved = try #require(try await run(router, "layer.get", ["layer": "Square"]) as? [String: Any])
        let transform = try #require(moved["transform"] as? [String: Any])
        #expect(transform["x"] as? Double == 18)
        _ = try await run(router, "layer.setOpacity", ["layer": id, "opacity": 50, "percent": true])
        _ = try await run(router, "layer.setBlendMode", ["layer": id, "blendMode": "multiply"])
        let adjustment = try #require(try await run(router, "adjustmentLayer.add", ["kind": "Levels", "settings": ["black": 20, "white": 200]]) as? [String: Any])
        #expect(adjustment["kind"] as? String == "adjustment")
        let levels = try #require((adjustment["adjustment"] as? [String: Any])?["levels"] as? [String: Any])
        let ranges = try #require(levels["ranges"] as? [[String: Any]])
        #expect(ranges[0]["black"] as? Double == 20)
        let rendered = try #require(try await run(router, "project.render", ["format": "png"]) as? [String: Any])
        let data = try #require(Data(base64Encoded: try #require(rendered["data"] as? String)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.height == 32)
        let state = try #require(try await run(router, "project.state") as? [String: Any])
        let document = try #require(state["document"] as? [String: Any])
        #expect(document["layerCount"] as? Int == 2)
    }

    @Test func selectionsFillsAndHistoryWork() async throws {
        let router = router()
        _ = try await run(router, "project.new", ["width": 40, "height": 40])
        _ = try await run(router, "color.set", ["foreground": "#00FF00"])
        let selection = try #require(try await run(router, "selection.rect", ["rect": [0, 0, 20, 40]]) as? [String: Any])
        let bounds = try #require(selection["bounds"] as? [String: Any])
        #expect(bounds["width"] as? Double == 20)
        _ = try await run(router, "selection.rect", ["rect": [10, 0, 30, 40], "mode": "intersect"])
        let intersected = try #require(try await run(router, "selection.get") as? [String: Any])
        #expect((intersected["bounds"] as? [String: Any])?["width"] as? Double == 10)
        _ = try await run(router, "selection.all")
        _ = try await run(router, "selection.fill")
        _ = try await run(router, "selection.none")
        let session = router.workspace.current.session
        #expect(session.selection == nil)
        let layer = try #require(session.document?.layers.first)
        #expect(layer.asset != nil)
        let count = session.history.undoCount
        let undo = try #require(try await run(router, "history.undo") as? [String: Any])
        #expect(undo["undone"] as? Int == 1)
        #expect(session.history.undoCount == count - 1)
        _ = try await run(router, "history.redo")
        #expect(session.history.undoCount == count)
    }

    @Test func paintingEffectsAndMasksGoThroughTheSession() async throws {
        let router = router()
        _ = try await run(router, "project.new", ["width": 50, "height": 50, "background": "#FFFFFF"])
        _ = try await run(router, "paint.stroke", ["points": [[5, 25], [45, 25]], "color": "#0000FF", "diameter": 6, "hardness": 1])
        let session = router.workspace.current.session
        let layer = try #require(session.activeLayer)
        #expect(session.history.undoName == "Brush Stroke")
        let effects = try #require(try await run(router, "effects.set", ["effects": ["shadow": ["distance": 3, "color": "#000000", "opacity": 0.5], "stroke": ["size": 2, "color": "#FF0000"]]]) as? [String: Any])
        #expect(effects["shadow"] != nil && effects["stroke"] != nil)
        _ = try await run(router, "effects.setEnabled", ["kind": "Stroke", "enabled": false])
        #expect(session.activeLayer?.effects?.stroke?.isEnabled == false)
        _ = try await run(router, "mask.add", ["reveal": false])
        #expect(session.activeLayer?.mask != nil)
        _ = try await run(router, "mask.setEnabled", ["layer": layer.id.uuidString, "enabled": false])
        #expect(session.activeLayer?.mask?.isEnabled == false)
        let text = try #require(try await run(router, "text.add", ["content": "Hi", "origin": [2, 2], "fontSize": 12, "color": "#333333"]) as? [String: Any])
        #expect(text["kind"] as? String == "text")
        let changed = try #require(try await run(router, "text.set", ["content": "Hello"]) as? [String: Any])
        #expect((changed["text"] as? [String: Any])?["content"] as? String == "Hello")
        let shape = try #require(try await run(router, "shape.add", ["kind": "Ellipse", "rect": [10, 10, 20, 20], "color": "#00FF00"]) as? [String: Any])
        #expect(shape["kind"] as? String == "shape")
    }

    @Test func canvasOperationsResizeTheDocument() async throws {
        let router = router()
        _ = try await run(router, "project.new", ["width": 30, "height": 20])
        var report = try #require(try await run(router, "canvas.size", ["width": 40, "anchor": "topLeft"]) as? [String: Any])
        #expect(report["width"] as? Int == 40 && report["height"] as? Int == 20)
        report = try #require(try await run(router, "canvas.imageSize", ["percent": 50]) as? [String: Any])
        #expect(report["width"] as? Int == 20 && report["height"] as? Int == 10)
        report = try #require(try await run(router, "canvas.crop", ["rect": [0, 0, 10, 10]]) as? [String: Any])
        #expect(report["width"] as? Int == 10 && report["height"] as? Int == 10)
        _ = try await run(router, "guides.add", ["axis": "vertical", "position": 5])
        let guides = try #require(try await run(router, "guides.list") as? [[String: Any]])
        #expect(guides.count == 1)
    }

    @Test func batchesReportEveryStepAndStopOnErrors() async throws {
        let router = router()
        let reply = try await post(router, ["steps": [
            ["op": "project.new", "width": 10, "height": 10],
            ["op": "layer.add", "name": "Two"],
            ["op": "nope.nothing"],
            ["op": "layer.add", "name": "Three"],
        ]])
        #expect(reply.status == 200)
        #expect(reply.json["ok"] as? Bool == false)
        let results = try #require(reply.json["results"] as? [[String: Any]])
        #expect(results.count == 3)
        #expect(results[1]["ok"] as? Bool == true)
        #expect(results[2]["ok"] as? Bool == false)
        #expect(router.workspace.current.session.document?.layers.count == 2)
        let single = try await post(router, ["op": "layer.rename", "layer": "Two", "name": "Renamed"])
        #expect(single.status == 200)
        #expect((single.json["result"] as? [String: Any])?["name"] as? String == "Renamed")
        let bad = try await post(router, ["op": "layer.setOpacity", "opacity": 7])
        #expect(bad.status == 400)
        let unknown = await router.route(AutomationHTTPRequest(method: "GET", path: "/v1/nothing", query: [:], headers: [:], body: Data()))
        #expect(unknown.status == 404)
        let health = await router.route(AutomationHTTPRequest(method: "GET", path: "/v1/health", query: [:], headers: [:], body: Data()))
        #expect(health.status == 200)
        #expect(String(decoding: health.serialized.prefix(15), as: UTF8.self) == "HTTP/1.1 200 OK")
    }

    @Test func savesOpensAndExportsThroughFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorAutomationTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = router()
        _ = try await run(router, "project.new", ["width": 12, "height": 8, "background": "#123456"])
        let project = root.appendingPathComponent("demo.comp")
        let saved = try #require(try await run(router, "project.save", ["path": project.path]) as? [String: Any])
        #expect(saved["isModified"] as? Bool == false)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("manifest.json").path))
        let png = root.appendingPathComponent("out.png")
        _ = try await run(router, "project.export", ["path": png.path])
        #expect(FileManager.default.fileExists(atPath: png.path))
        let jpeg = root.appendingPathComponent("out.jpg")
        let exported = try #require(try await run(router, "project.export", ["path": jpeg.path, "quality": 0.5]) as? [String: Any])
        #expect(exported["format"] as? String == "jpeg")
        _ = try await run(router, "project.close", ["discard": true])
        let opened = try #require(try await run(router, "project.open", ["path": project.path]) as? [String: Any])
        #expect((opened["document"] as? [String: Any])?["width"] as? Int == 12)
        let added = try #require(try await run(router, "layer.addImage", ["path": png.path, "origin": [0, 0]]) as? [String: Any])
        #expect((added["pixelSize"] as? [String: Any])?["width"] as? Int == 12)
        #expect(router.workspace.current.session.document?.layers.count == 2)
    }
}
