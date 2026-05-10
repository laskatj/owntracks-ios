//
//  BluetoothHeartRateManager.m
//  OwnTracks
//
//  Copyright © 2025 OwnTracks. All rights reserved.
//

#import "BluetoothHeartRateManager.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

NSNotificationName const OTBluetoothHeartRateDidUpdateNotification = @"OTBluetoothHeartRateDidUpdateNotification";

// Heart Rate Service and Measurement characteristic UUIDs (Bluetooth SIG).
static NSString * const kHeartRateServiceUUID        = @"180D";
static NSString * const kHeartRateMeasurementUUID    = @"2A37";

// Readings older than this are not reported (nil is returned instead).
static const NSTimeInterval kHeartRateMaxAge = 30.0;

// CBCentralManager restoration identifier for background BLE state restoration.
static NSString * const kCentralRestoreIdentifier = @"org.owntracks.heartrate";

@interface BluetoothHeartRateManager ()
@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong, nullable) CBPeripheral *heartRatePeripheral;
@property (nonatomic, strong, nullable) NSNumber *_heartRate;
@property (nonatomic, strong, nullable) NSDate *_lastReadingDate;
@property (nonatomic, assign) BOOL scanningRequested;
@end

@implementation BluetoothHeartRateManager

static const DDLogLevel ddLogLevel = DDLogLevelInfo;
static BluetoothHeartRateManager *theInstance = nil;

+ (BluetoothHeartRateManager *)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        theInstance = [[BluetoothHeartRateManager alloc] init];
    });
    return theInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSDictionary *options = @{
            CBCentralManagerOptionRestoreIdentifierKey: kCentralRestoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: @YES
        };
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self
                                                               queue:nil
                                                             options:options];
    }
    return self;
}

#pragma mark - Public API

- (nullable NSNumber *)heartRate {
    if (!self._heartRate || !self._lastReadingDate) {
        return nil;
    }
    if (-self._lastReadingDate.timeIntervalSinceNow > kHeartRateMaxAge) {
        return nil;
    }
    return self._heartRate;
}

- (nullable NSNumber *)heartRateIfSampleWithin:(NSTimeInterval)maxSampleAge {
    if (!self._heartRate || !self._lastReadingDate) {
        return nil;
    }
    if (maxSampleAge <= 0.0) {
        return self._heartRate;
    }
    if (-self._lastReadingDate.timeIntervalSinceNow > maxSampleAge) {
        return nil;
    }
    return self._heartRate;
}

- (nullable NSDate *)lastReadingDate {
    return self._lastReadingDate;
}

- (void)startScanning {
    self.scanningRequested = YES;
    [self _startScanningIfReady];
}

- (void)stopScanning {
    self.scanningRequested = NO;
    if (self.centralManager.isScanning) {
        [self.centralManager stopScan];
        DDLogInfo(@"[BHRM] stopped scan");
    }
    if (self.heartRatePeripheral) {
        [self.centralManager cancelPeripheralConnection:self.heartRatePeripheral];
        self.heartRatePeripheral = nil;
    }
    self._heartRate = nil;
    self._lastReadingDate = nil;
    [self _postHeartRateNotification];
}

- (void)_postHeartRateNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OTBluetoothHeartRateDidUpdateNotification
                                                            object:self];
    });
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    DDLogInfo(@"[BHRM] centralManagerDidUpdateState: %ld", (long)central.state);
    if (central.state == CBManagerStatePoweredOn && self.scanningRequested) {
        [self _startScanningIfReady];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    DDLogInfo(@"[BHRM] discovered peripheral: %@ RSSI:%@", peripheral.name ?: peripheral.identifier.UUIDString, RSSI);
    // Connect to the first heart-rate peripheral found; stop scanning immediately to
    // avoid unnecessary radio use.
    [self.centralManager stopScan];
    self.heartRatePeripheral = peripheral;
    peripheral.delegate = self;
    [self.centralManager connectPeripheral:peripheral options:nil];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    DDLogInfo(@"[BHRM] connected to %@", peripheral.name ?: peripheral.identifier.UUIDString);
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kHeartRateServiceUUID]]];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(nullable NSError *)error {
    DDLogError(@"[BHRM] failed to connect: %@", error.localizedDescription);
    self.heartRatePeripheral = nil;
    // Retry scan after a short delay.
    if (self.scanningRequested) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self _startScanningIfReady];
        });
    }
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(nullable NSError *)error {
    DDLogInfo(@"[BHRM] disconnected from %@ error:%@",
              peripheral.name ?: peripheral.identifier.UUIDString,
              error.localizedDescription);
    self.heartRatePeripheral = nil;
    self._heartRate = nil;
    self._lastReadingDate = nil;
    [self _postHeartRateNotification];
    if (self.scanningRequested) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self _startScanningIfReady];
        });
    }
}

// State restoration: reconnect to any peripheral that was connected before the app was
// suspended.
- (void)centralManager:(CBCentralManager *)central
      willRestoreState:(NSDictionary<NSString *, id> *)dict {
    NSArray<CBPeripheral *> *peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey];
    CBPeripheral *restored = peripherals.firstObject;
    if (restored) {
        DDLogInfo(@"[BHRM] restoring peripheral: %@", restored.identifier.UUIDString);
        self.heartRatePeripheral = restored;
        restored.delegate = self;
        if (restored.state != CBPeripheralStateConnected) {
            [self.centralManager connectPeripheral:restored options:nil];
        } else {
            [restored discoverServices:@[[CBUUID UUIDWithString:kHeartRateServiceUUID]]];
        }
    }
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverServices:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] service discovery error: %@", error.localizedDescription);
        return;
    }
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:kHeartRateServiceUUID]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:kHeartRateMeasurementUUID]]
                                     forService:service];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] characteristic discovery error: %@", error.localizedDescription);
        return;
    }
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kHeartRateMeasurementUUID]]) {
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            DDLogInfo(@"[BHRM] subscribed to Heart Rate Measurement");
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] characteristic update error: %@", error.localizedDescription);
        return;
    }
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kHeartRateMeasurementUUID]]) {
        NSNumber *bpm = [self _parseHeartRateMeasurement:characteristic.value];
        if (bpm) {
            self._heartRate = bpm;
            self._lastReadingDate = [NSDate date];
            DDLogVerbose(@"[BHRM] heart rate: %@ bpm", bpm);
            [self _postHeartRateNotification];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] notification state error: %@", error.localizedDescription);
    }
}

#pragma mark - Private helpers

- (void)_startScanningIfReady {
    if (self.centralManager.state != CBManagerStatePoweredOn) {
        return;
    }
    if (self.heartRatePeripheral) {
        return; // already connected or connecting
    }
    if (self.centralManager.isScanning) {
        return;
    }
    DDLogInfo(@"[BHRM] starting scan for Heart Rate Service");
    [self.centralManager
        scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:kHeartRateServiceUUID]]
        options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

/// Parse the Heart Rate Measurement characteristic value per the Bluetooth GATT spec.
/// Byte 0 is the flags field; bit 0 indicates whether BPM is stored as UInt8 (0) or
/// UInt16 (1).
- (nullable NSNumber *)_parseHeartRateMeasurement:(nullable NSData *)data {
    if (!data || data.length < 2) {
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    uint8_t flags = bytes[0];
    uint16_t bpm;
    if (flags & 0x01) {
        // UInt16 format
        if (data.length < 3) { return nil; }
        bpm = (uint16_t)(bytes[1] | (bytes[2] << 8));
    } else {
        // UInt8 format
        bpm = bytes[1];
    }
    return @(bpm);
}

@end
