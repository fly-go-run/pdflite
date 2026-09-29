# PDFLite 应用图标

石墨灰底座、银白折角纸页和冷灰阅读标记。配色由用户选定，保留阅读与标注的产品特征。外侧透明留白用于 macOS Dock / Finder 显示。

- `source.png`：使用内置 imagegen 编辑并提取透明背景的 PNG，1254 × 1254。
- `../../PDFLite/Resources/AppIcon.icns`：应用实际使用的多尺寸图标。
- 运行 `./design/AppIcon/build.sh`，使用系统 `sips` 和 `iconutil` 从原图生成 16–1024 像素的图标表示，无第三方依赖。

## 当前配色编辑提示词

```text
Use case: precise-object-edit.
Edit target: the provided PDFLite app icon.
Primary request: the user chose GRAPHITE GRAY + SILVER WHITE instead of orange. Recolor this exact icon. Preserve the centered upright document silhouette, folded upper-right corner, rounded square tile, three horizontal reading strokes, framing, transparent margins, subtle three-dimensional material and soft studio lighting.
Change colors only: tile becomes deep neutral graphite gray, with subtle lighting from #51555C at top-left to #24272C at bottom-right. Document becomes clean silver-white (#F2F3F5), its folded corner softly shaded in neutral silver. The two thin reading strokes become medium cool gray (#B6BBC3). The formerly yellow central highlighter bar becomes darker slate silver (#737C89) to distinguish it from the two lighter reading strokes. All shadows must be neutral charcoal.
Overall appearance: restrained, sophisticated, monochrome, matte, premium native macOS icon. Absolutely no orange, amber, yellow, cream, warm color cast or saturated colors anywhere.
Constraints: preserve every shape, layout, scale, and optical centering. Do not add details or text. Single icon only. Genuine alpha transparency outside the tile, clean antialiased boundary, no checkerboard, no background surface or backdrop, no colored specks outside the tile.
```

## 透明背景编辑提示词（依次执行）

```text
Use case: background-extraction. Remove the checkerboard background from this graphite gray and silver-white macOS icon. Deliver an actual transparent PNG cutout. Every pixel outside the dark rounded-square tile must be fully transparent (alpha zero), including the corners and margins. Preserve all content inside the dark tile exactly, including the silver paper, folded corner, gray reading strokes, scale, layout and shading. No recoloring or redesign. No drawn checkerboard; no background color. One icon with real alpha transparency and clean edges.
```

```text
Make the background transparent. Isolate the graphite rounded-square app icon with its silver-white document. Remove the gray checkerboard completely. Return transparent PNG.
```

## 初始造型生成提示词（随后以上面的提示词改为石墨灰）

```text
Use case: logo-brand
Asset type: final production macOS application icon for PDFLite, a lightweight native academic PDF reader.
Primary request: redesign an unattractive plain white document icon into a beautifully crafted, restrained, memorable native Mac app icon. Generate ONE icon, no presentation board.
Subject: a single centered ivory paper sheet, upright portrait proportions, with an elegant folded upper-right corner. Three short horizontal reading strokes are integrated on the sheet, with one warm golden-yellow highlighted passage. Strong simple silhouette readable at 32px. The paper should feel light, with subtle sculpted edges and a soft short contact shadow.
Scene/backdrop: a rich warm amber-to-orange rounded square icon tile, exceptionally smooth continuous corners, gentle tonal depth, using the warm highlighter accent of the existing product as its identity. True transparent background OUTSIDE the rounded tile, not white and not checkerboard.
Style/medium: sophisticated macOS app icon, precision geometry, softly dimensional matte materials, restrained tactile paper, impeccably clean, front-facing, no isometric tilt. Not a photo or mockup.
Composition/framing: square 1024x1024 canvas; rounded tile occupies about 84% of the canvas (roughly x=82 to 942 and y=82 to 942), centered with equal transparent margins. White document dominates the center at roughly 48% canvas width and 60% canvas height. Balanced optical centering and generous breathing room.
Lighting/mood: soft upper-left studio light, subtle warm shading, crisp legible forms without plastic gloss.
Text: NONE. No letters, no words, no PDF label, no tiny text.
Constraints: single finished icon only, transparent outer corners and margins, no border around the canvas, no watermark, no pens, no magnifying glass, no sparkles, no extra symbols, no busy ornamental details, no long cast shadows. The folded corner and highlighted reading line are the only meaningful details.
```
