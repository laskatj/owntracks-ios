# Backend: Native OAuth callback for embedded iOS app

Use this prompt when implementing or updating the backend so the iOS app can pass an OAuth access token into the web session.

---

## Contract

### Endpoint

**`GET /auth/native-callback?access_token=<JWT>`**

- Same host (and path base, if any) as the web app (e.g. `https://sauron-dev.tlaska.com/auth/native-callback`).
- The iOS app obtains `access_token` via ASWebAuthenticationSession + PKCE and then either loads this URL in a WebView or has the web app call it (same origin).

### Required behavior

1. **Validate** `access_token` (e.g. with your IdP or token introspection). If invalid or missing, return 401 or 302 to your login/error page.
2. **Set the session cookie** on the response:
   - One `Set-Cookie` header with your session cookie (e.g. `.AspNetCore.NativeSession` or your app’s session cookie name).
   - Attributes: `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax`.
   - Omit `Domain` or set it to the request host so the cookie applies to the same origin.
3. **Respond with HTTP 200** (not 302) so the client can read headers and body.

### Response body (choose one)

**Option A – Redirect page (typical)**  
Return HTML that redirects to the app after a short delay so the browser has time to store the cookie before the next request:

```html
<!DOCTYPE html>
<html>
<head>
  <meta http-equiv="refresh" content="2;url=/map">
</head>
<body>Signing you in...</body>
</html>
```

- Use a delay of **at least 1–2 seconds** (e.g. `content="2;url=/map"` or `setTimeout(..., 2000)`).  
- `url` must be **same-origin** (e.g. `/map` or `https://your-host/map`), not the IdP.

**Option B – One-shot (recommended for iOS)**  
Return the **same HTML your app serves for `/map`** (e.g. your SPA shell) in the response body, still with `Set-Cookie` on this response. Then the client does not need a second request to load the app; the single response sets the cookie and delivers the page, which avoids iOS WKWebView not sending the cookie on the next navigation.

- Status: **200**
- Headers: `Set-Cookie` as above, plus your normal `Content-Type: text/html`, etc.
- Body: the same HTML you would return for `GET /map` when the user is authenticated (or at least the same SPA shell).

### Verification with curl

1. Get a valid `access_token` (e.g. from the iOS app logs or your IdP).
2. Run:
   ```bash
   curl -v -c cookies.txt "https://YOUR_HOST/auth/native-callback?access_token=VALID_TOKEN"
   ```
   - Must return **200** and a **Set-Cookie** header with `Path=/`.
3. Then:
   ```bash
   curl -v -b cookies.txt "https://YOUR_HOST/map"
   ```
   - Must return **200** with app content, **not** 302 to the IdP.

### Optional: SPA shell for unauthenticated `/map`

If **`GET /map`** (or your app root) returns **200** with your SPA shell even when there is no session cookie (and the SPA then shows login or redirects client-side), the iOS app can use a “token in fragment” flow: it loads `https://YOUR_HOST/map#access_token=...`, and the page (or an injected script) calls `GET /auth/native-callback?access_token=...` and then navigates to `/map`. That flow relies on the first request to `/map` not being redirected to the IdP.

---

## Summary

| Item | Requirement |
|------|-------------|
| URL | `GET /auth/native-callback?access_token=<JWT>` |
| Validation | Validate token; 401/302 if invalid |
| Cookie | One `Set-Cookie`, `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax` |
| Status | 200 |
| Body | Option A: HTML with delayed same-origin redirect to `/map` (delay ≥ 1–2 s). Option B: Same HTML as authenticated `/map` (one-shot). |
| Redirect target | Same origin only (e.g. `/map`), never to the IdP in this response |

Implement the above so the embedded iOS app can complete native OAuth and land the user in the web app with a valid session.
