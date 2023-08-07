# @version 0.2.12
# @author skozin <info@lido.fi>
# @licence MIT
from vyper.interfaces import ERC20


interface BridgeConnector:
    def forward_beth(terra_address: bytes32, amount: uint256, extra_data: Bytes[1024]): nonpayable
    def forward_ust(terra_address: bytes32, amount: uint256, extra_data: Bytes[1024]): nonpayable
    def adjust_amount(amount: uint256, decimals: uint256) -> uint256: view


interface RewardsLiquidator:
    def liquidate(ust_recipient: address) -> uint256: nonpayable


interface InsuranceConnector:
    def total_shares_burnt() -> uint256: view


interface Mintable:
    def mint(owner: address, amount: uint256): nonpayable
    def burn(owner: address, amount: uint256): nonpayable


interface Lido:
    def submit(referral: address) -> uint256: payable
    def totalSupply() -> uint256: view
    def getTotalShares() -> uint256: view
    def sharesOf(owner: address) -> uint256: view
    def getPooledEthByShares(shares_amount: uint256) -> uint256: view


event Deposited:
    sender: indexed(address)
    amount: uint256
    terra_address: bytes32
    beth_amount_received: uint256


event Withdrawn:
    recipient: indexed(address)
    amount: uint256
    steth_amount_received: uint256


event Refunded:
    recipient: indexed(address)
    beth_amount: uint256
    steth_amount: uint256
    comment: String[1024]


event RefundedBethBurned:
    beth_amount: uint256


event RewardsCollected:
    steth_amount: uint256
    ust_amount: uint256


event AdminChanged:
    new_admin: address


event EmergencyAdminChanged:
    new_emergency_admin: address


event BridgeConnectorUpdated:
    bridge_connector: address


event RewardsLiquidatorUpdated:
    rewards_liquidator: address


event InsuranceConnectorUpdated:
    insurance_connector: address


event LiquidationConfigUpdated:
    liquidations_admin: address
    no_liquidation_interval: uint256
    restricted_liquidation_interval: uint256


event AnchorRewardsDistributorUpdated:
    anchor_rewards_distributor: bytes32


event VersionIncremented:
    new_version: uint256


event OperationsStopped:
    pass


event OperationsResumed:
    pass


BETH_DECIMALS: constant(uint256) = 18

# A constant used in `_can_deposit_or_withdraw` when comparing Lido share prices.
#
# Due to integer rounding, Lido.getPooledEthByShares(10**18) may return slightly
# different numbers even if there were no oracle reports between two calls. This
# might happen if someone submits ETH before the second call. It can be mathematically
# proven that this difference won't be more than 10 wei given that Lido holds at least
# 0.1 ETH and the share price is of the same order of magnitude as the amount of ETH
# held. Both of these conditions are true if Lido operates normally—and if it doesn't,
# it's desirable for AnchorVault operations to be suspended. See:
#
# https://github.com/lidofinance/lido-dao/blob/eb33eb8/contracts/0.4.24/Lido.sol#L445
# https://github.com/lidofinance/lido-dao/blob/eb33eb8/contracts/0.4.24/StETH.sol#L288
#
STETH_SHARE_PRICE_MAX_ERROR: constant(uint256) = 10

# Aragon Agent contract of the Lido DAO
LIDO_DAO_AGENT: constant(address) = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c

# WARNING: since this contract is behind a proxy, don't change the order of the variables
# and don't remove variables during the code upgrades. You can only append new variables
# to the end of the list.

admin: public(address)

beth_token: public(address)
steth_token: public(address)
bridge_connector: public(address)
rewards_liquidator: public(address)
insurance_connector: public(address)
anchor_rewards_distributor: public(bytes32)

liquidations_admin: public(address)
no_liquidation_interval: public(uint256)
restricted_liquidation_interval: public(uint256)

last_liquidation_time: public(uint256)
last_liquidation_share_price: public(uint256)
last_liquidation_shares_burnt: public(uint256)

# The contract version. Used to mark backwards-incompatible changes to the contract
# logic, including installing delegates with an incompatible API. Can be changed both
# in `_initialize_vX` after implementation code changes and by calling `bump_version`
# after installing a new delegate.
#
# The following functions revert unless the value of the `_expected_version` argument
# matches the one stored in this state variable:
#
# * `deposit`
# * `withdraw`
#
# It's recommended for any external code interacting with this contract, both onchain
# and offchain, to have the current version set as a configurable parameter to make
# sure any incompatible change to the contract logic won't produce unexpected results,
# reverting the transactions instead until the compatibility is manually checked and
# the configured version is updated.
#
version: public(uint256)

emergency_admin: public(address)
operations_allowed: public(bool)

total_beth_refunded: public(uint256)


@internal
def _assert_version(_expected_version: uint256):
    assert _expected_version == self.version, "unexpected contract version"


@internal
def _assert_not_stopped():
    assert self.operations_allowed, "contract stopped"


@internal
def _assert_admin(addr: address):
    assert addr == self.admin # dev: unauthorized


@internal
def _assert_dao_governance(addr: address):
    assert addr == LIDO_DAO_AGENT # dev: unauthorized


@internal
def _initialize_v3(emergency_admin: address):
    self.emergency_admin = emergency_admin
    log EmergencyAdminChanged(emergency_admin)
    self.version = 3
    log VersionIncremented(3)


@external
def initialize(beth_token: address, steth_token: address, admin: address, emergency_admin: address):
    assert self.beth_token == ZERO_ADDRESS # dev: already initialized
    assert self.version == 0 # dev: already initialized

    assert beth_token != ZERO_ADDRESS # dev: invalid bETH address
    assert steth_token != ZERO_ADDRESS # dev: invalid stETH address

    assert ERC20(beth_token).totalSupply() == 0 # dev: non-zero bETH total supply

    self.beth_token = beth_token
    self.steth_token = steth_token
    # we're explicitly allowing zero admin address for ossification
    self.admin = admin
    self.last_liquidation_share_price = Lido(steth_token).getPooledEthByShares(10**18)
    self._initialize_v3(emergency_admin)

    log AdminChanged(admin)


@external
def petrify_impl():
    """
    @dev Prevents initialization of an implementation sitting behind a proxy.
    """
    assert self.version == 0 # dev: already initialized
    self.version = MAX_UINT256


@external
def emergency_stop():
    """
    @dev Performs emergency stop of the contract. Can only be called
    by the current emergency admin or by the current admin.

    While contract is in the stopped state, the following functions revert:

    * `submit`
    * `withdraw`
    * `collect_rewards`

    See `resume`, `set_emergency_admin`.
    """
    assert msg.sender == self.emergency_admin or msg.sender == self.admin # dev: unauthorized
    self._assert_not_stopped()
    self.operations_allowed = False
    log OperationsStopped()


@external
def resume():
    """
    @dev Resumes normal operations of the contract. Can only be called
    by the Lido DAO governance contract.

    See `emergency_stop`.
    """
    self._assert_dao_governance(msg.sender)
    assert not self.operations_allowed # dev: not stopped
    self.operations_allowed = True
    log OperationsResumed()


@external
def change_admin(new_admin: address):
    """
    @dev Changes the admin address. Can only be called by the current admin address.

    Setting the admin to zero ossifies the contract, i.e. makes it irreversibly non-administrable.
    """
    self._assert_admin(msg.sender)
    # we're explicitly allowing zero admin address for ossification
    self.admin = new_admin
    log AdminChanged(new_admin)


@external
def set_emergency_admin(new_emergency_admin: address):
    """
    @dev Sets the address allowed to perform an emergency stop and having no other privileges.

    Can only be called by the Lido DAO governance contract.

    See `emergency_stop`, `resume`.
    """
    self._assert_dao_governance(msg.sender)
    # we're explicitly allowing zero address
    self.emergency_admin = new_emergency_admin
    log EmergencyAdminChanged(new_emergency_admin)


@external
def bump_version():
    """
    @dev Increments contract version. Can only be called by the current admin address.

    Due to the usage of replaceable delegates, contract version cannot be compiled to
    the AnchorVault implementation as a constant. Instead, the governance should call
    this function when backwards-incompatible changes are made to the contract or its
    delegates.
    """
    self._assert_admin(msg.sender)
    new_version: uint256 = self.version + 1
    self.version = new_version
    log VersionIncremented(new_version)


@internal
def _set_bridge_connector(_bridge_connector: address):
    self.bridge_connector = _bridge_connector
    log BridgeConnectorUpdated(_bridge_connector)


@external
def set_bridge_connector(_bridge_connector: address):
    """
    @dev Sets the bridge connector contract: an adapter contract for communicating
         with the Terra bridge.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_bridge_connector(_bridge_connector)


@internal
def _set_rewards_liquidator(_rewards_liquidator: address):
    self.rewards_liquidator = _rewards_liquidator # dev: unauthorized
    log RewardsLiquidatorUpdated(_rewards_liquidator)


@external
def set_rewards_liquidator(_rewards_liquidator: address):
    """
    @dev Sets the rewards liquidator contract: a contract for selling stETH rewards to UST.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_rewards_liquidator(_rewards_liquidator)


@internal
def _set_insurance_connector(_insurance_connector: address):
    self.insurance_connector = _insurance_connector
    log InsuranceConnectorUpdated(_insurance_connector)


@external
def set_insurance_connector(_insurance_connector: address):
    """
    @dev Sets the insurance connector contract: a contract for obtaining the total number of
         shares burnt for the purpose of insurance/cover application from the Lido protocol.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_insurance_connector(_insurance_connector)


@internal
def _set_liquidation_config(
    _liquidations_admin: address,
    _no_liquidation_interval: uint256,
    _restricted_liquidation_interval: uint256
):
    assert _restricted_liquidation_interval >= _no_liquidation_interval

    self.liquidations_admin = _liquidations_admin
    self.no_liquidation_interval = _no_liquidation_interval
    self.restricted_liquidation_interval = _restricted_liquidation_interval

    log LiquidationConfigUpdated(
        _liquidations_admin,
        _no_liquidation_interval,
        _restricted_liquidation_interval
    )


@external
def set_liquidation_config(
    _liquidations_admin: address,
    _no_liquidation_interval: uint256,
    _restricted_liquidation_interval: uint256,
):
    """
    @dev Sets the liquidation config consisting of liquidation admin, the address that is allowed
         to sell stETH rewards to UST during after the no-liquidation interval ends and before
         the restricted liquidation interval ends, as well as both intervals.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_liquidation_config(
        _liquidations_admin,
        _no_liquidation_interval,
        _restricted_liquidation_interval
    )


@internal
def _set_anchor_rewards_distributor(_anchor_rewards_distributor: bytes32):
    self.anchor_rewards_distributor = _anchor_rewards_distributor
    log AnchorRewardsDistributorUpdated(_anchor_rewards_distributor)


@external
def set_anchor_rewards_distributor(_anchor_rewards_distributor: bytes32):
    """
    @dev Sets the Terra-side UST rewards distributor contract allowing Terra-side bETH holders
         to claim their staking rewards in the UST form.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_anchor_rewards_distributor(_anchor_rewards_distributor)


@external
def configure(
    _bridge_connector: address,
    _rewards_liquidator: address,
    _insurance_connector: address,
    _liquidations_admin: address,
    _no_liquidation_interval: uint256,
    _restricted_liquidation_interval: uint256,
    _anchor_rewards_distributor: bytes32,
):
    """
    @dev A shortcut function for setting all admin-configurable settings at once.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_bridge_connector(_bridge_connector)
    self._set_rewards_liquidator(_rewards_liquidator)
    self._set_insurance_connector(_insurance_connector)
    self._set_liquidation_config(
        _liquidations_admin,
        _no_liquidation_interval,
        _restricted_liquidation_interval
    )
    self._set_anchor_rewards_distributor(_anchor_rewards_distributor)


@internal
@view
def _get_rate(_is_withdraw_rate: bool) -> uint256:
    steth_balance: uint256 = ERC20(self.steth_token).balanceOf(self)
    beth_supply: uint256 = ERC20(self.beth_token).totalSupply() - self.total_beth_refunded
    if steth_balance >= beth_supply:
        return 10**18
    elif _is_withdraw_rate:
        return (steth_balance * 10**18) / beth_supply
    elif steth_balance == 0:
        return 10**18
    else:
        return (beth_supply * 10**18) / steth_balance


@external
@view
def get_rate() -> uint256:
    """
    @dev How much bETH one receives for depositing one stETH, and how much bETH one needs
         to provide to withdraw one stETH, 10**18 being the 1:1 rate.

    This rate is notmally 10**18 (1:1) but might be different after severe penalties inflicted
    on the Lido validators.
    """
    return self._get_rate(False)


@pure
@internal
def _diff_abs(new: uint256, old: uint256) -> uint256:
    if new > old :
        return new - old
    else:
        return old - new


@view
@internal
def _can_deposit_or_withdraw() -> bool:
    share_price: uint256 = Lido(self.steth_token).getPooledEthByShares(10**18)
    return self._diff_abs(share_price, self.last_liquidation_share_price) <= STETH_SHARE_PRICE_MAX_ERROR


@view
@external
def can_deposit_or_withdraw() -> bool:
    """
    @dev Whether deposits and withdrawals are enabled.

    Deposits and withdrawals are disabled if stETH token has rebased (e.g. Lido
    oracle reported Beacon chain rewards/penalties or insurance was applied) but
    vault rewards accrued since the last rewards sell operation are not sold to
    UST yet. Normally, this period should not last more than a couple of minutes
    each 24h.
    """
    return self.operations_allowed and self._can_deposit_or_withdraw()


@external
@payable
def submit(
    _amount: uint256,
    _terra_address: bytes32,
    _extra_data: Bytes[1024],
    _expected_version: uint256
) -> (uint256, uint256):
    """
    @dev Locks the `_amount` of provided ETH or stETH tokens in return for bETH tokens
         minted to the `_terra_address` address on the Terra blockchain.

    When ETH is provided, it will be deposited to Lido and converted to stETH first.
    In this case, transaction value must be the same as `_amount` argument.

    To provide stETH, set the transavtion value to zero and approve this contract for spending
    the `_amount` of stETH on your behalf.

    The call fails if `AnchorVault.can_deposit_or_withdraw()` is false.

    The conversion rate from stETH to bETH should normally be 1 but might be different after
    severe penalties inflicted on the Lido validators. You can obtain the current conversion
    rate by calling `AnchorVault.get_rate()`.
    """
    self._assert_not_stopped()
    self._assert_version(_expected_version)
    assert self._can_deposit_or_withdraw() # dev: share price changed

    steth_token: address = self.steth_token
    steth_amount: uint256 = _amount

    if msg.value != 0:
        assert msg.value == _amount # dev: unexpected ETH amount sent
        shares_minted: uint256 = Lido(steth_token).submit(self, value=_amount)
        steth_amount = Lido(steth_token).getPooledEthByShares(shares_minted)

    connector: address = self.bridge_connector

    beth_rate: uint256 = self._get_rate(False)
    beth_amount: uint256 = (steth_amount * beth_rate) / 10**18
    # the bridge might not support full precision amounts
    beth_amount = BridgeConnector(connector).adjust_amount(beth_amount, BETH_DECIMALS)

    steth_amount_adj: uint256 = (beth_amount * 10**18) / beth_rate
    assert steth_amount_adj <= steth_amount # dev: invalid adjusted amount

    if msg.value == 0:
        ERC20(steth_token).transferFrom(msg.sender, self, steth_amount_adj)
    elif steth_amount_adj < steth_amount:
        ERC20(steth_token).transfer(msg.sender, steth_amount - steth_amount_adj)

    Mintable(self.beth_token).mint(connector, beth_amount)
    BridgeConnector(connector).forward_beth(_terra_address, beth_amount, _extra_data)

    log Deposited(msg.sender, steth_amount_adj, _terra_address, beth_amount)

    return (steth_amount_adj, beth_amount)


@internal
def _withdraw(recipient: address, beth_amount: uint256, steth_rate: uint256) -> uint256:
    assert self._can_deposit_or_withdraw() # dev: share price changed
    steth_amount: uint256 = (beth_amount * steth_rate) / 10**18
    ERC20(self.steth_token).transfer(recipient, steth_amount)
    return steth_amount



@external
def withdraw(
    _beth_amount: uint256,
    _expected_version: uint256,
    _recipient: address = msg.sender
) -> uint256:
    """
    @dev Burns the `_beth_amount` of provided Ethereum-side bETH tokens in return for stETH
         tokens transferred to the `_recipient` Ethereum address.

    To withdraw Terra-side bETH, you should firstly transfer the tokens to the Ethereum
    blockchain.

    The call fails if `AnchorVault.can_deposit_or_withdraw()` returns false.

    The conversion rate from stETH to bETH should normally be 1 but might be different after
    severe penalties inflicted on the Lido validators. You can obtain the current conversion
    rate by calling `AnchorVault.get_rate()`.
    """
    self._assert_not_stopped()
    self._assert_version(_expected_version)

    steth_rate: uint256 = self._get_rate(True)
    Mintable(self.beth_token).burn(msg.sender, _beth_amount)
    steth_amount: uint256 = self._withdraw(_recipient, _beth_amount, steth_rate)

    log Withdrawn(_recipient, _beth_amount, steth_amount)

    return steth_amount


@internal
def _withdraw_for_refunding_burned_beth(
    _burned_beth_amount: uint256,
    _recipient: address,
    _comment: String[1024]
) -> uint256:
    """
    @dev Withdraws stETH without burning the corresponding bETH, assuming that
         the corresponding bETH was already effectively burned, i.e. that it
         cannot be moved from the address it currently belongs to. Returns
         the amount of stETH withdrawn.

    Can be used by the DAO governance to refund bETH that became locked as the
    result of a contract or user error, e.g. by using an incorrect encoding of
    the Terra recipient address. The governance takes the responsibility for
    verifying the immobility of the bETH being refunded and for taking all
    required actions should the refunded bETH become movable again.

    The call fails if `AnchorVault.can_deposit_or_withdraw()` returns false.

    The same conversion rate from bETH to stETH as in the `withdraw` method
    is applied. The call doesn't change the conversion rate.

    See: `withdraw`, `burn_refunded_beth`.
    """
    steth_rate: uint256 = self._get_rate(True)
    self.total_beth_refunded += _burned_beth_amount
    steth_amount: uint256 = self._withdraw(_recipient, _burned_beth_amount, steth_rate)

    log Refunded(_recipient, _burned_beth_amount, steth_amount, _comment)

    return steth_amount


@external
def burn_refunded_beth(beth_amount: uint256):
    """
    @dev Burns bETH belonging to the AnchorVault contract address, assuming that
         the corresponding stETH amount was already withdrawn from the vault
         via the `_withdraw_for_refunding_burned_beth` method.

    Can only be called by the current admin address.

    Used by the governance to actually burn bETH that previously became locked as
    the result of a contract or user error and was subsequently refunded.

    Reverts unless at least the specified bETH amount was refunded and wasn't
    burned yet.

    See: `_withdraw_for_refunding_burned_beth`.
    """
    self._assert_admin(msg.sender)

    # this will revert if beth_amount exceeds total_beth_refunded
    self.total_beth_refunded -= beth_amount

    Mintable(self.beth_token).burn(self, beth_amount)

    log RefundedBethBurned(beth_amount)


@internal
def _perform_refund_for_2022_01_26_incident():
    """
    @dev Withdraws stETH corresponding to bETH irreversibly locked at inaccessible Terra
         addresses as the result of the 2022-01-26 incident caused by incorrect address
         encoding produced by cached UI code after onchain migration to the Wormhole bridge.

    Tx 1: 0xc875f85f525d9bc47314eeb8dc13c288f0814cf06865fc70531241e21f5da09d
    bETH burned: 4449999990000000000

    Tx 2: 0x7abe086dd5619a577f50f87660a03ea0a1934c4022cd432ddf00734771019951
    bETH burned: 439111118580000000000
    """
    # prevent this funciton from being called after the v3 upgrade (see `finalize_upgrade_v3`)
    self._assert_version(0)
    LIDO_DAO_FINANCE_MULTISIG: address = 0x48F300bD3C52c7dA6aAbDE4B683dEB27d38B9ABb
    BETH_AMOUNT_BURNED: uint256 = 4449999990000000000 + 439111118580000000000
    self._withdraw_for_refunding_burned_beth(
        BETH_AMOUNT_BURNED,
        LIDO_DAO_FINANCE_MULTISIG,
        "refund for 2022-01-26 incident, txid 0x7abe086dd5619a577f50f87660a03ea0a1934c4022cd432ddf00734771019951 and 0xc875f85f525d9bc47314eeb8dc13c288f0814cf06865fc70531241e21f5da09d"
    )


@external
def finalize_upgrade_v3(emergency_admin: address):
    """
    @dev Performs state changes required for proxy upgrade from version 2 to version 3.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    # in v2, the version() function returned constant value of 2; in the upgraded impl,
    # the same function reads a storage slot that's zero until this function is called
    self._assert_version(0)
    self._perform_refund_for_2022_01_26_incident()
    self._initialize_v3(emergency_admin)
    self.operations_allowed = True


@external
def collect_rewards() -> uint256:
    """
    @dev Sells stETH rewards and transfers them to the distributor contract in the
         Terra blockchain.
    """
    self._assert_not_stopped()

    time_since_last_liquidation: uint256 = block.timestamp - self.last_liquidation_time

    if msg.sender == self.liquidations_admin:
        assert time_since_last_liquidation > self.no_liquidation_interval # dev: too early to sell
    else:
        assert time_since_last_liquidation > self.restricted_liquidation_interval # dev: too early to sell

    # The code below sells all rewards accrued by stETH held in the vault to UST
    # and forwards the outcome to the rewards distributor contract in Terra.
    #
    # To calculate the amount of rewards, we need to take the amount of stETH shares
    # the vault holds and determine how these shares' price increased since the last
    # rewards sell operation. We know that each shares that was transferred to the
    # vault since then was worth the same amount of stETH because the vault reverts
    # any deposits and withdrawals if the current share price is different from the
    # one actual at the last rewards sell time (see `can_deposit_or_withdraw` fn).
    #
    # When calculating the difference in share price, we need to account for possible
    # insurance applications that might have occured since the last rewards sell operation.
    # Insurance is applied by burning stETH shares, and the resulting price increase of
    # a single share shouldn't be considered as rewards and should recover bETH/stETH
    # peg instead:
    #
    # rewards = vault_shares_bal * (new_share_price - prev_share_price)
    #
    # new_share_price = new_total_ether / new_total_shares
    # new_total_ether = prev_total_ether + d_ether_io + d_rewards
    # new_total_shares = prev_total_shares + d_shares_io - d_shares_insurance_burnt
    #
    # rewards_corrected = vault_shares_bal * (new_share_price_corrected - prev_share_price)
    # new_share_price_corrected = new_total_ether / new_total_shares_corrected
    # new_total_shares_corrected = prev_total_shares + d_shares_io
    # new_share_price_corrected = new_total_ether / (new_total_shares + d_shares_insurance_burnt)

    steth_token: address = self.steth_token
    total_pooled_eth: uint256 = Lido(steth_token).totalSupply()
    total_shares: uint256 = Lido(steth_token).getTotalShares()

    share_price: uint256 = (10**18 * total_pooled_eth) / total_shares
    shares_burnt: uint256 = InsuranceConnector(self.insurance_connector).total_shares_burnt()

    prev_share_price: uint256 = self.last_liquidation_share_price
    prev_shares_burnt: uint256 = self.last_liquidation_shares_burnt

    self.last_liquidation_time = block.timestamp
    self.last_liquidation_share_price = share_price
    self.last_liquidation_shares_burnt = shares_burnt

    shares_burnt_since: uint256 = shares_burnt - prev_shares_burnt
    share_price_corrected: uint256 = (10**18 * total_pooled_eth) / (total_shares + shares_burnt_since)
    shares_balance: uint256 = Lido(steth_token).sharesOf(self)

    if share_price_corrected <= prev_share_price or shares_balance == 0:
        log RewardsCollected(0, 0)
        return 0

    steth_to_sell: uint256 = shares_balance * (share_price_corrected - prev_share_price) / 10**18

    connector: address = self.bridge_connector
    liquidator: address = self.rewards_liquidator

    ERC20(steth_token).transfer(liquidator, steth_to_sell)
    ust_amount: uint256 = RewardsLiquidator(liquidator).liquidate(connector)

    BridgeConnector(connector).forward_ust(self.anchor_rewards_distributor, ust_amount, b"")

    log RewardsCollected(steth_to_sell, ust_amount)

    return ust_amount