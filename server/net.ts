// 네트워크 도우미: PC 의 LAN 주소 후보, UDP 알림(같은 Wi-Fi 의 폰이 게임을 자동으로 찾게)
import dgram from 'node:dgram';
import os from 'node:os';
import { BEACON_PORT, PROTOCOL_VERSION } from '../src/game/protocol.ts';

// VPN·WSL·가상머신 어댑터는 폰에서 접속할 수 없는 주소라 뒤로 미룬다
const VIRTUAL = /vEthernet|WSL|Hyper-V|VirtualBox|VMware|Loopback|Tailscale|ZeroTier|Hamachi|VPN|TAP|Docker|Bluetooth/i;
const isPrivate = (a: string) => /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a);

export type AddressInfo = { address: string; iface: string; preferred: boolean; broadcast: string };

function broadcastOf(address: string, netmask: string): string {
  const a = address.split('.').map(Number);
  const m = netmask.split('.').map(Number);
  return a.map((v, i) => (v | (~m[i] & 255)) & 255).join('.');
}

export function lanAddresses(): AddressInfo[] {
  const out: AddressInfo[] = [];
  for (const [iface, list] of Object.entries(os.networkInterfaces())) {
    for (const n of list ?? []) {
      if (n.family !== 'IPv4' || n.internal) continue;
      out.push({ address: n.address, iface, preferred: isPrivate(n.address) && !VIRTUAL.test(iface), broadcast: broadcastOf(n.address, n.netmask) });
    }
  }
  return out.sort((x, y) => Number(y.preferred) - Number(x.preferred));
}

export type BeaconInfo = () => { code: string; port: number; open: boolean };

/** 1초마다 UDP 브로드캐스트: {"app":"pocketcard", protocol, name, code, port, addresses, open} */
export function startBeacon(info: BeaconInfo): () => void {
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  let timer: NodeJS.Timeout | null = null;
  sock.on('error', (e) => console.warn(`[beacon] ${e.message}`));
  sock.bind(0, () => {
    sock.setBroadcast(true);
    timer = setInterval(() => {
      const addrs = lanAddresses();
      const i = info();
      const msg = Buffer.from(JSON.stringify({
        app: 'pocketcard', protocol: PROTOCOL_VERSION, name: os.hostname(), code: i.code, port: i.port, open: i.open,
        addresses: addrs.map((a) => a.address),
      }));
      const targets = new Set(['255.255.255.255', ...addrs.map((a) => a.broadcast)]);
      for (const t of targets) sock.send(msg, BEACON_PORT, t, () => {});
    }, 1000);
  });
  return () => { if (timer) clearInterval(timer); try { sock.close(); } catch { /* 이미 닫힘 */ } };
}
