"""Render the README's before/after picture: synthetic photo in, real output out."""
from pathlib import Path
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
from synthetic import FONT, make_photo  # noqa: E402

SCRIPT = Path(__file__).resolve().parent.parent / "paper-exorcist.sh"
LINES = [
    "Notice of Eviction",
    "",
    "To: the shadow in the upper left corner",
    "",
    "You have occupied this page without paying",
    "rent since the photo was taken. The table",
    "behind the paper has also been informed.",
    "",
    "Effective immediately, the following must leave:",
    "  - the trapezoid",
    "  - the gradient of despair",
    "  - approximately 40% of the background",
    "",
    "The words may stay. They are now searchable.",
    "",
    "Signed,",
    "paper-exorcist",
]


def main(target):
    with tempfile.TemporaryDirectory(prefix="paper-exorcist-demo-") as directory:
        directory = Path(directory)
        photo = make_photo(directory / "photo.jpg", LINES)
        pdf = directory / "page.pdf"
        subprocess.run(["/bin/bash", str(SCRIPT), "--mode", "scan", "--ocr-lang", "eng",
                        "-o", str(pdf), str(photo)], check=True)
        subprocess.run(["pdftoppm", "-r", "60", "-png", "-singlefile", str(pdf), str(directory / "page")],
                       check=True)
        before, after = Image.open(photo), Image.open(directory / "page.png").convert("RGB")
        height = 640
        before = before.resize((round(before.width * height / before.height), height), Image.LANCZOS)
        after = after.resize((round(after.width * height / after.height) - 2, height - 2), Image.LANCZOS)
        after = ImageOps.expand(after, border=1, fill=(170, 170, 170))
        gap, label = 40, 50
        canvas = Image.new("RGB", (before.width + after.width + 3 * gap, height + label + gap), "white")
        canvas.paste(before, (gap, label))
        canvas.paste(after, (before.width + 2 * gap, label))
        draw = ImageDraw.Draw(canvas)
        font = ImageFont.truetype(FONT, 22)
        draw.text((gap, 14), "before: a haunted rectangle", fill="black", font=font)
        draw.text((before.width + 2 * gap, 14), "after: a pdf with a job", fill="black", font=font)
        canvas.save(target, quality=82, optimize=True)


if __name__ == "__main__":
    Path(sys.argv[1]).parent.mkdir(parents=True, exist_ok=True)
    main(sys.argv[1])
