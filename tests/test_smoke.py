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
        # ASCII85 would make every image stream ~25% larger for nothing.
        self.assertNotIn(b"/ASCII85Decode", (self.work / "out.pdf").read_bytes())

    def test_transparent_pixels_become_white_paper(self):
        from PIL import Image
        transparent = self.work / "transparent.png"
        Image.new("RGBA", (300, 400), (0, 0, 0, 0)).save(transparent)
        output = self.work / "out.pdf"
        self.run_script("--no-ocr", "--no-auto-crop", "--paper", "image", "--margin-mm", 0, "-o", output, transparent)
        subprocess.run(["pdftoppm", "-r", "30", "-png", "-singlefile", str(output), str(self.work / "page")], check=True)
        # Transparent black must come out as paper, not as a black hole.
        self.assertGreater(min(Image.open(self.work / "page.png").convert("RGB").getpixel((10, 10))), 240)

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

    def nautilus(self, *selected, script="Exorcise to PDF", zenity_progress="cat >/dev/null"):
        """Run the right-click script with stand-ins for zenity and notify-send."""
        tools = self.work / "desktop-bin"
        calls = self.work / "calls.log"
        if not tools.exists():
            tools.mkdir()
            (tools / "paper-exorcist").symlink_to(SCRIPT)
            (tools / "notify-send").write_text(f'#!/bin/sh\necho "notify $*" >> "{calls}"\n')
        (tools / "zenity").write_text(textwrap.dedent(f"""\
            #!/bin/sh
            echo "zenity $*" >> "{calls}"
            case "$*" in *--progress*) {zenity_progress} ;; esac
        """))
        for tool in tools.iterdir():
            if not tool.is_symlink():
                tool.chmod(0o755)
        runner = self.work / script
        if not runner.exists():
            shutil.copy(SCRIPT.parent / "nautilus" / "exorcise-to-pdf", runner)
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", XDG_CACHE_HOME=str(self.work / "cache"),
                   NAUTILUS_SCRIPT_SELECTED_FILE_PATHS="".join(f"{path}\n" for path in selected))
        result = subprocess.run(["/bin/bash", str(runner)], capture_output=True, text=True, env=env, cwd="/")
        return result, calls.read_text() if calls.exists() else ""

    def test_nautilus_names_the_pdf_and_never_overwrites(self):
        photos = self.work / "photos"
        photos.mkdir()
        shutil.copy(self.photo, photos / "receipt.jpg")
        for expected in ("receipt.pdf", "receipt (2).pdf"):
            result, calls = self.nautilus(photos / "receipt.jpg")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(page_count(photos / expected), 1)
            self.assertIn(f"paper-exorcist {expected} hazır", calls)
        self.assertIn("zenity --progress", calls)
        result, _ = self.nautilus(photos / "receipt.jpg", self.photo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(page_count(next(photos.glob("exorcised-*.pdf"))), 2)

    def test_nautilus_scan_variant_makes_grayscale_pages(self):
        result, _ = self.nautilus(self.photo, script="Exorcise to PDF (scan)")
        self.assertEqual(result.returncode, 0, result.stderr)
        listing = subprocess.run(["pdfimages", "-list", str(self.fixtures / "photo.pdf")],
                                 capture_output=True, text=True, check=True).stdout
        (self.fixtures / "photo.pdf").unlink()
        self.assertIn(" gray ", listing)

    def test_nautilus_closing_the_progress_bar_cancels_cleanly(self):
        for number in range(8):
            shutil.copy(self.photo, self.work / f"page{number}.jpg")
        pages = sorted(self.work.glob("page*.jpg"))
        # Close the window once pages are being processed, not during startup.
        result, calls = self.nautilus(*pages, zenity_progress="sleep 2.5; exit 1")
        log = (self.work / "cache/paper-exorcist/last-run.log").read_text()
        self.assertEqual(result.returncode, 130, log)
        self.assertIn("İşlem iptal edildi", log)
        self.assertIn("iptal edildi", calls)
        self.assertEqual(list(self.work.glob("*.pdf")) + list(self.work.glob(".paper-exorcist-*")), [])

    def test_nautilus_shows_errors_in_a_dialog(self):
        broken = self.work / "broken.jpg"
        broken.write_bytes(b"not a jpeg")
        result, calls = self.nautilus(broken)
        self.assertEqual(result.returncode, 1)
        self.assertIn("zenity --error", calls)
        self.assertIn("broken.jpg", calls)

    def test_strict_and_keep_going_cannot_be_combined(self):
        result = self.run_script("--no-ocr", "--strict", "-k", "-o", self.work / "out.pdf", self.photo, expect=2)
        self.assertIn("--strict", result.stderr)
        self.assertFalse((self.work / "out.pdf").exists())

    def test_keep_going_survives_damaged_archives(self):
        junk = self.work / "junk.zip"
        junk.write_bytes(b"not a zip at all")
        output = self.work / "junk.pdf"
        self.run_script("--no-ocr", "-o", output, junk, self.photo, expect=1)
        result = self.run_script("--no-ocr", "-k", "-o", output, junk, self.photo, expect=2)
        self.assertIn("Atlandı", result.stderr)
        self.assertEqual(page_count(output), 1)
        # Only the damaged member is lost, not its healthy neighbour.
        damaged = self.work / "damaged.zip"
        with zipfile.ZipFile(damaged, "w", zipfile.ZIP_STORED) as zf:
            zf.write(self.photo, "a.jpg")
            zf.write(self.photo, "b.jpg")
            offset = zf.getinfo("a.jpg").header_offset + 30 + len("a.jpg") + 2000
        data = bytearray(damaged.read_bytes())
        data[offset] ^= 0xff
        damaged.write_bytes(data)
        output = self.work / "damaged.pdf"
        self.run_script("--no-ocr", "-o", output, damaged, expect=1)
        result = self.run_script("--no-ocr", "-k", "-j", 2, "-o", output, damaged, expect=2)
        self.assertIn("damaged.zip!a.jpg", result.stderr)
        self.assertEqual(page_count(output), 1)

    def test_keep_going_stops_when_nothing_or_a_limit_remains(self):
        junk = self.work / "junk.zip"
        junk.write_bytes(b"not a zip at all")
        output = self.work / "out.pdf"
        for jobs in (1, 2):
            result = self.run_script("--no-ocr", "-k", "-j", jobs, "-o", output, junk, expect=1)
            self.assertIn("Hiçbir sayfa", result.stderr)
        archive = self.work / "pages.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.write(self.photo, "a.jpg")
            zf.write(self.photo, "b.jpg")
        result = self.run_script("--no-ocr", "-k", "--zip-max-files", 1, "-o", output, archive, expect=1)
        self.assertIn("--zip-max-files", result.stderr)
        self.assertFalse(output.exists())

    def test_output_name_defaults_to_the_single_input(self):
        result = self.run_script("--no-ocr", self.photo)
        self.assertIn("photo.pdf", result.stdout)
        self.assertEqual(page_count(self.work / "photo.pdf"), 1)
        folder = self.work / "scans.v2"
        folder.mkdir()
        shutil.copy(self.photo, folder)
        self.run_script("--no-ocr", folder)
        self.assertEqual(page_count(self.work / "scans.v2.pdf"), 1)
        result = self.run_script("--no-ocr", self.photo, self.photo, expect=1)
        self.assertIn("-o", result.stderr)

    def test_filesystem_without_hard_links_or_chmod(self):
        # What a FAT/exFAT USB stick does to the final publish step.
        source = SCRIPT.read_text(encoding="utf-8")
        engine = source.split("<<'PYTHON'\n", 1)[1].rsplit("PYTHON", 1)[0]
        harness = self.work / "harness.py"
        harness.write_text(textwrap.dedent("""\
            import os, sys
            def refuse(*args, **kwargs):
                raise PermissionError(1, "Operation not permitted")
            os.link = os.chmod = refuse
            engine = open(sys.argv[1], encoding="utf-8").read()
            sys.argv = ["paper-exorcist"] + sys.argv[2:]
            exec(compile(engine, "engine", "exec"), {"__name__": "__main__"})
        """))
        engine_path = self.work / "engine.py"
        engine_path.write_text(engine, encoding="utf-8")
        output = self.work / "usb.pdf"
        command = [sys.executable, str(harness), str(engine_path), "--no-ocr", "-o", str(output), str(self.photo)]
        result = subprocess.run(command, capture_output=True, text=True, cwd=self.work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(page_count(output), 1)
        self.assertEqual([p.name for p in self.work.glob(".paper-exorcist-*")], [])

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
