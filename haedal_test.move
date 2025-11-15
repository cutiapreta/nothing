#[test_only]
module haedal::haedal_test {
    use sui::clock;
    use sui::coin;
    use sui::test_scenario::{Self, Scenario};
    use haedal::hasui;
    use haedal::staking;
    use haedal::manage;
    use haedal::config;
    use sui::address;
    use std::debug;
    use haedal::util;


    //use sui::coin;
    //use sui::test_scenario;
    //use sui::test_scenario::{Self, Scenario};
    use sui_system::sui_system::{Self, SuiSystemState};
    use sui_system::staking_pool::{Self, StakedSui, PoolTokenExchangeRate};
    use sui::test_utils::assert_eq;
    use sui_system::validator_set;
    use sui::test_utils;
    use sui::table::{Self, Table};
    use std::vector;

    use sui_system::governance_test_utils::{
        Self,
        add_validator,
        add_validator_candidate,
        advance_epoch,
        advance_epoch_with_reward_amounts,
        create_validator_for_testing,
        create_sui_system_state_for_testing,
        stake_with,
        remove_validator,
        remove_validator_candidate,
        total_sui_balance,
        unstake,
    };

    const VALIDATOR_ADDR_1: address = @0x1;
    const VALIDATOR_ADDR_2: address = @0x2;

    const STAKER_ADDR_1: address = @0x42;
    const STAKER_ADDR_2: address = @0x43;
    const STAKER_ADDR_3: address = @0x44;

    const NEW_VALIDATOR_ADDR: address = @0x1a4623343cd42be47d67314fce0ad042f3c82685544bc91d8c11d24e74ba7357;
    // Generated with seed [0;32]
    const NEW_VALIDATOR_PUBKEY: vector<u8> = x"99f25ef61f8032b914636460982c5cc6f134ef1ddae76657f2cbfec1ebfc8d097374080df6fcf0dcb8bc4b0d8e0af5d80ebbff2b4c599f54f42d6312dfc314276078c1cc347ebbbec5198be258513f386b930d02c2749a803e2330955ebd1a10";
    // Generated using [fn test_proof_of_possession]
    const NEW_VALIDATOR_POP: vector<u8> = x"8b93fc1b33379e2796d361c4056f0f04ad5aea7f4a8c02eaac57340ff09b6dc158eb1945eece103319167f420daf0cb3";

    const MIST_PER_SUI: u64 = 1_000_000_000;

    // init the env
    public fun haedal_test_setup(tester: address): (Scenario, staking::Staking, manage::AdminCap, clock::Clock) {
        let scenario_object = test_scenario::begin(tester);
        let scenario = &mut scenario_object;

        // init clock
        test_scenario::next_tx(scenario, tester);
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };


        // mock deploy
        test_scenario::next_tx(scenario, tester);
        {
            hasui::init_stsui_for_test(test_scenario::ctx(scenario));
            manage::init_staking_for_test(test_scenario::ctx(scenario));
        };

        // initialize
        test_scenario::next_tx(scenario, tester);
        {
            let admin_cap = test_scenario::take_from_sender<manage::AdminCap>(scenario);
            let treasury = test_scenario::take_from_sender<coin::TreasuryCap<hasui::HASUI>>(scenario);
            manage::initialize(&mut admin_cap, treasury, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, admin_cap);
        };

        // commit the above transaction
        test_scenario::next_tx(scenario, tester);

        // get the objects
        let clock_object = test_scenario::take_shared<clock::Clock>(scenario);
        let staking_object = test_scenario::take_shared<staking::Staking>(scenario);
        let admin_cap = test_scenario::take_from_sender<manage::AdminCap>(scenario);

        (scenario_object, staking_object, admin_cap, clock_object)
    }

    public fun haedal_test_tear_down(scenario: Scenario, staking_object: staking::Staking, admin_cap: manage::AdminCap, clock_object: clock::Clock) {
        test_scenario::return_shared(staking_object);
        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(clock_object);
        test_scenario::end(scenario);
    }

    
    public fun set_up_sui_system_state() {
        let scenario_val = test_scenario::begin(@0x0);
        let scenario = &mut scenario_val;
        let ctx = test_scenario::ctx(scenario);

        let validators = vector[
            create_validator_for_testing(VALIDATOR_ADDR_1, 100, ctx),
            create_validator_for_testing(VALIDATOR_ADDR_2, 100, ctx)
        ];
        create_sui_system_state_for_testing(validators, 0, 0, ctx);
        test_scenario::end(scenario_val);
    }

    public fun set_up_sui_system_state_with_storage_fund() {
        let scenario_val = test_scenario::begin(@0x0);
        let scenario = &mut scenario_val;
        let ctx = test_scenario::ctx(scenario);

        let validators = vector[
            create_validator_for_testing(VALIDATOR_ADDR_1, 100, ctx),
            create_validator_for_testing(VALIDATOR_ADDR_2, 100, ctx)
        ];
        create_sui_system_state_for_testing(validators, 300, 100, ctx);
        test_scenario::end(scenario_val);
    }

    public fun get_test_validators(): vector<address> {
        vector[
            VALIDATOR_ADDR_1, VALIDATOR_ADDR_2
        ]
    }

    public fun set_up_sui_system_state_with_storage_fund_n(s: u256, e: u256) {
        let scenario_val = test_scenario::begin(@0x0);
        let scenario = &mut scenario_val;
        let ctx = test_scenario::ctx(scenario);

        let validator_addresses = get_test_validators_n(s, e);
        let validators = vector::empty();
        let i=0;
        let length = e - s;
        while (i < length) {
            let validator = *vector::borrow(&validator_addresses, (i as u64));
            vector::push_back(&mut validators, create_validator_for_testing(validator, 100, ctx));
            i = i + 1;
        };

        create_sui_system_state_for_testing(validators, 300, 100, ctx);
        test_scenario::end(scenario_val);
    }

    public fun get_test_validators_n(s: u256, e: u256): vector<address> {
        let ret = create_address(s, e);
        test_utils::print(b"create_address");
        debug::print(&ret);
        ret
    }

    fun create_address(s: u256, e: u256): vector<address> {
        let ret = vector::empty<address>();
        while (s<=e){
            vector::push_back(&mut ret, address::from_u256(s));
            s = s + 1;
        };
        ret
    }


    public fun assert_gt(t1: u64, t2: u64) {
        let res = t1 > t2;
        if (!res) {
            print(b"assert_gt Assertion failed:");
            std::debug::print(&t1);
            print(b"<=");
            std::debug::print(&t2);
            abort(0)
        }
    }

    public fun assert_lt(t1: u64, t2: u64) {
        let res = t1 < t2;
        if (!res) {
            print(b"assert_lt Assertion failed:");
            std::debug::print(&t1);
            print(b">=");
            std::debug::print(&t2);
            abort(0)
        }
    }

    public fun print(str: vector<u8>) {
        std::debug::print(&std::ascii::string(str))
    }

}
