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

// Strict scan uses service UUID 180D in the CoreBluetooth filter. Many chest straps (Polar H6,
// others) do not include 180D in the advertisement packet, so they only appear after we fall
// back to a relaxed scan (no service filter) and match by name / advertised UUIDs.
static const NSTimeInterval kBHRMStrictScanWindowSeconds = 8.0;

/// If a peripheral stays in CBPeripheralStateConnecting (common right after state restore), give up
/// and cancel so scanning can resume instead of blocking on "already have peripheral".
static const NSTimeInterval kBHRMConnectingStallSeconds = 12.0;

// CBCentralManager restoration identifier for background BLE state restoration.
static NSString * const kCentralRestoreIdentifier = @"org.owntracks.heartrate";

static NSString *OT_BHRM_CentralStateString(CBManagerState state) {
    switch (state) {
        case CBManagerStateUnknown: return @"Unknown";
        case CBManagerStateResetting: return @"Resetting";
        case CBManagerStateUnsupported: return @"Unsupported";
        case CBManagerStateUnauthorized: return @"Unauthorized";
        case CBManagerStatePoweredOff: return @"PoweredOff";
        case CBManagerStatePoweredOn: return @"PoweredOn";
        default: return [@(state) description];
    }
}

static NSString *OT_BHRM_PeripheralStateString(CBPeripheralState state) {
    switch (state) {
        case CBPeripheralStateDisconnected: return @"Disconnected";
        case CBPeripheralStateConnecting: return @"Connecting";
        case CBPeripheralStateConnected: return @"Connected";
        case CBPeripheralStateDisconnecting: return @"Disconnecting";
        default: return [@(state) description];
    }
}

@interface BluetoothHeartRateManager ()
@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong, nullable) CBPeripheral *heartRatePeripheral;
@property (nonatomic, strong, nullable) NSNumber *_heartRate;
@property (nonatomic, strong, nullable) NSDate *_lastReadingDate;
@property (nonatomic, assign) BOOL scanningRequested;
/// Incremented on stop (and start) so delayed fallback scans do not run after the user disables scanning.
@property (nonatomic, assign) NSUInteger scanSessionId;
/// After strict scan finds nothing for a while, scan all BLE ads and filter candidates.
@property (nonatomic, assign) BOOL relaxedHRScan;
/// Bumped to invalidate delayed "still Connecting?" watchdog blocks.
@property (nonatomic, assign) NSUInteger connectingWatchdogToken;
/// Map chip / UI: set when connect watchdog fires; cleared on connect, stop, or fresh \c startScanning.
@property (nonatomic, copy, readwrite, nullable) NSString *connectionTroubleHint;
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
        // Keep state restoration for background HR resume. If Connecting stalls persist, try
        // removing CBCentralManagerOptionRestoreIdentifierKey for a cold central each launch.
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

- (BOOL)isHeartRatePeripheralConnected {
    return self.heartRatePeripheral != nil &&
           self.heartRatePeripheral.state == CBPeripheralStateConnected;
}

- (void)setConnectionTroubleHint:(NSString *)connectionTroubleHint {
    NSString *normalized = (connectionTroubleHint.length > 0) ? [connectionTroubleHint copy] : nil;
    if ((_connectionTroubleHint == normalized) ||
        (_connectionTroubleHint && normalized && [_connectionTroubleHint isEqualToString:normalized]) ||
        (!_connectionTroubleHint && !normalized)) {
        return;
    }
    _connectionTroubleHint = normalized;
    [self _postHeartRateNotification];
}

- (void)startScanning {
    [self _invalidateConnectingWatchdog];
    self.connectionTroubleHint = nil;
    // Fresh scan session: cancel any non-connected peripheral (e.g. stuck restore "Connecting")
    // so CoreBluetooth does not keep a stale CBPeripheral reference across retries.
    if (self.heartRatePeripheral != nil &&
        self.heartRatePeripheral.state != CBPeripheralStateConnected) {
        DDLogInfo(@"[BHRM] startScanning: reset non-connected peripheral state=%@ id=%@",
                  OT_BHRM_PeripheralStateString(self.heartRatePeripheral.state),
                  self.heartRatePeripheral.identifier.UUIDString);
        [self.centralManager cancelPeripheralConnection:self.heartRatePeripheral];
        self.heartRatePeripheral = nil;
        self._heartRate = nil;
        self._lastReadingDate = nil;
    }
    self.scanningRequested = YES;
    self.relaxedHRScan = NO;
    self.scanSessionId++;
    NSUInteger session = self.scanSessionId;
    DDLogInfo(@"[BHRM] startScanning session=%lu centralState=%@(%ld) existingPeripheral=%@",
              (unsigned long)session,
              OT_BHRM_CentralStateString(self.centralManager.state),
              (long)self.centralManager.state,
              self.heartRatePeripheral ? self.heartRatePeripheral.identifier.UUIDString : @"(none)");
    DDLogInfo(@"[BHRM] strict scan filters ads by [180D]; many straps omit it—relaxed name/UUID scan after %.0fs if none",
              kBHRMStrictScanWindowSeconds);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBHRMStrictScanWindowSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.scanSessionId != session || !strongSelf.scanningRequested) {
            return;
        }
        if (strongSelf.heartRatePeripheral != nil) {
            return;
        }
        DDLogInfo(@"[BHRM] session=%lu: no connection after strict scan window → relaxed scan (all peripherals, name/UUID filter)",
                  (unsigned long)session);
        strongSelf.relaxedHRScan = YES;
        if (strongSelf.centralManager.isScanning) {
            [strongSelf.centralManager stopScan];
        }
        [strongSelf _startScanningIfReady];
    });
    [self _startScanningIfReady];
}

- (void)stopScanning {
    [self _invalidateConnectingWatchdog];
    self.connectionTroubleHint = nil;
    self.scanningRequested = NO;
    self.relaxedHRScan = NO;
    NSUInteger wasSession = self.scanSessionId;
    self.scanSessionId++;
    DDLogInfo(@"[BHRM] stopScanning session %lu → %lu (invalidate pending fallbacks)",
              (unsigned long)wasSession, (unsigned long)self.scanSessionId);
    if (self.centralManager.isScanning) {
        [self.centralManager stopScan];
        DDLogInfo(@"[BHRM] stopScan: central stopped active scan");
    }
    if (self.heartRatePeripheral) {
        DDLogInfo(@"[BHRM] stopScan: cancelPeripheralConnection name=%@ id=%@ state=%ld",
                  self.heartRatePeripheral.name ?: @"(nil)",
                  self.heartRatePeripheral.identifier.UUIDString,
                  (long)self.heartRatePeripheral.state);
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
    DDLogInfo(@"[BHRM] centralManagerDidUpdateState: %@ (%ld) scanningRequested=%d",
              OT_BHRM_CentralStateString(central.state),
              (long)central.state,
              (int)self.scanningRequested);
    if (central.state == CBManagerStatePoweredOn && self.scanningRequested) {
        [self _startScanningIfReady];
    } else if (self.scanningRequested && central.state != CBManagerStatePoweredOn) {
        DDLogInfo(@"[BHRM] scan deferred: Bluetooth not ready for scanning yet");
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSNumber *connectable = advertisementData[CBAdvertisementDataIsConnectable];
    NSArray *svcUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    NSString *localName = advertisementData[CBAdvertisementDataLocalNameKey];
    DDLogInfo(@"[BHRM] DISCOVER name=%@ id=%@ RSSI=%@ relaxed=%d connectableAdv=%@ localName=%@ svcUUIDs=%@",
              peripheral.name ?: @"(nil)",
              peripheral.identifier.UUIDString,
              RSSI,
              (int)self.relaxedHRScan,
              connectable ?: @"(absent)",
              [localName isKindOfClass:[NSString class]] ? localName : @"(nil)",
              [svcUUIDs isKindOfClass:[NSArray class]] ? svcUUIDs : @"(nil)");
    if (self.relaxedHRScan && ![self _advertisementLooksLikeHeartRateCandidate:advertisementData peripheral:peripheral]) {
        DDLogInfo(@"[BHRM] DISCOVER skip (relaxed filter): not an HR candidate");
        return;
    }
    // Connect to the first matching peripheral; stop scanning immediately to
    // avoid unnecessary radio use.
    [self.centralManager stopScan];
    self.heartRatePeripheral = peripheral;
    peripheral.delegate = self;
    if (connectable && connectable.intValue == 0) {
        DDLogInfo(@"[BHRM] CONNECT note: connectableAdv=0 is common for some chest straps; link may still succeed");
    }
    DDLogInfo(@"[BHRM] CONNECT attempt → peripheral=%@ id=%@ state=%@ (scan stopped)",
              peripheral.name ?: @"(nil)",
              peripheral.identifier.UUIDString,
              OT_BHRM_PeripheralStateString(peripheral.state));
    [self.centralManager connectPeripheral:peripheral options:nil];
    [self _scheduleConnectingWatchdogForPeripheral:peripheral];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    [self _invalidateConnectingWatchdog];
    self.connectionTroubleHint = nil;
    DDLogInfo(@"[BHRM] CONNECTED name=%@ id=%@ state=%@ → discoverServices [180D]",
              peripheral.name ?: @"(nil)",
              peripheral.identifier.UUIDString,
              OT_BHRM_PeripheralStateString(peripheral.state));
    self.relaxedHRScan = NO;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kHeartRateServiceUUID]]];
    [self _postHeartRateNotification];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(nullable NSError *)error {
    [self _invalidateConnectingWatchdog];
    self.connectionTroubleHint = nil;
    DDLogError(@"[BHRM] CONNECT FAILED name=%@ id=%@ err=%@ domain=%@ code=%ld",
                peripheral.name ?: @"(nil)",
                peripheral.identifier.UUIDString,
                error ? error.localizedDescription : @"(nil)",
                error ? error.domain : @"(nil)",
                (long)(error ? error.code : 0));
    self.heartRatePeripheral = nil;
    [self _postHeartRateNotification];
    // Retry scan after a short delay.
    if (self.scanningRequested) {
        DDLogInfo(@"[BHRM] scheduling scan retry in 5s after connect failure");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self _startScanningIfReady];
        });
    }
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(nullable NSError *)error {
    [self _invalidateConnectingWatchdog];
    DDLogInfo(@"[BHRM] DISCONNECTED name=%@ id=%@ err=%@",
              peripheral.name ?: @"(nil)",
              peripheral.identifier.UUIDString,
              error ? error.localizedDescription : @"(none)");
    self.heartRatePeripheral = nil;
    self._heartRate = nil;
    self._lastReadingDate = nil;
    [self _postHeartRateNotification];
    if (self.scanningRequested) {
        DDLogInfo(@"[BHRM] scheduling scan retry in 3s after disconnect");
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
        DDLogInfo(@"[BHRM] STATE RESTORE peripheral=%@ state=%@",
                  restored.identifier.UUIDString,
                  OT_BHRM_PeripheralStateString(restored.state));
        self.heartRatePeripheral = restored;
        restored.delegate = self;
        switch (restored.state) {
            case CBPeripheralStateConnected:
                DDLogInfo(@"[BHRM] RESTORE already connected → discoverServices [180D]");
                [restored discoverServices:@[[CBUUID UUIDWithString:kHeartRateServiceUUID]]];
                break;
            case CBPeripheralStateDisconnected:
                DDLogInfo(@"[BHRM] RESTORE disconnected → CONNECT id=%@ (watchdog %.0fs)",
                          restored.identifier.UUIDString, kBHRMConnectingStallSeconds);
                [self.centralManager connectPeripheral:restored options:nil];
                [self _scheduleConnectingWatchdogForPeripheral:restored];
                break;
            case CBPeripheralStateConnecting:
            case CBPeripheralStateDisconnecting:
                DDLogInfo(@"[BHRM] RESTORE mid-link state=%@ → skip redundant connectPeripheral; watchdog %.0fs",
                          OT_BHRM_PeripheralStateString(restored.state), kBHRMConnectingStallSeconds);
                [self _scheduleConnectingWatchdogForPeripheral:restored];
                break;
            default:
                DDLogInfo(@"[BHRM] RESTORE unknown peripheral state %@ → CONNECT id=%@",
                          OT_BHRM_PeripheralStateString(restored.state), restored.identifier.UUIDString);
                [self.centralManager connectPeripheral:restored options:nil];
                [self _scheduleConnectingWatchdogForPeripheral:restored];
                break;
        }
    }
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverServices:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] GATT discoverServices error: %@", error.localizedDescription);
        return;
    }
    NSMutableString *svcList = [NSMutableString string];
    for (CBService *s in peripheral.services ?: @[]) {
        [svcList appendFormat:@"%@ ", s.UUID.UUIDString];
    }
    DDLogInfo(@"[BHRM] GATT services count=%lu: %@", (unsigned long)peripheral.services.count, svcList);
    BOOL foundHR = NO;
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:kHeartRateServiceUUID]]) {
            foundHR = YES;
            DDLogInfo(@"[BHRM] GATT discoverCharacteristics [2A37] for service 180D");
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:kHeartRateMeasurementUUID]]
                                     forService:service];
        }
    }
    if (!foundHR) {
        DDLogError(@"[BHRM] GATT: Heart Rate service 180D not found on peripheral");
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] characteristic discovery error: %@", error.localizedDescription);
        return;
    }
    DDLogInfo(@"[BHRM] GATT characteristics count=%lu for service %@",
              (unsigned long)service.characteristics.count, service.UUID.UUIDString);
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kHeartRateMeasurementUUID]]) {
            DDLogInfo(@"[BHRM] GATT setNotifyValue YES for 2A37 (Heart Rate Measurement)");
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
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
            DDLogVerbose(@"[BHRM] HR sample: %@ bpm (2A37 notify)", bpm);
            [self _postHeartRateNotification];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(nullable NSError *)error {
    if (error) {
        DDLogError(@"[BHRM] notification state error: %@", error.localizedDescription);
        return;
    }
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kHeartRateMeasurementUUID]]) {
        DDLogInfo(@"[BHRM] NOTIFY state for 2A37: isNotifying=%d err=%@",
                  (int)characteristic.isNotifying,
                  error ? error.localizedDescription : @"(none)");
        if (characteristic.isNotifying) {
            [self _postHeartRateNotification];
        }
    }
}

#pragma mark - Private helpers

- (void)_invalidateConnectingWatchdog {
    self.connectingWatchdogToken++;
}

- (void)_scheduleConnectingWatchdogForPeripheral:(CBPeripheral *)peripheral {
    self.connectingWatchdogToken++;
    NSUInteger token = self.connectingWatchdogToken;
    NSUUID *peripheralId = peripheral.identifier;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBHRMConnectingStallSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.connectingWatchdogToken != token) {
            return;
        }
        CBPeripheral *p = strongSelf.heartRatePeripheral;
        if (!p || ![p.identifier isEqual:peripheralId]) {
            return;
        }
        if (p.state != CBPeripheralStateConnecting) {
            return;
        }
        // Invalidate before cancel so a duplicate watchdog block (same token) exits on token check.
        [strongSelf _invalidateConnectingWatchdog];
        p = strongSelf.heartRatePeripheral;
        if (!p || ![p.identifier isEqual:peripheralId] || p.state != CBPeripheralStateConnecting) {
            return;
        }
        NSString *hint = NSLocalizedString(@"Map heart rate BLE stall hint",
                                           @"Map chip: BLE connect stalled—user may have another app using the strap");
        strongSelf.connectionTroubleHint = hint;
        DDLogError(@"[BHRM] CONNECT stall: still %@ after %.0fs → cancel (resume scan if requested)",
                   OT_BHRM_PeripheralStateString(p.state), kBHRMConnectingStallSeconds);
        [strongSelf.centralManager cancelPeripheralConnection:p];
    });
}

- (void)_startScanningIfReady {
    if (!self.scanningRequested) {
        DDLogInfo(@"[BHRM] scan skipped: scanningRequested=NO");
        return;
    }
    if (self.centralManager.state != CBManagerStatePoweredOn) {
        DDLogInfo(@"[BHRM] scan skipped: central not PoweredOn (is %@)",
                  OT_BHRM_CentralStateString(self.centralManager.state));
        return;
    }
    if (self.heartRatePeripheral) {
        CBPeripheralState st = self.heartRatePeripheral.state;
        if (st == CBPeripheralStateConnected || st == CBPeripheralStateConnecting ||
            st == CBPeripheralStateDisconnecting) {
            DDLogInfo(@"[BHRM] scan skipped: already have peripheral id=%@ state=%@",
                      self.heartRatePeripheral.identifier.UUIDString,
                      OT_BHRM_PeripheralStateString(st));
            return;
        }
        if (st == CBPeripheralStateDisconnected) {
            DDLogInfo(@"[BHRM] clearing stale disconnected peripheral before scan id=%@",
                      self.heartRatePeripheral.identifier.UUIDString);
            self.heartRatePeripheral = nil;
        }
    }
    if (self.centralManager.isScanning) {
        DDLogInfo(@"[BHRM] scan skipped: central already scanning");
        return;
    }
    NSArray<CBUUID *> *serviceFilter = self.relaxedHRScan ? nil : @[[CBUUID UUIDWithString:kHeartRateServiceUUID]];
    DDLogInfo(@"[BHRM] SCAN start relaxed=%d serviceFilter=%@ allowDuplicates=NO",
              (int)self.relaxedHRScan,
              serviceFilter ? @"[180D]" : @"nil(all BLE)");
    [self.centralManager scanForPeripheralsWithServices:serviceFilter
                                                options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    DDLogInfo(@"[BHRM] SCAN issued to CoreBluetooth");
}

/// When \c relaxedHRScan is YES we use \c scanForPeripheralsWithServices:nil — only connect if this returns YES.
- (BOOL)_advertisementLooksLikeHeartRateCandidate:(NSDictionary<NSString *, id> *)advertisementData
                                       peripheral:(CBPeripheral *)peripheral {
    NSArray *uuidObjs = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if ([uuidObjs isKindOfClass:[NSArray class]]) {
        CBUUID *hr = [CBUUID UUIDWithString:kHeartRateServiceUUID];
        for (CBUUID *u in uuidObjs) {
            if ([u isEqual:hr]) {
                return YES;
            }
        }
    }
    NSString *local = advertisementData[CBAdvertisementDataLocalNameKey];
    if (![local isKindOfClass:[NSString class]] || local.length == 0) {
        local = peripheral.name;
    }
    if (![local isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *ln = local.lowercaseString;
    static NSArray<NSString *> *needles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        needles = @[
            @"polar", @"garmin", @"wahoo", @"coospo", @"tickr", @"h10", @"h9", @"hrm",
            @"heart rate", @"heartrate", @"rhythm", @"chest", @"strap"
        ];
    });
    for (NSString *n in needles) {
        if ([ln containsString:n]) {
            return YES;
        }
    }
    return NO;
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
