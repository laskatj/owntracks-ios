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
