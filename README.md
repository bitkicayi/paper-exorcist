# paper-exorcist

i wanted a pdf. my phone offered a haunted rectangle.

so i put python inside a bash script and told the shadows to find a job.
it crops document photos, corrects perspective, reduces shadows, and turns images or zip archives into one pdf. now the words can leave the rectangle too: ocr adds searchable, selectable text.

made this for myself. use it if you want. bring your own coffee.

## summon it (ubuntu 22.04)

```bash
sudo apt update
sudo apt install python3 python3-opencv python3-pil python3-reportlab
sudo apt install tesseract-ocr tesseract-ocr-tur tesseract-ocr-eng fonts-dejavu-core

git clone https://github.com/bitkicayi/paper-exorcist.git
cd paper-exorcist

mkdir -p "$HOME/.local/bin"
install -m 755 paper-exorcist.sh "$HOME/.local/bin/paper-exorcist"
export PATH="$HOME/.local/bin:$PATH"
```

if another terminal forgets the command, add `$HOME/.local/bin` to its `PATH` too.
you can also skip installation and run `bash paper-exorcist.sh` with the same options.

## feed it rectangles

```bash
# one photo, one pdf
paper-exorcist -o document.pdf photo.png

# phone photos with shadow-related emotional baggage
paper-exorcist --mode scan -o document.pdf photos.zip

# english text, searchable and selectable (ocr is on by default)
paper-exorcist --ocr-lang eng --mode scan -o searchable.pdf photos.zip

# turkish books deserve their own dictionary
paper-exorcist --ocr-lang tur -o book.pdf page.png

# same book, visible shadows evicted too
paper-exorcist --ocr-lang tur --mode scan -o book-clean.pdf page.jpeg

# labels scattered around a diagram
paper-exorcist --ocr-psm 11 -o diagram.pdf diagram.png

# sometimes a rectangle just wants to remain a rectangle
paper-exorcist --no-ocr -o image-only.pdf photo.png

# several offerings, one pdf, in the order you give them
paper-exorcist -o combined.pdf page1.png page2.jpg archive.zip

# a folder, including its basement
paper-exorcist --recursive --mode scan -o document.pdf ./photos

# already cropped? let the corners rest
paper-exorcist --no-auto-crop -o document.pdf scans.zip

# manual eviction: x,y,width,height in pixels
paper-exorcist --crop 120,80,1000,1400 -o document.pdf photo.png

# the remaining knobs
paper-exorcist --help
```

png, jpeg, webp, bmp and single-page tiff work. zip subfolders are included automatically.
folder and archive contents use natural filename order. one image becomes one pdf page.

`--mode scan` reduces shadows and produces grayscale. the default keeps colors.
existing output? add `--force`. failed detection keeps the full image; `--strict` stops instead.

automatic cropping occasionally develops free will. check the result; use `--crop` or `--no-auto-crop` when it gets philosophical.
ocr runs locally with [tesseract](https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html). the default languages are `tur+eng`; for a single-language document, choose `--ocr-lang tur` or `--ocr-lang eng`. other languages need their tesseract language pack. `tesseract --list-langs` lists installed languages.
ocr follows cropping and rotation. it cleans shadows in its own working copy by default, even when the pdf keeps its original colors. use `--mode scan` to clean the visible page too, or `--ocr-preprocess none` if the cleanup makes your particular image worse.
invisible, selectable text follows the recognized lines so copying a sentence does not turn it into word soup. `--no-ocr` skips recognition and does not require tesseract.
`--ocr-psm 3` handles page layout automatically; try `6` for one text block or `11` for scattered labels. slow page? raise `--ocr-timeout 120`.
recognition can misread handwriting, blur and tiny text. this is still a coffee-powered script, not a resurrection service.
