# changelog

the rectangle's medical history.

## 1.4.2

- fixed: raw pixels of finished pages piled up in memory. a long zip no longer needs a bigger laptop.
- fewer finished pages wait in line during parallel runs.
- `--keep-going` now survives damaged zips and damaged zip members too. safety limits still stop the run.
- `--strict` and `--keep-going` can no longer be combined: one stops, the other doesn't. pick a personality.
- `.gitignore` now knows about heic and about phones that shout `IMG_0001.JPG`.

## 1.4.1

- `-o` is optional for a single input: `photo.jpg` becomes `photo.pdf` right here.
- fixed: fat/exfat usb sticks have no hard links, so the finished pdf died on the doorstep.
- a missing `osd` language pack now tells you what to install.

## 1.4.0

- heic/heif photos work through `heif-convert`; iphone depth maps are politely ignored.
- `--rotate auto` asks tesseract which way is up.
- `--debug-dir` shows where the corners were found and suggests a `--crop`.
- pages are processed in parallel (`--jobs`, default: cores, at most 4). roughly 3x faster on big zips.
- `--keep-going` skips broken pages and exits with 2 instead of abandoning everyone.
- progress counter: `[17/40]`, so silence no longer looks like death.
- fixed: the pdf was born readable only by its owner (`0600`). it now follows your umask.
- tests, ci, `make install`, a license.

## 1.3.1

- ocr cleans shadows in its own working copy and keeps sentences in reading order.

## 1.0.0

- summoned.
