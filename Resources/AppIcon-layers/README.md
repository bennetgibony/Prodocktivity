# App icon layers (for Icon Composer)

Made by `swift scripts/make-icon.swift <folder>`; the app itself uses `Resources/AppIcon.icns`, built
from the same drawing (light look only, since an .icns has one look).

To make a layered `.icon` (needs Icon Composer, which comes with Xcode):

1. Open Icon Composer, File › New, canvas 1024.
2. Background: a gradient fill. Default (light) #8E96E7 at the top to #6264DC at the bottom;
   Dark #343450 to #232331 (or drop in background-light.png / background-dark.png).
3. Add `glyph.svg` (two groups: `bar` and `window`). Put the window in its own layer at 50 % opacity.
   Glyph color white in Default, #E8EBFD in Dark.
4. Leave glass, lighting and shadow to the system; check Default, Dark, Clear and Tinted.
5. Save as `Resources/AppIcon.icon`. Turning it into the app's icon needs Xcode's `actool`
   (the Command Line Tools can't), so until then the .icns stays in use.
