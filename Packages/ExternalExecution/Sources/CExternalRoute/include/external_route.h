/* SPDX-License-Identifier: MIT */
#ifndef VPNSPLITTER_EXTERNAL_ROUTE_H
#define VPNSPLITTER_EXTERNAL_ROUTE_H
#include <stdint.h>
typedef struct er_context er_context;
typedef struct {
    uint32_t destination; /* host byte order; canonical network address */
    uint32_t gateway;     /* host byte order */
    uint16_t interface_index;
    uint16_t tunnel_index;
    uint8_t prefix;
} er_spec;
/* Status: 0 acknowledged, 1 refused/no authority, 2 uncertain,
 * 3 ADD not attempted (only GET/pre-send failure). Never errno-as-success. */
typedef struct { int32_t status; uint64_t token; } er_result;
/* Diagnostic fields are fixed categories and counters, never addresses or raw messages.
 * The first failure survives later cleanup; attempts count ADD/DELETE syscall attempts
 * on this context, NOT successful mutations. A GET uses write(2) but is not a mutation. */
typedef struct {
    int32_t stage, reason, decode_field, system_errno, reply_errno, reply_type;
    uint32_t mutation_attempts;
} er_diagnostic;
enum { ER_STAGE_NONE, ER_STAGE_TARGET_GET, ER_STAGE_GATEWAY_GET, ER_STAGE_ADD,
       ER_STAGE_REMOVE_GET, ER_STAGE_DELETE };
enum { ER_REASON_NONE, ER_REASON_INVALID, ER_REASON_READ_ONLY, ER_REASON_POISONED,
       ER_REASON_EVENT, ER_REASON_EVENT_LIMIT, ER_REASON_RECEIVE, ER_REASON_TRUNCATED,
       ER_REASON_REQUEST, ER_REASON_CLOCK, ER_REASON_SEND, ER_REASON_TIMEOUT,
       ER_REASON_POLL, ER_REASON_REPLY_TYPE, ER_REASON_DECODE, ER_REASON_REPLY_KEY,
       ER_REASON_KERNEL, ER_REASON_TARGET_PATH, ER_REASON_GATEWAY_PATH, ER_REASON_OWNERSHIP };
er_context *er_open(void);
er_context *er_open_query(void); /* GET-only context, including when opened as root. */
er_result er_probe(er_context *context, er_spec spec); /* two GETs, no ADD/DELETE/receipt */
er_diagnostic er_get_diagnostic(const er_context *context);
void er_close(er_context *context); /* closes the socket, NEVER deletes routes */
int32_t er_drain(er_context *context);
int32_t er_owns(er_context *context, uint64_t token);
er_result er_add(er_context *context, er_spec spec);
er_result er_remove(er_context *context, uint64_t token);
double er_continuous_seconds(void);
void er_install_stop_handlers(void);
int32_t er_stop_requested(void);
int32_t er_console_confirm(void); /* exact APPLY newline, bounded wait, TTY required */
int32_t er_console_poll(void);    /* enter/EOF/signal/error requests stop */
#endif
