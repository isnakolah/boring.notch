#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates KDE Connect's persistent TLS identity payload. The caller imports
/// it through Security so Network.framework receives a real P-256 identity.
FOUNDATION_EXPORT NSData * _Nullable KDECreatePKCS12Identity(NSString *deviceID, NSError **error);

/// Sends discovery through an actual IPv4 broadcast socket. Network.framework
/// does not enable SO_BROADCAST, so packets addressed to 255.255.255.255 can
/// remain local instead of reaching Android KDE Connect listeners.
FOUNDATION_EXPORT BOOL KDESendUDPBroadcast(NSData *packet, NSError **error);

NS_ASSUME_NONNULL_END
