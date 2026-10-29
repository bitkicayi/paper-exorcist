"""Black-box tests: run the real script on synthetic photos and inspect the PDF."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from synthetic import make_photo  # noqa: E402

SCRIPT = Path(__file__).resolve().parent.parent / "paper-exorcist.sh"
LINES = [f"Line {i}: the haunted rectangle signs a lease." for i in range(1, 25)]


def page_text(pdf):
    return subprocess.run(["pdftotext", "-layout", str(pdf), "-"], capture_output=True,
                          text=True, check=True).stdout


def page_count(pdf):
    info = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True, check=True).stdout
    return int(next(line.split()[-1] for line in info.splitlines() if line.startswith("Pages:")))


class PaperExorcistTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = Path(tempfile.mkdtemp(prefix="paper-exorcist-fixtures-"))
        cls.photo = make_photo(cls.fixtures / "photo.jpg", LINES)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.fixtures)

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="paper-exorcist-test-"))
        self.addCleanup(shutil.rmtree, self.work)

    def run_script(self, *args, env=None, expect=0):
        result = subprocess.run(["/bin/bash", str(SCRIPT), *map(str, args)], capture_output=True,
                                text=True, env=env, cwd=self.work)
        self.assertEqual(result.returncode, expect, result.stderr)
        return result

    def test_photo_becomes_searchable_pdf_with_normal_permissions(self):
        old = os.umask(0o022)
        try:
            result = self.run_script("-o", self.work / "out.pdf", self.photo)
        finally:
            os.umask(old)
        self.assertIn("[1/1]", result.stderr)
        self.assertIn("perspektif düzeltildi", result.stderr)
        self.assertIn("haunted rectangle", page_text(self.work / "out.pdf"))
        self.assertEqual(stat.S_IMODE((self.work / "out.pdf").stat().st_mode), 0o644)

    def test_zip_keeps_natural_order_in_parallel(self):
        archive = self.work / "pages.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            for number in (10, 2, 1):
                path = make_photo(self.work / f"p{number}.jpg", [f"Page number {number} speaking."] * 12)
                zf.write(path, f"scans/p{number}.jpg")
        self.run_script("-j", 3, "--ocr-lang", "eng", "-o", self.work / "out.pdf", archive)
        text = page_text(self.work / "out.pdf")
        positions = [text.index(f"number {n} speaking") for n in (1, 2, 10)]
        self.assertEqual(positions, sorted(positions))

    def test_refuses_to_overwrite_without_force(self):
        output = self.work / "out.pdf"
        self.run_script("--no-ocr", "-o", output, self.photo)
        result = self.run_script("--no-ocr", "-o", output, self.photo, expect=1)
        self.assertIn("--force", result.stderr)
        self.run_script("--no-ocr", "-f", "-o", output, self.photo)

    def test_no_ocr_works_without_tesseract(self):
        env = dict(os.environ, PATH="/nonexistent")
        self.run_script("--no-ocr", "-o", self.work / "out.pdf", self.photo, env=env)
        result = self.run_script("-o", self.work / "ocr.pdf", self.photo, env=env, expect=1)
        self.assertIn("Tesseract", result.stderr)

    def test_rotate_auto_turns_sideways_photo_upright(self):
        sideways = make_photo(self.work / "sideways.jpg", LINES, rotate=90)
        result = self.run_script("--rotate", "auto", "--ocr-lang", "eng", "-o", self.work / "out.pdf", sideways)
        self.assertIn("döndürüldü", result.stderr)
        self.assertIn("haunted rectangle", page_text(self.work / "out.pdf"))

    def test_debug_dir_shows_corners_and_crop_hint(self):
        debug = self.work / "debug"
        result = self.run_script("--no-ocr", "--debug-dir", debug, "-o", self.work / "out.pdf", self.photo)
        self.assertIn("--crop önerisi", result.stderr)
        self.assertEqual(sorted(p.name for p in debug.iterdir()),
                         ["0001-photo-detect.jpg", "0001-photo-page.jpg"])

    def test_keep_going_skips_broken_pages(self):
        broken = self.work / "broken.png"
        broken.write_bytes(b"definitely not a png")
        output = self.work / "out.pdf"
        result = self.run_script("--no-ocr", "-o", output, self.photo, broken, expect=1)
        self.assertIn("broken.png", result.stderr)
        self.assertFalse(output.exists())
        result = self.run_script("--no-ocr", "-k", "-o", output, self.photo, broken, expect=2)
        self.assertIn("Atlandı", result.stderr)
        self.assertEqual(page_count(output), 1)

    def test_heic_goes_through_heif_convert_and_ignores_depth_maps(self):
        # A stand-in converter: copies the "HEIC" (really a PNG) and adds a
        # depth map the way heif-convert does for iPhone portrait photos.
        tools = self.work / "bin"
        tools.mkdir()
        stub = tools / "heif-convert"
        stub.write_text(textwrap.dedent(f"""\
            #!{sys.executable}
            import shutil, sys
            from pathlib import Path
            out = Path(sys.argv[2])
            shutil.copy(sys.argv[1], out)
            shutil.copy(sys.argv[1], out.with_name(out.stem + "-depth.png"))
        """))
        stub.chmod(0o755)
        heic = self.work / "IMG_0001.HEIC"
        make_photo(self.work / "source.png", LINES)
        shutil.copy(self.work / "source.png", heic)
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
        result = self.run_script("--no-ocr", "-o", self.work / "out.pdf", heic, env=env)
        self.assertIn("perspektif düzeltildi", result.stderr)
        self.assertNotIn("HEIC içinde", result.stderr)
        self.assertEqual(page_count(self.work / "out.pdf"), 1)

    def test_heic_without_converter_explains_how_to_install(self):
        heic = self.work / "IMG_0001.heic"
        heic.write_bytes(b"\0")
        env = dict(os.environ, PATH="/nonexistent")
        result = self.run_script("--no-ocr", "-o", self.work / "out.pdf", heic, env=env, expect=1)
        self.assertIn("libheif-examples", result.stderr)

    @unittest.skipUnless(shutil.which("heif-enc") and shutil.which("heif-convert"),
                         "libheif-examples is not installed")
    def test_real_heic(self):
        heic = self.work / "photo.heic"
        subprocess.run(["heif-enc", "-q", "90", "-o", str(heic), str(self.photo)],
                       check=True, capture_output=True)
        self.run_script("--ocr-lang", "eng", "-o", self.work / "out.pdf", heic)
        self.assertIn("haunted rectangle", page_text(self.work / "out.pdf"))


if __name__ == "__main__":
    unittest.main()
