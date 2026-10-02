"""Client for the Compositor automation API.

Compositor runs a local HTTP server when started with ``--automation`` (see docs/automation-api.md).
This module is a thin, dependency-free wrapper around it, so a script can drive a whole edit:

    from compositor_api import Compositor

    app = Compositor()                                     # http://127.0.0.1:4747
    app.run("project.open", path="~/Desktop/shot.comp")
    app.run("adjust.levels", black=12, white=240, gamma=1.1)
    app.run("filter.cameraRaw", light={"exposure": 0.4, "contrast": 15})
    app.run("project.export", path="~/Desktop/shot.jpg", format="jpeg", quality=0.9)

Or as one batch that stops at the first failure and reports every step:

    app.batch([
        {"op": "project.open", "path": "~/Desktop/shot.comp"},
        {"op": "layer.add", "name": "Grade"},
        {"op": "project.save"},
    ])

Run ``python compositor_api.py ops`` to print every operation the running app understands, with parameters.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable


class CompositorError(RuntimeError):
    """An operation was rejected. ``status`` is the HTTP status, ``payload`` the decoded JSON body."""

    def __init__(self, status: int, payload: Any):
        self.status = status
        self.payload = payload
        message = payload.get("error") if isinstance(payload, dict) else str(payload)
        super().__init__(f"{status}: {message}")


class Compositor:
    def __init__(self, base_url: str | None = None, token: str | None = None, timeout: float = 600):
        self.base_url = (base_url or os.environ.get("COMPOSITOR_URL") or "http://127.0.0.1:4747").rstrip("/")
        self.token = token or os.environ.get("COMPOSITOR_TOKEN")
        self.timeout = timeout

    # -- transport -------------------------------------------------------------------------------------

    def _request(self, method: str, path: str, body: Any = None, query: dict | None = None, raw: bool = False):
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
                if raw:
                    return payload
                return json.loads(payload or b"{}")
        except urllib.error.HTTPError as error:
            payload = error.read()
            try:
                decoded = json.loads(payload or b"{}")
            except ValueError:
                decoded = payload.decode("utf-8", "replace")
            raise CompositorError(error.code, decoded) from None
        except urllib.error.URLError as error:
            # Status 0: no HTTP reply at all, usually because the app isn't running with --automation.
            message = f"Compositor isn't answering at {self.base_url} ({error.reason}). Start it with --automation."
            raise CompositorError(0, {"ok": False, "error": message}) from None

    # -- API -------------------------------------------------------------------------------------------

    def health(self) -> dict:
        return self._request("GET", "/v1/health")

    def state(self, project: str | None = None, include: str | None = None) -> dict:
        """The active (or named) project's full state: canvas, layers, selection, guides, history."""
        return self._request("GET", "/v1/state", query={"project": project, "include": include})

    def ops(self) -> dict:
        """The catalog of operations and their parameters, as the running app reports it."""
        return self._request("GET", "/v1/ops")

    def run(self, op: str, project: str | None = None, **params: Any) -> Any:
        """Run one operation and return its ``result``."""
        body = {"op": op, **params}
        if project is not None:
            body["project"] = project
        reply = self._request("POST", "/v1/run", body)
        return reply.get("result")

    def batch(self, steps: Iterable[dict], project: str | None = None, stop_on_error: bool = True) -> list:
        """Run several operations in order. Returns the per-step results; raises on the first failure
        when ``stop_on_error`` is set."""
        body: dict[str, Any] = {"steps": list(steps), "stopOnError": stop_on_error}
        if project is not None:
            body["project"] = project
        reply = self._request("POST", "/v1/run", body)
        results = reply.get("results", [])
        if stop_on_error:
            for step in results:
                if not step.get("ok", False):
                    raise CompositorError(422, step)
        return results

    def render(self, path: str | None = None, layer: str | None = None, format: str = "png",
               quality: float | None = None, scale: float | None = None, project: str | None = None) -> bytes:
        """The flattened composite (or one layer) as image bytes; written to ``path`` when given."""
        data = self._request("GET", "/v1/render", raw=True, query={
            "layer": layer, "format": format, "quality": quality, "scale": scale, "project": project,
        })
        if path:
            with open(os.path.expanduser(path), "wb") as handle:
                handle.write(data)
        return data

    # -- conveniences ----------------------------------------------------------------------------------

    @staticmethod
    def encode_file(path: str) -> str:
        """Base64 for inline image payloads (``imageData`` parameters), for when the app's sandbox cannot
        read the path directly."""
        with open(os.path.expanduser(path), "rb") as handle:
            return base64.b64encode(handle.read()).decode("ascii")

    def add_image(self, path: str, inline: bool = False, **params: Any) -> Any:
        if inline:
            return self.run("layer.addImage", imageData=self.encode_file(path), name=os.path.basename(path), **params)
        return self.run("layer.addImage", path=path, **params)


def _main(argv: list[str]) -> int:
    app = Compositor()
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    command = argv[1]
    if command == "health":
        print(json.dumps(app.health(), indent=2))
    elif command == "state":
        print(json.dumps(app.state(), indent=2))
    elif command == "ops":
        catalog = app.ops()
        for group in catalog.get("groups", []):
            print(f"\n## {group['name']}: {group.get('summary', '')}")
            for op in group.get("ops", []):
                params = ", ".join(f"{p['name']}{'' if p.get('required') else '?'}: {p['type']}" for p in op.get("params", []))
                print(f"  {op['op']}({params})")
                if op.get("summary"):
                    print(f"      {op['summary']}")
    elif command == "run":
        # python compositor_api.py run '{"op": "layer.add", "name": "Foo"}'  or  run @script.json
        source = argv[2]
        payload = json.load(open(source[1:])) if source.startswith("@") else json.loads(source)
        if "steps" in payload:
            print(json.dumps(app.batch(payload["steps"], project=payload.get("project"),
                                       stop_on_error=payload.get("stopOnError", True)), indent=2))
        else:
            op = payload.pop("op")
            print(json.dumps(app.run(op, **payload), indent=2))
    elif command == "render":
        out = argv[2] if len(argv) > 2 else "render.png"
        app.render(out)
        print(out)
    else:
        print(f"unknown command {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(_main(sys.argv))
    except CompositorError as error:
        print(json.dumps(error.payload, indent=2) if isinstance(error.payload, dict) else error, file=sys.stderr)
        sys.exit(1)
