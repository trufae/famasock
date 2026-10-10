#ifndef FAMASOCK_H
#define FAMASOCK_H
#include <stdint.h>
#include <stddef.h>
typedef struct Handle FamasockHandle;
/* Version is available without opening the core. Static string; do not free. */
const char * _Nonnull famasock_version(void);
/* Public crypto capabilities as owned JSON; release with string_free. */
char * _Nonnull famasock_crypto_info(void);
/* All functions block: call off the UI thread. Strings returned are owned. */
FamasockHandle *famasock_open(const char *path, const char *name, const uint8_t key[32], char **error);
char *famasock_command(FamasockHandle *, const char *json);
char *famasock_next_event(FamasockHandle *);
int32_t famasock_send_packet(FamasockHandle *, const char *session, const uint8_t *, size_t);
int32_t famasock_receive_packet(FamasockHandle *, const char *session, uint8_t *, size_t);
void famasock_string_free(char *);
/* shutdown wakes blocked calls. Join ALL callers before free. */
void famasock_shutdown(FamasockHandle *);
void famasock_free(FamasockHandle *);
#endif
