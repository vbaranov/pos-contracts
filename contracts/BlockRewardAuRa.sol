pragma solidity 0.4.25;

import "./abstracts/BlockRewardBase.sol";
import "./interfaces/IERC20Minting.sol";
import "./interfaces/IRandomAuRa.sol";


contract BlockRewardAuRa is BlockRewardBase {

    function reward(address[] benefactors, uint16[] kind)
        external
        onlySystem
        returns(address[], uint256[])
    {
        require(benefactors.length == kind.length);
        require(benefactors.length == 1);
        require(kind[0] == 0);

        if (benefactors[0] == address(0)) {
            // Return empty arrays for zero input address
            // https://github.com/paritytech/parity-ethereum/issues/9764
            return (new address[](0), new uint256[](0));
        }

        IValidatorSet validatorSetContract = IValidatorSet(VALIDATOR_SET_CONTRACT);

        // Check if the validator is existed
        if (validatorSetContract.validatorSetApplyBlock() == block.number) {
            // If `finalizeChange` was called in this block
            require(
                validatorSetContract.isValidator(benefactors[0]) ||
                validatorSetContract.isValidatorOnPreviousEpoch(benefactors[0])
            );
        } else {
            require(validatorSetContract.isValidator(benefactors[0]));
        }

        // Start new staking epoch every `STAKING_EPOCH_DURATION` blocks
        validatorSetContract.newValidatorSet();

        // Distribute fees
        address[] memory receivers;
        uint256[] memory rewards;
        uint256 i;

        uint256 stakingEpoch = _getStakingEpoch();

        // Distribute bridge's native fee
        (receivers, rewards) = _distributeBridgeFee(stakingEpoch, false, true);
        for (i = 0; i < receivers.length; i++) {
            addressArrayStorage[REWARD_TEMPORARY_ARRAY].push(receivers[i]);
            uintArrayStorage[REWARD_TEMPORARY_ARRAY].push(rewards[i]);
        }
        if (stakingEpoch > 0) {
            // Handle previous staking epoch as well (just in case)
            (receivers, rewards) = _distributeBridgeFee(stakingEpoch - 1, true, true);
            for (i = 0; i < receivers.length; i++) {
                addressArrayStorage[REWARD_TEMPORARY_ARRAY].push(receivers[i]);
                uintArrayStorage[REWARD_TEMPORARY_ARRAY].push(rewards[i]);
            }
        }

        // Distribute bridge's token fee
        IERC20Minting erc20TokenContract = IERC20Minting(
            validatorSetContract.erc20TokenContract()
        );
        if (erc20TokenContract != address(0)) {
            (receivers, rewards) = _distributeBridgeFee(stakingEpoch, false, false);
            if (receivers.length > 0) {
                erc20TokenContract.mintReward(receivers, rewards);
            }
            if (stakingEpoch > 0) {
                // Handle previous staking epoch as well (just in case)
                (receivers, rewards) = _distributeBridgeFee(stakingEpoch - 1, true, false);
                if (receivers.length > 0) {
                    erc20TokenContract.mintReward(receivers, rewards);
                }
            }
        }

        // We don't accrue any block reward in native coins to validator here.
        // We just mint native coins by bridge if needed.
        (receivers, rewards) = _mintNativeCoinsByErcToNativeBridge();
        for (i = 0; i < receivers.length; i++) {
            addressArrayStorage[REWARD_TEMPORARY_ARRAY].push(receivers[i]);
            uintArrayStorage[REWARD_TEMPORARY_ARRAY].push(rewards[i]);
        }

        // Move the arrays of receivers and their rewards from storage to memory
        receivers = addressArrayStorage[REWARD_TEMPORARY_ARRAY];
        rewards = uintArrayStorage[REWARD_TEMPORARY_ARRAY];

        delete addressArrayStorage[REWARD_TEMPORARY_ARRAY];
        delete uintArrayStorage[REWARD_TEMPORARY_ARRAY];

        // Mark that the current validator produced a block during the current phase.
        // Publish current random number at the end of the current collection round.
        // Check if current validators participated in the current collection round.
        IRandomAuRa(validatorSetContract.randomContract()).onBlockClose(benefactors[0]);

        return (receivers, rewards);
    }

    function _distributeBridgeFee(uint256 _stakingEpoch, bool _previousEpoch, bool _native)
        internal
        returns(address[], uint256[])
    {
        uint256 bridgeFeeAmount;

        if (_native) {
            bridgeFeeAmount = _getBridgeNativeFee(_stakingEpoch);
            _clearBridgeNativeFee(_stakingEpoch);
        } else {
            bridgeFeeAmount = _getBridgeTokenFee(_stakingEpoch);
            _clearBridgeTokenFee(_stakingEpoch);
        }

        if (bridgeFeeAmount == 0) {
            return (new address[](0), new uint256[](0));
        }

        IValidatorSet validatorSetContract = IValidatorSet(VALIDATOR_SET_CONTRACT);
        address[] memory validators;
        address[] memory receivers;
        uint256[] memory rewards;
        uint256 poolReward;
        uint256 remainder;
        uint256 i;

        if (!_previousEpoch) {
            validators = validatorSetContract.getValidators();
        } else {
            validators = validatorSetContract.getPreviousValidators();
        }
        if (_stakingEpoch == 0) {
            // On initial staking epoch only initial validators get reward

            poolReward = bridgeFeeAmount / validators.length;
            remainder = bridgeFeeAmount % validators.length;

            rewards = new uint256[](validators.length);

            for (i = 0; i < validators.length; i++) {
                rewards[i] = poolReward;
            }
            rewards[0] += remainder;

            return (validators, rewards);
        } else {
            poolReward = bridgeFeeAmount / snapshotValidators(_stakingEpoch).length;
            remainder = bridgeFeeAmount % snapshotValidators(_stakingEpoch).length;

            for (i = 0; i < validators.length; i++) {
                // Distribute the reward among validators and their stakers
                (
                    receivers,
                    rewards
                ) = _distributePoolReward(
                    _stakingEpoch,
                    validators[i],
                    i == 0 ? poolReward + remainder : poolReward
                );

                for (uint256 r = 0; r < receivers.length; r++) {
                    addressArrayStorage[DISTRIBUTE_TEMPORARY_ARRAY].push(receivers[r]);
                    uintArrayStorage[DISTRIBUTE_TEMPORARY_ARRAY].push(rewards[r]);
                }
            }

            receivers = addressArrayStorage[DISTRIBUTE_TEMPORARY_ARRAY];
            rewards = uintArrayStorage[DISTRIBUTE_TEMPORARY_ARRAY];

            delete addressArrayStorage[DISTRIBUTE_TEMPORARY_ARRAY];
            delete uintArrayStorage[DISTRIBUTE_TEMPORARY_ARRAY];

            return (receivers, rewards);
        }
    }

    bytes32 internal constant DISTRIBUTE_TEMPORARY_ARRAY = keccak256("distributeTemporaryArray");
    bytes32 internal constant REWARD_TEMPORARY_ARRAY = keccak256("rewardTemporaryArray");

}
