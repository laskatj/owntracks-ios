//
//  TVHardcodedConfig.h
//  SauronTV
//
//  Baked-in MQTT credentials for the tvOS target.
//  Fill in the values before building. Do NOT commit real credentials.
//

#pragma once

// MQTT broker host (e.g. @"mqtt.example.com")
static NSString * const kTVMQTTHost      = @"YOUR_MQTT_HOST";

// MQTT broker port (8883 = TLS, 1883 = plain)
static UInt32     const kTVMQTTPort      = 8883;

// Set YES for TLS, NO for plain TCP
static BOOL       const kTVMQTTTLS       = YES;

// Broker credentials
static NSString * const kTVMQTTUser      = @"YOUR_MQTT_USER";
static NSString * const kTVMQTTPassword  = @"YOUR_MQTT_PASSWORD";

// Client ID shown in broker logs; must be unique per connected client
static NSString * const kTVMQTTClientId  = @"sauron-tv";

// Topic filter — subscribes to all users and devices
static NSString * const kTVBaseTopic     = @"owntracks/+/+";
