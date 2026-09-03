const fs = require('fs');
const path = require('path');

/**
 * Resolve a Chromium binary that is already present on this machine.
 * Set PLAYWRIGHT_CHROMIUM_EXECUTABLE to point at one explicitly, or let this
 * pick up a pre-provisioned build under PLAYWRIGHT_BROWSERS_PATH (e.g. CI
 * images that ship browsers instead of running `npx playwright install`).
 * Returns undefined when nothing is found, so Playwright uses its own download.
 */
function findChromium() {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE) {
    return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
  }
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!root || !fs.existsSync(root)) return undefined;
  return fs
    .readdirSync(root)
    .filter((name) => /^chromium-\d+$/.test(name))
    .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]))
    .map((name) => path.join(root, name, 'chrome-linux', 'chrome'))
    .find((p) => fs.existsSync(p));
}

module.exports = { findChromium };
