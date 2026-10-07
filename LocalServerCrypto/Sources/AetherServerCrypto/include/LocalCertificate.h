#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
NSDictionary<NSString *, NSData *> * _Nullable aether_create_local_certificate(NSData * _Nullable issuerDER, NSData * _Nullable issuerPEM);
bool aether_validate_local_certificate(NSData * _Nonnull der, NSData * _Nonnull keyPEM, NSData * _Nullable issuerDER, bool root, long remainingSeconds);
#ifdef __cplusplus
}
#endif
