//
//  TailscaleBridge.h
//  Moonlight Bureau
//
//  Tailscale inside the app (libs/tsbridge, Go tsnet built as a C archive): no Tailscale app,
//  no iOS VPN. It relays 127.0.0.1:<Sunshine Tel ports> to the PC over the tailnet.
//

#pragma once

// Starts the Tailscale node once. dir keeps the login between launches.
void MBTailscaleStart(char *dir, char *hostname, char *peer, int portStart, int portEnd);

// State as JSON (state, authURL, selfIP, target, forwarding, error, log). Free with free().
char *MBTailscaleStatus(void);
