// Renders scripts/og-image.html into the link preview cards site/assets/og.png (Japanese) and og-en.png.
//
//   node scripts/make-og-image.mjs
//
// Needs Playwright with Chromium (`npm i -g playwright && npx playwright install chromium`, or one already on
// the machine). The card uses the system font, so render it on a Mac to get Hiragino Sans. Elsewhere, set
// OG_FONT_DIR to a folder of Noto Sans JP woff2 files (the @fontsource/noto-sans-jp package's files/).
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Resolved through require so a globally installed Playwright works without a package.json here.
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = pathToFileURL(join(root, "scripts/og-image.html")).href;

function fontFaces(dir) {
    return readdirSync(dir)
        .map((name) => name.match(/^noto-sans-jp-(japanese|latin)-(\d+)-normal\.woff2$/))
        .filter(Boolean)
        .map(
            ([name, , weight]) =>
                `@font-face { font-family: "Noto Sans JP"; font-weight: ${weight}; ` +
                `src: url("${pathToFileURL(join(dir, name)).href}"); }`,
        )
        .join("\n");
}

const browser = await chromium.launch();
try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
    for (const [hash, out] of [
        ["", "site/assets/og.png"],
        ["#en", "site/assets/og-en.png"],
    ]) {
        await page.goto(source + hash);
        if (hash) await page.reload();
        if (process.env.OG_FONT_DIR) {
            await page.addStyleTag({ content: fontFaces(process.env.OG_FONT_DIR) });
            // Forces the injected faces to win over a system fallback picked before they loaded.
            await page.addStyleTag({ content: `:root { --sans: "Noto Sans JP", sans-serif; }` });
        }
        await page.evaluate(() => document.fonts.ready);
        await page.screenshot({ path: join(root, out) });
        console.log(`Wrote ${out}`);
    }
} finally {
    await browser.close();
}
