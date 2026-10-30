// Build-time compatibility check; never linked into Aether.
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/rsa.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(value) do { if (!(value)) { \
    fprintf(stderr, "OpenSSL compatibility check failed: %s\n", #value); \
    ERR_print_errors_fp(stderr); exit(EXIT_FAILURE); } } while (0)

static void check_pkcs12(EVP_PKEY *key, X509 *certificate, int cipher)
{
    PKCS12 *p12 = PKCS12_create("fixture-password", "Aether build check", key,
        certificate, NULL, cipher, cipher, 2048, 2048, 0);
    CHECK(p12);
    unsigned char *der = NULL;
    int size = i2d_PKCS12(p12, &der);
    CHECK(size > 0);
    const unsigned char *cursor = der;
    PKCS12 *decoded = d2i_PKCS12(NULL, &cursor, size);
    CHECK(decoded);
    CHECK(PKCS12_verify_mac(decoded, "fixture-password", -1));
    CHECK(!PKCS12_verify_mac(decoded, "wrong-password", -1));
    EVP_PKEY *parsed_key = NULL;
    X509 *parsed_certificate = NULL;
    CHECK(PKCS12_parse(decoded, "fixture-password", &parsed_key, &parsed_certificate, NULL));
    CHECK(EVP_PKEY_eq(key, parsed_key) == 1);
    CHECK(X509_cmp(certificate, parsed_certificate) == 0);
    EVP_PKEY_free(parsed_key);
    X509_free(parsed_certificate);
    PKCS12_free(decoded);
    OPENSSL_free(der);
    PKCS12_free(p12);
}

int main(void)
{
    CHECK(OPENSSL_VERSION_MAJOR == 3 && OPENSSL_VERSION_MINOR == 5);
    OSSL_PROVIDER *standard = OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER *legacy = OSSL_PROVIDER_load(NULL, "legacy");
    CHECK(standard && legacy);
    EVP_PKEY *key = EVP_RSA_gen(2048);
    CHECK(key);
    X509 *certificate = X509_new();
    CHECK(certificate);
    CHECK(X509_set_version(certificate, 2));
    CHECK(ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1));
    CHECK(X509_gmtime_adj(X509_getm_notBefore(certificate), -60));
    CHECK(X509_gmtime_adj(X509_getm_notAfter(certificate), 3600));
    CHECK(X509_set_pubkey(certificate, key));
    X509_NAME *subject = X509_get_subject_name(certificate);
    CHECK(X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC,
        (const unsigned char *)"Aether build check", -1, -1, 0));
    CHECK(X509_set_issuer_name(certificate, subject));
    CHECK(X509_sign(certificate, key, EVP_sha256()));
    check_pkcs12(key, certificate, NID_aes_256_cbc);
    check_pkcs12(key, certificate, NID_pbe_WithSHA1And40BitRC2_CBC);

    const char payload[] = "Aether CMS signing compatibility";
    BIO *input = BIO_new_mem_buf(payload, sizeof(payload) - 1);
    CHECK(input);
    CMS_ContentInfo *cms = CMS_sign(certificate, key, NULL, input, CMS_BINARY | CMS_DETACHED);
    CHECK(cms);
    BIO_free(input);
    input = BIO_new_mem_buf(payload, sizeof(payload) - 1);
    BIO *output = BIO_new(BIO_s_null());
    CHECK(input && output);
    CHECK(CMS_verify(cms, NULL, NULL, input, output, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY));
    BIO_free(input);
    BIO_free(output);
    CMS_ContentInfo_free(cms);
    X509_free(certificate);
    EVP_PKEY_free(key);
    OSSL_PROVIDER_unload(legacy);
    OSSL_PROVIDER_unload(standard);
    printf("%s: AES/RC2 PKCS#12 and CMS checks passed.\n", OpenSSL_version(OPENSSL_VERSION));
    return 0;
}
