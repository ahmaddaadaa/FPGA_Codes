#!/usr/bin/env python3
"""Utilities for converting a drawn foreground mask into a 28x28 input."""

from dataclasses import dataclass

import cv2
import numpy as np

MNIST_SIZE = 28
DIGIT_BOX_SIZE = 20
STROKE_OPERATION_MARGIN = 2
CENTERING_EDGE_MARGIN = 1
MAX_PROCESSING_DIMENSION = 800
THIN_STROKE_WIDTH = 1.45
THICK_STROKE_WIDTH = 3.25


class PreprocessingError(RuntimeError):
    """Raised when the supplied image does not contain a usable digit."""


@dataclass
class PreprocessingResult:
    selected_region: np.ndarray
    grayscale_region: np.ndarray
    foreground_mask: np.ndarray
    normalized_image: np.ndarray
    input_bytes: np.ndarray
    roi: tuple
    component_bounds: tuple
    component_area: int
    foreground_fraction: float
    processing_scale: float
    grouped_component_count: int
    stroke_width_before: float
    stroke_width_after: float
    stroke_action: str


def _odd_at_most(value, maximum):
    result = min(int(value), int(maximum))
    if result % 2 == 0:
        result -= 1
    return max(3, result)


def _binary_image(image, threshold=0):
    return np.where(image > threshold, 255, 0).astype(np.uint8)


def _component_count(image):
    return cv2.connectedComponents(image, connectivity=8)[0] - 1


def segment_black_digit(gray):
    minimum_dimension = min(gray.shape)
    if minimum_dimension < 15:
        raise PreprocessingError("selected region is too small to process")

    background_kernel = _odd_at_most(
        max(51, round(minimum_dimension * 0.25)),
        minimum_dimension,
    )
    background = cv2.GaussianBlur(
        gray,
        (background_kernel, background_kernel),
        0,
    )
    background = np.maximum(background, 1)

    flattened = cv2.divide(gray, background, scale=255)
    flattened = cv2.GaussianBlur(flattened, (5, 5), 0)

    threshold_block = _odd_at_most(
        max(31, round(minimum_dimension * 0.08)),
        minimum_dimension,
    )
    adaptive_mask = cv2.adaptiveThreshold(
        flattened,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        threshold_block,
        12,
    )
    _, global_mask = cv2.threshold(
        flattened,
        0,
        255,
        cv2.THRESH_BINARY_INV | cv2.THRESH_OTSU,
    )

    mask = cv2.bitwise_or(adaptive_mask, global_mask)
    mask = cv2.morphologyEx(
        mask,
        cv2.MORPH_OPEN,
        np.ones((2, 2), dtype=np.uint8),
    )
    return cv2.morphologyEx(
        mask,
        cv2.MORPH_CLOSE,
        np.ones((3, 3), dtype=np.uint8),
    )


def _morphological_skeleton(binary):
    remaining = _binary_image(binary)
    skeleton = np.zeros_like(remaining)
    kernel = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))

    while cv2.countNonZero(remaining):
        opened = cv2.morphologyEx(
            remaining,
            cv2.MORPH_OPEN,
            kernel,
            borderType=cv2.BORDER_CONSTANT,
            borderValue=0,
        )
        skeleton = cv2.bitwise_or(skeleton, cv2.subtract(remaining, opened))
        remaining = cv2.erode(
            remaining,
            kernel,
            borderType=cv2.BORDER_CONSTANT,
            borderValue=0,
        )

    return skeleton


def _effective_stroke_width(image):
    binary = _binary_image(image, threshold=31)
    if cv2.countNonZero(binary) == 0:
        return 0.0, binary, np.zeros_like(binary), 0

    skeleton = _morphological_skeleton(binary)
    padded = cv2.copyMakeBorder(
        binary,
        1,
        1,
        1,
        1,
        cv2.BORDER_CONSTANT,
        value=0,
    )
    distance = cv2.distanceTransform(padded, cv2.DIST_L2, 5)[1:-1, 1:-1]
    radii = distance[skeleton > 0]
    width = max(1.0, 2.0 * float(np.percentile(radii, 75.0)) - 1.0)

    return width, binary, skeleton, _component_count(binary)


def _restore_foreground_contrast(image):
    peak = int(np.max(image))
    if peak <= 0:
        raise PreprocessingError("detected digit has zero intensity")

    normalized = image.astype(np.float64) / peak
    adjusted = 255.0 * np.sqrt(normalized)
    return np.clip(np.rint(adjusted), 0, 255).astype(np.uint8)


def _normalize_stroke_width(image):
    width_before, _, skeleton, component_count = _effective_stroke_width(image)

    if width_before < THIN_STROKE_WIDTH or component_count > 2:
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2, 2))
        adjusted = cv2.dilate(image, kernel)
        action = "thicken"
    elif width_before > THICK_STROKE_WIDTH:
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        adjusted = cv2.dilate(skeleton, kernel)
        action = "thin"
    else:
        adjusted = image
        action = "unchanged"

    adjusted = _restore_foreground_contrast(adjusted)
    width_after, _, _, _ = _effective_stroke_width(adjusted)
    return adjusted, width_before, width_after, action


def _closest_component_points(labels, component_total):
    closest = None

    for first_label in range(1, component_total):
        first_points = np.argwhere(labels == first_label)

        for second_label in range(first_label + 1, component_total):
            second_points = np.argwhere(labels == second_label)
            deltas = first_points[:, None, :] - second_points[None, :, :]
            squared_distances = np.sum(deltas * deltas, axis=2)

            flat_index = int(np.argmin(squared_distances))
            first_index, second_index = np.unravel_index(
                flat_index,
                squared_distances.shape,
            )
            distance_squared = int(squared_distances[first_index, second_index])

            if closest is None or distance_squared < closest[0]:
                closest = (
                    distance_squared,
                    first_points[first_index],
                    second_points[second_index],
                )

    return closest


def _repair_resampling_breaks(image, expected_component_count):
    expected_component_count = int(expected_component_count or 0)
    if expected_component_count <= 0:
        return image, False

    repaired = np.ascontiguousarray(image.copy())
    changed = False

    while True:
        binary = _binary_image(repaired, threshold=15)
        component_total, labels = cv2.connectedComponents(binary, connectivity=8)
        component_count = component_total - 1

        if component_count <= expected_component_count:
            break

        closest = _closest_component_points(labels, component_total)
        if closest is None or closest[0] > 9:
            break

        _, first_point, second_point = closest
        start = (int(first_point[1]), int(first_point[0]))
        end = (int(second_point[1]), int(second_point[0]))
        bridge_value = max(
            128,
            int(repaired[first_point[0], first_point[1]]),
            int(repaired[second_point[0], second_point[1]]),
        )
        cv2.line(repaired, start, end, bridge_value, 1, cv2.LINE_AA)
        changed = True

    if changed:
        repaired = _restore_foreground_contrast(repaired)

    return repaired, changed


def _bounded_centering_shift(image, desired_x, desired_y):
    x, y, width, height = [int(value) for value in cv2.boundingRect(_binary_image(image))]
    if width <= 0 or height <= 0:
        return float(desired_x), float(desired_y)

    minimum_x = CENTERING_EDGE_MARGIN - x
    maximum_x = MNIST_SIZE - CENTERING_EDGE_MARGIN - (x + width)
    minimum_y = CENTERING_EDGE_MARGIN - y
    maximum_y = MNIST_SIZE - CENTERING_EDGE_MARGIN - (y + height)

    return (
        float(np.clip(desired_x, minimum_x, maximum_x)),
        float(np.clip(desired_y, minimum_y, maximum_y)),
    )


def _fit_and_center_digit(component, bounds, preserve_connectivity=False):
    x, y, width, height = bounds
    cropped = component[y : y + height, x : x + width]

    crop_height, crop_width = cropped.shape
    scale = float(DIGIT_BOX_SIZE) / max(crop_width, crop_height)
    resized_width = max(1, round(crop_width * scale))
    resized_height = max(1, round(crop_height * scale))
    interpolation = cv2.INTER_AREA if scale < 1.0 else cv2.INTER_LINEAR

    resized = cv2.resize(
        cropped,
        (resized_width, resized_height),
        interpolation=interpolation,
    )
    resized = _restore_foreground_contrast(resized)
    resized = cv2.copyMakeBorder(
        resized,
        STROKE_OPERATION_MARGIN,
        STROKE_OPERATION_MARGIN,
        STROKE_OPERATION_MARGIN,
        STROKE_OPERATION_MARGIN,
        cv2.BORDER_CONSTANT,
        value=0,
    )

    resized, width_before, width_after, stroke_action = _normalize_stroke_width(
        resized
    )

    expected_components = 0
    connectivity_repaired = False
    if preserve_connectivity:
        expected_components = _component_count(component)
        resized, connectivity_repaired = _repair_resampling_breaks(
            resized,
            expected_components,
        )

    resized_height, resized_width = resized.shape
    canvas = np.zeros((MNIST_SIZE, MNIST_SIZE), dtype=np.uint8)
    start_x = (MNIST_SIZE - resized_width) // 2
    start_y = (MNIST_SIZE - resized_height) // 2
    canvas[start_y : start_y + resized_height, start_x : start_x + resized_width] = resized

    moments = cv2.moments(canvas, binaryImage=False)
    if moments["m00"] <= 0:
        raise PreprocessingError("detected digit has zero intensity")

    center_x = moments["m10"] / moments["m00"]
    center_y = moments["m01"] / moments["m00"]
    target_center = (MNIST_SIZE - 1) / 2.0
    shift_x, shift_y = _bounded_centering_shift(
        canvas,
        target_center - center_x,
        target_center - center_y,
    )

    translation = np.float32(
        [[1.0, 0.0, shift_x], [0.0, 1.0, shift_y]]
    )
    normalized = cv2.warpAffine(
        canvas,
        translation,
        (MNIST_SIZE, MNIST_SIZE),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    normalized = _restore_foreground_contrast(normalized)

    if preserve_connectivity:
        normalized, repaired_after_centering = _repair_resampling_breaks(
            normalized,
            expected_components,
        )
        connectivity_repaired = connectivity_repaired or repaired_after_centering

    if connectivity_repaired:
        stroke_action += "+connect"

    return normalized, width_before, width_after, stroke_action


def _limit_processing_resolution(region):
    height, width = region.shape[:2]
    scale = min(1.0, float(MAX_PROCESSING_DIMENSION) / max(width, height))
    if scale >= 1.0:
        return region, 1.0

    resized = cv2.resize(
        region,
        (max(1, round(width * scale)), max(1, round(height * scale))),
        interpolation=cv2.INTER_AREA,
    )
    return resized, scale


def quantize_normalized_image(normalized_image, input_scale):
    if normalized_image.shape != (MNIST_SIZE, MNIST_SIZE):
        raise ValueError("normalized image must be 28x28")

    input_scale = float(input_scale)
    if not 0 < input_scale <= 127:
        raise ValueError("input scale must be within the signed INT8 range")

    values = np.rint(normalized_image.astype(np.float64) * (input_scale / 255.0))
    return np.clip(values, 0, 127).astype(np.int8).reshape(-1)


def preprocess_foreground_mask(foreground_mask, input_scale):
    if foreground_mask is None or foreground_mask.size == 0:
        raise PreprocessingError("foreground mask is empty")
    if foreground_mask.ndim != 2:
        raise PreprocessingError("foreground mask must be a two-dimensional image")

    mask = _binary_image(foreground_mask)
    height, width = mask.shape
    area = cv2.countNonZero(mask)
    minimum_area = max(12, round(mask.size * 0.00005))

    if area < minimum_area:
        raise PreprocessingError("draw a larger digit before recognizing it")

    bounds = tuple(int(value) for value in cv2.boundingRect(mask))
    _, _, bounds_width, bounds_height = bounds
    minimum_span = max(4, round(min(mask.shape) * 0.025))

    if max(bounds_width, bounds_height) < minimum_span:
        raise PreprocessingError("draw a larger digit before recognizing it")

    normalized, width_before, width_after, stroke_action = _fit_and_center_digit(
        mask,
        bounds,
        preserve_connectivity=True,
    )
    input_bytes = quantize_normalized_image(normalized, input_scale)
    grouped_count = _component_count(mask)
    grayscale = cv2.subtract(np.full_like(mask, 255), mask)
    selected_region = cv2.cvtColor(grayscale, cv2.COLOR_GRAY2BGR)

    return PreprocessingResult(
        selected_region=selected_region,
        grayscale_region=grayscale,
        foreground_mask=mask,
        normalized_image=normalized,
        input_bytes=input_bytes,
        roi=(0, 0, width, height),
        component_bounds=bounds,
        component_area=area,
        foreground_fraction=float(area) / mask.size,
        processing_scale=1.0,
        grouped_component_count=grouped_count,
        stroke_width_before=width_before,
        stroke_width_after=width_after,
        stroke_action=stroke_action,
    )
