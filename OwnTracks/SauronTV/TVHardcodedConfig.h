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
static NSString * const kTVMQTTUser      = @"laskatj";
static NSString * const kTVMQTTPassword  = @"abelard9";

// Client ID shown in broker logs; must be unique per connected client
static NSString * const kTVMQTTClientId  = @"sauron-tv";

// Topic filter — subscribes to all users and devices
static NSString * const kTVBaseTopic     = @"owntracks/+/+";
