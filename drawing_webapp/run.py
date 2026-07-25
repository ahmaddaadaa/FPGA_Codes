#!/usr/bin/env python3
"""Run the local digit drawing demo."""

import argparse
import base64
import json
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import cv2
import numpy as np

from preprocessing import preprocess_foreground_mask

ROOT_DIR = Path(__file__).resolve().parent
STATIC_DIR = ROOT_DIR / "phone_canvas"
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_STROKES = 128
MAX_POINTS = 20_000

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}


def finite_number(value, field_name):
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be numeric") from exc

    if not np.isfinite(number):
        raise ValueError(f"{field_name} must be finite")
    return number


def validate_stroke_payload(payload):
    if not isinstance(payload, dict):
        raise ValueError("request body must be a JSON object")

    width = finite_number(payload.get("width"), "width")
    height = finite_number(payload.get("height"), "height")
    if not 1 <= width <= 10_000 or not 1 <= height <= 10_000:
        raise ValueError("canvas dimensions are outside the supported range")

    brush_size = finite_number(payload.get("brush_size", 0.025), "brush_size")
    if not 0.002 <= brush_size <= 0.12:
        raise ValueError("brush_size must be between 0.002 and 0.12")

    raw_strokes = payload.get("strokes")
    if not isinstance(raw_strokes, list) or not raw_strokes:
        raise ValueError("draw a digit before recognizing it")
    if len(raw_strokes) > MAX_STROKES:
        raise ValueError("drawing contains too many strokes")

    strokes = []
    total_points = 0

    for stroke_index, raw_stroke in enumerate(raw_strokes):
        if not isinstance(raw_stroke, dict):
            raise ValueError(f"stroke {stroke_index} is invalid")

        raw_points = raw_stroke.get("points")
        if not isinstance(raw_points, list) or not raw_points:
            continue

        points = []
        for raw_point in raw_points:
            if not isinstance(raw_point, dict):
                raise ValueError("stroke point is invalid")

            x = finite_number(raw_point.get("x"), "point x")
            y = finite_number(raw_point.get("y"), "point y")
            pressure = finite_number(raw_point.get("pressure", 0.5), "pressure")

            if not 0 <= x <= 1 or not 0 <= y <= 1:
                raise ValueError("stroke coordinates must be normalized to 0..1")

            points.append((x, y, float(np.clip(pressure, 0.0, 1.0))))
            total_points += 1
            if total_points > MAX_POINTS:
                raise ValueError("drawing contains too many points")

        if points:
            strokes.append(points)

    if not strokes:
        raise ValueError("draw a digit before recognizing it")

    return width, height, brush_size, strokes


def render_strokes(payload, long_side=512):
    width, height, brush_size, strokes = validate_stroke_payload(payload)

    scale = float(long_side) / max(width, height)
    render_width = max(32, round(width * scale))
    render_height = max(32, round(height * scale))
    line_width = max(1, round(brush_size * min(render_width, render_height)))

    mask = np.zeros((render_height, render_width), dtype=np.uint8)

    for stroke in strokes:
        pixel_points = []
        for x, y, _pressure in stroke:
            pixel_x = int(round(x * (render_width - 1)))
            pixel_y = int(round(y * (render_height - 1)))
            pixel_points.append(
                (
                    int(np.clip(pixel_x, 0, render_width - 1)),
                    int(np.clip(pixel_y, 0, render_height - 1)),
                )
            )

        if len(pixel_points) == 1:
            cv2.circle(
                mask,
                pixel_points[0],
                max(1, line_width // 2),
                255,
                -1,
                cv2.LINE_AA,
            )
            continue

        for start, end in zip(pixel_points, pixel_points[1:]):
            cv2.line(mask, start, end, 255, line_width, cv2.LINE_AA)

    return mask


def image_data_url(image, scale=1):
    if scale != 1:
        image = cv2.resize(
            image,
            (image.shape[1] * scale, image.shape[0] * scale),
            interpolation=cv2.INTER_NEAREST,
        )

    success, encoded = cv2.imencode(".png", image)
    if not success:
        raise RuntimeError("could not encode normalized image")

    payload = base64.b64encode(encoded).decode("ascii")
    return f"data:image/png;base64,{payload}"


def make_mock_prediction(input_bytes):
    values = input_bytes.astype(np.float64)
    average_intensity = np.sum(values) / (127.0 * len(values))

    scores = np.array(
        [((digit + 1) * average_intensity) % (digit + 3) for digit in range(10)],
        dtype=np.float64,
    )
    scores -= np.max(scores)

    exponentials = np.exp(scores)
    probabilities = 100.0 * exponentials / np.sum(exponentials)
    return int(np.argmax(probabilities)), probabilities


def build_inference_response(result, preprocessing_ms, simulate):
    response = {
        "prediction": None,
        "probability_percentages": None,
        "confidence_percentages": None,
        "probability_note": "no simulation",
        "model_family": "mlp",
        "configuration": "local_demo",
        "effective_output_scale": None,
        "preprocessing_ms": preprocessing_ms,
        "udp_round_trip_ms": 0.0,
        "endpoint": "local",
        "normalized_png": image_data_url(result.normalized_image, scale=10),
        "stroke_action": result.stroke_action,
        "stroke_width_before": result.stroke_width_before,
        "stroke_width_after": result.stroke_width_after,
    }

    if not simulate:
        return response

    prediction, probabilities = make_mock_prediction(result.input_bytes)
    probability_values = [float(value) for value in probabilities]

    response.update(
        {
            "prediction": prediction,
            "probability_percentages": probability_values,
            "confidence_percentages": probability_values,
            "probability_note": "softmax probabilities; mock predictions",
            "effective_output_scale": 1.0,
            "endpoint": "local-mock",
        }
    )
    return response


class LocalRequestHandler(BaseHTTPRequestHandler):
    server_version = "DemoFPGAWebapp/1.0"

    @property
    def simulate(self):
        return bool(getattr(self.server, "simulate", False))

    def send_bytes(self, status, content_type, body):
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_bytes(status, "application/json; charset=utf-8", body)

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/api/status":
            self.send_json(
                HTTPStatus.OK,
                {
                    "state": "ready",
                    "endpoint": "local-mock" if self.simulate else "local",
                    "transport": (
                        "local (simulated)" if self.simulate else "local (no FPGA)"
                    ),
                    "model_family": "mlp",
                    "configuration": "local_demo",
                },
            )
            return

        static_file = STATIC_FILES.get(path)
        if static_file is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        filename, content_type = static_file
        try:
            body = (STATIC_DIR / filename).read_bytes()
        except OSError as exc:
            self.send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": f"could not load drawing page: {exc}"},
            )
            return

        self.send_bytes(HTTPStatus.OK, content_type, body)

    def do_POST(self):
        if urlparse(self.path).path != "/api/infer":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid body length"})
            return

        if not 0 < content_length <= MAX_REQUEST_BYTES:
            self.send_json(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"error": "drawing request is empty or too large"},
            )
            return

        try:
            request_body = self.rfile.read(content_length).decode("utf-8")
            payload = json.loads(request_body)

            started_at = time.perf_counter()
            mask = render_strokes(payload)
            result = preprocess_foreground_mask(mask, input_scale=127.0)
            preprocessing_ms = (time.perf_counter() - started_at) * 1000.0

            response = build_inference_response(
                result,
                preprocessing_ms=preprocessing_ms,
                simulate=self.simulate,
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except Exception as exc:
            self.send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": str(exc)})
            return

        self.send_json(HTTPStatus.OK, response)

    def log_message(self, format_string, *args):
        return


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Run local Vakili phone canvas demo (no FPGA)"
    )
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--web-port", type=int, default=8765)
    parser.add_argument(
        "--simulate",
        action="store_true",
        help="enable deterministic mock inference responses (default: off)",
    )
    return parser.parse_args()


def main():
    args = parse_arguments()
    server = ThreadingHTTPServer((args.bind, args.web_port), LocalRequestHandler)
    server.simulate = args.simulate

    print(f"Local demo webapp listening on {args.bind}:{args.web_port}")
    print(f"Open the page in a browser http://localhost:{args.web_port}/.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopping local webapp")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
