/// Interface for breaker.
module haedal::breaker {
    use haedal::manage::{BreakerCap};
    use haedal::staking::{Self, Staking};
  
    public entry fun toggle_unstake_v2(_: &BreakerCap, staking: &mut Staking, status: bool) {
        staking::assert_version(staking);
        staking::toggle_unstake(staking, status);
    }

    public entry fun toggle_claim_v2(_: &BreakerCap, staking: &mut Staking, status: bool) {
        staking::assert_version(staking);
        staking::toggle_claim(staking, status);
    }

}
