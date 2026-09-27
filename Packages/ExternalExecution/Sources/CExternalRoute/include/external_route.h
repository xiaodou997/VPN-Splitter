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
/* Status: 0 acknowledged, 1 refused/no authority, 2 uncertain. Never errno-as-success. */
typedef struct { int32_t status; uint64_t token; } er_result;
er_context *er_open(void);
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
