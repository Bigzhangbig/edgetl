🧪 **Add initial test suite using Vitest for _worker.js**

🎯 **What:** The repository lacked any automated tests to verify the functionality of `_worker.js`. Setting up the initial testing framework establishes a strong foundation.

📊 **Coverage:**
- Added a `worker.test.js` file leveraging Vitest framework
- Polyfilled Node `crypto` module to simulate Cloudflare Workers `crypto.subtle` API natively
- Added tests verifying:
  - `_worker.js` properly exports the `fetch` function
  - The fallback/base route routing safely replies with `text/html` without crashing
  - The configuration parsing (specifically `HOST` arrays) processes correctly and handles environment configuration safely

✨ **Result:**
- A simple, reliable command `npm test` has been added
- Ensures foundational parts of the Cloudflare Worker don't crash when refactoring
- Gives the repo an official test foundation that other developers can add more coverage onto
