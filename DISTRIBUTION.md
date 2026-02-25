# Frespr Distribution Options

This is a native macOS app — "deploying on the web" means distributing it for download.

## Free Hosting Options

**GitHub Releases** (most common for open source)
- Push repo to GitHub, create a Release, attach `Frespr.pkg`
- Free, permanent URLs, good for technical users
- Discoverable if the repo gets stars

**Gumroad** (best for visibility + optionally monetizing)
- Host the `.pkg` as a free product
- Has a marketplace feel, people browse it, you get a product page
- Free tier exists (they take a cut only on paid products)

**Homebrew Cask** (best for developer reach)
- Submit a cask formula so people can `brew install --cask frespr`
- High discoverability among Mac devs
- Requires `.pkg` or `.dmg` hosted somewhere (GitHub Releases works)

**Itch.io** (surprisingly good for free utilities)
- Designed for games but works fine for Mac apps
- Has a browse/discovery layer, free hosting

## Launch Visibility

**Product Hunt** — not a host, but launching there drives a lot of downloads on day one.
Pair with GitHub Releases or Gumroad.

## Recommended Path

1. GitHub Releases for hosting
2. Product Hunt for the launch spike
3. Homebrew Cask for ongoing dev discoverability

## Blocker Before Release

The app is currently **ad-hoc signed** — Gatekeeper will block it for most users on download.

Options:
- Get an Apple Developer account ($99/yr) for a real signing cert + notarization
- Or document the workaround for users:
  ```
  xattr -dr com.apple.quarantine /Applications/Frespr.app
  ```


  1. Commit and push the docs/ folder:                                                         
  git add docs/
  git commit -m "Add GitHub Pages landing page"                                                
  git push                                                        

  2. Enable Pages on GitHub:
  - Go to github.com/salah-saleh/frespr → Settings → Pages
  - Source: Deploy from a branch
  - Branch: main, Folder: /docs
  - Hit Save

  3. Create a Release with the .pkg:
  - Go to Releases → Draft a new release
  - Tag: v0.1.0, attach Frespr.pkg
  - Publish

  Your site will be live at https://salah-saleh.github.io/frespr within a minute or two. The
  download button is already wired to the releases/latest/download/Frespr.pkg URL, so future
  releases automatically work without touching the page.
