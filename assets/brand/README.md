# SightLatch visual identity / 品牌标识

An open display frame meets an inward action pointer: observe a screen, then act through hardware. No robot face, eye illustration, or third-party logo is used.

屏幕边框与动作指针构成一个简洁标记，表达“看见屏幕，再执行一步”。

- `app-icon.svg` is the editable icon master; `app-icon.png` is the opaque, square 1024 × 1024 RGB iOS source. iOS applies its own mask; do not pre-round its corners.
- `mark-light.svg` / `mark-dark.svg`: transparent marks for light / dark surfaces.
- `mark-mono.svg`: single-color vector using `currentColor`.
- `readme-hero.svg`: repository header.
- `brand-preview.png`: light/dark and 16–48 px comparison.

Palette: midnight `#11182E`, ink `#242E52`, frost `#F4F6FF`, mint `#66E2D3`, deep teal `#158B85`. Preserve proportions and keep clear space around the mark. Avoid extra glows, bevels or text inside the app icon.

The main iOS app owns `Assets.xcassets` and its `AppIcon` catalog setting. Broadcast and widget extension resource phases are intentionally unchanged. The app header uses the adaptive `BrandMark` image set. Bundle identifiers, entitlements, hardware protocols and firmware are unchanged.

Validation: `python tests/check_brand_assets.py` verifies icon dimensions/opacity, SVG and JSON parsing, image references and target wiring. This does not replace Xcode/actool or a real-device check.
