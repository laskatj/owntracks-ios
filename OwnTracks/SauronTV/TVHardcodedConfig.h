//
//  TVHardcodedConfig.h
//  SauronTV
//
//  Baked-in MQTT credentials for the tvOS target.
//  Fill in the values before building. Do NOT commit real credentials.
//

#pragma once

// MQTT broker host (e.g. @"mqtt.example.com")
static NSString * const kTVMQTTHost      = @"mediahub";

// MQTT broker port (9001 = plain WS, 443/8884 = WSS)
static UInt32     const kTVMQTTPort      = 9001;

// Set YES for TLS (WSS), NO for plain WS
static BOOL       const kTVMQTTTLS       = NO;

// Set YES to connect via WebSocket (MQTT over WS/WSS)
static BOOL       const kTVMQTTWS        = YES;

// Broker credentials
static NSString * const kTVMQTTUser      = @"tomsdevices";
static NSString * const kTVMQTTPassword  = @"$@EAG&22iuia9y";

// Client ID shown in broker logs; must be unique per connected client
static NSString * const kTVMQTTClientId  = @"sauron-tv";

// Topic filter — # matches all levels so we receive both location messages
// (owntracks/user/device) and sub-topic messages like cards
// (owntracks/user/device/info) and events (owntracks/user/device/event).
static NSString * const kTVBaseTopic     = @"owntracks/#";

// Optional OwnTracks Recorder / web app origin for historical route polylines
// (scheme + host + port only, e.g. @"https://recorder.example.com"). Leave empty
// @"" to skip REST and draw only MQTT-accumulated points while a friend is selected.
static NSString * const kTVWebAppOriginURL = @"https://sauron.tlaska.com/";

// OAuth access token for GET /api/location/history/.../route (same as iOS Bearer).
// If non-empty, overrides Keychain / device flow (dev only).
static NSString * const kTVWebAppBearerToken = @"";

// Authentik OIDC discovery (RFC 8628 device flow + refresh). Leave discovery @"" to skip
// OAuth unless kTVWebAppBearerToken is set.
static NSString * const kTVOAuthDiscoveryURL =
    @"https://identity.tlaska.com/application/o/sauron/.well-known/openid-configuration";

// OAuth2 public client id from Authentik application (must allow device authorization grant).
static NSString * const kTVOAuthClientId = @"d8ntY1AOtH6UaYE9QGRfy1AXKmKVH9wmwcl0bSJJ";

// Authentik provider "Client type": Confidential → paste the client secret here (sent on
// device + token POSTs). Public → keep @"". Mismatch (secret required but empty, or wrong
// client_id vs the Authentik application) typically yields invalid_grant on /application/o/token/.
static NSString * const kTVOAuthClientSecret = @"";

// Space-separated scopes; include offline_access for refresh_token when provider allows.
static NSString * const kTVOAuthScope = @"openid profile email offline_access";
