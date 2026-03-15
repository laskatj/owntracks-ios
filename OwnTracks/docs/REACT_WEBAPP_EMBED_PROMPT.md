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
   - Send that config to the native app in one of two ways:
     - **Preferred (in-app):**  
       `window.webkit.messageHandlers.owntracks.postMessage({ type: "config", configuration: provisioningJson })`  
       where `provisioningJson` is the object (not a string). Only call this when `window.webkit?.messageHandlers?.owntracks` exists.
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

6. **Native OAuth/OIDC (optional but recommended for embedded auth)**
   - When embedded, the app can perform login via **ASWebAuthenticationSession** (system browser sheet) with **PKCE**, so users get passkeys and system credential UI instead of in-WebView login.
   - The app discovers auth config from: **`GET [webAppOrigin]/.well-known/owntracks-app-auth`** (JSON). Your backend should serve this with:
     - `authorization_endpoint` – full URL of the OAuth2/OIDC authorization endpoint
     - `token_endpoint` – full URL of the token endpoint
     - `client_id` – OAuth client id (public client, no secret; PKCE is used)
     - `scope` – optional (e.g. `"openid profile"`)
     - `login_path` – optional path that indicates "login page" (e.g. `"/login"` or `"/auth"`); when the WebView would load this URL, the app intercepts and opens the native auth sheet instead
   - The app uses **redirect URI** `owntracks:///auth/callback` (register this with your IdP). After the user signs in, the app exchanges the authorization code for tokens (PKCE: `code_challenge` / `code_verifier`).
   - To pass the session into the WebView, the app loads **`GET [webAppOrigin]/auth/native-callback?access_token=...`** in the WebView (standard browser flow). Your backend must validate the token, set the session cookie, then send the user to the app. **Recommended (200 + HTML redirect):** Respond with **HTTP 200**, **Set-Cookie** on that response, and a minimal HTML body that redirects to the app. **Use a short delay (e.g. 1 second) before redirecting** so WKWebView has time to commit the cookie; an immediate redirect (`content="0;url=/map"`) often results in the `/map` request being sent before the cookie is stored, so the server redirects to login again. Example: `<!DOCTYPE html><html><head><meta http-equiv="refresh" content="1;url=/map"></head><body>Signing you in...</body></html>` or use JavaScript: `<script>setTimeout(function(){ window.location.href='/map'; }, 800);</script>` with a "Signing you in..." message.
     - **Validate** the `access_token` (e.g. with your IdP or introspect it).
     - **Set-Cookie** on the response with: `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax`; omit `Domain` or set it to the request host so the cookie applies to the same origin.
     - **Redirect target** must be **same-origin** (e.g. `/map` or `https://sauron-dev.tlaska.com/map`). If you redirect to another origin (e.g. the IdP), the cookie will not be sent and the user will see the IdP again.
     - **Alternative:** If you prefer a single round-trip, you can try **303 See Other** with `Set-Cookie` and `Location: /map`; some clients handle 303 better than 302. If the embedded app still lands on the IdP after login, switch to the 200 + HTML redirect approach above.
     - **Backend verification:** The app may request the callback URL itself (not in the WebView), read `Set-Cookie` from the response, inject it into the WebView, then load the app URL. Ensure the callback returns **HTTP 200** (not 302) with exactly one **Set-Cookie** header whose **Path=/** (so the cookie is sent for `/map`). Verify with curl: (1) `curl -v -c cookies.txt "https://YOUR_HOST/auth/native-callback?access_token=VALID_TOKEN"` — must return 200 with Set-Cookie; (2) `curl -v -b cookies.txt "https://YOUR_HOST/map"` — must return 200 (app content), not 302 to the IdP.
     - **iOS WKWebView:** On iOS, the embedded app may load the web app URL with the token in the fragment (e.g. `https://YOUR_HOST/map#access_token=...`) and inject a script that fetches `GET /auth/native-callback?access_token=...` (same origin, so the response’s `Set-Cookie` is stored) then navigates to `/map`. If your server returns **200 for `/map` without a cookie** (e.g. SPA shell), this flow works; if `/map` redirects unauthenticated users to the IdP, the native app will intercept that and the user can log in again.
   - If `/.well-known/owntracks-app-auth` is not available or discovery fails, the app falls back to loading the web app as before (in-WebView login remains possible).

**Implementation notes:**
- Parse `window.location.search` or use `URLSearchParams` to read `embedded` and `needs_provision`.
- Guard all `window.webkit.messageHandlers.owntracks` usage with a check that it exists before calling `postMessage`.
- For the redirect, use the same scheme the app registers (sauron or owntracks). Base64-encode the JSON string for the `inline` query parameter.
- For native auth: implement `/.well-known/owntracks-app-auth` and `/auth/native-callback` on your backend; register `owntracks:///auth/callback` as a valid redirect URI with your OAuth2/OIDC provider and enable PKCE (code_challenge_method S256).

Implement the above so the React app is aware of the mobile embedding, respects the `needs_provision` hint, and can send the provisioning config back to the app when appropriate.
