# Card scenarios

Every scenario in [`test/e2e/CardScenarios.sol`](../../bridge/test/e2e/CardScenarios.sol) runs against
every setup. The cardholder starts with $1,000 in the setup's funding source. Unless noted, each
scenario also checks the program ledger:

- the settlement wallet received every settled pull plus reserve draws;
- Bridge liquidity paid every credit;
- each closed authorization pulled what it captured plus fees, minus what it returned.

"Gap" marks where a setup falls short of the ideal. Some gaps are Bridge's setups today. Others
are decisions for the Tempo handler ([`design.md`](design.md#decisions)).

## Purchases

| Scenario                                  | Situation                              | Expected                              |
| ----------------------------------------- | -------------------------------------- | ------------------------------------- |
| `purchase_captureSettlesExactAmount`      | $42.50 grocery auth and capture        | Charged once, settlement +$42.50      |
| `purchase_reversalReturnsHold`            | Merchant cancels before capture        | Full hold returned                    |
| `purchase_expiryReleasesHold`             | Uncaptured auth reaches 7 days         | Hold returned, not before expiry      |
| `purchase_partialCaptureReturnsRemainder` | $100 auth, $60 capture                 | $40 returned                          |
| `purchase_multipleCaptures`               | Split shipment: $30 then $50           | Charged $80                           |
| `restaurant_tipWithinHold`                | $50 auth holds $60, $58 capture        | Charged $58, $2 returned              |
| `restaurant_tipBeyondHoldPullsDifference` | $65 capture on a $60 hold              | Extra $5 pulled                       |
| `overcapture_withoutFunds_reserveCovers`  | $1,100 capture, $200 left              | Reserve pays $300, cardholder owes it |
| `hotel_incrementalAuthorization`          | $200 lodging auth, +$150, $320 capture | 31-day window, charged $320           |
| `fuelPump_preauthorizationThenActual`     | $1 pump auth, $47.23 capture           | $100 hold, charged $47.23             |
| `crossBorder_feePulledWithPrincipal`      | $110 with a 1.5% fee                   | $111.65 in one pull                   |
| `atm_withdrawalWithFee`                   | $200 plus a $3 fee                     | Charged $203                          |
| `forceCapture_withoutAuthorization`       | Offline capture, no auth               | Pulled at capture                     |
| `forceCapture_withoutFunds_reserveCovers` | Offline capture on an empty wallet     | Reserve pays, cardholder owes         |

## Refunds and disputes

| Scenario                        | Situation                           | Expected                                                                                                                      |
| ------------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `refund_full`, `refund_partial` | Merchant refunds after capture      | Credited back                                                                                                                 |
| `refund_afterFundsMovedAway`    | Refund after the wallet was emptied | Credited to the funding source                                                                                                |
| `refund_landsInFundingSource`   | Earn cardholder refunded            | Ideal: back into Earn. Every setup refunds stablecoin (gap; decided for the Tempo handler, [decision 4](design.md#decisions)) |
| `dispute_wonCreditsCardholder`  | Dispute won                         | Credited                                                                                                                      |
| `dispute_lostKeepsCharge`       | Dispute lost                        | No change                                                                                                                     |

## Declines and controls

| Scenario                         | Situation                               | Expected                                             |
| -------------------------------- | --------------------------------------- | ---------------------------------------------------- |
| `decline_insufficientFunds`      | $1,500 on $1,000                        | Declined, nothing moves                              |
| `decline_afterCardholderRevokes` | Cardholder revokes the card's authority | Declined                                             |
| `decline_whenProgramPaused`      | Bridge pauses the program               | Declined. Private: approved, bounced, reserve pays   |
| `spendLimit_capsSpend`           | $100 limit, two $60 auths               | Second declined                                      |
| `spendLimit_resetsEachPeriod`    | Next 30-day period                      | Limit refreshed (gap for Bridge: lifetime allowance) |
| `standingAllowance_betweenPulls` | After a pull                            | Nothing approved (gap for Bridge: allowance remains) |

## Concurrency and failures

| Scenario                                | Situation                              | Expected                                                                                                                                          |
| --------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `concurrentAuthorizations_noOverspend`  | $700 and $400 back to back             | Second declined                                                                                                                                   |
| `fundsMovedAfterApproval_reserveCovers` | Funds moved between preflight and pull | Reserve pays, cardholder owes                                                                                                                     |
| `retrySameAction_neverDoubleCharges`    | Bridge resubmits a settled pull        | Ideal: rejected on chain. Every setup relies on Bridge's off-chain dedupe (gap; decided for the Tempo handler, [decision 3](design.md#decisions)) |

## Earn

| Scenario                                   | Situation                                | Expected                                                     |
| ------------------------------------------ | ---------------------------------------- | ------------------------------------------------------------ |
| `earn_yieldAccruesUntilSpent`              | 1% yield before a purchase               | Fewer shares burned, yield kept                              |
| `earn_priceDropAfterQuote_boundsShareCost` | Share price drops 2% after Bridge quotes | Pull refused (gap for Bridge TF, EV: burns beyond the quote) |
| `earn_illiquidVenue`                       | Venue cannot redeem                      | Declined. Private: approved, bounced, reserve pays           |
| `split_stablecoinFirstThenEarn`            | $30 stablecoin, $50 purchase             | $30 stablecoin and $20 from Earn in one pull                 |

## Privacy

| Scenario                                | Situation                                                                           | Expected                                                                                                                            |
| --------------------------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `private_cardholderNeverAppearsOnTempo` | Pull, capture return and refund                                                     | No Tempo log contains the cardholder's address                                                                                      |
| `private_leakedZoneKeyStaysInProgram`   | Bridge's Zone key withdraws to an outside address, then to another admitted account | Ideal: nothing leaves the program. Accepted risk (decision 7): any address in open Zones, any admitted account in closed-loop Zones |
