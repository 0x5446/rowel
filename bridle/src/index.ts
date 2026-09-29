/**
 * The Bridle as a library, for the end-to-end tests and for embedding it in
 * another process. The CLI in `cli.ts` is a thin shell over exactly this.
 */

export { BridleCore, type DshStatus } from './core.ts'
export { VERSION } from './version.ts'
export { DirectServer, DIRECT_PATH, localAddresses, dialableAddresses } from './direct-server.ts'
export type { AgentClient, AgentHealth, AgentResult, AgentStream } from './agents/types.ts'
export { DshClient, assertLoopback, type DshHealth, type DshResult } from './dsh/client.ts'
export { dshHomeUrl, ensureDsh, portOpen, probeDsh, type DiscoveredDsh } from './dsh/discovery.ts'
export { EventLog, type LoggedEvent, type ReplayResult } from './tunnel/event-log.ts'
export { thinRoster, type Trimming } from './tunnel/roster.ts'
export { TunnelSession, deviceName, type SessionOptions, type TunnelTransport } from './tunnel/session.ts'
export { RelayClient, toWebSocketUrl, type RelayState } from './relay-client.ts'
export { createInvitation, publishInvitation, toHttpUrl, type Invitation } from './pair.ts'
export { installService, uninstallService, serviceLogPath, SERVICE_LABEL } from './service.ts'
export { BackupError, describeBackup, exportIdentity, importIdentity, sameIdentity, type BackupSummary } from './backup.ts'
export { clearRuntime, competingDaemon, readRuntime, writeRuntime, type RuntimeInfo } from './runtime.ts'
export { holdsIdentity, listInstances, rememberInstance, type InstanceSummary } from './instances.ts'
export {
  DEFAULT_DSH_URL,
  DEFAULT_RELAY_URL,
  approveClaimant,
  findPeer,
  loadState,
  offerMatch,
  redeemOffer,
  openPairingOffer,
  overrideState,
  reloadState,
  rowelHome,
  revokePeer,
  saveState,
  signingKeys,
  statePath,
  staticKeys,
  touchPeer,
  withdrawOffer,
  updateState,
  type BridleState,
  type PairedPeer,
  type PairingClaimant,
  type PairingOffer,
  type StateOverrides,
} from './identity.ts'
