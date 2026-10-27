## Theme

- **Name:**
- **Author and link:**
- **License:**

## Screenshot

<!-- Paste the screenshot here too, so it shows in the review. It must be the
     theme booted in Ventoy: a real machine, or scripts/themes/render-preview.sh
     (needs `brew install qemu`). The maintainer may re-render it so all
     previews match. -->

How I made it: <!-- real machine (which?) / render-preview.sh -->

## Checklist

- [ ] Added one entry to `themes/catalog.json`
- [ ] `download.url` is a fixed version: a release asset, or `https://codeload.github.com/<owner>/<repo>/zip/<full commit SHA>`. Not a branch name.
- [ ] `download.sha256` and `download.root` come from `swift run --package-path scripts/themes mactoy-themes hash <url>`
- [ ] Added `themes/previews/<id>.jpg`: JPEG, 16:9, at least 1280 px wide, at most 600 KB
- [ ] `swift run --package-path scripts/themes mactoy-themes validate themes/catalog.json --download --only <id>` passes
- [ ] Regenerated the gallery: `swift run --package-path scripts/themes mactoy-themes gallery themes/catalog.json themes/README.md`
- [ ] Regenerated the preview credits: `swift run --package-path scripts/themes mactoy-themes credits themes/catalog.json themes/previews/CREDITS.md`
- [ ] The theme's license allows people to download and use it
- [ ] I tried it on a Ventoy drive (Mactoy's Manage Disk → Theme → Add Theme from File…, or the `install` command)
- [ ] AI tools used? Say which, here:
