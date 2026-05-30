"""Send media to Telnyx WebSocket in expected format."""

import base64
import json

from starlette.websockets import WebSocket


async def send_media(ws: WebSocket, buffer: bytes) -> None:
    """Send audio buffer as Telnyx media event."""
    if ws.client_state.name != "CONNECTED":
        return
    payload = base64.b64encode(buffer).decode("ascii")
    msg = json.dumps({"event": "media", "media": {"payload": payload}})
    await ws.send_text(msg)


async def send_clear(ws: WebSocket) -> None:
    """Ask Telnyx to stop current media playback and clear queued media."""
    if ws.client_state.name != "CONNECTED":
        return
    await ws.send_text(json.dumps({"event": "clear"}))
