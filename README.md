# paper-exorcist

i wanted a pdf. my phone offered a haunted rectangle.

so i put python inside a bash script and told the shadows to find a job.
it crops document photos, corrects perspective, reduces shadows, and turns images or zip archives into one pdf.

made this for myself. use it if you want. bring your own coffee.

## summon it (ubuntu 22.04)

```bash
sudo apt update
sudo apt install python3 python3-opencv python3-pil python3-reportlab

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
no ocr, no resurrection of blurry text. just rectangles and caffeine.
