# PromptStudio browser capture

This is a Manifest V3 extension for Chrome, Edge, and Arc. It runs the selection overlay locally
and sends only user-approved selections to the bundled `PromptStudioCaptureHost` through Chrome
Native Messaging. The extension does not make network requests.

## Explicit user installation

1. Build or install `PromptStudio.app` so the helper exists at
   `PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost`.
2. In a terminal, run the explicit registration command (replace the path with the installed app):

   ```sh
   export PROMPTSTUDIO_EXTENSION_ID='your-signed-32-character-a-p-extension-id'
   Scripts/register_browser_hosts.sh register \
     "/Applications/PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost"
   ```

   Registration is user-scoped and writes exact-origin manifests to Chrome, Edge, and Arc. The
   app does not register hosts silently. Use `repair` after moving the app or `remove` to uninstall:

   ```sh
   Scripts/register_browser_hosts.sh repair \
     "/Applications/PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost"
   Scripts/register_browser_hosts.sh remove
   ```

   For the checked-in development extension, use the explicit development action instead (it
   does not accept a guessed production/Web Store ID):

   ```sh
   Scripts/register_browser_hosts.sh register-dev \
     "/Applications/PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost"
   ```

3. Open `chrome://extensions`, `edge://extensions`, or Arc's extensions page, enable Developer
   mode, and choose **Load unpacked** for this `BrowserExtension` directory.

The development extension origin is derived from the checked-in public manifest key. Production
registration requires an explicit `PROMPTSTUDIO_EXTENSION_ID` (the 32-character a-p ID supplied by
the signed/Web Store extension); the tooling never guesses or embeds a Web Store ID. Do not replace
an exact origin with `*`.

## Capture behavior

The feed button appears 300ms after a non-empty selection, is 28px, and disappears on scroll,
selection cancellation, or after five seconds. Password fields and restricted pages are ignored.
Clicking the button is the point at which the selected text and page metadata are read. Text over
50,000 characters is rejected in the page before Native Messaging. A successful response from the
app includes a screen-space mouth point; the content script maps it to viewport coordinates and
plays a short local text-flight animation.
