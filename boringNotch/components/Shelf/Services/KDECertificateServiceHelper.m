// KDE Connect certificate construction, migrated from KDE Connect iOS.
// SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only

#import "KDECertificateServiceHelper.h"
#import <openssl/evp.h>
#import <openssl/pkcs12.h>
#import <openssl/x509.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

static NSError *KDECertificateError(NSString *message) {
    return [NSError errorWithDomain:@"theboringteam.boringnotch.kdeconnect"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

NSData *KDECreatePKCS12Identity(NSString *deviceID, NSError **error) {
    EVP_PKEY_CTX *context = NULL;
    EVP_PKEY *key = NULL;
    X509 *certificate = NULL;
    PKCS12 *container = NULL;
    BIO *output = NULL;
    NSData *result = nil;

    context = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
    if (context == NULL || EVP_PKEY_keygen_init(context) != 1 ||
        EVP_PKEY_CTX_set_ec_paramgen_curve_nid(context, NID_X9_62_prime256v1) != 1 ||
        EVP_PKEY_keygen(context, &key) != 1) {
        goto failure;
    }

    certificate = X509_new();
    if (certificate == NULL || X509_set_version(certificate, 2) != 1 ||
        ASN1_INTEGER_set(X509_get_serialNumber(certificate), 10) != 1 ||
        X509_gmtime_adj(X509_get_notBefore(certificate), -31536000) == NULL ||
        X509_gmtime_adj(X509_get_notAfter(certificate), 315360000) == NULL ||
        X509_set_pubkey(certificate, key) != 1) {
        goto failure;
    }

    X509_NAME *name = X509_get_subject_name(certificate);
    if (name == NULL ||
        X509_NAME_add_entry_by_txt(name, "OU", MBSTRING_ASC, (const unsigned char *)"Kde connect", -1, -1, 0) != 1 ||
        X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, (const unsigned char *)"KDE", -1, -1, 0) != 1 ||
        X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)deviceID.UTF8String, -1, -1, 0) != 1 ||
        X509_set_issuer_name(certificate, name) != 1 ||
        X509_sign(certificate, key, EVP_sha512()) == 0) {
        goto failure;
    }

    container = PKCS12_create(NULL, "KDE Connect", key, certificate, NULL, 0, 0, 0, PKCS12_DEFAULT_ITER, 0);
    output = BIO_new(BIO_s_mem());
    if (container == NULL || output == NULL || i2d_PKCS12_bio(output, container) != 1) {
        goto failure;
    }

    char *bytes = NULL;
    const long length = BIO_get_mem_data(output, &bytes);
    if (length <= 0 || bytes == NULL) { goto failure; }
    result = [NSData dataWithBytes:bytes length:(NSUInteger)length];

failure:
    if (result == nil && error != NULL) { *error = KDECertificateError(@"KDE Connect certificate creation failed."); }
    BIO_free(output);
    PKCS12_free(container);
    X509_free(certificate);
    EVP_PKEY_free(key);
    EVP_PKEY_CTX_free(context);
    return result;
}

BOOL KDESendUDPBroadcast(NSData *packet, NSError **error) {
    const int socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketDescriptor < 0) { goto failure; }

    const int enabled = 1;
    if (setsockopt(socketDescriptor, SOL_SOCKET, SO_BROADCAST, &enabled, sizeof(enabled)) != 0) {
        close(socketDescriptor);
        goto failure;
    }

    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(1716);
    destination.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    const ssize_t sent = sendto(socketDescriptor, packet.bytes, packet.length, 0,
                                (const struct sockaddr *)&destination, sizeof(destination));
    close(socketDescriptor);
    if (sent == (ssize_t)packet.length) { return YES; }

failure:
    if (error != NULL) { *error = KDECertificateError(@"KDE Connect UDP broadcast failed."); }
    return NO;
}
