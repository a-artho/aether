#import "include/LocalCertificate.h"
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/rand.h>
#include <memory>

namespace {
using Key = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;
using Cert = std::unique_ptr<X509, decltype(&X509_free)>;
using Bio = std::unique_ptr<BIO, decltype(&BIO_free)>;

Cert readCert(NSData *data) {
    if (!data || data.length > 1024 * 1024) return Cert(nullptr, X509_free);
    const unsigned char *p = static_cast<const unsigned char *>(data.bytes);
    return Cert(d2i_X509(nullptr, &p, static_cast<long>(data.length)), X509_free);
}
Key readKey(NSData *data) {
    if (!data || data.length > 1024 * 1024) return Key(nullptr, EVP_PKEY_free);
    Bio bio(BIO_new_mem_buf(data.bytes, static_cast<int>(data.length)), BIO_free);
    return Key(bio ? PEM_read_bio_PrivateKey(bio.get(), nullptr, nullptr, nullptr) : nullptr, EVP_PKEY_free);
}
NSData *bioData(BIO *bio) {
    char *p = nullptr;
    long count = BIO_get_mem_data(bio, &p);
    return count > 0 ? [NSData dataWithBytes:p length:static_cast<NSUInteger>(count)] : nil;
}
bool extension(X509 *cert, X509 *issuer, int nid, const char *value) {
    X509V3_CTX context;
    X509V3_set_ctx(&context, issuer, cert, nullptr, nullptr, 0);
    std::unique_ptr<X509_EXTENSION, decltype(&X509_EXTENSION_free)> ext(
        X509V3_EXT_conf_nid(nullptr, &context, nid, value), X509_EXTENSION_free);
    return ext && X509_add_ext(cert, ext.get(), -1) == 1;
}
}

NSDictionary<NSString *, NSData *> *aether_create_local_certificate(NSData *issuerDER, NSData *issuerPEM) {
    const bool root = issuerDER == nil && issuerPEM == nil;
    Cert issuer = readCert(issuerDER);
    Key issuerKey = readKey(issuerPEM);
    if (!root && (!issuer || !issuerKey || X509_check_ca(issuer.get()) <= 0 ||
                  X509_check_private_key(issuer.get(), issuerKey.get()) != 1)) return nil;
    std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> context(
        EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nullptr), EVP_PKEY_CTX_free);
    EVP_PKEY *rawKey = nullptr;
    if (!context || EVP_PKEY_keygen_init(context.get()) != 1 ||
        EVP_PKEY_CTX_set_ec_paramgen_curve_nid(context.get(), NID_X9_62_prime256v1) != 1 ||
        EVP_PKEY_keygen(context.get(), &rawKey) != 1) { EVP_PKEY_free(rawKey); return nil; }
    Key key(rawKey, EVP_PKEY_free);
    Cert cert(X509_new(), X509_free);
    unsigned char serial[16];
    if (!cert || RAND_bytes(serial, sizeof(serial)) != 1) return nil;
    serial[0] &= 0x7f; serial[0] |= 1;
    std::unique_ptr<BIGNUM, decltype(&BN_free)> number(BN_bin2bn(serial, sizeof(serial), nullptr), BN_free);
    std::unique_ptr<ASN1_INTEGER, decltype(&ASN1_INTEGER_free)> integer(
        number ? BN_to_ASN1_INTEGER(number.get(), nullptr) : nullptr, ASN1_INTEGER_free);
    if (!integer || X509_set_version(cert.get(), 2) != 1 ||
        X509_set_serialNumber(cert.get(), integer.get()) != 1 ||
        !X509_gmtime_adj(X509_getm_notBefore(cert.get()), -300) ||
        !X509_gmtime_adj(X509_getm_notAfter(cert.get()), root ? 10L * 365 * 86400 : 90L * 86400) ||
        X509_set_pubkey(cert.get(), key.get()) != 1) return nil;
    if (!root && ASN1_TIME_compare(X509_get0_notAfter(cert.get()), X509_get0_notAfter(issuer.get())) > 0 &&
        X509_set1_notAfter(cert.get(), X509_get0_notAfter(issuer.get())) != 1) return nil;
    X509_NAME *name = X509_get_subject_name(cert.get());
    const char *commonName = root ? "Aether Local Server CA" : "Aether Local Server";
    if (X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
        reinterpret_cast<const unsigned char *>(commonName), -1, -1, 0) != 1 ||
        X509_set_issuer_name(cert.get(), root ? name : X509_get_subject_name(issuer.get())) != 1) return nil;
    X509 *signer = root ? cert.get() : issuer.get();
    if (!extension(cert.get(), signer, NID_basic_constraints, root ? "critical,CA:TRUE,pathlen:0" : "critical,CA:FALSE") ||
        !extension(cert.get(), signer, NID_key_usage, root ? "critical,keyCertSign,cRLSign" : "critical,digitalSignature") ||
        !extension(cert.get(), signer, NID_subject_key_identifier, "hash")) return nil;
    if (!root && (!extension(cert.get(), signer, NID_ext_key_usage, "serverAuth") ||
                  !extension(cert.get(), signer, NID_subject_alt_name, "IP:127.0.0.1") ||
                  !extension(cert.get(), signer, NID_authority_key_identifier, "keyid:always"))) return nil;
    if (X509_sign(cert.get(), root ? key.get() : issuerKey.get(), EVP_sha256()) <= 0) return nil;
    Bio certificateBIO(BIO_new(BIO_s_mem()), BIO_free);
    Bio keyBIO(BIO_new(BIO_s_mem()), BIO_free);
    if (!certificateBIO || !keyBIO || PEM_write_bio_X509(certificateBIO.get(), cert.get()) != 1 ||
        PEM_write_bio_PrivateKey(keyBIO.get(), key.get(), nullptr, nullptr, 0, nullptr, nullptr) != 1) return nil;
    unsigned char *der = nullptr;
    int length = i2d_X509(cert.get(), &der);
    if (length <= 0) return nil;
    NSData *certificateDER = [NSData dataWithBytes:der length:static_cast<NSUInteger>(length)];
    OPENSSL_free(der);
    NSData *certificatePEM = bioData(certificateBIO.get()), *keyPEM = bioData(keyBIO.get());
    if (!certificatePEM || !keyPEM) return nil;
    return @{ @"certificateDER": certificateDER, @"certificatePEM": certificatePEM, @"privateKeyPEM": keyPEM };
}

bool aether_validate_local_certificate(NSData *der, NSData *keyPEM, NSData *issuerDER,
                                       bool root, long remainingSeconds) {
    Cert cert = readCert(der), issuer = readCert(issuerDER);
    Key key = readKey(keyPEM);
    if (!cert || !key || remainingSeconds < 0 || X509_check_private_key(cert.get(), key.get()) != 1) return false;
    time_t now = time(nullptr), minimum = now + remainingSeconds;
    if (X509_cmp_time(X509_get0_notBefore(cert.get()), &now) != -1 ||
        X509_cmp_time(X509_get0_notAfter(cert.get()), &minimum) != 1) return false;
    if (root) {
        return X509_check_ca(cert.get()) > 0 && X509_check_issued(cert.get(), cert.get()) == X509_V_OK &&
               X509_verify(cert.get(), key.get()) == 1;
    }
    if (!issuer || X509_check_ca(cert.get()) != 0 || X509_check_ca(issuer.get()) <= 0 ||
        X509_check_issued(issuer.get(), cert.get()) != X509_V_OK ||
        X509_check_ip_asc(cert.get(), "127.0.0.1", 0) != 1 ||
        X509_check_purpose(cert.get(), X509_PURPOSE_SSL_SERVER, 0) != 1) return false;
    Key issuerPublicKey(X509_get_pubkey(issuer.get()), EVP_PKEY_free);
    return issuerPublicKey && X509_verify(cert.get(), issuerPublicKey.get()) == 1;
}
