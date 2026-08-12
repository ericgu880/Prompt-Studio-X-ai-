# PromptStudio browser capture

This is a Manifest V3 extension for Chrome, Edge, and Arc. It runs the selection overlay locally
and sends only user-approved selections to the bundled `PromptStudioCaptureHost` through Chrome
Native Messaging. The extension does not make network requests.

## Explicit user installation

1. Build or install `PromptStudio.app` so the helper exists at
   `PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost`.
2. In PromptStudio settings, open **桌宠与网页采集** and explicitly enable **浏览器连接**.
   PromptStudio detects installed supported browsers and writes only their user-scoped manifests.
   Disabling the setting removes PromptStudio's manifests. For development and repair workflows,
   the equivalent terminal command is (replace the path with the installed app):

   ```sh
   export PROMPTSTUDIO_EXTENSION_ID='your-signed-32-character-a-p-extension-id'
   Scripts/register_browser_hosts.sh register \
     "/Applications/PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost"
   ```

   Registration is user-scoped and writes exact-origin manifests to installed Chrome, Edge, or
   Arc browsers. The app does not register hosts until the user enables the setting. Use `repair`
   after moving the app or `remove` to uninstall:

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
   mode, and choose **Load unpacked** for this `BrowserExtension` directory when testing the
   development build. Production users install the separately published Web Store extension;
   release app bundles intentionally do not contain the development-key extension.

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

## Manual release checklist

- Repeat Chrome, Edge, and Arc checks with PromptStudio already open and fully quit; cold launch
  must connect within five seconds without bringing the main window forward.
- Verify confirm, cancel, save failure, hidden-pet silent save/notification, pause for one hour,
  and the optional source-selection clearing behavior.
- Exercise a second display on each side of the primary display, a full-screen Space, Retina and
  non-Retina scaling, and Reduce Motion. The panel must remain visible and never take key focus.
- Confirm password fields, browser-internal pages, empty selections, and 50,001 characters never
  reach persistence; confirm exactly 50,000 characters succeeds.
- Run 100 sequential captures and a rapid second capture while the first confirmation is open.
  The library must contain exactly one item per capture ID, while the second concurrent request
  receives the retryable `pet-busy` result.
- Move the app, toggle browser connection off/on to repair the absolute helper path, then remove
  the connection and verify PromptStudio's manifests are gone from all three browser locations.
