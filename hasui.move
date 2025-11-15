module haedal::hasui {
    use std::option;
    use sui::coin::{Self};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url::{Self};

    friend haedal::staking;

    struct HASUI has drop {}

    fun init(_witness: HASUI, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            _witness,
            9,
            b"haSUI",
            b"haSUI",
            b"haSUI is a staking token of SUI",
            option::some(url::new_unsafe_from_bytes(b"https://assets.haedal.xyz/logos/hasui.svg")),
            ctx
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, tx_context::sender(ctx));
    }

    #[test_only]
    public fun init_stsui_for_test(ctx: &mut TxContext) {
        init(HASUI{}, ctx);
    }
}
