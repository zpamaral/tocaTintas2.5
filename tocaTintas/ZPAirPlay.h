//
//  ZPAirPlay.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 12/11/2024.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZPAirPlay : NSObject

/// An array of discovered AirPlay device names.
@property (nonatomic, strong, readonly) NSArray<NSString *> *discoveredDevices;

- (void)startDiscovery; // Starts the discovery process
- (void)stopDiscovery;  // Stops the discovery process
- (void)cleanupBonjourFile; // Cleans up AirPlay_BonJour.txt on app quit

@property (nonatomic, strong) NSMutableSet<NSString *> *capturedAddresses; // Store unique addresses
@property (nonatomic, strong, readonly) NSString *bonjourFilePath; // Declare bonjourFilePath as readonly

@end

NS_ASSUME_NONNULL_END
