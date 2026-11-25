// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Optional callback surface a `requestRedeem` receiver may advertise. `EarnVault`
///         invokes these AFTER moving value to the receiver, inside a try/catch, so an EOA receiver
///         simply keeps the transferred payout and a contract receiver gets a completion callback.
/// @dev A cancellation returns the current-value EarnShare minted by the EarnVault to the SAME stored
///      receiver the finalize path would have used. The amount may differ from the EarnShare burned at
///      request time because the queued position can gain or lose value.
///      Both hooks are best-effort: the EarnVault ignores a revert or an out-of-gas hook and still
///      completes, so the claim is closed and the hook is not called again. An engine may cap a payout's
///      gas: in a solved batch, `VedaEngine` gives each payout 2,000,000 gas, so `onRedeemFinalized` gets
///      roughly 63/64 of what remains of that after the payout. A receiver whose hook needs more gas must
///      not depend on it running in a batch solve.
interface IAsyncRedeemReceiver {
    function onRedeemFinalized(bytes32 requestId, address asset, uint256 amount) external;
    function onRedeemCancelled(bytes32 requestId, address earnShare, uint256 earnShares) external;
}
