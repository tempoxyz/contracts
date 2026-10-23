import { erc4626Abi, parseAbi } from 'viem'

/**
 * Hand-maintained ABIs for contracts built outside this repository: Tempo Zone predeploys, the
 * PropAMM pool, oracle, and controller, the Veda periphery, and the Morpho fee wrapper. The pinned
 * DirectPropAMM test fixture (`test/fixtures/propamm/`) is a test build, not the deployed pool
 * interface, so it is not a source of truth.
 * Earn contract ABIs come from `generated.ts`; token ABIs from `viem` (`erc20Abi`, `erc4626Abi`) and
 * `viem/tempo` (`Abis.tip20`). Keep this the only hand-written ABI module and add a function here
 * once, not at each call site.
 */

/**
 * Tempo `ZonePortal`: token readiness, Zone identity, enforcement modes, account and gateway roles,
 * and the encrypted return. `Role` is `None` 0, `Sequencer` 1, `Account` 2, `CallbackGateway` 3,
 * `PauseGuardian` 4.
 */
export const zonePortalAbi = parseAbi([
  'function admin() view returns (address)',
  'function areDepositsActive(address token) view returns (bool)',
  'function depositEncrypted(address token, uint128 amount, uint256 keyIndex, (bytes32 ephemeralPubkeyX, uint8 ephemeralPubkeyYParity, bytes ciphertext, bytes12 nonce, bytes16 tag) encrypted, address tempoRefundRecipient) returns (bytes32)',
  'function enableToken(address token)',
  'function encryptionKeyCount() view returns (uint256)',
  'function hasRole(address account, uint8 role) view returns (bool)',
  'function isAccessEnforced() view returns (bool)',
  'function isGatewayOpen() view returns (bool)',
  'function isTokenEnabled(address token) view returns (bool)',
  'function lastSyncedTempoBlockNumber() view returns (uint64)',
  'function messenger() view returns (address)',
  'function sequencerAt(uint256 index) view returns (address)',
  'function sequencerCount() view returns (uint256)',
  'function setAccessMode(bool enforced)',
  'function setAllowedAccount(address account, bool allowed)',
  'function setGateway(address account, bool allowed)',
  'function setGatewayMode(bool enforced)',
  'function withdrawalBatchIndex() view returns (uint64)',
  'function withdrawalQueueHead() view returns (uint256)',
  'function withdrawalQueueTail() view returns (uint256)',
  'function zoneId() view returns (uint32)',
  'event WithdrawalProcessed(address indexed to, bytes32 indexed senderTag, address token, uint128 amount, bool callbackSuccess)',
  'error AccountNotAllowed(address account)',
])

/** Gnosis Safe: the subset used to act as a 1-of-1 Safe owner that also submits the transaction. */
export const safeAbi = parseAbi([
  'function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver, bytes signatures) payable returns (bool)',
  'function getOwners() view returns (address[])',
  'function getThreshold() view returns (uint256)',
])

/**
 * Tempo `ZoneFactory` version 1. Keep this shape explicit until the public `viem/tempo` ABI exposes
 * the deployed `zones` tuple.
 */
export const zoneFactoryAbi = parseAbi([
  'function zones(uint32 zoneId) view returns ((uint32 zoneId,address portal,bool accessMode,bool gatewayMode,address admin,address[] sequencers,uint8 threshold,address verifier,string rpcUrl) info)',
  'event ZoneCreated(uint32 indexed zoneId,address indexed portal,address initialToken,bool accessMode,bool gatewayMode,address admin,address[] sequencers,uint8 threshold,address verifier)',
])

/** Zone predeploy that names the Zone's Tempo Portal. */
export const zoneInboxAbi = parseAbi(['function tempoPortal() view returns (address)'])

/** Zone messenger, shared by every Zone on a Tempo network. */
export const zoneMessengerAbi = parseAbi(['function zoneFactory() view returns (address)'])

/** Zone predeploy reporting the Tempo block the Zone has imported. */
export const tempoStateAbi = parseAbi(['function tempoBlockNumber() view returns (uint64)'])

/**
 * `DirectPropAMMRebalanceController`, which can own a conversion pool. The pinned DirectPropAMM test
 * fixture predates it, so no artifact exists to generate from.
 */
export const propAMMRebalanceControllerAbi = parseAbi([
  'function execute(bytes data)',
  'function owner() view returns (address)',
  'function pool() view returns (address)',
])

/** Deployed `DirectPropAMM` conversion pool: pause, admission, inventory, and quote surface. */
export const propAMMPoolAbi = parseAbi([
  'function addressRegistry() view returns (address)',
  'function baseToken() view returns (address)',
  'function fund(address token, uint256 amount, bytes32 memo)',
  'function maxOracleAge() view returns (uint256)',
  'function oracle() view returns (address)',
  'function owner() view returns (address)',
  'function pause()',
  'function paused() view returns (bool)',
  'function quoteExactInputFor(address taker, address recipient, bytes32 customerId, bool baseToQuote, uint256 amountIn) view returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter)',
  'function quoteToken() view returns (address)',
  'function recipientAllowed(address recipient) view returns (bool)',
  'function resolveRecipient(address recipient) view returns (address)',
  'function setRecipientAllowed(address recipient, bool allowed)',
  'function setTakerAllowed(address taker, bool allowed)',
  'function takerAllowed(address taker) view returns (bool)',
  'function unpause()',
  'function withdraw(address token, address recipient, uint256 amount, bytes32 memo)',
])

/** `ManagedDirectPropAMM` conversion pool: per-pair configuration, taker lists, and pause. */
export const managedPropAMMPoolAbi = parseAbi([
  'struct Pair { address base; address quote; address oracle; uint8 baseDecimals; uint8 quoteDecimals; uint8 oracleDecimals; uint256 priceScale; uint256 maxOracleAge; uint256 maxPriceDeviationBps; uint8 access; }',
  'function owner() view returns (address)',
  'function pair(uint16 pairIndex) view returns (Pair)',
  'function paused() view returns (bool)',
  'function setMembers(uint16 pairIndex, uint64 sponsorId, address[] accounts, bool allowed)',
  'function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) view returns (bool)',
])

/** A conversion pool's price oracle, such as `PushPriceOracle`. */
export const priceOracleAbi = parseAbi([
  'function decimals() view returns (uint8)',
  'function latestPrice() view returns (uint256 price, uint256 updatedAt)',
])

/** Veda `TellerWithMultiAssetSupport`: deposit configuration, transfer locks, and accounting events. */
export const vedaTellerAbi = parseAbi([
  'function assetData(address asset) view returns (bool allowDeposits, bool allowWithdraws, uint16 sharePremium)',
  'function beforeTransferData(address account) view returns (bool denyFrom,bool denyTo,bool denyOperator,bool permissionedOperator,uint256 shareUnlockTime)',
  'function shareLockPeriod() view returns (uint64)',
  'event BulkDeposit(address indexed asset,uint256 depositAmount)',
  'event BulkWithdraw(address indexed asset,uint256 shareAmount)',
  'event Deposit(uint256 nonce,address indexed receiver,address indexed depositAsset,uint256 depositAmount,uint256 shareAmount,uint256 depositTimestamp,uint256 shareLockPeriodAtTimeOfDeposit,address indexed referralAddress)',
  'event Withdraw(address indexed asset,uint256 shareAmount)',
])

/** Veda `BoringOnChainQueue`: tracked withdrawal requests and their previewed output. */
export const vedaBoringQueueAbi = parseAbi([
  'function getOnChainWithdraw(bytes32 requestId) view returns (uint96 nonce,address user,address assetOut,uint128 amountOfShares,uint128 amountOfAssets,uint40 creationTime,uint24 secondsToMaturity,uint24 secondsToDeadline)',
  'function nonce() view returns (uint96)',
  'function previewAssetsOut(address assetOut,uint128 amountOfShares,uint16 discount) view returns (uint128 amountOfAssets)',
  'function trackWithdrawsOnChain() view returns (bool)',
])

/** Veda `AccountantWithRateProviders`. */
export const vedaAccountantAbi = parseAbi([
  'function base() view returns (address)',
  'function getRateInQuoteSafe(address quote) view returns (uint256)',
  'function vault() view returns (address)',
])

/** Veda `BoringVault` and its role `Authority`. */
export const vedaBoringVaultAbi = parseAbi([
  'function authority() view returns (address)',
  'function owner() view returns (address)',
])

/** Veda `RolesAuthority` guarding the BoringVault. */
export const vedaRolesAuthorityAbi = parseAbi([
  'function canCall(address user, address target, bytes4 functionSig) view returns (bool)',
])

/** A Morpho fee wrapper: an ERC-4626 vault over a Morpho `venue`. */
export const morphoFeeWrapperAbi = [
  ...erc4626Abi,
  ...parseAbi(['function venue() view returns (address)']),
] as const
