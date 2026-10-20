#include "pairing_verifier.h"
#include <string.h>
#include "mbedtls/bignum.h"
#include "mbedtls/dhm.h"
#include "mbedtls/sha512.h"
#include "mbedtls/platform_util.h"

esp_err_t pairing_verifier(const char *password, const uint8_t salt[32], uint8_t verifier[384]) {
    // RFC5054 3072-bit group uses the RFC3526 MODP prime and generator FIVE.
    // Do not use esp_srp_gen_salt_verifier in IDF5.5.2: its MPI serialization
    // can shorten a leading-zero salt without returning the actual salt length.
    static const unsigned char prime[] = MBEDTLS_DHM_RFC3526_MODP_3072_P_BIN;
    uint8_t inner[64], xbytes[64];
    mbedtls_sha512_context hash;
    mbedtls_sha512_init(&hash);
    mbedtls_mpi n, g, x, v;
    mbedtls_mpi_init(&n); mbedtls_mpi_init(&g);
    mbedtls_mpi_init(&x); mbedtls_mpi_init(&v);
    int rc = mbedtls_sha512_starts(&hash, 0);
    if (!rc) rc = mbedtls_sha512_update(&hash, (const unsigned char *)"sightlatch:", 11);
    if (!rc) rc = mbedtls_sha512_update(&hash, (const unsigned char *)password, strlen(password));
    if (!rc) rc = mbedtls_sha512_finish(&hash, inner);
    if (!rc) rc = mbedtls_sha512_starts(&hash, 0);
    if (!rc) rc = mbedtls_sha512_update(&hash, salt, 32);
    if (!rc) rc = mbedtls_sha512_update(&hash, inner, sizeof(inner));
    if (!rc) rc = mbedtls_sha512_finish(&hash, xbytes);
    if (!rc) rc = mbedtls_mpi_read_binary(&n, prime, sizeof(prime));
    if (!rc) rc = mbedtls_mpi_lset(&g, 5);
    if (!rc) rc = mbedtls_mpi_read_binary(&x, xbytes, sizeof(xbytes));
    if (!rc) rc = mbedtls_mpi_exp_mod(&v, &g, &x, &n, NULL);
    if (!rc) rc = mbedtls_mpi_write_binary(&v, verifier, 384);
    mbedtls_platform_zeroize(inner, sizeof(inner));
    mbedtls_platform_zeroize(xbytes, sizeof(xbytes));
    mbedtls_sha512_free(&hash);
    mbedtls_mpi_free(&n); mbedtls_mpi_free(&g); mbedtls_mpi_free(&x); mbedtls_mpi_free(&v);
    return rc ? ESP_FAIL : ESP_OK;
}
