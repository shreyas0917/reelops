"""Serve the built frontend (Vite's dist/) from the API's own origin."""

from __future__ import annotations

import mimetypes
from pathlib import PurePosixPath

from starlette.exceptions import HTTPException
from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope

ASSET_CACHE = "public, max-age=31536000, immutable"  # hashed filenames never change

# The slim image's mimetypes database lacks web fonts (they'd be served as
# application/octet-stream).
mimetypes.add_type("font/woff2", ".woff2")
mimetypes.add_type("font/woff", ".woff")


class SpaStaticFiles(StaticFiles):
    """StaticFiles with an index.html fallback for page paths only.

    `/anything` serves the app; a missing file like `/assets/old.js` stays a
    real 404 instead of returning HTML where the browser expects JavaScript.
    """

    async def get_response(self, path: str, scope: Scope) -> Response:
        try:
            response = await super().get_response(path, scope)
        except HTTPException as exc:
            if exc.status_code != 404 or PurePosixPath(path).suffix:
                raise
            response = await super().get_response("index.html", scope)

        if path.startswith("assets/"):
            response.headers["Cache-Control"] = ASSET_CACHE
        else:
            # index.html and other unhashed files: always revalidate, so a new
            # deploy is picked up on the next load.
            response.headers["Cache-Control"] = "no-cache"
        return response
