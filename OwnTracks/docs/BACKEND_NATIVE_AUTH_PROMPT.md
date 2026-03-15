# Backend: Native OAuth callback for embedded iOS app

Use this prompt when implementing or updating the backend so the iOS app can pass an OAuth access token into the web session.

---

## How the iOS app uses this endpoint

After completing native OIDC via `ASWebAuthenticationSession` (system browser sheet), the iOS app loads `/auth/native-callback?access_token=<JWT>` **directly inside the `WKWebView`**. It does **not** use `NSURLSession` to call this endpoint.

This is the key architectural constraint: the WebView's HTTP request machinery runs in a separate OS process (the WebContent process). Cookies received as `Set-Cookie` response headers from a request *made by the WebView* are stored directly in the WebContent process — no cross-process sync required. The very next navigation (your redirect to `/map`) therefore carries the session cookie.

Any approach that involves native code fetching the token exchange endpoint and injecting the cookie into `WKHTTPCookieStore` suffers from an unavoidable synchronization lag between the UI process and the WebContent process, causing the `/map` request to arrive without the cookie.

---

## Contract

### Endpoint

**`GET /auth/native-callback?access_token=<JWT>`**

- Same host (and path base, if any) as the web app (e.g. `https://sauron-dev.example.com/auth/native-callback`).

### Required behavior

1. **Validate** `access_token` against your IdP or via token introspection. If invalid or missing, return 401 or redirect to your login/error page.
2. **Set the session cookie** on the response:
   - `Set-Cookie: <your-session-cookie>=...; Path=/; Secure; HttpOnly; SameSite=Lax`
   - Omit `Domain` or set it to the exact request host.
3. **Redirect to `/map`** — the redirect *must* come in the same HTTP response that carries `Set-Cookie`, so the WebView stores the cookie before it fetches `/map`.

### Recommended response: 302 redirect

```
HTTP/1.1 302 Found
Location: /map
Set-Cookie: .AspNetCore.Session=<value>; Path=/; Secure; HttpOnly; SameSite=Lax
```

This is the simplest and most reliable option. The WebView receives `Set-Cookie`, stores the cookie, then follows the `Location` header to `/map` — all within the same WebContent process, no timing issues.

### Alternative response: 200 with immediate JavaScript redirect

If a 302 is inconvenient (e.g. your framework always writes a body), return 200 with an **immediate** JavaScript redirect. Do **not** use a timed delay — the SPA must not initialize before the redirect fires:

```html
HTTP/1.1 200 OK
Set-Cookie: .AspNetCore.Session=<value>; Path=/; Secure; HttpOnly; SameSite=Lax
Content-Type: text/html

<!DOCTYPE html>
<html><head>
  <script>window.location.replace('/map');</script>
</head><body></body></html>
```

> **Do not** use `<meta http-equiv="refresh" content="2;url=/map">` with a delay, and do not load your React/SPA bundle on this page. If the SPA initializes before the redirect, it will check auth state, find no session, and redirect to the IdP — losing the cookie before `/map` is ever loaded.

### What to avoid

| Pattern | Why it fails |
|---|---|
| `meta-refresh` with delay ≥ 1 s | SPA JS runs, checks auth, redirects to IdP before cookie is sent to `/map` |
| Return 200 + full SPA bundle | Same: SPA initializes, re-checks auth, cookie never reaches `/map` |
| Native `NSURLSession` fetch + `WKHTTPCookieStore` injection | Cross-process sync lag; WebView makes the `/map` request before the cookie arrives |

---

## Verification with curl

1. Get a valid `access_token` from the iOS app logs or your IdP.
2. Test the endpoint:
   ```bash
   curl -v -L -c cookies.txt "https://YOUR_HOST/auth/native-callback?access_token=VALID_TOKEN"
   ```
   - Must set a `Set-Cookie` header and follow through to `/map` returning **200** with app content.
3. Test a subsequent authenticated request:
   ```bash
   curl -v -b cookies.txt "https://YOUR_HOST/map"
   ```
   - Must return **200** with app content, **not** 302 to the IdP.

---

## Summary

| Item | Requirement |
|------|-------------|
| URL | `GET /auth/native-callback?access_token=<JWT>` |
| Validation | Validate token; 401/redirect if invalid |
| Cookie | `Set-Cookie`, `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax` |
| Redirect | 302 to `/map` (preferred) **or** 200 + `window.location.replace('/map')` |
| Redirect timing | Immediate — no delay, no SPA initialization on this page |
| Redirect target | Same origin (e.g. `/map`), never to the IdP |
