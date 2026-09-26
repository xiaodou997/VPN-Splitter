// SPDX-License-Identifier: MIT
#ifndef VPN_SPLITTER_PACKET_FLOW_H
#define VPN_SPLITTER_PACKET_FLOW_H
#include <stdint.h>
// Borrowed buffers remain valid for the complete (potentially blocking) call.
// The bridge copies input and never retains a caller-owned pointer.
int32_t wgTurnOnPacketFlow(const char *settings, int32_t mtu);
void wgTurnOffPacketFlow(int32_t handle);
int32_t wgReadPacketFlow(int32_t handle, uint8_t *buffer, int32_t capacity);
int32_t wgWritePacketFlow(int32_t handle, const uint8_t *buffer, int32_t length);
#endif
