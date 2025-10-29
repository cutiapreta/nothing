Module 0xecc6c5425f6328f7e7b9ef17d5b287932c2bb1806058ee99bebef38fb367112f::dxlyn_coin
Struct CommitOwnershipEvent
Struct ApplyOwnershipEvent
Struct CommitMinterEvent
Struct ApplyMinterEvent
Struct PauseEvent
Struct UnPauseEvent
Resource DxlynInfo
Struct DXLYN
Resource CoinCaps
Resource InitialSupply
Constants
Function commit_transfer_ownership
Arguments
Dev
Function apply_transfer_ownership
Arguments
Dev
Function commit_transfer_minter
Arguments
Dev
Function apply_transfer_minter
Arguments
Dev
Function pause
Arguments
Dev
Function unpause
Arguments
Dev
Function mint
Arguments
Function mint_to_community
Arguments
Function transfer
Arguments
Function burn_from
Arguments
Function freeze_token
Arguments
Function unfreeze_token
Arguments
Function balance_of
Arguments
Returns
Function total_supply
Returns
Function get_dxlyn_asset_metadata
Returns
Function get_dxlyn_asset_address
Returns
Function get_dxlyn_object_address
Returns
use 0x1::coin;
use 0x1::event;
use 0x1::fungible_asset;
use 0x1::object;
use 0x1::option;
use 0x1::primary_fungible_store;
use 0x1::signer;
use 0x1::string;
use 0x1::supra_account;

Struct CommitOwnershipEvent
Represents the commitment to transfer ownership of the DXLYN contract

#[event]
struct CommitOwnershipEvent has drop, store

Struct ApplyOwnershipEvent
Represents the application of ownership transfer in the DXLYN contract

#[event]
struct ApplyOwnershipEvent has drop, store

Struct CommitMinterEvent
Represents the commitment to transfer minter of the DXLYN contract

#[event]
struct CommitMinterEvent has drop, store

Struct ApplyMinterEvent
Represents the application of minter transfer in the DXLYN contract

#[event]
struct ApplyMinterEvent has drop, store

Struct PauseEvent
Pauses the DXLYN contract

#[event]
struct PauseEvent has drop, store

Struct UnPauseEvent
Unpauses the DXLYN contract

#[event]
struct UnPauseEvent has drop, store

Resource DxlynInfo
DxlynInfo holds the information about the dxlyn token

struct DxlynInfo has key

Struct DXLYN
DXLYN legacy coin

struct DXLYN

Resource CoinCaps
Store legacy coin capabilities

struct CoinCaps has key

Resource InitialSupply
Token Generation Event

struct InitialSupply has key

Constants

The seed used to create the DXLYN object account

const DXLYN_OBJECT_ACCOUNT_SEED: vector<u8> = [68, 88, 76, 89, 78];

Try to pause the contract when it is already paused

const ERROR_ALREADY_PAUSED: u64 = 105;

Apply transfer minter without setting future minter

const ERROR_FUTURE_MINTER_NOT_SET: u64 = 104;

Apply transfer ownership without setting future owner

const ERROR_FUTURE_OWNER_NOT_SET: u64 = 103;

User has insufficient DXLYN balance

const ERROR_INSUFFICIENT_BALANCE: u64 = 102;

Caller is not the owner of the dxlyn system

const ERROR_NOT_OWNER: u64 = 101;

Try to unpause the contract when it is not paused

const ERROR_NOT_PAUSED: u64 = 106;

Try to mint when the contract is paused

const ERROR_PAUSED: u64 = 107;

DXLYN Initial supply

const INITIAL_SUPPLY: u64 = 10000000000000000;

Creator address of the DXLYN object account

const SC_ADMIN: address = 0xecc6c5425f6328f7e7b9ef17d5b287932c2bb1806058ee99bebef38fb367112f;

Function commit_transfer_ownership
Commit transfer ownership of dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner of the dxlyn token.
future_owner: The address of the future owner to whom ownership will be transferred.

Dev
This function can only be called by the current owner of the dxlyn token.
public entry fun commit_transfer_ownership(owner: &signer, future_owner: address)

Function apply_transfer_ownership
Apply transfer ownership of dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner of the dxlyn token.

Dev
This function can only be called after commit_transfer_ownership has been called
public entry fun apply_transfer_ownership(owner: &signer)

Function commit_transfer_minter
Commit transfer minter of dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner of the dxlyn token.
future_minter: The address of the future minter to whom minting rights will be transferred.

Dev
This function can only be called by the current owner of the dxlyn token.
public entry fun commit_transfer_minter(owner: &signer, future_minter: address)

Function apply_transfer_minter
Apply transfer minter of dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner of the dxlyn token.

Dev
This function can only be called after commit_transfer_minter has been called
public entry fun apply_transfer_minter(owner: &signer)

Function pause
Pause dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner of the dxlyn token.

Dev
This function can only be called by the current owner of the dxlyn token.
public entry fun pause(owner: &signer)

Function unpause
Unpause dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner of the dxlyn token.

Dev
This function can only be called by the current owner of the dxlyn token.
public entry fun unpause(owner: &signer)

Function mint
Mint dxlyn token


Arguments
owner: The signer of the transaction, representing the current owner or minter of the dxlyn token.
to: The address to which the minted tokens will be sent.
amount: The amount of dxlyn tokens to mint.
public entry fun mint(owner: &signer, to: address, amount: u64)

Function mint_to_community
Mint dxlyn token for community


Arguments
owner: The signer of the transaction, representing the current owner or minter of the dxlyn token.
to: The address to which the minted tokens will be sent.
amount: The amount of dxlyn tokens to mint.
public entry fun mint_to_community(owner: &signer, to: address, amount: u64)

Function transfer
Transfer dxlyn token


Arguments
account: The signer of the transaction, representing the account from which the tokens will be transferred.
to: The address to which the tokens will be transferred.
amount: The amount of dxlyn tokens to transfer.
public entry fun transfer(account: &signer, to: address, amount: u64)

Function burn_from
Burn dxlyn token from


Arguments
owner: The signer of the transaction, the owner of the system.
from: The address from which the tokens will be burned.
amount: The amount of dxlyn tokens to burn.
public entry fun burn_from(owner: &signer, from: address, amount: u64)

Function freeze_token
Freeze dxlyn token to user account


Arguments
owner: The signer of the transaction, the owner of the system.
user: The address to which the tokens will be freezed.
public entry fun freeze_token(owner: &signer, user: address)

Function unfreeze_token
Unfreeze dxlyn token from user account


Arguments
owner: The signer of the transaction, the owner of the system.
user: The address to which the tokens will be transferred.
public entry fun unfreeze_token(owner: &signer, user: address)

Function balance_of
Get the dxlyn coin balance of a user


Arguments
user_addr: The address of the user whose dxlyn balance is to be retrieved.

Returns
The balance of dxlyn tokens held by the user.
#[view]
public fun balance_of(user_addr: address): u64

Function total_supply
Get the dxlyn coin supply


Returns
The total supply of dxlyn tokens.
#[view]
public fun total_supply(): u128

Function get_dxlyn_asset_metadata
Get dxlyn asset metadata


Returns
The metadata of the dxlyn asset.
#[view]
public fun get_dxlyn_asset_metadata(): object::Object<fungible_asset::Metadata>

Function get_dxlyn_asset_address
Get dxlyn asset address


Returns
The address of the dxlyn asset.
#[view]
public fun get_dxlyn_asset_address(): address

Function get_dxlyn_object_address
Get dxlyn object address


Returns
The address of the dxlyn object.
#[view]
public fun get_dxlyn_object_address(): address
