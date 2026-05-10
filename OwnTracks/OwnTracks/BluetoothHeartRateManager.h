//
//  BluetoothHeartRateManager.h
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

FOUNDATION_EXPORT NSNotificationName _Nonnull const OTBluetoothHeartRateDidUpdateNotification;

NS_ASSUME_NONNULL_BEGIN

/// Discovers and maintains a BLE connection to a peripheral with the standard Heart
/// Rate Service (UUID 0x180D). Starts with a filtered scan (device must advertise
/// 0x180D); if nothing connects within a short window, falls back to a broader scan
/// and only connects to likely HR candidates (e.g. advertised 0x180D or common strap
/// name prefixes). There is no in-app device picker—the first matching peripheral wins.
///
/// Readings older than 30 s are considered stale and treated as unavailable.
@interface BluetoothHeartRateManager : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>

+ (BluetoothHeartRateManager *)sharedInstance;

/// Most recently received heart rate in beats per minute, or nil if unavailable / stale.
@property (nonatomic, readonly, nullable) NSNumber *heartRate;

/// Like \c heartRate but allows samples up to \p maxSampleAge seconds old.
- (nullable NSNumber *)heartRateIfSampleWithin:(NSTimeInterval)maxSampleAge
    NS_SWIFT_NAME(heartRateIfSample(within:));

/// Timestamp of the most recent reading, or nil if no reading has been received.
@property (nonatomic, readonly, nullable) NSDate *lastReadingDate;

/// YES when a peripheral is in \c CBPeripheralStateConnected (GATT session active).
@property (nonatomic, readonly) BOOL isHeartRatePeripheralConnected;

/// Localized short message when a BLE connect attempt stalled (e.g. strap busy); nil otherwise.
@property (nonatomic, readonly, nullable) NSString *connectionTroubleHint;

/// Start scanning for a heart rate peripheral.  Safe to call multiple times.
- (void)startScanning;

/// Stop scanning and disconnect from the current peripheral.
- (void)stopScanning;

@end

NS_ASSUME_NONNULL_END
