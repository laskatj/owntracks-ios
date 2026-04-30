# Prompt: React Web App – Embedded in Mobile App & Provisioning

Use this prompt (or adapt it) when implementing your React web app so it is aware of the OwnTracks/Sauron iOS app embedding and can send configuration back to the app.

---

## Prompt

**Context:** This React app can be opened in a browser or embedded inside a native iOS app (Sauron/OwnTracks) via a WKWebView. When embedded, the native app may ask for a “provisioning” JSON so it can configure its MQTT/HTTP connection (host, credentials, topics, etc.) without the user typing everything in the app’s Settings.

**Requirements:**

1. **Detect when running inside the mobile app**
   - The page is loaded with query parameters set by the app:
     - `embedded=1` – always present when loaded in the app’s WebView.
     - `needs_provision=1` – present when the app is not yet provisioned (no valid connection config). Use this to decide whether to prompt or auto-offer provisioning after login.
   - Additionally, you can detect the WebView by checking for the native bridge:  
     `typeof window.webkit !== 'undefined' && window.webkit.messageHandlers && window.webkit.messageHandlers.owntracks`

2. **Expose a way to send configuration to the app**
   - When the user is authenticated (e.g. after OIDC login), if `needs_provision=1` is in the URL (or the user taps “Send config to app” / “Provision device”), fetch the provisioning JSON from your backend (the same format the app expects: `_type: "configuration"`, plus `mode`, `host`, `deviceId`, `tid`, `clientId`, `subTopic`, `pubTopicBase`, `sub`, etc.).
   - **Strict native contract:** The object you pass as `configuration` in `postMessage` is passed verbatim to iOS `Settings.fromDictionary`. That API **requires** top-level `"_type": "configuration"`. The native app does **not** add or fix `_type` for you. Omitting it surfaces a configuration error in the app. The same object (including `_type`) must be used for the redirect fallback’s `JSON.stringify(provisioningJson)` / `inline` payload. If you use a hook such as `useEmbeddedProvisioning`, ensure tests cover both the happy path and missing `_type` (should not ship).
   - Send that config to the native app in one of two ways:
     - **Preferred (in-app):**  
       `window.webkit.messageHandlers.owntracks.postMessage({ type: "config", configuration: provisioningJson })`  
       where `provisioningJson` is the object (not a string), and `provisioningJson._type === "configuration"`. Only call this when `window.webkit?.messageHandlers?.owntracks` exists.
     - **Fallback (redirect):**  
       `window.location = "sauron:///config?inline=" + btoa(unescape(encodeURIComponent(JSON.stringify(provisioningJson))))`  
       (Use `owntracks` instead of `sauron` if the app only registers the owntracks scheme.)

3. **UX when embedded and needs_provision=1**
   - After successful login, if the URL has `needs_provision=1` and the bridge is available, show a short message like “This device isn’t configured yet. Send config from your account?” with a “Provision this device” (or “Send config”) button that triggers the fetch + postMessage (or redirect) above.
   - Optionally, you can auto-trigger the provisioning flow once after login when `needs_provision=1` and the bridge is present, with a one-line confirmation.

4. **Provisioning JSON shape**
   - The app expects an object that `Settings.fromDictionary` accepts, e.g.:
     - `_type: "configuration"`
     - `mode`: 0 (MQTT) or 1 (HTTP)
     - `host`, `deviceId`, `tid`, `clientId`, `subTopic`, `pubTopicBase`
     - `sub`: true (so the app receives waypoints etc.)
     - Plus other keys as needed (port, tls, user, password, etc.). Your backend should return this structure for the authenticated user/device.

5. **Don’t break normal browser usage**
   - If `embedded` or the WebView bridge is not present, do not show “Provision device” or rely on postMessage. Only use the redirect fallback when you know the app has registered a custom scheme (e.g. after redirect back from OIDC, you might still be in the WebView).

**Implementation notes:**
- Parse `window.location.search` or use `URLSearchParams` to read `embedded` and `needs_provision`.
- Guard all `window.webkit.messageHandlers.owntracks` usage with a check that it exists before calling `postMessage`.
- For the redirect, use the same scheme the app registers (sauron or owntracks). Base64-encode the JSON string for the `inline` query parameter.

Implement the above so the React app is aware of the mobile embedding, respects the `needs_provision` hint, and can send the provisioning config back to the app when appropriate.
