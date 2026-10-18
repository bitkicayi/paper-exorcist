#!/usr/bin/env bash
# Ubuntu 22.04: Bash entry point with an embedded Python image-processing engine.
set -euo pipefail

python_bin="${PAPER_EXORCIST_PYTHON:-/usr/bin/python3}"
if ! command -v "$python_bin" >/dev/null 2>&1; then
    printf 'Hata: Python bulunamadı: %s\n' "$python_bin" >&2
    printf 'Kurulum: sudo apt install python3 python3-opencv python3-pil python3-reportlab\n' >&2
    exit 127
fi

exec "$python_bin" - "$@" <<'PYTHON'
import argparse
import csv
import io
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import warnings
import zipfile

VERSION = "1.3.1"
IMAGE_FORMATS = {
    ".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG", ".webp": "WEBP",
    ".bmp": "BMP", ".tif": "TIFF", ".tiff": "TIFF",
}


def load_dependencies():
    global cv2, np, Image, ImageOps, ImageReader, canvas, A4, LETTER, pdfmetrics, TTFont
    try:
        import cv2
        import numpy as np
        from PIL import Image, ImageOps
        from reportlab.lib.utils import ImageReader
        from reportlab.pdfgen import canvas
        from reportlab.lib.pagesizes import A4, LETTER
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont
    except ImportError as exc:
        raise ValueError(
            f"Eksik Python bağımlılığı: {exc}.\n"
            "Kurulum: sudo apt install python3-opencv python3-pil python3-reportlab\n"
            "Özel Python ortamı kullanıyorsanız PAPER_EXORCIST_PYTHON değişkenini kontrol edin."
        ) from exc


def crop_argument(value):
    try:
        x, y, width, height = map(int, value.split(","))
        if min(x, y) < 0 or min(width, height) < 2:
            raise ValueError
        return x, y, width, height
    except ValueError:
        raise argparse.ArgumentTypeError(
            "Kırpma X,Y,GENİŞLİK,YÜKSEKLİK biçiminde olmalı; "
            "X/Y >= 0, genişlik/yükseklik >= 2."
        )


def arguments():
    parser = argparse.ArgumentParser(
        prog="paper-exorcist",
        description="Resim veya ZIP içindeki belgeleri kırp, perspektiflerini düzelt ve PDF oluştur.",
        epilog="Örnek: paper-exorcist -o belgeler.pdf taramalar.zip sayfa1.png",
    )
    parser.add_argument("inputs", nargs="+", metavar="RESİM_ZIP_KLASÖR")
    parser.add_argument("-o", "--output", required=True, metavar="PDF", help="Çıktı PDF yolu")
    parser.add_argument("-r", "--recursive", action="store_true", help="Klasörlerin altına da bak")
    parser.add_argument("-f", "--force", action="store_true", help="Mevcut PDF'in üzerine yaz")
    crop = parser.add_mutually_exclusive_group()
    crop.add_argument("--crop", type=crop_argument, metavar="X,Y,W,H", help="Piksel cinsinden elle kırp")
    crop.add_argument("--no-auto-crop", action="store_true", help="Görüntünün tamamını kullan")
    parser.add_argument("--strict", action="store_true", help="Belge algılanamazsa PDF oluşturmadan dur")
    parser.add_argument("--min-area", type=float, default=0.15, metavar="ORAN",
                        help="Belgenin kaplaması gereken en küçük alan oranı (varsayılan: 0.15)")
    parser.add_argument("--mode", choices=("color", "gray", "bw", "scan"), default="color",
                        help="Renkli, gri, siyah-beyaz veya gölge azaltılmış tarama (varsayılan: color)")
    parser.add_argument("--compression", choices=("auto", "lossless", "jpeg"), default="auto",
                        help="PDF resim sıkıştırması; auto: JPEG kaynakları yeniden sıkıştır (varsayılan: auto)")
    parser.add_argument("--jpeg-quality", type=int, default=92, metavar="1-100",
                        help="JPEG sıkıştırma kalitesi (varsayılan: 92)")
    parser.add_argument("--rotate", type=int, choices=(0, 90, 180, 270), default=0,
                        help="Kırpmadan sonra saat yönünde döndür")
    parser.add_argument("--paper", choices=("a4", "letter", "image"), default="a4",
                        help="Sayfa boyutu; image: görüntü/DPI (varsayılan: a4)")
    parser.add_argument("--dpi", type=int, default=300, help="image modunun DPI değeri (varsayılan: 300)")
    parser.add_argument("--margin-mm", type=float, default=5.0, metavar="MM",
                        help="PDF sayfa kenar boşluğu (varsayılan: 5 mm)")
    parser.add_argument("--zip-max-mb", type=int, default=1024, metavar="MiB",
                        help="ZIP'lerden açılacak toplam resim boyutu sınırı (varsayılan: 1024 MiB)")
    parser.add_argument("--zip-max-files", type=int, default=5000, metavar="SAYI",
                        help="ZIP'lerden açılacak toplam resim sayısı sınırı (varsayılan: 5000)")
    ocr = parser.add_mutually_exclusive_group()
    ocr.add_argument("--ocr", dest="ocr", action="store_true", help="Seçilebilir metin ekle (varsayılan)")
    ocr.add_argument("--no-ocr", dest="ocr", action="store_false", help="OCR yapmadan yalnızca görüntüyü ekle")
    parser.set_defaults(ocr=True)
    parser.add_argument("--ocr-lang", default="tur+eng", metavar="DİL",
                        help="Tesseract dilleri; örnek: tur+eng veya eng (varsayılan: tur+eng)")
    parser.add_argument("--ocr-psm", type=int, choices=(3, 4, 6, 11), default=3,
                        help="OCR yerleşimi: 3 otomatik, 4 sütun, 6 metin bloğu, 11 dağınık metin")
    parser.add_argument("--ocr-preprocess", choices=("scan", "none"), default="scan",
                        help="OCR için gölge temizliği; PDF görüntüsünü değiştirmez (varsayılan: scan)")
    parser.add_argument("--ocr-timeout", type=float, default=120, metavar="SANİYE",
                        help="Sayfa başına OCR süre sınırı (varsayılan: 120 saniye)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    args = parser.parse_args()
    if not math.isfinite(args.min_area) or not 0.01 <= args.min_area < 0.95:
        parser.error("--min-area 0.01 ile 0.95 arasında olmalı (0.95 hariç).")
    if not 36 <= args.dpi <= 1200:
        parser.error("--dpi 36 ile 1200 arasında olmalı.")
    if not math.isfinite(args.margin_mm) or not 0 <= args.margin_mm <= 50:
        parser.error("--margin-mm 0 ile 50 arasında olmalı.")
    if args.strict and (args.crop or args.no_auto_crop):
        parser.error("--strict yalnızca otomatik kırpma ile kullanılabilir.")
    if args.zip_max_mb < 1 or args.zip_max_files < 1:
        parser.error("--zip-max-mb ve --zip-max-files en az 1 olmalı.")
    if not 1 <= args.jpeg_quality <= 100:
        parser.error("--jpeg-quality 1 ile 100 arasında olmalı.")
    if not re.fullmatch(r"[A-Za-z0-9_]+(?:\+[A-Za-z0-9_]+)*", args.ocr_lang):
        parser.error("--ocr-lang dil kodları tur+eng biçiminde olmalı.")
    if not math.isfinite(args.ocr_timeout) or args.ocr_timeout <= 0:
        parser.error("--ocr-timeout pozitif ve sonlu olmalı.")
    return args


def natural_key(path):
    path = Path(str(path))
    # Sort the stem first so 'capture.jpeg' precedes 'capture (1).jpeg'.
    # Including the dot/extension in the text key reverses WhatsApp's sequence.
    stem = str(path.with_suffix(""))
    return tuple((1, int(part)) if part.isdigit() else (0, part.casefold())
                 for part in re.split(r"(\d+)", stem)) + ((2, path.suffix.casefold()),)


def collect_inputs(inputs, recursive):
    files, seen = [], set()
    supported = set(IMAGE_FORMATS) | {".zip"}
    for name in inputs:
        path = Path(name).expanduser()
        if path.is_dir():
            iterator = path.rglob("*") if recursive else path.iterdir()
            candidates = sorted(
                (p for p in iterator if p.is_file() and p.suffix.lower() in supported),
                key=natural_key,
            )
            if not candidates:
                raise ValueError(f"Klasörde desteklenen resim veya ZIP bulunamadı: {path}")
        elif path.is_file() and path.suffix.lower() in supported:
            candidates = [path]
        else:
            raise ValueError(f"Desteklenen resim, ZIP veya klasör bulunamadı: {path}")
        for candidate in candidates:
            resolved = candidate.resolve()
            if resolved not in seen:
                seen.add(resolved)
                files.append(candidate)
    return files


def expand_archives(files, directory, args):
    pages = []
    total_size, total_files = 0, 0
    limit = args.zip_max_mb * 1024 * 1024
    for path in files:
        if path.suffix.lower() != ".zip":
            pages.append((path, str(path)))
            continue
        try:
            with zipfile.ZipFile(path) as archive:
                members = []
                for info in archive.infolist():
                    normalized = info.filename.replace("\\", "/")
                    parts = normalized.split("/")
                    suffix = Path(parts[-1]).suffix.lower()
                    if (not info.is_dir() and suffix in IMAGE_FORMATS
                            and "__MACOSX" not in parts and not parts[-1].startswith("._")):
                        members.append(info)
                members.sort(key=lambda info: natural_key(info.filename.replace("\\", "/")))
                if not members:
                    raise ValueError("Arşivde desteklenen resim bulunamadı.")
                if total_files + len(members) > args.zip_max_files:
                    raise ValueError("ZIP resim sayısı sınırı aşıldı; --zip-max-files ile artırabilirsiniz.")
                if total_size + sum(info.file_size for info in members) > limit:
                    raise ValueError("Açılmış ZIP boyutu sınırı aşıldı; --zip-max-mb ile artırabilirsiniz.")
                for info in members:
                    if info.flag_bits & 1:
                        raise ValueError(f"Şifreli ZIP resmi desteklenmiyor: {info.filename}")
                    total_files += 1
                    suffix = Path(info.filename.replace("\\", "/")).suffix.lower()
                    # Never use archive paths on disk: even ../ or absolute member
                    # names become generated flat filenames inside a private temp dir.
                    destination = directory / f"{total_files:06d}{suffix}"
                    with archive.open(info) as source, destination.open("xb") as target:
                        while True:
                            chunk = source.read(1024 * 1024)
                            if not chunk:
                                break
                            total_size += len(chunk)
                            if total_size > limit:
                                raise ValueError("Açılmış ZIP boyutu sınırı aşıldı (--zip-max-mb).")
                            target.write(chunk)
                    pages.append((destination, f"{path}!{info.filename}"))
        except Exception as exc:
            raise ValueError(f"ZIP açılamadı: {path}: {exc}") from exc
    return pages


def read_rgb(path, label=None):
    label = str(path) if label is None else label
    # Pillow handles Unicode paths, palette images and alpha safely.
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(path) as source:
            expected = IMAGE_FORMATS.get(path.suffix.lower())
            if source.format != expected:
                raise ValueError(f"İçerik {expected} biçiminde değil: {label}")
            if getattr(source, "n_frames", 1) > 1:
                raise ValueError(f"Animasyonlu/çok sayfalı resim desteklenmiyor: {label}")
            if min(source.size) < 2:
                raise ValueError(f"Görüntü en az 2 x 2 piksel olmalı: {label}")
            is_tiff = source.format == "TIFF"
            source.load()
            # Pillow's TIFF decoder applies orientation while loading. Calling
            # getexif/exif_transpose afterwards both risks a double rotation and
            # accesses a closed TIFF stream on Ubuntu 22.04's Pillow 9.0.1.
            if not is_tiff:
                source = ImageOps.exif_transpose(source)
            source = source.convert("RGBA")
            background = Image.new("RGBA", source.size, (255, 255, 255, 255))
            rgb_image = Image.alpha_composite(background, source).convert("RGB")
            # Avoid Pillow 9's obsolete __array__ protocol with NumPy 2, which
            # users may have installed alongside the Ubuntu system packages.
            return np.frombuffer(rgb_image.tobytes(), dtype=np.uint8).reshape(
                rgb_image.height, rgb_image.width, 3
            ).copy()


def order_corners(points):
    # Angle ordering avoids duplicate corners from sum/difference ordering at 45°.
    points = np.asarray(points, dtype=np.float32).reshape(4, 2)
    center = points.mean(axis=0)
    angles = np.arctan2(points[:, 1] - center[1], points[:, 0] - center[0])
    ordered = points[np.argsort(angles)]
    return np.roll(ordered, -int(np.argmin(ordered.sum(axis=1))), axis=0)


def plausible_quad(points):
    if not cv2.isContourConvex(np.rint(points).astype(np.int32)):
        return False
    sides = np.linalg.norm(points - np.roll(points, -1, axis=0), axis=1)
    if sides.min() < 12:
        return False
    # A shadow often forms a trapezoid with one side half the other side.
    # Avoid extreme warps; uncertain captures can retain the complete image.
    if max(sides[0] / sides[2], sides[2] / sides[0],
           sides[1] / sides[3], sides[3] / sides[1]) > 1.45:
        return False
    for i in range(4):
        u, v = points[i - 1] - points[i], points[(i + 1) % 4] - points[i]
        if abs(float(np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v)))) > 0.65:
            return False
    return True


def text_mask(gray, central=False):
    close = cv2.morphologyEx(gray, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    binary = ((cv2.subtract(close, gray) > 25)
              & (gray.astype(np.float32) < close.astype(np.float32) * 0.72)).astype(np.uint8)
    if central:
        # Ignore dark tabletop/keyboards in the upper margin when extending a
        # detected paper edge. The full contour check below uses all text.
        top = round(gray.shape[0] * 0.2)
        paper_background = cv2.medianBlur(gray, 31)
        binary[:top] *= (paper_background[:top] > 100).astype(np.uint8)
    _, labels, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
    allowed = ((stats[:, cv2.CC_STAT_WIDTH] <= 40)
               & (stats[:, cv2.CC_STAT_HEIGHT] >= 3)
               & (stats[:, cv2.CC_STAT_HEIGHT] <= 30)
               & (stats[:, cv2.CC_STAT_AREA] >= 4)
               & (stats[:, cv2.CC_STAT_AREA] <= 500))
    allowed[0] = False
    result = allowed[labels].astype(np.uint8)
    if central:
        result[:, :round(gray.shape[1] * 0.1)] = 0
        result[:, round(gray.shape[1] * 0.9):] = 0
    return result


def text_coverage(points, ink):
    count = int(ink.sum())
    if count < 200:
        return 1.0
    inside = np.zeros(ink.shape, np.uint8)
    cv2.fillConvexPoly(inside, np.rint(points).astype(np.int32), 1)
    return float((inside * ink).sum()) / count


def detect_border_document(gray, min_area):
    """Recover near-upright large pages whose contour is broken by shadows."""
    h, w = gray.shape
    ink = text_mask(gray, central=True)
    iy, ix = np.nonzero(ink)
    if len(ix) < 200:
        return None
    edges = cv2.Canny(cv2.GaussianBlur(gray, (3, 3), 0), 30, 100)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 720, threshold=50,
                            minLineLength=min(h, w) * 0.15, maxLineGap=25)
    if lines is None:
        return None
    groups = {key: [] for key in ("left", "right", "top", "bottom")}
    for x1, y1, x2, y2 in lines[:, 0].astype(float):
        dx, dy = x2 - x1, y2 - y1
        length = math.hypot(dx, dy)
        if abs(dy) > h * 0.22 and abs(dx) < abs(dy) * 0.3:
            a, b = dx / dy, x1 - (dx / dy) * y1
            middle = a * h * 0.5 + b
            side = "left" if middle < 0.3 * w else "right" if middle > 0.7 * w else None
            if side is None:
                continue
            ys = np.linspace(max(min(y1, y2), h * 0.04), min(max(y1, y2), h * 0.98), 100)
            xs = a * ys + b
            direction = 1 if side == "left" else -1
            inner, outer = xs + direction * 10, xs - direction * 10
            valid = (inner >= 0) & (inner < w) & (outer >= 0) & (outer < w) & (ys >= 0) & (ys < h)
            if valid.sum() < 20:
                continue
            contrast = np.median(gray[ys[valid].astype(int), inner[valid].astype(int)].astype(float)
                                 - gray[ys[valid].astype(int), outer[valid].astype(int)])
        elif abs(dx) > w * 0.18 and abs(dy) < abs(dx) * 0.3:
            a, b = dy / dx, y1 - (dy / dx) * x1
            middle = a * w * 0.5 + b
            side = "top" if middle < 0.3 * h else "bottom" if middle > 0.7 * h else None
            if side is None:
                continue
            xs = np.linspace(max(min(x1, x2), w * 0.02), min(max(x1, x2), w * 0.98), 100)
            ys = a * xs + b
            direction = 1 if side == "top" else -1
            inner, outer = ys + direction * 10, ys - direction * 10
            valid = (inner >= 0) & (inner < h) & (outer >= 0) & (outer < h) & (xs >= 0) & (xs < w)
            if valid.sum() < 20:
                continue
            contrast = np.median(gray[inner[valid].astype(int), xs[valid].astype(int)].astype(float)
                                 - gray[outer[valid].astype(int), xs[valid].astype(int)])
        else:
            continue
        if contrast > 7:
            groups[side].append((length * min(contrast, 80), a, b))
    selected = {key: max(values) if values else None for key, values in groups.items()}
    if sum(value is not None for value in selected.values()) < 2:
        return None
    # Move edges outward if the proposed crop excludes central printed text.
    for side, values in selected.items():
        if values is None:
            continue
        score, a, b = values
        residual = ix - a * iy - b if side in ("left", "right") else iy - a * ix - b
        if side in ("left", "top"):
            shift = min(0, float(np.percentile(residual, 0.1)) - min(h, w) * 0.01)
        else:
            shift = max(0, float(np.percentile(residual, 99.9)) + min(h, w) * 0.01)
        selected[side] = (score, a, b + shift)
    defaults = {"left": (0, 0, 0), "right": (0, 0, w - 1),
                "top": (0, 0, 0), "bottom": (0, 0, h - 1)}
    points = []
    for vertical, horizontal in (("left", "top"), ("right", "top"),
                                  ("right", "bottom"), ("left", "bottom")):
        _, av, bv = selected[vertical] or defaults[vertical]
        _, ah, bh = selected[horizontal] or defaults[horizontal]
        y = (ah * bv + bh) / (1 - ah * av)
        points.append((av * y + bv, y))
    points = np.asarray(points, dtype=np.float32)
    points[:, 0] = np.clip(points[:, 0], 0, w - 1)
    points[:, 1] = np.clip(points[:, 1], 0, h - 1)
    if (cv2.contourArea(points) < h * w * max(0.4, min_area)
            or not plausible_quad(points) or text_coverage(points, ink) < 0.99):
        return None
    return points


def detect_document(rgb, min_area):
    height, width = rgb.shape[:2]
    scale = min(1.0, 1000.0 / max(height, width))
    size = (max(2, round(width * scale)), max(2, round(height * scale)))
    small = cv2.resize(rgb, size, interpolation=cv2.INTER_AREA)
    raw_gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)
    ink = text_mask(raw_gray)
    gray = cv2.GaussianBlur(raw_gray, (5, 5), 0)
    edges = cv2.Canny(gray, 40, 140)
    kernel = np.ones((5, 5), dtype=np.uint8)
    edges = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, kernel)
    _, light = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    light = cv2.morphologyEx(light, cv2.MORPH_CLOSE, kernel)
    candidates = []
    h, w = gray.shape
    for mask in (edges, light, cv2.bitwise_not(light)):
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:40]:
            if cv2.contourArea(contour) < h * w * min_area:
                continue
            perimeter = cv2.arcLength(contour, True)
            for epsilon in (0.015, 0.025, 0.04):
                quad = cv2.approxPolyDP(contour, epsilon * perimeter, True)
                if len(quad) != 4 or not cv2.isContourConvex(quad):
                    continue
                area = cv2.contourArea(quad)
                if area < h * w * min_area:
                    continue
                points = order_corners(quad)
                if not plausible_quad(points) or text_coverage(points, ink) < 0.99:
                    continue
                x, y, rw, rh = cv2.boundingRect(quad)
                border_count = sum((x <= 1, y <= 1, x + rw >= w - 1, y + rh >= h - 1))
                # A frame along most image edges is not evidence of a document.
                if border_count >= 3:
                    continue
                sides = np.linalg.norm(points - np.roll(points, -1, axis=0), axis=1)
                if sides.min() < max(12, min(h, w) * 0.05) or sides.max() / sides.min() > 12:
                    continue
                valid_angles = True
                for i in range(4):
                    u, v = points[i - 1] - points[i], points[(i + 1) % 4] - points[i]
                    cosine = float(np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v)))
                    if abs(cosine) > 0.8:
                        valid_angles = False
                        break
                if not valid_angles:
                    continue
                inside = np.zeros((h, w), dtype=np.uint8)
                cv2.fillConvexPoly(inside, quad.reshape(4, 2), 255)
                inner = cv2.erode(inside, kernel, iterations=2)
                ring = cv2.subtract(cv2.dilate(inside, kernel, iterations=3), inside)
                if not np.any(inner) or not np.any(ring):
                    continue
                contrast = abs(float(np.median(gray[inner > 0])) - float(np.median(gray[ring > 0])))
                if contrast < 12:
                    continue
                candidates.append((area, points))
                break
    if candidates:
        points = max(candidates, key=lambda candidate: candidate[0])[1]
    else:
        points = detect_border_document(raw_gray, min_area)
        if points is None:
            return None
    points *= np.array([width / w, height / h], dtype=np.float32)
    points[:, 0] = np.clip(points[:, 0], 0, width - 1)
    points[:, 1] = np.clip(points[:, 1], 0, height - 1)
    return points


def warp_document(rgb, corners):
    tl, tr, br, bl = corners
    width = max(2, round(max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl))))
    height = max(2, round(max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr))))
    destination = np.float32([[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]])
    matrix = cv2.getPerspectiveTransform(np.float32(corners), destination)
    warped = cv2.warpPerspective(rgb, matrix, (width, height), flags=cv2.INTER_CUBIC,
                                 borderMode=cv2.BORDER_REPLICATE)
    # Remove the interpolation fringe along detected paper edges. Limit the
    # inset to 1% of the shorter edge, especially for narrow receipts.
    inset = min(max(2, math.ceil(max(width, height) / 700)), min(width, height) // 100)
    if inset:
        warped = warped[inset:-inset, inset:-inset].copy()
    return warped


def scan_image(rgb):
    """Flatten uneven paper illumination while keeping grayscale text edges."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    size = max(15, round(max(gray.shape) / 25)) | 1
    background = cv2.morphologyEx(gray, cv2.MORPH_CLOSE, np.ones((size, size), np.uint8))
    background = cv2.GaussianBlur(background, (3, 3), 0)
    normalized = cv2.divide(gray, np.maximum(background, 1), scale=255)
    black = min(100, float(np.percentile(normalized, 1)))
    return np.clip((normalized.astype(np.float32) - black) * 255 / (248 - black), 0, 255).astype(np.uint8)


def process_page(path, args, label=None):
    label = str(path) if label is None else label
    rgb = read_rgb(path, label)
    original_h, original_w = rgb.shape[:2]
    status = "tam görüntü"
    if args.crop:
        x, y, width, height = args.crop
        if x + width > original_w or y + height > original_h:
            raise ValueError(f"Kırpma görüntü sınırlarını aşıyor: {label} ({original_w}x{original_h})")
        rgb = rgb[y:y + height, x:x + width].copy()
        status = "elle kırpıldı"
    elif not args.no_auto_crop:
        corners = detect_document(rgb, args.min_area)
        if corners is None:
            message = f"Belge sınırı algılanamadı: {label}"
            if args.strict:
                raise ValueError(message)
            print(f"Uyarı: {message}; tam görüntü kullanılıyor.", file=sys.stderr)
        else:
            rgb = warp_document(rgb, corners)
            status = "belge kırpıldı / perspektif düzeltildi"
    if args.rotate:
        rgb = np.ascontiguousarray(np.rot90(rgb, -(args.rotate // 90)))
    if args.mode in ("gray", "bw", "scan"):
        gray = scan_image(rgb) if args.mode == "scan" else cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
        if args.mode == "bw":
            # For tiny crops use Otsu; adaptive threshold needs a meaningful window.
            block = min(41, min(gray.shape) if min(gray.shape) % 2 else min(gray.shape) - 1)
            if block < 3:
                _, gray = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
            else:
                gray = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                             cv2.THRESH_BINARY, block, 12)
        image = Image.fromarray(gray)
        if args.mode == "bw":
            image = image.convert("1", dither=Image.NONE)
    else:
        image = Image.fromarray(rgb)
    image.info["source_format"] = IMAGE_FORMATS[path.suffix.lower()]
    print(f"{label}: {original_w}x{original_h} -> {image.width}x{image.height}; {status}", file=sys.stderr)
    return image


def prepare_ocr(args):
    if not args.ocr:
        return
    args.tesseract = shutil.which("tesseract")
    if args.tesseract is None:
        raise ValueError(
            "Seçilebilir metin için Tesseract gerekli.\n"
            "Kurulum: sudo apt install tesseract-ocr tesseract-ocr-tur tesseract-ocr-eng fonts-dejavu-core\n"
            "Yalnızca görüntü içeren PDF için --no-ocr kullanabilirsiniz."
        )
    try:
        result = subprocess.run([args.tesseract, "--list-langs"], capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=30)
    except subprocess.TimeoutExpired as exc:
        raise ValueError("Tesseract dil listesi alınırken zaman aşımı oluştu.") from exc
    if result.returncode:
        raise ValueError(f"Tesseract başlatılamadı: {result.stderr.strip()}")
    available = set(result.stdout.splitlines())
    missing = set(args.ocr_lang.split("+")) - available
    if missing:
        raise ValueError(
            f"OCR dil paketi eksik: {', '.join(sorted(missing))}.\n"
            "Türkçe/İngilizce kurulumu: sudo apt install tesseract-ocr-tur tesseract-ocr-eng\n"
            "Yüklü dilleri görmek için: tesseract --list-langs"
        )
    fonts = (
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        Path("/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf"),
        Path("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"),
    )
    font_path = next((path for path in fonts if path.is_file()), None)
    if font_path is None:
        raise ValueError("OCR metin fontu bulunamadı. Kurulum: sudo apt install fonts-dejavu-core")
    args.ocr_font = "PaperExorcistOCR"
    pdfmetrics.registerFont(TTFont(args.ocr_font, str(font_path)))


def recognize_words(image, args, effective_dpi):
    # Upscale only the recognition input; the PDF's visible image is unchanged.
    scale = min(2.0, max(1.0, 300 / effective_dpi))
    size = (max(2, round(image.width * scale)), max(2, round(image.height * scale)))
    if min(size) < 10:
        return []
    with tempfile.TemporaryDirectory(prefix="paper-exorcist-ocr-") as directory:
        path = Path(directory) / "page.png"
        # Recognition must not depend on the chosen visible PDF color mode.
        # Clean shadows before upscaling, just as --mode scan does for the image.
        recognition = image
        if args.ocr_preprocess == "scan" and args.mode not in ("scan", "bw"):
            recognition = Image.fromarray(scan_image(np.asarray(image.convert("RGB"))))
        try:
            if size == recognition.size:
                recognition.save(path, format="PNG")
            else:
                with recognition.resize(size, getattr(Image, "Resampling", Image).LANCZOS) as enlarged:
                    enlarged.save(path, format="PNG")
        finally:
            if recognition is not image:
                recognition.close()
        command = [args.tesseract, str(path), "stdout", "-l", args.ocr_lang,
                   "--psm", str(args.ocr_psm), "--dpi",
                   str(max(70, min(2400, round(effective_dpi * scale)))),
                   "-c", "tessedit_create_tsv=1"]
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=args.ocr_timeout)
        except subprocess.TimeoutExpired as exc:
            raise ValueError("OCR zaman aşımı: --ocr-timeout ile süreyi artırabilirsiniz.") from exc
    if result.returncode:
        raise ValueError(f"Tesseract OCR başarısız: {result.stderr.strip()}")
    reader = csv.DictReader(io.StringIO(result.stdout), delimiter="\t", quoting=csv.QUOTE_NONE)
    required = {"level", "page_num", "block_num", "par_num", "line_num",
                "left", "top", "width", "height", "text"}
    if not required.issubset(reader.fieldnames or ()):
        raise ValueError("Tesseract geçerli TSV metin verisi döndürmedi.")
    words = []
    for row in reader:
        if row.get("level") != "5":
            continue
        text = re.sub(r"\s+", " ", (row.get("text") or "").replace("\x00", "")).strip()
        if not text:
            continue
        try:
            left, top, width, height = (int(row[key]) for key in ("left", "top", "width", "height"))
        except (TypeError, ValueError) as exc:
            raise ValueError("Tesseract geçersiz sözcük koordinatları döndürdü.") from exc
        if min(left, top) < 0 or min(width, height) <= 0:
            continue
        right, bottom = min(size[0], left + width), min(size[1], top + height)
        if right <= left or bottom <= top:
            continue
        # Normalize boxes so resizing, crop, rotation, A4 fitting and margins
        # all share the same mapping into the final page coordinates.
        line = tuple(row[key] for key in ("page_num", "block_num", "par_num", "line_num"))
        words.append((text, left / size[0], top / size[1],
                      (right - left) / size[0], (bottom - top) / size[1], line))
    return words


def draw_ocr_layer(pdf, words, args, origin_x, origin_y, image_width, image_height):
    ascent, descent = pdfmetrics.getAscentDescent(args.ocr_font)
    lines = {}
    for word in words:
        lines.setdefault(word[5], []).append(word)
    for line in lines.values():
        # Glyph boxes have different heights (capitals, descenders, punctuation).
        # A shared baseline prevents PDF readers from reordering one sentence
        # into several rows when copying text from a slightly curved book page.
        line_height = float(np.median([word[4] for word in line])) * image_height
        font_size = max(1.0, line_height * 1000 / (ascent - descent))
        bottom = float(np.median([word[2] + word[4] for word in line]))
        baseline = origin_y + image_height * (1 - bottom) - descent * font_size / 1000
        text = pdf.beginText()
        text.setFont(args.ocr_font, font_size)
        text.setTextRenderMode(3)  # Invisible glyphs remain searchable/selectable.
        for word, left, top, width, height, _ in line:
            text_width = pdfmetrics.stringWidth(word, args.ocr_font, font_size)
            if text_width <= 0:
                continue
            text.setTextOrigin(origin_x + left * image_width, baseline)
            text.setHorizScale(100 * width * image_width / text_width)
            text.textOut(word + " ")
        pdf.drawText(text)


def draw_page(pdf, image, args):
    margin = args.margin_mm * 72 / 25.4
    if args.paper == "image":
        page_w = image.width * 72 / args.dpi + 2 * margin
        page_h = image.height * 72 / args.dpi + 2 * margin
    else:
        page_w, page_h = A4 if args.paper == "a4" else LETTER
        if image.width > image.height:
            page_w, page_h = page_h, page_w
    content_w, content_h = page_w - 2 * margin, page_h - 2 * margin
    if min(content_w, content_h) <= 0:
        raise ValueError("Kenar boşluğu sayfa için fazla büyük.")
    factor = min(content_w / image.width, content_h / image.height)
    width, height = image.width * factor, image.height * factor
    pdf.setPageSize((page_w, page_h))
    use_jpeg = args.compression == "jpeg" or (
        args.compression == "auto" and image.info.get("source_format") == "JPEG"
    )
    if use_jpeg and image.mode != "1":
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=args.jpeg_quality, optimize=True)
        buffer.seek(0)
        reader = ImageReader(buffer)
    else:
        reader = ImageReader(image)
    origin_x, origin_y = (page_w - width) / 2, (page_h - height) / 2
    pdf.drawImage(reader, origin_x, origin_y,
                  width=width, height=height)
    if args.ocr:
        words = recognize_words(image, args, 72 / factor)
        draw_ocr_layer(pdf, words, args, origin_x, origin_y, width, height)
        if words:
            print(f"OCR: {len(words)} sözcük; {args.ocr_lang}", file=sys.stderr)
        else:
            print("Uyarı: Bu sayfada OCR ile okunabilir metin bulunamadı.", file=sys.stderr)
    pdf.showPage()


def create_pdf(args):
    files = collect_inputs(args.inputs, args.recursive)
    output = Path(args.output).expanduser().absolute()
    if output.suffix.lower() != ".pdf":
        raise ValueError("Çıktı dosyasının uzantısı .pdf olmalı.")
    if not output.parent.is_dir():
        raise ValueError(f"Çıktı klasörü mevcut değil: {output.parent}")
    if output.is_symlink():
        raise ValueError(f"Çıktı sembolik bağlantı olamaz: {output}")
    if output.exists() and (not args.force or not output.is_file()):
        raise ValueError(f"Çıktı zaten var: {output}. Değiştirmek için --force kullanın.")
    resolved_output = output.resolve()
    for path in files:
        if path.resolve() == resolved_output or (output.exists() and os.path.samefile(path, output)):
            raise ValueError("Çıktı bir girdi dosyasıyla aynı olamaz.")
    with tempfile.TemporaryDirectory(prefix="paper-exorcist-zip-") as directory:
        pages = expand_archives(files, Path(directory), args)
        write_pdf(pages, output, args)


def write_pdf(pages, output, args):
    # Build alongside the destination, then publish only the finished PDF.
    fd, temporary = tempfile.mkstemp(prefix=".paper-exorcist-", suffix=".pdf", dir=output.parent)
    os.close(fd)
    try:
        pdf = canvas.Canvas(temporary, pagesize=A4, pageCompression=1)
        pdf.setTitle(output.stem)
        pdf.setCreator(f"paper-exorcist {VERSION}")
        for path, label in pages:
            try:
                with process_page(path, args, label) as image:
                    draw_page(pdf, image, args)
            except Exception as exc:
                raise ValueError(f"İşlenemedi: {label}: {exc}") from exc
        pdf.save()
        if args.force:
            os.replace(temporary, output)
        else:
            # Hard-link is atomic and refuses an output created during processing.
            try:
                os.link(temporary, output)
            except FileExistsError as exc:
                raise ValueError(f"Çıktı işlem sırasında oluşturuldu: {output}") from exc
        print(f"Hazır: {output} ({len(pages)} sayfa)")
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main():
    args = arguments()
    try:
        load_dependencies()
        prepare_ocr(args)
        create_pdf(args)
    except KeyboardInterrupt:
        print("\nİşlem iptal edildi.", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"Hata: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYTHON
