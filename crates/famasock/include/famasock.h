#ifndef FAMASOCK_H
#define FAMASOCK_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct Handle FamasockHandle;
/* Static version string. Do not free it. */
const char *famasock_version(void);
/* Owned JSON strings: release with famasock_string_free. */
char *famasock_crypto_info(void);
char *famasock_qr_code(const char *text);
/* All calls block. Use worker threads, including opening and shutdown.
 * Desktop open persists an owner-only identity in path; only one process can
 * own that state directory. Mobile open uses an external 32-byte Keychain key. */
FamasockHandle *famasock_open_desktop(const char *path, const char *name, char **error);
FamasockHandle *famasock_open(const char *path, const char *name, const uint8_t key[32], char **error);
char *famasock_command(FamasockHandle *, const char *json);
char *famasock_next_event(FamasockHandle *);
int32_t famasock_send_packet(FamasockHandle *, const char *session, const uint8_t *, size_t);
int32_t famasock_receive_packet(FamasockHandle *, const char *session, uint8_t *, size_t);
void famasock_string_free(char *);
/* Shutdown wakes blocked calls. Join ALL callers before free. */
void famasock_shutdown(FamasockHandle *);
void famasock_free(FamasockHandle *);
#ifdef __cplusplus
}
#endif
#endif
