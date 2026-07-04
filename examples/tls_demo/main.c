#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/opensslv.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    const char *msg = "dirlir";
    EVP_Digest(msg, strlen(msg), digest, &len, EVP_sha256(), NULL);
    printf("%s\n", OpenSSL_version(OPENSSL_VERSION));
    printf("sha256(\"%s\") = ", msg);
    for (unsigned int i = 0; i < len; i++)
        printf("%02x", digest[i]);
    printf("\n");
    return 0;
}
